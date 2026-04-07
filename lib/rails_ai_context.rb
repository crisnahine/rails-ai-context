# frozen_string_literal: true

require "zeitwerk"

loader = Zeitwerk::Loader.for_gem(warn_on_extra_files: false)
loader.inflector.inflect("devops_introspector" => "DevOpsIntrospector", "cli" => "CLI", "vfs" => "VFS")
loader.ignore("#{__dir__}/generators")
loader.ignore("#{__dir__}/rails-ai-context.rb")
loader.setup

module RailsAiContext
  class Error < StandardError; end
  class ConfigurationError < Error; end

  class << self
    # Global configuration
    attr_writer :configuration

    def configuration
      @configuration ||= Configuration.new
    end

    def configure
      @configured_via_block = true
      yield(configuration)
    end

    def configured_via_block?
      @configured_via_block || false
    end

    # Quick access to introspect the current Rails app
    # Returns a hash of all discovered context
    def introspect(app = nil)
      app ||= Rails.application
      Introspector.new(app).call
    end

    # Generate context files (CLAUDE.md, .cursor/rules/, etc.)
    def generate_context(app = nil, format: :all)
      app ||= Rails.application
      context = introspect(app)
      Serializers::ContextFileSerializer.new(context, format: format).call
    end

    # Start the MCP server programmatically
    def start_mcp_server(app = nil, transport: :stdio)
      app ||= Rails.application
      Server.new(app, transport: transport).start
    end
  end
end

# Rails integration — loaded by Bundler.require after Rails is booted
require_relative "rails_ai_context/engine" if defined?(Rails::Engine)
