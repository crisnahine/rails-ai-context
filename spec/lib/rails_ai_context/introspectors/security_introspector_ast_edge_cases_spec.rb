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
    let!(:original_content) { File.read(app_controller) }

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

  describe "an ApplicationController without the verify_authenticity_token callback" do
    let(:app_controller) { File.join(Rails.root, "app/controllers/application_controller.rb") }
    let!(:original_content) { File.read(app_controller) }

    after { File.write(app_controller, original_content) }

    it "names the skip when the file turns protection on and then skips the callback" do
      File.write(app_controller, <<~RUBY)
        class ApplicationController < ActionController::Base
          protect_from_forgery with: :exception
          skip_before_action :verify_authenticity_token
        end
      RUBY
      stub_const("ApplicationController", Class.new(ActionController::Base) {
        protect_from_forgery with: :exception
        skip_before_action :verify_authenticity_token
      })

      expect(introspector.call[:csrf]).to include(default: "skipped (skip_before_action :verify_authenticity_token present)")
    end

    # Base gains the callback from default_protect_from_forgery, so each example builds the class one default gives.
    it "says the callback does not run when the file neither calls nor skips it" do
      File.write(app_controller, "class ApplicationController < ActionController::Base\nend\n")
      stub_const("ApplicationController", Class.new(ActionController::Base) {
        skip_before_action :verify_authenticity_token, raise: false
      })

      expect(introspector.call[:csrf]).to include(default: "off (verify_authenticity_token does not run)")
    end

    it "reads protection as enabled when Base already runs the callback and the file says nothing" do
      File.write(app_controller, "class ApplicationController < ActionController::Base\nend\n")
      stub_const("ApplicationController", Class.new(ActionController::Base) {
        protect_from_forgery with: :exception
      })

      expect(introspector.call[:csrf]).to include(default: "enabled")
    end
  end

  describe "an API-only ApplicationController" do
    let(:app_controller) { File.join(Rails.root, "app/controllers/application_controller.rb") }
    let!(:original_content) { File.read(app_controller) }

    after { File.write(app_controller, original_content) }

    # ActionController::API leaves RequestForgeryProtection out of its modules.
    it "reports CSRF protection as not included, with no token settings" do
      File.write(app_controller, "class ApplicationController < ActionController::API\nend\n")
      stub_const("ApplicationController", Class.new(ActionController::API))

      expect(introspector.call[:csrf]).to eq(default: "not included (ActionController::API)")
    end

    it "reports CSRF protection when the app includes it back" do
      File.write(app_controller, <<~RUBY)
        class ApplicationController < ActionController::API
          include ActionController::RequestForgeryProtection
          protect_from_forgery with: :exception
        end
      RUBY
      stub_const("ApplicationController", Class.new(ActionController::API) {
        include ActionController::RequestForgeryProtection
        protect_from_forgery with: :exception
      })

      expect(introspector.call[:csrf]).to include(default: "enabled", protect_from_forgery: "with: :exception")
    end

    # Including the module adds the macro; only protect_from_forgery adds the verify_authenticity_token callback.
    it "reports CSRF protection as off when the app includes it back but never turns it on" do
      File.write(app_controller, <<~RUBY)
        class ApplicationController < ActionController::API
          include ActionController::RequestForgeryProtection
        end
      RUBY
      stub_const("ApplicationController", Class.new(ActionController::API) {
        include ActionController::RequestForgeryProtection
      })

      expect(introspector.call[:csrf]).to include(default: "off (verify_authenticity_token does not run)")
    end
  end

  describe "an ApplicationController that cannot be loaded" do
    let(:app_controller) { File.join(Rails.root, "app/controllers/application_controller.rb") }
    let!(:original_content) { File.read(app_controller) }
    let(:fresh_dir) { Dir.mktmpdir }
    let(:config) { Rails.application.config.action_controller }
    let!(:original_default) { config.default_protect_from_forgery }

    after do
      File.write(app_controller, original_content)
      FileUtils.rm_rf(fresh_dir)
      config.default_protect_from_forgery = original_default
    end

    # The app's copy is already required, so the autoload points at a fresh path with the same source.
    def autoload_application_controller(source)
      hide_const("ApplicationController")
      File.write(app_controller, source)
      fresh = File.join(fresh_dir, "application_controller.rb")
      File.write(fresh, source)
      Object.autoload(:ApplicationController, fresh)
    end

    it "reads the file's chain when the file has a syntax error" do
      config.default_protect_from_forgery = true
      autoload_application_controller("class ApplicationController < ActionController::Base\n  def broken(\nend\n")

      expect(introspector.call[:csrf]).to include(default: "enabled")
    end

    it "reads the file's chain when the file names a missing constant" do
      config.default_protect_from_forgery = true
      autoload_application_controller("class ApplicationController < ActionController::Base\n  include MissingConcern\nend\n")

      expect(introspector.call[:csrf]).to include(default: "enabled")
    end

    # Without default_protect_from_forgery, Base adds no verify_authenticity_token callback.
    it "reads protection as off on old defaults when the file never turns it on" do
      config.default_protect_from_forgery = false
      autoload_application_controller("class ApplicationController < ActionController::Base\n  include MissingConcern\nend\n")

      expect(introspector.call[:csrf]).to include(default: "off (verify_authenticity_token does not run)")
    end

    it "reads protection as enabled on old defaults when the file calls protect_from_forgery" do
      config.default_protect_from_forgery = false
      autoload_application_controller(<<~RUBY)
        class ApplicationController < ActionController::Base
          include MissingConcern
          protect_from_forgery with: :exception
        end
      RUBY

      expect(introspector.call[:csrf]).to include(default: "enabled", protect_from_forgery: "with: :exception")
    end

    it "reads protection as skipped when the file skips it" do
      config.default_protect_from_forgery = true
      autoload_application_controller("class ApplicationController < ActionController::Base\n  include MissingConcern\n  skip_forgery_protection\nend\n")

      expect(introspector.call[:csrf]).to include(default: "skipped (skip_forgery_protection present)")
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
