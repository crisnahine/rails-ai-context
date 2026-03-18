# frozen_string_literal: true

require_relative "rails_ai_context/version"

module RailsAiContext
  class Error < StandardError; end
  class ConfigurationError < Error; end
  class IntrospectionError < Error; end

  class << self
    # Global configuration
    attr_writer :configuration

    def configuration
      @configuration ||= Configuration.new
    end

    def configure
      yield(configuration)
    end

    # Quick access to introspect the current Rails app
    # Returns a hash of all discovered context
    def introspect(app = nil)
      app ||= Rails.application
      Introspector.new(app).call
    end

    # Generate context files (CLAUDE.md, .cursorrules, etc.)
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

# Configuration
require_relative "rails_ai_context/configuration"

# Cache invalidation
require_relative "rails_ai_context/fingerprinter"

# Core introspection
require_relative "rails_ai_context/introspector"
require_relative "rails_ai_context/introspectors/schema_introspector"
require_relative "rails_ai_context/introspectors/model_introspector"
require_relative "rails_ai_context/introspectors/route_introspector"
require_relative "rails_ai_context/introspectors/job_introspector"
require_relative "rails_ai_context/introspectors/gem_introspector"
require_relative "rails_ai_context/introspectors/convention_detector"
require_relative "rails_ai_context/introspectors/stimulus_introspector"
require_relative "rails_ai_context/introspectors/database_stats_introspector"

# MCP Tools
require_relative "rails_ai_context/tools/base_tool"
require_relative "rails_ai_context/tools/get_schema"
require_relative "rails_ai_context/tools/get_routes"
require_relative "rails_ai_context/tools/get_model_details"
require_relative "rails_ai_context/tools/get_gems"
require_relative "rails_ai_context/tools/search_code"
require_relative "rails_ai_context/tools/get_conventions"

# Serializers
require_relative "rails_ai_context/serializers/context_file_serializer"
require_relative "rails_ai_context/serializers/markdown_serializer"
require_relative "rails_ai_context/serializers/claude_serializer"
require_relative "rails_ai_context/serializers/rules_serializer"
require_relative "rails_ai_context/serializers/copilot_serializer"
require_relative "rails_ai_context/serializers/json_serializer"

# Diagnostics
require_relative "rails_ai_context/doctor"

# MCP Resources & Server
require_relative "rails_ai_context/resources"
require_relative "rails_ai_context/server"

# Rails integration — loaded by Bundler.require after Rails is booted
require_relative "rails_ai_context/engine" if defined?(Rails::Engine)
