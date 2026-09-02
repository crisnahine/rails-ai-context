# frozen_string_literal: true

require "json"

module RailsAiContext
  # Virtual File System - pattern-matched URI routing for MCP resources.
  # Each resolve call introspects fresh (zero stale data).
  module VFS
    SCHEME = "rails-ai-context"

    PATTERNS = [
      { pattern: %r{\Arails-ai-context://controllers/(.+)/([^/]+)\z}, handler: :resolve_controller_action },
      { pattern: %r{\Arails-ai-context://controllers/(.+)\z}, handler: :resolve_controller },
      { pattern: %r{\Arails-ai-context://models/(.+)\z}, handler: :resolve_model },
      { pattern: %r{\Arails-ai-context://views/(.+)\z}, handler: :resolve_view },
      { pattern: %r{\Arails-ai-context://routes/(.+)\z}, handler: :resolve_routes }
    ].freeze

    class << self
      # Resolve a rails-ai-context:// URI to MCP resource content.
      # Returns an array of content hashes: [{uri:, mimeType:, text:}].
      # Keys are MCP-spec camelCase because the MCP SDK serializes the
      # resources/read handler's return value into the JSON-RPC response
      # verbatim - a snake_case :mime_type key would reach clients unchanged.
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

        key = Tools::BaseTool.fuzzy_find_key(models.keys, name) || name
        data = models[key]

        unless data
          available = models.keys.sort.first(20)
          content = JSON.pretty_generate(error: "Model '#{name}' not found", available: available)
          return [ { uri: uri, mimeType: "application/json", text: content } ]
        end

        # Enrich with schema columns if available
        table_name = data[:table_name]
        schema = context.dig(:schema, :tables, table_name) if table_name
        enriched = data.merge(schema: schema).compact

        [ { uri: uri, mimeType: "application/json", text: JsonBudget.for_resource(enriched) } ]
      end

      def resolve_controller(uri, name)
        context = RailsAiContext.introspect
        controllers = context.dig(:controllers, :controllers) || {}
        key = find_controller(context, name)

        unless key
          available = controllers.keys.sort.first(20)
          content = JSON.pretty_generate(error: "Controller '#{name}' not found", available: available)
          return [ { uri: uri, mimeType: "application/json", text: content } ]
        end

        [ { uri: uri, mimeType: "application/json", text: JsonBudget.for_resource(controllers[key]) } ]
      end

      def resolve_controller_action(uri, controller_name, action_name)
        context = RailsAiContext.introspect
        controllers = context.dig(:controllers, :controllers) || {}

        # "admin/posts" is a namespaced controller unless "admin" is itself a
        # controller with a "posts" action.
        whole = find_controller(context, "#{controller_name}/#{action_name}")
        key = find_controller(context, controller_name)
        prefix_action = key && (controllers.dig(key, :actions) || []).any? { |a| a.to_s.casecmp?(action_name) }
        return resolve_controller(uri, "#{controller_name}/#{action_name}") if whole && !prefix_action

        unless key
          content = JSON.pretty_generate(error: "Controller '#{controller_name}' not found")
          return [ { uri: uri, mimeType: "application/json", text: content } ]
        end

        info = controllers[key]
        actions = info[:actions] || []
        action = actions.find { |a| a.to_s.casecmp?(action_name) }

        unless action
          content = JSON.pretty_generate(error: "Action '#{action_name}' not found in #{key}", available: actions)
          return [ { uri: uri, mimeType: "application/json", text: content } ]
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

        [ { uri: uri, mimeType: "application/json", text: JsonBudget.for_resource(action_data) } ]
      end

      def resolve_view(uri, path)
        root = RailsAiContext.default_app.root.to_s
        content, result = RailsAiContext::ViewFile.read(root, path)
        case result.refusal
        when :traversal, :outside then raise RailsAiContext::Error, "Path not allowed: #{path}"
        when :sensitive then raise RailsAiContext::Error, "Path not allowed: #{path} (sensitive file)"
        when :too_large
          text = JSON.pretty_generate(error: "File too large: #{path}")
          return [ { uri: uri, mimeType: "application/json", text: text } ]
        when :missing
          text = JSON.pretty_generate(error: "View not found: #{path}. Paths are relative to app/views; the extension is optional (posts/index and posts/index.html.erb both resolve).")
          return [ { uri: uri, mimeType: "application/json", text: text } ]
        end

        mime = result.relative.end_with?(".rb") ? "text/x-ruby" : "text/html"
        [ { uri: uri, mimeType: mime, text: content.to_s } ]
      end

      def resolve_routes(uri, controller)
        context = RailsAiContext.introspect
        routes_data = context[:routes] || {}

        # The route introspector groups routes as {controller_name => [entries]}
        # under :by_controller (there is no flat :routes list). Entries omit the
        # controller because it is the grouping key, so merge it back in to keep
        # each row self-describing in the flattened output. PUT/PATCH update
        # pairs merge into one PATCH|PUT entry so this resource reports the
        # same counts as the routes tool.
        by_controller = routes_data[:by_controller] || {}
        # A controller with no file derives a route key Rails never routed by,
        # so the caller's string is the filter when the exact key finds nothing.
        key = find_controller(context, controller)
        route_key = key && Payload.controller_route_key(context, key)
        names = by_controller.keys.map(&:to_s)
        selected = names.include?(route_key) ? [ route_key ] : names.select { |n| n.include?(controller) }
        routes = by_controller.flat_map { |name, entries|
          next [] unless selected.include?(name.to_s)

          Tools::BaseTool.dedupe_put_patch_routes(Array(entries)).map { |entry| entry.merge(controller: name.to_s) }
        }

        data = { filtered_by: controller, total_routes: routes.size, routes: routes }

        [ { uri: uri, mimeType: "application/json", text: JsonBudget.for_resource(data) } ]
      end

      # "posts", "PostsController", "admin/posts", "Admin::PostsController",
      # and a route key whose declared constant does not camelize from it.
      def find_controller(ctx, input)
        controllers = ctx.dig(:controllers, :controllers) || {}
        by_route = Payload.controller_for_route_key(ctx, input.to_s.delete_suffix("_controller"))
        return by_route.first if by_route

        Tools::BaseTool.fuzzy_find_key(controllers.keys, input) ||
          Tools::BaseTool.fuzzy_find_key(controllers.keys, "#{input}Controller") ||
          Tools::BaseTool.fuzzy_find_key(controllers.keys, "#{input.to_s.camelize}Controller")
      end
    end
  end
end
