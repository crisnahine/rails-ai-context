# frozen_string_literal: true

module RailsAiContext
  module Introspectors
    # Extracts ActiveSupport runtime surface that other introspectors don't
    # cover: Concerns registry (`app/**/concerns`), Deprecators registry,
    # MessageEncryptor/MessageVerifier usage, and TaggedLogging tags.
    # Covers RAILS_NERVOUS_SYSTEM.md §17 (ActiveSupport).
    class ActiveSupportIntrospector < Base
      extend StaticTier
      static_tier :alternate_source

      def call
        {
          concerns: extract_concerns,
          deprecators: extract_deprecators,
          message_verifier_usage: extract_message_verifier_usage,
          notification_subscriptions: scan_sources[:notification_subscriptions],
          tagged_logging: detect_tagged_logging,
          on_load_hooks: common_on_load_hooks,
          cache_usage: detect_cache_usage
        }
      end

      # Concerns, MessageVerifier usage and tagged logging are read off disk.
      # The registered deprecators, the subscribed load hooks and the cache
      # store only exist in a running process; an empty list for them renders
      # as "this app has none", so they refuse instead.
      def static_call
        unavailable = { unavailable: StaticTier.unavailable_reason }
        {
          concerns: extract_concerns,
          deprecators: unavailable,
          message_verifier_usage: extract_message_verifier_usage,
          notification_subscriptions: scan_sources[:notification_subscriptions],
          tagged_logging: detect_tagged_logging(static: true),
          on_load_hooks: unavailable,
          cache_usage: unavailable
        }
      end

      private

      # Keyed by directory, each concerns directory then each autoload root holding a
      # concern outside them, so every entry says where it lives.
      def extract_concerns
        result = {}
        lookup = SuperclassChain.lookup_for(root)
        sources = ConcernPaths.resolve(root).map { |dir| [ dir, Dir.glob(File.join(dir, "**/*.rb")).sort ] } +
                  ConcernPaths.outside(root).group_by(&:root_dir).map { |dir, entries| [ dir, entries.map(&:path) ] }
        sources.each do |dir, paths|
          rel_dir = dir.sub("#{root}/", "")

          modules = paths.filter_map do |path|
            content = RailsAiContext::SafeFile.read(path) or next
            # The constant the file declares, as rails_get_concern names it: Edition::Featurable
            # and Featurable are two modules the basename would print alike.
            mod_name = ConcernPaths.name_for(path, dir, content)
            next if RailsAiContext::ConcernMembership.excluded?(mod_name)

            ast = SourceIntrospector.walk(path, {
              concern_macros: -> { Listeners::GenericMacroListener.new(:included, :class_methods) }
            })
            hits = ast[:concern_macros]

            entry = { name: mod_name, file: path.sub("#{root}/", "") }
            # An app/models/concerns directory holds classes too - every
            # validator in some apps - and a class is not a concern, let
            # alone a "plain module".
            declarations = DeclaredConstant.declarations(content)
            declared = declarations.find { |d| d.name.split("::").last.casecmp?(mod_name.split("::").last) }
            if declared
              entry[:kind] = "class"
              entry[:superclass] = declared.superclass
            end
            validator = SuperclassChain.validator_base(content, name: mod_name, lookup: lookup)
            entry[:validator] = validator if validator
            entry[:uses_active_support_concern] = true if content.include?("ActiveSupport::Concern")
            entry[:included_blocks] = hits.count { |h| h[:macro] == :included }
            entry[:class_methods_block] = hits.any? { |h| h[:macro] == :class_methods }
            entry
          end
          result[rel_dir] = Array(result[rel_dir]) + modules if modules.any?
        end
        result
      rescue => e
        RailsAiContext.debug_fail(e, {}, label: "extract_concerns")
      end

      # Rails 7.1+ registers deprecators per gem/component via
      # `Rails.application.deprecators`. Return the registered keys.
      def extract_deprecators
        return [] unless app.respond_to?(:deprecators)
        registry = app.deprecators
        return [] unless registry

        keys = if registry.respond_to?(:each) && registry.respond_to?(:map)
          registry.map { |name, _d| name.to_s }
        elsif registry.instance_variable_defined?(:@deprecators)
          (registry.instance_variable_get(:@deprecators) || {}).keys.map(&:to_s)
        else
          []
        end
        keys.compact.sort.uniq
      rescue => e
        RailsAiContext.debug_fail(e, [], label: "extract_deprecators")
      end

      def extract_message_verifier_usage
        scan_sources[:message_verifier_usage]
      end

      SUBSCRIBE_CALLS = %w[subscribe monotonic_subscribe].freeze
      # Prefilter: only the receivers subscriptions_from keeps, so a newsletter `subscribe` is not parsed.
      SUBSCRIPTION_HINT = /Notifications\s*&?\.\s*(?:monotonic_)?subscribe\b|\battach_to\b/
      VERIFIER_HINTS = %w[MessageEncryptor MessageVerifier message_verifier ActiveStorage.verifier].freeze
      VERIFIER_CALLS = %w[message_verifier message_verifiers verifier].freeze

      # One read of lib/, app/ and the initializers serves both lists; a file that
      # mentions either is walked once, for both.
      def scan_sources
        @scan_sources ||= begin
          verifier = []
          subscriptions = []
          source_paths.each do |path|
            content = RailsAiContext::SafeFile.read(path) or next
            relative = path.sub("#{root}/", "")
            verifies = VERIFIER_HINTS.any? { |hint| content.include?(hint) } && !relative.start_with?("config/")
            subscribes = (content.include?("subscribe") || content.include?("attach_to")) && content.match?(SUBSCRIPTION_HINT)
            next unless verifies || subscribes

            walked = walk_usage(content, verifies: verifies, subscribes: subscribes) or next
            usage = verifier_usage(walked)
            verifier << { file: relative, **usage } if usage.values.any?
            subscriptions.concat(subscriptions_from(walked, relative))
          end
          { message_verifier_usage: verifier, notification_subscriptions: subscriptions.sort_by { |s| [ s[:file], s[:line], s[:event] ] } }
        end
      rescue => e
        RailsAiContext.debug_fail(e, { message_verifier_usage: [], notification_subscriptions: [] }, label: "scan_sources")
      end

      # Sort before slicing - Dir.glob ordering is filesystem-dependent and
      # would produce non-deterministic output on large monorepos.
      def source_paths
        paths = %w[lib app].flat_map do |rel|
          dir = File.join(root, rel)
          Dir.exist?(dir) ? Dir.glob(File.join(dir, "**/*.rb")).sort.first(2000) : []
        end
        paths + PathResolver.initializer_paths(root)
      end

      def walk_usage(content, verifies:, subscribes:)
        listeners = {}
        if verifies
          listeners[:constants] = -> { Listeners::ConstantReferenceListener.new(names: %w[MessageVerifier MessageEncryptor]) }
          listeners[:verifier_calls] = -> { Listeners::MethodCallListener.new(names: VERIFIER_CALLS) }
        end
        if subscribes
          listeners[:calls] = -> { Listeners::MethodCallListener.new(names: SUBSCRIBE_CALLS + %w[attach_to]) }
          listeners[:methods] = Listeners::MethodsListener
        end
        SourceIntrospector.walk_source(content, listeners)
      rescue StandardError, ScriptError => e
        RailsAiContext.debug_fail(e, nil, label: "active_support usage walk")
      end

      # The class itself, Rails.application.message_verifier(s) or ActiveStorage.verifier.
      def verifier_usage(walked)
        constants = Array(walked[:constants]).map { |ref| ref[:name] }
        calls = Array(walked[:verifier_calls]).select do |call|
          call[:name] != "verifier" || call[:receiver].to_s.match?(/(\A|::)ActiveStorage\z/)
        end
        { encryptor: constants.include?("MessageEncryptor"), verifier: constants.include?("MessageVerifier") || calls.any? }
      end

      # A Subscriber's attach_to listens for "<public method>.<namespace>", one event per method.
      def subscriptions_from(walked, relative)
        Array(walked[:calls]).flat_map do |call|
          if call[:name] == "attach_to"
            attach_to_events(call, walked[:methods], relative)
          elsif call[:receiver].to_s.match?(/(\A|::)Notifications\z/)
            pattern = call[:arguments].first
            event = pattern.nil? ? "every event" : pattern.to_s
            [ { event: event, via: call[:name], file: relative, line: call[:line] } ]
          else
            []
          end
        end
      end

      def attach_to_events(call, methods, relative)
        namespace = call[:arguments].first
        return [] unless namespace.is_a?(Symbol) || namespace.is_a?(String)

        receiver = call[:receiver]&.to_s
        owner = receiver.nil? || receiver == "self" ? owner_at(methods, call) : receiver
        short = owner.to_s.split("::").last
        names = Array(methods).select { |m| m[:scope] == :instance && m[:visibility] == :public && m[:owner]&.last.to_s.split("::").last == short }.map { |m| m[:name] }
        via = [ owner, "attach_to" ].compact.join(".")
        events = names.empty? ? [ "every public method of #{owner || "the subscriber"}, as <method>.#{namespace}" ] : names.map { |name| "#{name}.#{namespace}" }
        events.map { |event| { event: event, via: via, file: relative, line: call[:line] } }
      end

      # attach_to sits in the class body above the defs it attaches, so the next def names the class.
      def owner_at(methods, call)
        defs = Array(methods).select { |m| m[:offset] && m[:owner]&.any? }.sort_by { |m| m[:offset] }
        (defs.find { |m| m[:offset] > call[:offset] } || defs.last)&.dig(:owner)&.last
      end

      # config.log_tags is evaluated at boot, so a static run reads only the initializer.
      def detect_tagged_logging(static: false)
        result = { configured: false }
        if static
          result[:tags] = { unavailable: StaticTier.unavailable_reason }
        elsif (config_logger = app.config.log_tags).is_a?(Array) && config_logger.any?
          result[:configured] = true
          result[:tags] = config_logger.map(&:to_s)
        end

        # Initializer pattern: Rails.logger = ActiveSupport::TaggedLogging.new(…)
        PathResolver.initializer_paths(root).each do |path|
          content = RailsAiContext::SafeFile.read(path) or next
          if content.include?("ActiveSupport::TaggedLogging")
            result[:configured] = true
            result[:initializer] = path.sub("#{root}/", "")
            break
          end
        end
        result
      rescue => e
        RailsAiContext.debug_fail(e, { configured: false }, label: "detect_tagged_logging")
      end

      # The canonical lazy hooks that Railties expose. Report which have at
      # least one subscriber attached so AI can reason about load-order.
      COMMON_HOOKS = %i[
        active_record before_initialize after_initialize
        action_controller action_controller_base action_controller_api
        action_view action_mailer active_job active_storage
        action_cable action_text action_mailbox
      ].freeze

      def common_on_load_hooks
        return [] unless defined?(ActiveSupport) && ActiveSupport.respond_to?(:on_load)
        registry = ActiveSupport.instance_variable_get(:@load_hooks)
        return [] unless registry.respond_to?(:each_key)

        registry.each_key.filter_map do |name|
          next unless COMMON_HOOKS.include?(name)
          callbacks = registry[name]
          callback_count = callbacks.respond_to?(:size) ? callbacks.size : 0
          { hook: name.to_s, callbacks: callback_count } if callback_count > 0
        end.sort_by { |h| h[:hook] }
      rescue => e
        RailsAiContext.debug_fail(e, [], label: "common_on_load_hooks")
      end

      def detect_cache_usage
        store = app.config.cache_store
        entry = {
          store: store.is_a?(Array) ? store.first.to_s : store.to_s
        }
        if store.is_a?(Array) && store.last.is_a?(Hash)
          entry[:options] = store.last.keys.map(&:to_s)
        end
        entry
      rescue => e
        RailsAiContext.debug_fail(e, {}, label: "detect_cache_usage")
      end
    end
  end
end
