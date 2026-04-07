# frozen_string_literal: true

require "json"

module RailsAiContext
  # Virtual File System — pattern-matched URI routing for MCP resources.
  # Each resolve call introspects fresh (zero stale data).
  module VFS
    SCHEME = "rails-ai-context"

    PATTERNS = [
      { pattern: %r{\Arails-ai-context://controllers/([^/]+)/([^/]+)\z}, handler: :resolve_controller_action },
      { pattern: %r{\Arails-ai-context://controllers/([^/]+)\z}, handler: :resolve_controller },
      { pattern: %r{\Arails-ai-context://models/(.+)\z}, handler: :resolve_model },
      { pattern: %r{\Arails-ai-context://views/(.+)\z}, handler: :resolve_view },
      { pattern: %r{\Arails-ai-context://routes/(.+)\z}, handler: :resolve_routes }
    ].freeze

    class << self
      # Resolve a rails-ai-context:// URI to MCP resource content.
      # Returns an array of content hashes: [{uri:, mime_type:, text:}]
      def resolve(uri)
        PATTERNS.each do |entry|
          match = uri.match(entry[:pattern])
          next unless match

          return send(entry[:handler], uri, *match.captures)
        end

        raise RailsAiContext::Error, "Unknown VFS URI: #{uri}"
      end

      private

      def resolve_model(uri, name)
        context = RailsAiContext.introspect
        models = context[:models] || {}

        # Case-insensitive lookup
        key = models.keys.find { |k| k.to_s.casecmp?(name) } || name
        data = models[key]

        unless data
          available = models.keys.sort.first(20)
          content = JSON.pretty_generate(error: "Model '#{name}' not found", available: available)
          return [ { uri: uri, mime_type: "application/json", text: content } ]
        end

        # Enrich with schema columns if available
        table_name = data[:table_name]
        schema = context.dig(:schema, :tables, table_name) if table_name
        enriched = data.merge(schema: schema).compact

        [ { uri: uri, mime_type: "application/json", text: JSON.pretty_generate(enriched) } ]
      end

      def resolve_controller(uri, name)
        context = RailsAiContext.introspect
        controllers = context.dig(:controllers, :controllers) || {}

        # Flexible matching: "posts", "PostsController", "postscontroller"
        input_snake = name.underscore.delete_suffix("_controller")
        key = controllers.keys.find { |k|
          k.underscore.delete_suffix("_controller") == input_snake ||
            k.downcase.delete_suffix("controller") == name.downcase.delete_suffix("controller")
        }

        unless key
          available = controllers.keys.sort.first(20)
          content = JSON.pretty_generate(error: "Controller '#{name}' not found", available: available)
          return [ { uri: uri, mime_type: "application/json", text: content } ]
        end

        [ { uri: uri, mime_type: "application/json", text: JSON.pretty_generate(controllers[key]) } ]
      end

      def resolve_controller_action(uri, controller_name, action_name)
        context = RailsAiContext.introspect
        controllers = context.dig(:controllers, :controllers) || {}

        input_snake = controller_name.underscore.delete_suffix("_controller")
        key = controllers.keys.find { |k|
          k.underscore.delete_suffix("_controller") == input_snake
        }

        unless key
          content = JSON.pretty_generate(error: "Controller '#{controller_name}' not found")
          return [ { uri: uri, mime_type: "application/json", text: content } ]
        end

        info = controllers[key]
        actions = info[:actions] || []
        action = actions.find { |a| a.to_s.casecmp?(action_name) }

        unless action
          content = JSON.pretty_generate(error: "Action '#{action_name}' not found in #{key}", available: actions)
          return [ { uri: uri, mime_type: "application/json", text: content } ]
        end

        # Build action-specific data
        action_data = {
          controller: key,
          action: action.to_s,
          filters: (info[:filters] || []).select { |f|
            if f[:only]&.any?
              f[:only].map(&:to_s).include?(action.to_s)
            elsif f[:except]&.any?
              !f[:except].map(&:to_s).include?(action.to_s)
            else
              true
            end
          },
          strong_params: info[:strong_params]
        }.compact

        [ { uri: uri, mime_type: "application/json", text: JSON.pretty_generate(action_data) } ]
      end

      def resolve_view(uri, path)
        # Block path traversal
        if path.include?("..") || path.start_with?("/")
          raise RailsAiContext::Error, "Path not allowed: #{path}"
        end

        views_dir = Rails.root.join("app", "views")
        full_path = views_dir.join(path)

        unless File.exist?(full_path)
          content = JSON.pretty_generate(error: "View not found: #{path}")
          return [ { uri: uri, mime_type: "application/json", text: content } ]
        end

        # Verify resolved path is still under views_dir
        unless File.realpath(full_path).start_with?(File.realpath(views_dir))
          raise RailsAiContext::Error, "Path not allowed: #{path}"
        end

        max_size = RailsAiContext.configuration.max_file_size
        if File.size(full_path) > max_size
          content = JSON.pretty_generate(error: "File too large: #{path} (#{File.size(full_path)} bytes)")
          return [ { uri: uri, mime_type: "application/json", text: content } ]
        end

        view_content = RailsAiContext::SafeFile.read(full_path) || ""
        mime = path.end_with?(".rb") ? "text/x-ruby" : "text/html"
        [ { uri: uri, mime_type: mime, text: view_content } ]
      end

      def resolve_routes(uri, controller)
        context = RailsAiContext.introspect
        routes_data = context[:routes] || {}

        filtered = (routes_data[:routes] || []).select { |r|
          r[:controller].to_s.include?(controller)
        }
        data = routes_data.merge(routes: filtered, filtered_by: controller)

        [ { uri: uri, mime_type: "application/json", text: JSON.pretty_generate(data) } ]
      end
    end
  end
end
