# frozen_string_literal: true

require "spec_helper"

RSpec.describe RailsAiContext::Introspectors::MiddlewareIntrospector do
  let(:app) { Rails.application }
  let(:introspector) { described_class.new(app) }

  before do
    @middleware_dir = File.join(app.root.to_s, "app/middleware")
    FileUtils.mkdir_p(@middleware_dir)

    File.write(File.join(@middleware_dir, "tenant_resolver.rb"), <<~RUBY)
      class TenantResolver
        def initialize(app)
          @app = app
        end

        def call(env)
          tenant = extract_tenant(env)
          Current.tenant = tenant
          @app.call(env)
        end

        private

        def extract_tenant(env)
          request = Rack::Request.new(env)
          subdomain = request.host.split(".").first
          Account.find_by(subdomain: subdomain)
        end
      end
    RUBY

    File.write(File.join(@middleware_dir, "request_logger.rb"), <<~RUBY)
      class RequestLogger
        def initialize(app)
          @app = app
        end

        def call(env)
          Rails.logger.info "Request: \#{env['REQUEST_METHOD']} \#{env['PATH_INFO']}"
          @app.call(env)
        end
      end
    RUBY
  end

  after do
    FileUtils.rm_rf(@middleware_dir)
  end

  describe "#call" do
    subject(:result) { introspector.call }

    it "discovers custom middleware files" do
      custom = result[:custom_middleware]
      expect(custom.size).to eq(2)
      names = custom.map { |m| m[:class_name] }
      expect(names).to include("TenantResolver", "RequestLogger")
    end

    it "detects middleware patterns" do
      tenant = result[:custom_middleware].find { |m| m[:class_name] == "TenantResolver" }
      expect(tenant[:detected_patterns]).to include("tenant")
      expect(tenant[:has_call_method]).to be true
      expect(tenant[:initializes_app]).to be true
    end

    it "reads the middleware's own initialize past a nested helper class" do
      File.write(File.join(@middleware_dir, "nested_helper.rb"), <<~RUBY)
        class NestedHelper
          class Bucket
            def initialize(size)
            end
          end

          def initialize(app)
            @app = app
          end

          def call(env)
          end
        end
      RUBY

      nested = introspector.call[:custom_middleware].find { |m| m[:class_name] == "NestedHelper" }
      expect(nested[:has_call_method]).to be true
      expect(nested[:initializes_app]).to be true
    end

    it "does not let a nested helper class answer for the middleware" do
      File.write(File.join(@middleware_dir, "outer_mw.rb"), <<~RUBY)
        class OuterMw
          class Bucket
            def initialize(app)
            end

            def call(env)
            end
          end

          def initialize(config)
            @config = config
          end
        end
      RUBY

      outer = introspector.call[:custom_middleware].find { |m| m[:class_name] == "OuterMw" }
      expect(outer[:has_call_method]).to be false
      expect(outer[:initializes_app]).to be false
    end

    it "reads the middleware class the file is named for, not a helper declared above it" do
      File.write(File.join(@middleware_dir, "audit_logger.rb"), <<~RUBY)
        class LogFormatter
          def initialize(prefix)
          end
        end

        class AuditLogger
          def initialize(app)
            @app = app
          end

          def call(env)
          end
        end
      RUBY

      audit = introspector.call[:custom_middleware].find { |m| m[:class_name] == "AuditLogger" }
      expect(audit[:has_call_method]).to be true
      expect(audit[:initializes_app]).to be true
    end

    it "names a namespaced middleware's own methods" do
      FileUtils.mkdir_p(File.join(@middleware_dir, "api"))
      File.write(File.join(@middleware_dir, "api", "throttle.rb"), <<~RUBY)
        module Api
          class Throttle
            def initialize(app)
              @app = app
            end

            def call(env)
            end
          end
        end
      RUBY

      throttle = introspector.call[:custom_middleware].find { |m| m[:class_name] == "Api::Throttle" }
      expect(throttle[:has_call_method]).to be true
      expect(throttle[:initializes_app]).to be true
    end

    it "detects logging pattern" do
      logger = result[:custom_middleware].find { |m| m[:class_name] == "RequestLogger" }
      expect(logger[:detected_patterns]).to include("logging")
    end

    it "extracts middleware stack" do
      expect(result[:middleware_stack]).to be_an(Array)
      expect(result[:middleware_stack]).not_to be_empty
    end

    it "returns middleware count" do
      expect(result[:middleware_count][:custom]).to eq(2)
      expect(result[:middleware_count][:total]).to be > 0
    end

    it "does not return an error" do
      expect(result[:error]).to be_nil
    end
  end

  describe "insertions an initializer makes" do
    let(:init_dir) { File.join(app.root.to_s, "config/initializers") }
    let(:lib_dir) { File.join(app.root.to_s, "lib/middleware") }

    before do
      FileUtils.mkdir_p(init_dir)
      FileUtils.mkdir_p(lib_dir)
      File.write(File.join(init_dir, "200-first_middlewares.rb"), <<~RUBY)
        Rails.configuration.middleware.unshift(Middleware::RequestTracker)
        Rails.configuration.middleware.move_before(Middleware::RequestTracker, ActionDispatch::RemoteIp)
        Rails.configuration.middleware.insert_before ActionDispatch::Flash, Middleware::EnforceHostname
        Rails.configuration.middleware.swap Rails::Rack::Logger, SilenceLogger
        Rails.configuration.middleware.delete ActionDispatch::Executor
      RUBY
      File.write(File.join(lib_dir, "request_tracker.rb"), <<~RUBY)
        module Middleware
          class RequestTracker
            def initialize(app)
              @app = app
            end

            def call(env)
              @app.call(env)
            end
          end
        end
      RUBY
    end

    after do
      FileUtils.rm_f(File.join(init_dir, "200-first_middlewares.rb"))
      FileUtils.rm_rf(lib_dir)
    end

    it "reads the insertions config/application.rb and an environment file make" do
      FileUtils.mkdir_p(File.join(app.root.to_s, "config/environments"))
      File.write(File.join(app.root.to_s, "config/application.rb"), <<~RUBY)
        module Dummy
          class Application < Rails::Application
            config.middleware.insert_after ActionDispatch::Flash, Middleware::DefaultHeaders
            config.middleware.delete Rack::Lock
          end
        end
      RUBY
      File.write(File.join(app.root.to_s, "config/environments/test.rb"), <<~RUBY)
        Rails.application.configure do
          config.middleware.use RspecErrorTracker
        end
      RUBY

      found = introspector.call[:middleware_from_initializers]

      expect(found).to include(
        { middleware: "Middleware::DefaultHeaders", action: "insert_after", file: "config/application.rb" },
        { middleware: "Rack::Lock", action: "delete", file: "config/application.rb" },
        { middleware: "RspecErrorTracker", action: "use", file: "config/environments/test.rb" }
      )
    ensure
      FileUtils.rm_f(File.join(app.root.to_s, "config/application.rb"))
      FileUtils.rm_f(File.join(app.root.to_s, "config/environments/test.rb"))
    end

    it "reads an insertion made through the app's own application class" do
      FileUtils.mkdir_p(File.join(app.root.to_s, "config"))
      File.write(File.join(app.root.to_s, "config/application.rb"), <<~RUBY)
        module Dummy
          class Application < Rails::Application
          end
        end
      RUBY
      File.write(File.join(init_dir, "app_class.rb"), <<~RUBY)
        Dummy::Application.config.middleware.use Rack::Deflater
        OtherApp::Application.config.middleware.use Rack::Timeout
      RUBY

      found = introspector.call[:middleware_from_initializers].map { |m| m[:middleware] }

      expect(found).to include("Rack::Deflater")
      expect(found).not_to include("Rack::Timeout")
    ensure
      FileUtils.rm_f(File.join(init_dir, "app_class.rb"))
      FileUtils.rm_f(File.join(app.root.to_s, "config/application.rb"))
    end

    it "credits the app with a middleware class its initializer declares" do
      File.write(File.join(init_dir, "silence_logger.rb"), <<~RUBY)
        class SilenceLogger < Rails::Rack::Logger
          def call(env)
            super
          end
        end

        Rails.configuration.middleware.swap Rails::Rack::Logger, SilenceLogger
      RUBY

      found = introspector.call[:custom_middleware].find { |m| m[:class_name] == "SilenceLogger" }

      expect(found).to include(file: "config/initializers/silence_logger.rb", has_call_method: true)
    ensure
      FileUtils.rm_f(File.join(init_dir, "silence_logger.rb"))
    end

    it "does not credit the app with a gem's class an initializer reopens" do
      File.write(File.join(init_dir, "rack_attack.rb"), <<~RUBY)
        class Rack::Attack
          throttle("logins/ip", limit: 5, period: 60) { |req| req.ip }
        end

        Rails.application.config.middleware.use Rack::Attack
      RUBY

      names = introspector.call[:custom_middleware].map { |m| m[:class_name] }

      expect(names).not_to include("Rack::Attack")
    ensure
      FileUtils.rm_f(File.join(init_dir, "rack_attack.rb"))
    end

    it "names the exceptions app apart from the stack" do
      FileUtils.mkdir_p(File.join(app.root.to_s, "config"))
      File.write(File.join(app.root.to_s, "config/application.rb"), <<~RUBY)
        module Dummy
          class Application < Rails::Application
            config.exceptions_app = Middleware::PublicExceptions.new(Rails.public_path)
          end
        end
      RUBY
      File.write(File.join(lib_dir, "public_exceptions.rb"), <<~RUBY)
        module Middleware
          class PublicExceptions
            def call(env)
              [500, {}, []]
            end
          end
        end
      RUBY

      result = introspector.call

      expect(result[:custom_middleware].map { |m| m[:class_name] }).not_to include("Middleware::PublicExceptions")
      expect(result[:exceptions_app]).to eq({ class_name: "Middleware::PublicExceptions", file: "lib/middleware/public_exceptions.rb" })
    ensure
      FileUtils.rm_f(File.join(app.root.to_s, "config/application.rb"))
    end

    it "reads every verb off Rails.configuration.middleware" do
      found = introspector.call[:middleware_from_initializers]

      expect(found).to include(
        { middleware: "Middleware::RequestTracker", action: "unshift", file: "config/initializers/200-first_middlewares.rb" },
        { middleware: "ActionDispatch::RemoteIp", action: "move_before", file: "config/initializers/200-first_middlewares.rb" },
        { middleware: "Middleware::EnforceHostname", action: "insert_before", file: "config/initializers/200-first_middlewares.rb" },
        { middleware: "SilenceLogger", action: "swap", file: "config/initializers/200-first_middlewares.rb" },
        { middleware: "ActionDispatch::Executor", action: "delete", file: "config/initializers/200-first_middlewares.rb" }
      )
    end

    it "names a class under lib/middleware the way the file declares it" do
      File.write(File.join(lib_dir, "bare_tracker.rb"), <<~RUBY)
        class BareTracker
          def initialize(app)
            @app = app
          end

          def call(env)
            @app.call(env)
          end
        end
      RUBY
      File.write(File.join(init_dir, "bare.rb"), "Rails.configuration.middleware.unshift(BareTracker)\n")

      names = introspector.call[:custom_middleware].map { |m| m[:class_name] }

      expect(names).to include("BareTracker")
      expect(names).not_to include("Middleware::BareTracker")
      expect(names.count("BareTracker")).to eq(1)
    ensure
      FileUtils.rm_f(File.join(init_dir, "bare.rb"))
    end

    it "lists a class the initializer unshifts onto Rails.application's own stack" do
      FileUtils.mkdir_p(File.join(app.root.to_s, "lib/mastodon/middleware"))
      File.write(File.join(init_dir, "prometheus_exporter.rb"), <<~RUBY)
        Rails.application.middleware.unshift Mastodon::Middleware::PrometheusQueueTime, instrument: false
      RUBY
      File.write(File.join(app.root.to_s, "lib/mastodon/middleware/prometheus_queue_time.rb"), <<~RUBY)
        module Mastodon
          module Middleware
            class PrometheusQueueTime
              def initialize(app)
                @app = app
              end

              def call(env)
                @app.call(env)
              end
            end
          end
        end
      RUBY

      result = introspector.call
      names = result[:custom_middleware].map { |m| m[:class_name] }

      expect(names).to include("Mastodon::Middleware::PrometheusQueueTime")
      expect(result[:middleware_from_initializers]).to include(
        { middleware: "Mastodon::Middleware::PrometheusQueueTime", action: "unshift",
          file: "config/initializers/prometheus_exporter.rb" }
      )
    ensure
      FileUtils.rm_f(File.join(init_dir, "prometheus_exporter.rb"))
      FileUtils.rm_rf(File.join(app.root.to_s, "lib/mastodon"))
    end

    it "lists an inserted class that lives anywhere the app autoloads from" do
      FileUtils.mkdir_p(File.join(app.root.to_s, "app/lib/middlewares"))
      File.write(File.join(init_dir, "middlewares.rb"), <<~RUBY)
        Rails.configuration.middleware.use(Middlewares::SetCookieDomain)
      RUBY
      File.write(File.join(app.root.to_s, "app/lib/middlewares/set_cookie_domain.rb"), <<~RUBY)
        module Middlewares
          class SetCookieDomain
            def initialize(app)
              @app = app
            end

            def call(env)
              @app.call(env)
            end
          end
        end
      RUBY

      found = introspector.call[:custom_middleware].find { |m| m[:class_name] == "Middlewares::SetCookieDomain" }

      expect(found[:file]).to eq("app/lib/middlewares/set_cookie_domain.rb")
      expect(found[:has_call_method]).to be true
    ensure
      FileUtils.rm_f(File.join(init_dir, "middlewares.rb"))
      FileUtils.rm_rf(File.join(app.root.to_s, "app/lib"))
    end

    it "does not list an inserted middleware that belongs to a gem" do
      names = introspector.call[:custom_middleware].map { |m| m[:class_name] }

      expect(names).not_to include("ActionDispatch::Flash", "Rails::Rack::Logger")
    end

    it "lists a class the initializer inserts and the directory scan already found only once" do
      found = introspector.call[:custom_middleware].select { |m| m[:class_name] == "Middleware::RequestTracker" }

      expect(found.size).to eq(1)
    end

    it "lists a middleware class the app keeps in lib/middleware" do
      names = introspector.call[:custom_middleware].map { |m| m[:class_name] }

      expect(names).to include("Middleware::RequestTracker")
    end
  end

  describe "config.ru" do
    let(:rackup) { File.join(app.root.to_s, "config.ru") }

    before do
      File.write(rackup, <<~RUBY)
        require_relative "config/environment"
        use Rack::ContentLength
        use Rack::Static, urls: ["/assets"]
        map "/health" do
          run ->(env) { [200, {}, ["ok"]] }
        end
        run Rails.application
      RUBY
    end

    after { FileUtils.rm_f(rackup) }

    it "names the middleware and the map mounts it puts in front of Rails, on both tiers" do
      expected = [
        { call: "use", target: "Rack::ContentLength", line: 2 },
        { call: "use", target: "Rack::Static", line: 3 },
        { call: "map", target: '"/health"', line: 4 }
      ]

      expect(introspector.call[:rackup]).to eq(expected)
      expect(described_class.new(RailsAiContext::StaticApp.new(app.root.to_s)).static_call[:rackup]).to eq(expected)
    end

    it "reads a map that runs the app itself as a path prefix, and lists the middleware inside it and its conditions" do
      File.write(rackup, <<~RUBY)
        if ENV["PROMETHEUS"] == "true"
          use Yabeda::Prometheus::Exporter
        end
        require_relative "config/environment"
        map (subdir || "/") do
          use Rack::Protection::JsonCsrf
          map "/health" do
            run ->(env) { [200, {}, []] }
          end
          run Rails.application
        end
      RUBY
      expected = [
        { call: "use", target: "Yabeda::Prometheus::Exporter", line: 2, condition: 'if ENV["PROMETHEUS"] == "true"' },
        { call: "use", target: "Rack::Protection::JsonCsrf", line: 6, within: '(subdir || "/")' },
        { call: "map", target: '"/health"', line: 7, within: '(subdir || "/")' }
      ]

      expect(introspector.call[:rackup]).to eq(expected)
      expect(described_class.new(RailsAiContext::StaticApp.new(app.root.to_s)).static_call[:rackup]).to eq(expected)
    end

    it "gives a map's path as written, quoted when it is a string, wherever it is named" do
      File.write(rackup, <<~RUBY)
        require_relative "config/environment"
        map "/admin" do
          use Rack::Auth::Basic
          run Rails.application
        end
        map ENV.fetch("HEALTH", "/up") do
          run ->(env) { [200, {}, []] }
        end
      RUBY

      expect(introspector.call[:rackup]).to eq([
        { call: "use", target: "Rack::Auth::Basic", line: 3, within: '"/admin"' },
        { call: "map", target: 'ENV.fetch("HEALTH", "/up")', line: 6 }
      ])
    end

    it "lists nothing for a map whose only job is to run the app's own class under a path" do
      application = File.join(app.root.to_s, "config/application.rb")
      File.write(application, "module Forum\n  class Application < Rails::Application\n  end\nend\n")
      File.write(rackup, <<~RUBY)
        map ActionController::Base.config.try(:relative_url_root) || "/" do
          run Forum::Application
        end
      RUBY

      expect(introspector.call).not_to have_key(:rackup)
    ensure
      FileUtils.rm_f(application)
    end

    it "does not parse a config.ru that only runs the app" do
      File.write(rackup, "# This file is used by Rack-based servers.\nrun Rails.application\n")
      allow(RailsAiContext::AstCache).to receive(:parse).and_call_original

      expect(described_class.rackup(app.root.to_s)).to eq([])
      expect(RailsAiContext::AstCache).not_to have_received(:parse).with(rackup)
    end

    it "says a config.ru Prism cannot make sense of was not read" do
      File.write(rackup, "use (((\n\xFF\n")

      expect(introspector.call[:rackup]).to eq([ { unread: "config.ru does not parse" } ])
    end

    it "says a config.ru with one unclosed block was not read, rather than listing no middleware" do
      File.write(rackup, "use Rack::Deflater\nmap \"/x\" do\n  run Rails.application\n")

      expect(described_class.rackup(app.root.to_s)).to eq([ { unread: "config.ru does not parse" } ])
    end
  end

  it "does not report an empty stack when there is no booted app to ask" do
    static = described_class.new(RailsAiContext::StaticApp.new(IntrospectedFixture::ROOT)).static_call

    expect(static).not_to have_key(:middleware_stack)
    expect(static[:custom_middleware]).to be_an(Array)
    expect(static).to include(:unavailable_sections)
    expect(static[:unavailable]).to be_nil
  end
end
