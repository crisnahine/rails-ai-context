# frozen_string_literal: true

module RailsAiContext
  module Introspectors
    # Discovers controllers and extracts filters, strong params,
    # respond_to formats, concerns, actions, and API detection.
    # Uses source-file parsing (not just Ruby reflection) so that
    # changes made mid-session are always visible.
    class ControllerIntrospector
      attr_reader :app

      def excluded_filters
        RailsAiContext.configuration.excluded_filters
      end

      def initialize(app)
        @app = app
      end

      def call
        eager_load_controllers!
        controllers = discover_controllers

        result = controllers.each_with_object({}) do |ctrl, hash|
          hash[ctrl.name] = extract_controller_details(ctrl)
        rescue => e
          hash[ctrl.name] = { error: e.message }
        end

        # Discover controllers from filesystem that may not be loaded as classes
        discover_from_filesystem.each do |name, path|
          next if result.key?(name)
          result[name] = extract_details_from_source(path)
        end

        { controllers: result }
      rescue => e
        { error: e.message }
      end

      private

      def eager_load_controllers!
        return if Rails.application.config.eager_load

        # Use targeted eager_load_dir to pick up newly created controller files
        controllers_path = File.join(app.root, "app", "controllers")
        if defined?(Zeitwerk) && Dir.exist?(controllers_path) &&
           Rails.autoloaders.respond_to?(:main) && Rails.autoloaders.main.respond_to?(:eager_load_dir)
          Rails.autoloaders.main.eager_load_dir(controllers_path)
        else
          Rails.application.eager_load!
        end
      rescue => e
        $stderr.puts "[rails-ai-context] eager_load_controllers! failed: #{e.message}" if ENV["DEBUG"]
        nil
      end

      def discover_controllers
        return [] unless defined?(ActionController::Base)

        bases = [ ActionController::Base ]
        bases << ActionController::API if defined?(ActionController::API)

        bases.flat_map(&:descendants).reject do |ctrl|
          ctrl.name.nil? || ctrl.name == "ApplicationController" ||
            ctrl.name.start_with?("Rails::", "ActionMailbox::", "ActiveStorage::")
        end.uniq.sort_by(&:name)
      end

      # Scan filesystem for controller files not yet loaded as classes
      def discover_from_filesystem
        controllers_dir = File.join(app.root, "app", "controllers")
        return {} unless Dir.exist?(controllers_dir)

        Dir.glob(File.join(controllers_dir, "**/*_controller.rb")).each_with_object({}) do |path, hash|
          relative = path.sub("#{controllers_dir}/", "")
          class_name = relative.sub(/\.rb\z/, "").split("/").map(&:camelize).join("::")
          next if class_name == "ApplicationController"
          next if class_name.start_with?("Rails::", "ActionMailbox::", "ActiveStorage::")
          hash[class_name] = path
        end
      end

      # Extract details purely from source file (for controllers not loaded as classes)
      def extract_details_from_source(path)
        source = RailsAiContext::SafeFile.read(path)
        return { error: "unreadable" } unless source
        parent = source.match(/class\s+\S+\s*<\s*(\S+)/)&.send(:[], 1) || "Unknown"
        rate_limit_raw = extract_rate_limit(source)
        details = {
          parent_class: parent,
          api_controller: parent.include?("API"),
          actions: extract_actions_from_source(source),
          filters: extract_filters_from_source(source),
          concerns: extract_concerns_from_source(source),
          strong_params: extract_strong_params(source),
          respond_to_formats: extract_respond_to(source),
          rescue_from: extract_rescue_from(source),
          rate_limit: rate_limit_raw,
          rate_limit_parsed: parse_rate_limit(rate_limit_raw),
          turbo_stream_actions: extract_turbo_stream_actions(source)
        }.compact
        details
      rescue => e
        { error: e.message }
      end

      def extract_controller_details(ctrl)
        source = read_source(ctrl)
        rate_limit_raw = extract_rate_limit(source)

        {
          parent_class: ctrl.superclass.name,
          api_controller: api_controller?(ctrl),
          actions: extract_actions(ctrl, source),
          filters: extract_filters(ctrl, source),
          concerns: extract_concerns(ctrl),
          strong_params: extract_strong_params(source),
          respond_to_formats: extract_respond_to(source),
          rescue_from: extract_rescue_from(source),
          rate_limit: rate_limit_raw,
          rate_limit_parsed: parse_rate_limit(rate_limit_raw),
          turbo_stream_actions: extract_turbo_stream_actions(source)
        }.compact
      end

      def api_controller?(ctrl)
        return true if defined?(ActionController::API) && ctrl.ancestors.include?(ActionController::API)
        false
      end

      # Prefer source-based parsing for actions — always reflects current file state.
      # Falls back to reflection for controllers without readable source files.
      def extract_actions(ctrl, source = nil)
        if source
          actions = extract_actions_from_source(source)
          return actions if actions.any?
        end
        ctrl.action_methods.to_a.sort
      rescue => e
        $stderr.puts "[rails-ai-context] extract_actions failed: #{e.message}" if ENV["DEBUG"]
        []
      end

      def extract_actions_from_source(source)
        in_private = false
        actions = []

        source.each_line do |line|
          if line.match?(/\A\s*(private|protected)\s*$/)
            in_private = true
          elsif line.match?(/\A\s*public\s*$/)
            in_private = false
          end

          next if in_private

          # Skip inline private/protected method definitions (e.g. `private def foo`)
          next if line.match?(/\A\s*(?:private|protected)\s+def\s/)

          if (match = line.match(/\A\s*def\s+(\w+[?!]?)/))
            actions << match[1] unless match[1].start_with?("_")
          end
        end

        actions.sort
      end

      # Hybrid approach: reflection for complete filter names (handles inheritance + skips),
      # source parsing from inheritance chain for only/except constraints.
      def extract_filters(ctrl, source = nil)
        if ctrl.respond_to?(:_process_action_callbacks)
          reflection_filters = ctrl._process_action_callbacks.filter_map do |cb|
            next if cb.filter.is_a?(Proc) || cb.filter.to_s.start_with?("_")
            next if excluded_filters.include?(cb.filter.to_s)
            { name: cb.filter.to_s, kind: cb.kind.to_s }
          end

          if reflection_filters.any?
            # Collect only/except constraints from source files in the inheritance chain
            source_constraints = collect_source_constraints(ctrl, source)
            reflection_filters.each do |f|
              if (sc = source_constraints[f[:name]])
                f[:only] = sc[:only] if sc[:only]&.any?
                f[:except] = sc[:except] if sc[:except]&.any?
                f[:unless] = sc[:unless] if sc[:unless]
                f[:if] = sc[:if] if sc[:if]
              end
            end

            # Evaluate known runtime conditions to remove inapplicable filters
            reflection_filters.reject! { |f| filter_excluded_by_condition?(ctrl, f) }

            return reflection_filters
          end
        end

        # Fallback to source parsing when reflection is unavailable
        if source
          filters = extract_filters_from_source(source)
          return filters if filters.any?
        end

        []
      rescue => e
        $stderr.puts "[rails-ai-context] extract_filters failed: #{e.message}" if ENV["DEBUG"]
        []
      end

      # Walk up the controller inheritance chain and collect filter constraints from source files
      def collect_source_constraints(ctrl, current_source = nil)
        constraints = {}
        klass = ctrl
        while klass && klass.name
          break if klass.name.start_with?("ActionController::", "AbstractController::")
          break if klass == ActionController::Base
          break if defined?(ActionController::API) && klass == ActionController::API

          src = (klass == ctrl) ? (current_source || read_source(klass)) : read_source(klass)
          if src
            extract_filters_from_source(src).each do |sf|
              # First definition wins (most specific controller in chain)
              constraints[sf[:name]] ||= sf
            end
          end
          klass = klass.superclass
        end
        constraints
      rescue => e
        $stderr.puts "[rails-ai-context] collect_source_constraints failed: #{e.message}" if ENV["DEBUG"]
        {}
      end

      def extract_filters_from_source(source)
        filters = []
        source.each_line do |line|
          next unless (match = line.match(
            /\A\s*(before_action|after_action|around_action|prepend_before_action|append_before_action)\s+:(\w+[?!]?)/
          ))

          kind = match[1].sub(/_action\z/, "").sub(/\A(?:prepend|append)_/, "")
          filter = { name: match[2], kind: kind }

          only = parse_action_constraint(line, "only")
          except = parse_action_constraint(line, "except")
          filter[:only] = only if only&.any?
          filter[:except] = except if except&.any?

          # Extract conditional modifiers (unless:, if:)
          if (unless_match = line.match(/unless:\s*:(\w+[?!]?)/))
            filter[:unless] = unless_match[1]
          end
          if (if_match = line.match(/\bif:\s*:(\w+[?!]?)/))
            filter[:if] = if_match[1]
          end

          filters << filter
        end
        filters
      end

      def parse_action_constraint(line, key)
        return nil unless line.include?("#{key}:")

        # %i[...] or %w[...] format
        if (match = line.match(/#{key}:\s*%[iwIW]\[([^\]]+)\]/))
          return match[1].split(/\s+/)
        end

        # [...] format with symbols
        if (match = line.match(/#{key}:\s*\[([^\]]+)\]/))
          return match[1].scan(/:(\w+[?!]?)/).flatten
        end

        # Single symbol format
        if (match = line.match(/#{key}:\s*:(\w+[?!]?)/))
          return [ match[1] ]
        end

        nil
      end

      # Statically evaluate known runtime conditions to exclude inapplicable filters.
      # e.g., `unless: :devise_controller?` on a Devise controller means the filter doesn't apply.
      def filter_excluded_by_condition?(ctrl, filter)
        # unless: :devise_controller? — filter does NOT apply to Devise controllers
        if filter[:unless] == "devise_controller?"
          return true if devise_controller?(ctrl)
        end

        # if: :devise_controller? — filter ONLY applies to Devise controllers
        if filter[:if] == "devise_controller?"
          return true unless devise_controller?(ctrl)
        end

        false
      end

      def devise_controller?(ctrl)
        return false unless defined?(::DeviseController)
        ctrl < ::DeviseController || ctrl.ancestors.any? { |a| a.name&.start_with?("Devise::") }
      rescue => e
        $stderr.puts "[rails-ai-context] devise_controller? failed: #{e.message}" if ENV["DEBUG"]
        false
      end

      def extract_action_condition(condition)
        return nil unless condition.is_a?(String) || condition.respond_to?(:to_s)
        match = condition.to_s.match(/action_name\s*==\s*['"](\w+)['"]/)
        match ? [ match[1] ] : nil
      end

      def extract_concerns(ctrl)
        ctrl.ancestors
          .select { |mod| mod.is_a?(Module) && !mod.is_a?(Class) }
          .reject { |mod| mod.name&.start_with?("ActionController", "ActionDispatch", "ActiveSupport", "AbstractController") }
          .map(&:name)
          .compact
      rescue => e
        $stderr.puts "[rails-ai-context] extract_concerns failed: #{e.message}" if ENV["DEBUG"]
        []
      end

      def extract_concerns_from_source(source)
        source.scan(/^\s*include\s+(\w+(?:::\w+)*)/).flatten
      end

      def extract_strong_params(source)
        return [] if source.nil?

        method_names = source.scan(/def\s+(\w+_params)\b/).flatten.uniq
        method_names.map { |name| extract_permit_details(source, name) }
      end

      def extract_permit_details(source, method_name)
        result = { name: method_name }
        body = extract_method_body(source, method_name)
        return result unless body

        # Detect params.permit! (unrestricted)
        if body.match?(/params\s*\.permit!/)
          result[:unrestricted] = true
          return result
        end

        # Extract require(:model)
        if (req = body.match(/params\s*\.require\(\s*:(\w+)\s*\)/))
          result[:requires] = req[1]
        end

        # Extract permit(...) — join multi-line into single string
        permit_match = body.match(/\.permit\((.*)\)/m)
        return result unless permit_match

        permit_body = permit_match[1].gsub(/\s*\n\s*/, " ").strip
        result.merge(parse_permit_args(permit_body))
      end

      def extract_method_body(source, method_name)
        lines = source.lines
        start_idx = lines.index { |l| l.match?(/\bdef\s+#{Regexp.escape(method_name)}\b/) }
        return nil unless start_idx

        indent = lines[start_idx].match(/^(\s*)/)[1].length
        body_lines = [ lines[start_idx] ]

        (start_idx + 1...lines.size).each do |i|
          body_lines << lines[i]
          break if lines[i].match?(/^\s{#{indent}}end\b/)
        end

        body_lines.join
      end

      def parse_permit_args(permit_body)
        permits = []
        nested = {}
        arrays = []

        # Tokenize: split on commas but respect nested brackets
        tokens = split_permit_tokens(permit_body)

        tokens.each do |token|
          token = token.strip
          if (m = token.match(/\A:(\w+)\s*=>\s*\[([^\]]*)\]\z/))
            # Hash rocket nested: :address => [:street, :city]
            key = m[1]
            vals = m[2].scan(/:(\w+)/).flatten
            if vals.any?
              nested[key] = vals
            else
              arrays << key
            end
          elsif (m = token.match(/\A(\w+):\s*\[([^\]]*)\]\z/))
            # Ruby keyword nested: address: [:street, :city]
            key = m[1]
            vals = m[2].scan(/:(\w+)/).flatten
            if vals.any?
              nested[key] = vals
            else
              arrays << key
            end
          elsif (m = token.match(/\A:(\w+)\z/))
            permits << m[1]
          end
        end

        result = {}
        result[:permits] = permits if permits.any?
        result[:nested] = nested if nested.any?
        result[:arrays] = arrays if arrays.any?
        result
      end

      def split_permit_tokens(str)
        tokens = []
        current = +""
        depth = 0

        str.each_char do |ch|
          case ch
          when "[" then depth += 1; current << ch
          when "]" then depth -= 1; current << ch
          when ","
            if depth == 0
              tokens << current
              current = +""
            else
              current << ch
            end
          else
            current << ch
          end
        end

        tokens << current unless current.strip.empty?
        tokens
      end

      def extract_respond_to(source)
        return [] if source.nil?
        return [] unless source.match?(/respond_to\s+do/)

        source.scan(/format\.(\w+)/).flatten.uniq.sort
      end

      def extract_rescue_from(source)
        return [] if source.nil?

        source.each_line.filter_map do |line|
          next unless (match = line.match(/\A\s*rescue_from\s+(.+)/))
          rest = match[1]
          # Extract exception class(es) and handler
          exception_part = rest.split(/,\s*with:/).first&.strip
          handler_match = rest.match(/with:\s*:(\w+[?!]?)/)
          handler = handler_match ? handler_match[1] : nil

          exceptions = exception_part&.scan(/([A-Z][\w:]+)/)&.flatten || []
          exceptions.map { |ex| { exception: ex, handler: handler }.compact }
        end.flatten
      rescue => e
        $stderr.puts "[rails-ai-context] extract_rescue_from failed: #{e.message}" if ENV["DEBUG"]
        []
      end

      def extract_rate_limit(source)
        return nil if source.nil?

        match = source.match(/^\s*rate_limit\s+(.+)$/)
        return nil unless match

        match[1].strip
      rescue => e
        $stderr.puts "[rails-ai-context] extract_rate_limit failed: #{e.message}" if ENV["DEBUG"]
        nil
      end

      def parse_rate_limit(rate_limit_raw)
        return nil if rate_limit_raw.nil?

        parsed = {}
        parsed[:to] = $1.to_i if rate_limit_raw.match(/to:\s*(\d+)/)
        parsed[:within] = $1 if rate_limit_raw.match(/within:\s*(\S+)/)
        parsed[:only] = $1.scan(/:(\w+)/).flatten if rate_limit_raw.match(/only:\s*(.+?)(?:,\s*\w+:|$)/)

        parsed.empty? ? nil : parsed
      rescue => e
        $stderr.puts "[rails-ai-context] parse_rate_limit failed: #{e.message}" if ENV["DEBUG"]
        nil
      end

      def extract_turbo_stream_actions(source)
        return [] if source.nil?
        return [] unless source.match?(/format\.turbo_stream|\.turbo_stream\.erb/)

        actions = []
        current_action = nil
        source.each_line do |line|
          if (action_match = line.match(/\A\s*def\s+(\w+)/))
            current_action = action_match[1]
          end
          if current_action && line.match?(/format\.turbo_stream/)
            actions << current_action
            current_action = nil # avoid duplicates within same action
          end
        end
        actions.uniq.sort
      rescue => e
        $stderr.puts "[rails-ai-context] extract_turbo_stream_actions failed: #{e.message}" if ENV["DEBUG"]
        []
      end

      def read_source(ctrl)
        path = source_path(ctrl)
        return nil unless path && File.exist?(path)
        RailsAiContext::SafeFile.read(path)
      end

      def source_path(ctrl)
        root = app.root.to_s
        underscored = ctrl.name.underscore
        File.join(root, "app", "controllers", "#{underscored}.rb")
      end
    end
  end
end
