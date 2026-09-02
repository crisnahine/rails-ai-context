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

  it "does not report an empty stack when there is no booted app to ask" do
    static = described_class.new(RailsAiContext::StaticApp.new(IntrospectedFixture::ROOT)).static_call

    expect(static).not_to have_key(:middleware_stack)
    expect(static[:custom_middleware]).to be_an(Array)
    expect(static).to include(:unavailable_sections)
    expect(static[:unavailable]).to be_nil
  end
end
