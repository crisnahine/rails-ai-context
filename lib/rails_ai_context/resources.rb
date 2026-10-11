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
        name: "Mounted Apps",
        description: "Mounted Rails engines and Rack apps with paths and descriptions",
        mime_type: "application/json",
        key: :engines
      }
    }.freeze

    MODEL_TEMPLATE = MCP::ResourceTemplate.new(
      uri_template: "rails-ai-context://models/{name}",
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

    # No mime_type: the spec has a template carry one only when every
    # resource it matches shares it, and a views directory holds ERB, HAML,
    # jbuilder and more. Each read names its own.
    VIEW_TEMPLATE = MCP::ResourceTemplate.new(
      uri_template: "rails-ai-context://views/{path}",
      name: "View Template",
      description: "View template source for a specific path relative to app/views"
    ).freeze

    ROUTES_TEMPLATE = MCP::ResourceTemplate.new(
      uri_template: "rails-ai-context://routes/{controller}",
      name: "Live Routes",
      description: "Application routes introspected fresh on each request, optionally filtered by controller name",
      mime_type: "application/json"
    ).freeze

    INVALID_PARAMS = -32602

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

      # What a read can name: each static resource, then each template.
      def served_uris
        STATIC_RESOURCES.keys + resource_templates.map { |template| template.to_h[:uriTemplate] }
      end

      def register(server)
        require "json"

        server.resources = static_resources

        server.resources_read_handler do |params|
          handle_read(params)
        rescue RailsAiContext::Error => e
          raise read_error(params, e)
        end
      end

      private

      # handle_read / VFS raise RailsAiContext::Error for unknown URIs and
      # blocked paths (traversal, sensitive files). Left unhandled, the MCP
      # SDK collapses them into a generic "-32603 Internal error" that hides
      # the URI. On mcp >= 0.20 they become the SDK's ResourceNotFoundError,
      # so the client gets a proper "-32602 Resource not found: <uri>" with
      # the URI in error data (the uniform message also avoids leaking why a
      # blocked path was rejected). That class doesn't exist on older but
      # still-supported mcp (gemspec allows >= 0.13), so the original error
      # goes through there - same behavior as before this wrapper.
      #
      # A name the app does not have, or a file over the cap, is no secret: it
      # fails with its own reason and the names the client can use instead,
      # where it used to succeed with an `{"error": ...}` body a client could
      # not tell from data.
      # The URI is echoed shortened, as a tool echoes an argument: a 100 KB
      # one came back whole, in the message and again in the data.
      def read_error(params, error)
        uri = Tools::BaseTool.echo_input(params[:uri])
        if error.is_a?(RailsAiContext::ResourceUnavailable) && handler_error_data?
          return MCP::Server::RequestHandlerError.new(
            error.message, params,
            error_type: :invalid_params, error_code: INVALID_PARAMS, error_data: { uri: uri }.merge(error.data)
          )
        end
        return error unless defined?(MCP::Server::ResourceNotFoundError)

        MCP::Server::ResourceNotFoundError.new(uri)
      end

      # error_code and error_data arrived together with ResourceNotFoundError,
      # which is built on them.
      def handler_error_data?
        MCP::Server::RequestHandlerError.instance_method(:initialize).parameters.any? { |_, name| name == :error_data }
      end

      # Content hashes use MCP-spec camelCase keys (mimeType): the SDK places
      # the handler's return value into the JSON-RPC response without renaming
      # keys, so snake_case would leak to clients as-is.
      def handle_read(params)
        # A read introspects afresh, but the booted tier reads reflection,
        # which only a code reload brings up to date after an edit.
        Tools::BaseTool.refresh_if_files_changed!
        # Resource reads introspect just like tool calls do, and they bypassed
        # SafeCall entirely - so a reload on another thread could unload
        # constants while one was reading them and hand back a short list
        # with nothing raised.
        RailsAiContext::CodeReloader.with_app_code { read_resource(params) }
      end

      def read_resource(params)
        uri = params[:uri]

        # The two schemes are historical; both resolve through VFS for every
        # template so clients don't have to remember which resource uses
        # which. Bare "rails://controllers" (no path) stays a static
        # resource. Contents are relabeled with the URI the client actually
        # requested.
        if uri.match?(%r{\Arails://(controllers|views|routes|models)/.})
          normalized = uri.sub("rails://", "#{VFS::SCHEME}://")
          return VFS.resolve(normalized).map { |content| content.merge(uri: uri) }
        end

        # Delegate rails-ai-context:// URIs to the VFS dispatcher
        return VFS.resolve(uri) if uri.start_with?("#{VFS::SCHEME}://")

        # Legacy rails:// URI handling
        context = RailsAiContext.introspect

        if STATIC_RESOURCES.key?(uri)
          key = STATIC_RESOURCES[uri][:key]
          content = JsonBudget.for_resource(context[key] || {})
          [ { uri: uri, mimeType: "application/json", text: content } ]
        else
          raise ResourceUnavailable.new("Resource not found: #{Tools::BaseTool.echo_input(uri)}", available: served_uris)
        end
      end
    end
  end
end
