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
      rescue
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
        source = File.read(path)
        parent = source.match(/class\s+\S+\s*<\s*(\S+)/)&.send(:[], 1) || "Unknown"
        {
          parent_class: parent,
          api_controller: parent.include?("API"),
          actions: extract_actions_from_source(source),
          filters: extract_filters_from_source(source),
          concerns: extract_concerns_from_source(source),
          strong_params: extract_strong_params(source),
          respond_to_formats: extract_respond_to(source)
        }.compact
      rescue => e
        { error: e.message }
      end

      def extract_controller_details(ctrl)
        source = read_source(ctrl)

        {
          parent_class: ctrl.superclass.name,
          api_controller: api_controller?(ctrl),
          actions: extract_actions(ctrl, source),
          filters: extract_filters(ctrl, source),
          concerns: extract_concerns(ctrl),
          strong_params: extract_strong_params(source),
          respond_to_formats: extract_respond_to(source)
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
      rescue
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

          if (match = line.match(/\A\s*def\s+(\w+[?!]?)/))
            actions << match[1] unless match[1].start_with?("_")
          end
        end

        actions.sort
      end

      # Prefer source-based parsing for filters — always reflects current file state.
      # Falls back to reflection for controllers without readable source files.
      def extract_filters(ctrl, source = nil)
        if source
          filters = extract_filters_from_source(source)
          return filters if filters.any?
        end
        return [] unless ctrl.respond_to?(:_process_action_callbacks)

        ctrl._process_action_callbacks.filter_map do |cb|
          next if cb.filter.is_a?(Proc) || cb.filter.to_s.start_with?("_")
          next if excluded_filters.include?(cb.filter.to_s)

          filter = { name: cb.filter.to_s, kind: cb.kind.to_s }
          filter[:only] = cb.instance_variable_get(:@if)&.filter_map { |c| extract_action_condition(c) }&.flatten
          filter[:except] = cb.instance_variable_get(:@unless)&.filter_map { |c| extract_action_condition(c) }&.flatten
          filter.delete(:only) if filter[:only]&.empty?
          filter.delete(:except) if filter[:except]&.empty?
          filter
        end
      rescue
        []
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
      rescue
        []
      end

      def extract_concerns_from_source(source)
        source.scan(/^\s*include\s+(\w+(?:::\w+)*)/).flatten
      end

      def extract_strong_params(source)
        return [] if source.nil?

        source.scan(/def\s+(\w+_params)\b/).flatten.uniq
      end

      def extract_respond_to(source)
        return [] if source.nil?
        return [] unless source.match?(/respond_to\s+do/)

        source.scan(/format\.(\w+)/).flatten.uniq.sort
      end

      def read_source(ctrl)
        path = source_path(ctrl)
        return nil unless path && File.exist?(path)
        File.read(path)
      rescue
        nil
      end

      def source_path(ctrl)
        root = app.root.to_s
        underscored = ctrl.name.underscore
        File.join(root, "app", "controllers", "#{underscored}.rb")
      end
    end
  end
end
