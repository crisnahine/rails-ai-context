# frozen_string_literal: true

require "spec_helper"

RSpec.describe RailsAiContext::Introspectors::AuthIntrospector, "AST edge cases" do
  let(:introspector) { described_class.new(Rails.application) }

  describe "dual auth: devise AND has_secure_password in the same model" do
    let(:fixture_model) { File.join(Rails.root, "app/models/hybrid_user.rb") }

    before do
      File.write(fixture_model, <<~RUBY)
        class HybridUser < ApplicationRecord
          devise :database_authenticatable, :registerable
          has_secure_password
        end
      RUBY
    end

    after { FileUtils.rm_f(fixture_model) }

    it "detects devise modules for the model" do
      result = introspector.call
      devise_entry = result[:authentication][:devise]&.find { |d| d[:model] == "HybridUser" }
      expect(devise_entry).not_to be_nil
      expect(devise_entry[:matches].first).to include("database_authenticatable")
    end

    it "detects has_secure_password for the same model" do
      result = introspector.call
      expect(result[:authentication][:has_secure_password]).to include("HybridUser")
    end

    it "includes both devise modules in devise_modules_per_model" do
      result = introspector.call
      modules = result[:devise_modules_per_model]["HybridUser"]
      expect(modules).to eq(%w[database_authenticatable registerable])
    end
  end

  describe "devise with multiline module list (comma continuation)" do
    let(:fixture_model) { File.join(Rails.root, "app/models/big_user.rb") }

    before do
      File.write(fixture_model, <<~RUBY)
        class BigUser < ApplicationRecord
          devise :database_authenticatable,
                 :registerable,
                 :recoverable,
                 :rememberable,
                 :validatable,
                 :confirmable,
                 :lockable,
                 :timeoutable,
                 :trackable
        end
      RUBY
    end

    after { FileUtils.rm_f(fixture_model) }

    it "extracts all modules from the multiline devise call" do
      result = introspector.call
      modules = result[:devise_modules_per_model]["BigUser"]
      expect(modules).to contain_exactly(
        "database_authenticatable",
        "registerable",
        "recoverable",
        "rememberable",
        "validatable",
        "confirmable",
        "lockable",
        "timeoutable",
        "trackable"
      )
    end

    it "formats the devise detection matches correctly" do
      result = introspector.call
      devise_entry = result[:authentication][:devise]&.find { |d| d[:model] == "BigUser" }
      expect(devise_entry).not_to be_nil
      # The old regex returned the entire line after `devise`. The AST version
      # returns each call's args as ":mod, :mod, ...". Verify they're all present.
      all_matches = devise_entry[:matches].join(", ")
      expect(all_matches).to include(":database_authenticatable")
      expect(all_matches).to include(":trackable")
    end
  end

  describe "allow_unauthenticated_access with both only: and except: in same controller" do
    let(:session_model) { File.join(Rails.root, "app/models/session.rb") }
    let(:current_model) { File.join(Rails.root, "app/models/current.rb") }
    let(:controller_file) { File.join(Rails.root, "app/controllers/mixed_access_controller.rb") }

    before do
      File.write(session_model, "class Session < ApplicationRecord; end")
      File.write(current_model, "class Current < ActiveSupport::CurrentAttributes; end")
      File.write(controller_file, <<~RUBY)
        class MixedAccessController < ApplicationController
          allow_unauthenticated_access only: %i[index show]
          allow_unauthenticated_access except: %i[destroy]
        end
      RUBY
    end

    after do
      [ session_model, current_model, controller_file ].each { |f| FileUtils.rm_f(f) }
    end

    it "produces two separate entries for the same controller" do
      result = introspector.call
      unauth = result[:authentication][:rails_auth][:allow_unauthenticated_access]
      entries = unauth.select { |h| h[:file] == "app/controllers/mixed_access_controller.rb" }
      expect(entries.size).to eq(2)
    end

    it "captures the only: scope correctly" do
      result = introspector.call
      unauth = result[:authentication][:rails_auth][:allow_unauthenticated_access]
      entries = unauth.select { |h| h[:file] == "app/controllers/mixed_access_controller.rb" }
      only_entry = entries.find { |h| h[:scope].start_with?("only:") }
      expect(only_entry).not_to be_nil
      expect(only_entry[:scope]).to include("index")
      expect(only_entry[:scope]).to include("show")
    end

    it "captures the except: scope correctly" do
      result = introspector.call
      unauth = result[:authentication][:rails_auth][:allow_unauthenticated_access]
      entries = unauth.select { |h| h[:file] == "app/controllers/mixed_access_controller.rb" }
      except_entry = entries.find { |h| h[:scope].start_with?("except:") }
      expect(except_entry).not_to be_nil
      expect(except_entry[:scope]).to include("destroy")
    end
  end

  describe "authenticate_with_http_token inside a method body (not at class level)" do
    let(:controller_file) { File.join(Rails.root, "app/controllers/nested_token_controller.rb") }

    before do
      File.write(controller_file, <<~RUBY)
        class NestedTokenController < ApplicationController
          before_action :require_token

          private

          def require_token
            authenticate_with_http_token do |token, _options|
              @current_api_key = ApiKey.find_by(token: token)
            end
          end
        end
      RUBY
    end

    after { FileUtils.rm_f(controller_file) }

    it "detects authenticate_with_http_token even inside a method body" do
      result = introspector.call
      expect(result[:token_auth][:http_token_auth]).to include("app/controllers/nested_token_controller.rb")
    end
  end

  describe "omniauth_providers: [] (empty array)" do
    let(:fixture_model) { File.join(Rails.root, "app/models/empty_omni_user.rb") }

    before do
      File.write(fixture_model, <<~RUBY)
        class EmptyOmniUser < ApplicationRecord
          devise :database_authenticatable, :omniauthable, omniauth_providers: []
        end
      RUBY
    end

    after { FileUtils.rm_f(fixture_model) }

    it "does not add any providers from empty omniauth_providers" do
      result = introspector.call
      # With an empty array, no providers should be added.
      # The key may be absent or empty.
      providers = result[:authentication][:omniauth_providers]
      expect(providers).to be_nil.or(be_empty)
    end

    it "still detects devise modules including omniauthable" do
      result = introspector.call
      modules = result[:devise_modules_per_model]["EmptyOmniUser"]
      expect(modules).to include("database_authenticatable", "omniauthable")
    end
  end

  describe "devise initializer with NO config.jwt (jwt should be detected: false)" do
    let(:lock_path) { File.join(Rails.root, "Gemfile.lock") }
    let(:devise_init) { File.join(Rails.root, "config/initializers/devise.rb") }

    before do
      File.write(lock_path, <<~LOCK)
        GEM
          remote: https://rubygems.org/
          specs:
            devise-jwt (0.11.0)

        PLATFORMS
          ruby
      LOCK
      FileUtils.mkdir_p(File.dirname(devise_init))
      File.write(devise_init, <<~RUBY)
        Devise.setup do |config|
          config.mailer_sender = 'no-reply@example.com'
          config.authentication_keys = [:email]
        end
      RUBY
    end

    after do
      FileUtils.rm_f(lock_path)
      FileUtils.rm_f(devise_init)
    end

    it "detects devise-jwt gem but reports jwt_configured as false" do
      result = introspector.call
      jwt = result[:token_auth][:devise_jwt]
      expect(jwt[:detected]).to eq(true)
      expect(jwt[:jwt_configured]).to eq(false)
    end
  end
end
