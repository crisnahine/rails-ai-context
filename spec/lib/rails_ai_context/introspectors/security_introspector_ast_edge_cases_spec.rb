# frozen_string_literal: true

require "spec_helper"

RSpec.describe RailsAiContext::Introspectors::SecurityIntrospector, "AST edge cases" do
  let(:introspector) { described_class.new(Rails.application) }

  describe "CSP with multiple directives on separate lines" do
    let(:init_path) { File.join(Rails.root, "config/initializers/content_security_policy.rb") }

    before do
      FileUtils.mkdir_p(File.dirname(init_path))
      File.write(init_path, <<~RUBY)
        Rails.application.config.content_security_policy do |policy|
          policy.default_src :self, :https
          policy.font_src    :self, :https, :data
          policy.img_src     :self, :https, :data
          policy.object_src  :none
          policy.script_src  :self, :https
          policy.style_src   :self, :https, :unsafe_inline
          policy.connect_src :self, :https, 'wss://example.com'
        end
      RUBY
    end

    after { FileUtils.rm_f(init_path) }

    it "extracts all seven directives" do
      result = introspector.call
      csp = result[:content_security_policy]
      expect(csp[:configured]).to eq(true)
      directives = csp[:directives].map { |d| d[:directive] }
      expect(directives).to contain_exactly(
        "default_src", "font_src", "img_src", "object_src",
        "script_src", "style_src", "connect_src"
      )
    end

    it "preserves all arguments per directive" do
      result = introspector.call
      csp = result[:content_security_policy]
      connect = csp[:directives].find { |d| d[:directive] == "connect_src" }
      expect(connect[:value]).to include(":self")
      expect(connect[:value]).to include(":https")
      expect(connect[:value]).to include("wss://example.com")
    end

    it "returns report_only as boolean" do
      result = introspector.call
      csp = result[:content_security_policy]
      expect(csp[:report_only]).to eq(true).or(eq(false))
    end
  end

  describe "controller with skip_forgery_protection (no args)" do
    let(:app_controller) { File.join(Rails.root, "app/controllers/application_controller.rb") }
    let(:original_content) { File.read(app_controller) }

    before do
      File.write(app_controller, <<~RUBY)
        class ApplicationController < ActionController::Base
          skip_forgery_protection
        end
      RUBY
    end

    after { File.write(app_controller, original_content) }

    it "reports CSRF as skipped" do
      result = introspector.call
      expect(result[:csrf][:default]).to eq("skipped (skip_forgery_protection present)")
    end

    it "does not include protect_from_forgery key" do
      result = introspector.call
      expect(result[:csrf]).not_to have_key(:protect_from_forgery)
    end
  end

  describe "allow_browser with versions: hash" do
    let(:controller_path) { File.join(Rails.root, "app/controllers/version_gate_controller.rb") }

    before do
      FileUtils.mkdir_p(File.dirname(controller_path))
      File.write(controller_path, <<~RUBY)
        class VersionGateController < ApplicationController
          allow_browser versions: { safari: 16.4, firefox: 121, chrome: 120, ie: false }
        end
      RUBY
    end

    after { FileUtils.rm_f(controller_path) }

    it "captures the allow_browser entry" do
      result = introspector.call
      entry = result[:allow_browser].find { |e| e[:file] == "app/controllers/version_gate_controller.rb" }
      expect(entry).not_to be_nil
    end

    it "includes the versions hash in args" do
      result = introspector.call
      entry = result[:allow_browser].find { |e| e[:file] == "app/controllers/version_gate_controller.rb" }
      expect(entry[:args]).to include("versions:")
      # The hash should contain browser names
      expect(entry[:args]).to include("safari")
      expect(entry[:args]).to include("chrome")
    end
  end

  describe "permissions policy with mixed :self and string allowlists" do
    let(:init_path) { File.join(Rails.root, "config/initializers/permissions_policy.rb") }

    before do
      FileUtils.mkdir_p(File.dirname(init_path))
      File.write(init_path, <<~RUBY)
        Rails.application.config.permissions_policy do |policy|
          policy.camera      :none
          policy.gyroscope   :none
          policy.microphone  :none
          policy.usb         :none
          policy.fullscreen  :self, 'https://example.com'
          policy.payment     :self
        end
      RUBY
    end

    after { FileUtils.rm_f(init_path) }

    it "extracts all six permission features" do
      result = introspector.call
      pp = result[:permissions_policy]
      expect(pp[:configured]).to eq(true)
      features = pp[:directives].map { |d| d[:feature] }
      expect(features).to contain_exactly(
        "camera", "gyroscope", "microphone", "usb", "fullscreen", "payment"
      )
    end

    it "captures :self in the allowlist" do
      result = introspector.call
      pp = result[:permissions_policy]
      fullscreen = pp[:directives].find { |d| d[:feature] == "fullscreen" }
      expect(fullscreen[:allowlist]).to include(":self")
    end

    it "captures string URLs in the allowlist" do
      result = introspector.call
      pp = result[:permissions_policy]
      fullscreen = pp[:directives].find { |d| d[:feature] == "fullscreen" }
      expect(fullscreen[:allowlist]).to include("https://example.com")
    end

    it "captures :none for restrictive features" do
      result = introspector.call
      pp = result[:permissions_policy]
      camera = pp[:directives].find { |d| d[:feature] == "camera" }
      expect(camera[:allowlist]).to include(":none")
    end
  end
end
