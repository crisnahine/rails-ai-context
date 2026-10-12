# frozen_string_literal: true

require "spec_helper"
require "open3"

RSpec.describe RailsAiContext::Engine do
  describe "class hierarchy" do
    it "is a subclass of Rails::Engine" do
      expect(described_class).to be < ::Rails::Engine
    end

    it "is defined within the RailsAiContext module" do
      expect(described_class.name).to eq("RailsAiContext::Engine")
    end
  end

  describe "initializers" do
    let(:initializer_names) { described_class.initializers.map(&:name) }

    it "registers the setup initializer" do
      expect(initializer_names).to include("rails_ai_context.setup")
    end

    it "registers the middleware initializer" do
      expect(initializer_names).to include("rails_ai_context.middleware")
    end

    it "registers the config file initializer" do
      expect(initializer_names).to include("rails_ai_context.config_file")
    end

    it "mounts the middleware after user initializers have run" do
      initializer = RailsAiContext::Engine.initializers.find { |i| i.name == "rails_ai_context.middleware" }
      expect(initializer).not_to be_nil
      expect(initializer.after).to eq(:load_config_initializers)
    end

    # At the end of the stack, auto_mount sat behind Active Record's
    # pending-migration check, so with a migration pending every MCP request
    # got the HTML error page. Replayed the way Rails builds the stack: the
    # frameworks' operations first, then the app's own.
    it "places auto_mount in front of the pending-migration check" do
      allow(RailsAiContext.configuration).to receive(:auto_mount).and_return(true)
      pending_check = Class.new
      frameworks = Rails::Configuration::MiddlewareStackProxy.new
      frameworks.insert_after ActionDispatch::Callbacks, pending_check
      app_operations = Rails::Configuration::MiddlewareStackProxy.new

      described_class.instance.initializers.find { |i| i.name == "rails_ai_context.middleware" }
        .run(double("app", middleware: app_operations))

      stack = ActionDispatch::MiddlewareStack.new do |middleware|
        middleware.use ActionDispatch::Executor, Rails.application.executor
        middleware.use ActionDispatch::Callbacks
        middleware.use ActionDispatch::Cookies
      end
      (frameworks + app_operations).merge_into(stack)

      expect(stack.middlewares.map(&:klass)).to eq([
        ActionDispatch::Executor, ActionDispatch::Callbacks, RailsAiContext::Middleware, pending_check, ActionDispatch::Cookies
      ])
    end
  end

  describe "an app whose inflections make acronyms" do
    # The app's loader and router camelize with the app's inflections, so "AI" or "MCP"
    # named constants the gem does not define: eager loading raised and the mount 404'd.
    %w[AI MCP].each do |acronym|
      it "eager loads and answers at the mount with #{acronym} an acronym" do
        skip "eager_load_dir needs zeitwerk 2.6" unless Zeitwerk::Loader.method_defined?(:eager_load_dir)

        script = <<~RUBY
          require "combustion"
          ActiveSupport::Inflector.inflections(:en) { |inflect| inflect.acronym #{acronym.inspect} }
          Combustion.initialize! :active_record, :action_controller, :action_mailer do
            config.eager_load = false
          end
          Rails.application.routes.prepend { mount RailsAiContext::Engine, at: "/mcp" }
          Rails.application.reload_routes!
          Rails.autoloaders.main.eager_load_dir(RailsAiContext::Engine.root.join("app/controllers").to_s)
          body = '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"t","version":"1"}}}'
          env = Rack::MockRequest.env_for("/mcp", method: "POST", input: body, "CONTENT_TYPE" => "application/json",
                                          "HTTP_ACCEPT" => "application/json, text/event-stream")
          status, _headers, response = Rails.application.call(env)
          text = +""
          response.each { |chunk| text << chunk }
          puts status
          puts text.include?('"protocolVersion"')
          puts RailsAiContext::McpController.name
        RUBY

        out, err, status = Open3.capture3(RbConfig.ruby, "-e", script, chdir: File.expand_path("../../..", __dir__))

        expect(err).not_to include("to define constant")
        expect(status).to be_success
        expect(out.lines.map(&:chomp).last(3)).to eq([ "200", "true", "RailsAiContext::McpController" ])
      end
    end
  end

  describe "configuration integration" do
    it "makes configuration accessible via Rails.application.config" do
      config = Rails.application.config.rails_ai_context
      expect(config).to be_a(RailsAiContext::Configuration)
    end

    it "returns a Configuration instance from the module" do
      expect(RailsAiContext.configuration).to be_a(RailsAiContext::Configuration)
    end
  end

  describe "rake tasks" do
    it "has a rake_tasks block registered" do
      # The engine should have registered a rake_tasks block
      # We verify by checking the initializer infrastructure exists
      expect(described_class).to respond_to(:rake_tasks)
    end
  end

  describe "generators" do
    it "has a generators block registered" do
      expect(described_class).to respond_to(:generators)
    end
  end

  describe "engine_name" do
    it "derives the engine name from the module" do
      expect(described_class.engine_name).to eq("rails_ai_context_engine")
    end
  end
end
