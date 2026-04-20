# frozen_string_literal: true

module RailsAiContext
  module Introspectors
    # Extracts ActiveSupport runtime surface that other introspectors don't
    # cover: Concerns registry (`app/**/concerns`), Deprecators registry,
    # MessageEncryptor/MessageVerifier usage, and TaggedLogging tags.
    # Covers RAILS_NERVOUS_SYSTEM.md §17 (ActiveSupport).
    class ActiveSupportIntrospector
      attr_reader :app

      def initialize(app)
        @app = app
      end

      def call
        {
          concerns: extract_concerns,
          deprecators: extract_deprecators,
          message_verifier_usage: extract_message_verifier_usage,
          tagged_logging: detect_tagged_logging,
          on_load_hooks: common_on_load_hooks,
          cache_usage: detect_cache_usage
        }
      rescue => e
        $stderr.puts "[rails-ai-context] ActiveSupportIntrospector#call failed: #{e.message}" if ENV["DEBUG"]
        { error: e.message }
      end

      private

      def root
        app.root.to_s
      end

      CONCERN_DIRS = %w[
        app/models/concerns
        app/controllers/concerns
        app/jobs/concerns
        app/mailers/concerns
        app/channels/concerns
      ].freeze

      def extract_concerns
        result = {}
        CONCERN_DIRS.each do |rel_dir|
          dir = File.join(root, rel_dir)
          next unless Dir.exist?(dir)

          modules = Dir.glob(File.join(dir, "**/*.rb")).sort.filter_map do |path|
            content = RailsAiContext::SafeFile.read(path) or next
            mod_name = File.basename(path, ".rb").camelize
            entry = { name: mod_name, file: path.sub("#{root}/", "") }
            entry[:uses_active_support_concern] = true if content.include?("ActiveSupport::Concern")
            entry[:included_blocks] = content.scan(/^\s*included\s+do\b/).size
            entry[:class_methods_block] = content.include?("class_methods do")
            entry
          end
          result[rel_dir] = modules if modules.any?
        end
        result
      rescue => e
        $stderr.puts "[rails-ai-context] extract_concerns failed: #{e.message}" if ENV["DEBUG"]
        {}
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
        $stderr.puts "[rails-ai-context] extract_deprecators failed: #{e.message}" if ENV["DEBUG"]
        []
      end

      # Scan `lib/` + `app/` for calls into ActiveSupport::MessageEncryptor and
      # ActiveSupport::MessageVerifier. Used for tokens, signed IDs, etc.
      def extract_message_verifier_usage
        hits = []
        %w[lib app].each do |rel|
          dir = File.join(root, rel)
          next unless Dir.exist?(dir)

          # Sort before slicing — Dir.glob ordering is filesystem-dependent
          # and would produce non-deterministic output on large monorepos.
          Dir.glob(File.join(dir, "**/*.rb")).sort.first(2000).each do |path|
            content = RailsAiContext::SafeFile.read(path) or next
            next unless content.match?(/MessageEncryptor|MessageVerifier/)
            relative = path.sub("#{root}/", "")
            hits << { file: relative, encryptor: content.include?("MessageEncryptor"), verifier: content.include?("MessageVerifier") }
          end
        end
        hits
      rescue => e
        $stderr.puts "[rails-ai-context] extract_message_verifier_usage failed: #{e.message}" if ENV["DEBUG"]
        []
      end

      def detect_tagged_logging
        result = { configured: false }
        config_logger = app.config.log_tags
        if config_logger.is_a?(Array) && config_logger.any?
          result[:configured] = true
          result[:tags] = config_logger.map(&:to_s)
        end

        # Initializer pattern: Rails.logger = ActiveSupport::TaggedLogging.new(…)
        Dir.glob(File.join(root, "config/initializers/*.rb")).each do |path|
          content = RailsAiContext::SafeFile.read(path) or next
          if content.include?("ActiveSupport::TaggedLogging")
            result[:configured] = true
            result[:initializer] = path.sub("#{root}/", "")
            break
          end
        end
        result
      rescue => e
        $stderr.puts "[rails-ai-context] detect_tagged_logging failed: #{e.message}" if ENV["DEBUG"]
        { configured: false }
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
        $stderr.puts "[rails-ai-context] common_on_load_hooks failed: #{e.message}" if ENV["DEBUG"]
        []
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
        $stderr.puts "[rails-ai-context] detect_cache_usage failed: #{e.message}" if ENV["DEBUG"]
        {}
      end
    end
  end
end
