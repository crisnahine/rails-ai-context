# frozen_string_literal: true

require "mcp"

module RailsAiContext
  # Registers MCP resources and resource templates that expose
  # static introspection data AI clients can read directly.
  module Resources
    STATIC_RESOURCES = {
      "rails://schema" => {
        name: "Database Schema",
        description: "Full database schema including tables, columns, indexes, and foreign keys",
        mime_type: "application/json",
        key: :schema
      },
      "rails://routes" => {
        name: "Application Routes",
        description: "All routes with HTTP verbs, paths, and controller actions",
        mime_type: "application/json",
        key: :routes
      },
      "rails://conventions" => {
        name: "Conventions & Patterns",
        description: "Detected architecture patterns, conventions, and directory structure",
        mime_type: "application/json",
        key: :conventions
      },
      "rails://gems" => {
        name: "Notable Gems",
        description: "Gem dependencies categorized by function with explanations",
        mime_type: "application/json",
        key: :gems
      },
      "rails://controllers" => {
        name: "Controllers",
        description: "All controllers with actions, filters, strong params, and concerns",
        mime_type: "application/json",
        key: :controllers
      },
      "rails://config" => {
        name: "Application Config",
        description: "Application configuration including cache, sessions, middleware, and initializers",
        mime_type: "application/json",
        key: :config
      },
      "rails://tests" => {
        name: "Test Infrastructure",
        description: "Test framework, factories, fixtures, CI, and coverage configuration",
        mime_type: "application/json",
        key: :tests
      },
      "rails://migrations" => {
        name: "Migrations",
        description: "Migration history, pending migrations, and migration statistics",
        mime_type: "application/json",
        key: :migrations
      },
      "rails://engines" => {
        name: "Mounted Engines",
        description: "Mounted Rails engines and Rack apps with paths and descriptions",
        mime_type: "application/json",
        key: :engines
      }
    }.freeze

    MODEL_TEMPLATE = MCP::ResourceTemplate.new(
      uri_template: "rails://models/{name}",
      name: "Model Details",
      description: "Detailed information about a specific ActiveRecord model",
      mime_type: "application/json"
    ).freeze

    CONTROLLER_TEMPLATE = MCP::ResourceTemplate.new(
      uri_template: "rails-ai-context://controllers/{name}",
      name: "Controller Details",
      description: "Controller with actions, filters, strong params, and schema hints",
      mime_type: "application/json"
    ).freeze

    CONTROLLER_ACTION_TEMPLATE = MCP::ResourceTemplate.new(
      uri_template: "rails-ai-context://controllers/{name}/{action}",
      name: "Controller Action",
      description: "Source code and metadata for a specific controller action",
      mime_type: "application/json"
    ).freeze

    VIEW_TEMPLATE = MCP::ResourceTemplate.new(
      uri_template: "rails-ai-context://views/{path}",
      name: "View Template",
      description: "View template content for a specific path relative to app/views",
      mime_type: "text/html"
    ).freeze

    ROUTES_TEMPLATE = MCP::ResourceTemplate.new(
      uri_template: "rails-ai-context://routes/{controller}",
      name: "Live Routes",
      description: "Application routes introspected fresh on each request, optionally filtered by controller name",
      mime_type: "application/json"
    ).freeze

    class << self
      def static_resources
        STATIC_RESOURCES.map do |uri, meta|
          MCP::Resource.new(
            uri: uri,
            name: meta[:name],
            description: meta[:description],
            mime_type: meta[:mime_type]
          )
        end
      end

      def resource_templates
        [ MODEL_TEMPLATE, CONTROLLER_TEMPLATE, CONTROLLER_ACTION_TEMPLATE, VIEW_TEMPLATE, ROUTES_TEMPLATE ]
      end

      def register(server)
        require "json"

        server.resources = static_resources

        server.resources_read_handler do |params|
          handle_read(params)
        end
      end

      private

      def handle_read(params)
        uri = params[:uri]

        # Delegate rails-ai-context:// URIs to the VFS dispatcher
        return VFS.resolve(uri) if uri.start_with?("#{VFS::SCHEME}://")

        # Legacy rails:// URI handling
        context = RailsAiContext.introspect

        if STATIC_RESOURCES.key?(uri)
          key = STATIC_RESOURCES[uri][:key]
          content = JSON.pretty_generate(context[key] || {})
          [ { uri: uri, mime_type: "application/json", text: content } ]
        elsif (match = uri.match(%r{\Arails://models/(.+)\z}))
          model_name = match[1]
          models = context[:models] || {}
          data = models[model_name] || { error: "Model '#{model_name}' not found" }
          content = JSON.pretty_generate(data)
          [ { uri: uri, mime_type: "application/json", text: content } ]
        else
          raise RailsAiContext::Error, "Unknown resource: #{uri}"
        end
      end
    end
  end
end
