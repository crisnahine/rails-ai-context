# frozen_string_literal: true

require "zeitwerk"

# Provide Data.define on Ruby 3.1 (no-op on 3.2+) before any value object is
# autoloaded. Defines a top-level constant, so it stays outside Zeitwerk.
require_relative "rails_ai_context/polyfill/data"

loader = Zeitwerk::Loader.for_gem(warn_on_extra_files: false)
loader.inflector.inflect("devops_introspector" => "DevOpsIntrospector", "cli" => "CLI", "vfs" => "VFS")
loader.ignore("#{__dir__}/generators")
loader.ignore("#{__dir__}/rails-ai-context.rb")
loader.ignore("#{__dir__}/rails_ai_context/polyfill")
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

    # Warn through Rails.logger when available, stderr otherwise. Introspection
    # runs in contexts where Rails.logger is nil (early-boot rake tasks, engine
    # dummy apps); a logging call that raises inside a rescue block defeats the
    # fault isolation the rescue exists to provide.
    def log_warn(message)
      if defined?(Rails) && Rails.respond_to?(:logger) && Rails.logger
        Rails.logger.warn(message)
      else
        $stderr.puts(message)
      end
    end

    # Operating tier. :runtime means the host app booted and live reflection
    # is available; :static means only source files are being analyzed.
    # Defaults to :runtime because in-app usage (railtie, rake tasks) only
    # reaches this code after a successful boot.
    attr_writer :tier

    def tier
      @tier || :runtime
    end

    def static_tier?
      tier == :static
    end

    # One-line explanation of why the static tier is active (boot failure
    # summary, or a note that --no-boot was requested). Nil in runtime tier.
    attr_accessor :static_reason

    # Quick access to introspect the current Rails app
    # Returns a hash of all discovered context
    def introspect(app = nil)
      app ||= default_app
      Introspector.new(app).call
    end

    # Generate context files (CLAUDE.md, .cursor/rules/, etc.)
    def generate_context(app = nil, format: :all)
      app ||= default_app
      context = introspect(app)
      Serializers::ContextFileSerializer.new(context, format: format).call
    end

    # Start the MCP server programmatically
    def start_mcp_server(app = nil, transport: :stdio)
      app ||= default_app
      Server.new(app, transport: transport).start
    end

    # The app object introspection runs against: the booted Rails app in
    # runtime tier, a filesystem-rooted stand-in in static tier.
    def default_app
      if static_tier?
        StaticApp.new(configuration.app_root || Dir.pwd)
      else
        Rails.application
      end
    end
  end
end

# Rails integration - loaded by Bundler.require after Rails is booted
require_relative "rails_ai_context/engine" if defined?(Rails::Engine)
