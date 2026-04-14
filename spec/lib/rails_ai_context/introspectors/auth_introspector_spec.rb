# frozen_string_literal: true

require "spec_helper"

RSpec.describe RailsAiContext::Introspectors::AuthIntrospector do
  let(:introspector) { described_class.new(Rails.application) }

  describe "#call" do
    subject(:result) { introspector.call }

    it "does not return an error" do
      expect(result).not_to have_key(:error)
    end

    it "returns authentication as a hash" do
      expect(result[:authentication]).to be_a(Hash)
    end

    it "returns authorization as a hash" do
      expect(result[:authorization]).to be_a(Hash)
    end

    it "returns security as a hash" do
      expect(result[:security]).to be_a(Hash)
    end

    it "returns empty auth when no auth framework present" do
      expect(result[:authentication][:devise]).to be_nil
      expect(result[:authentication][:rails_auth]).to be_nil
    end

    it "returns empty authorization when no policies" do
      expect(result[:authorization][:pundit]).to be_nil
      expect(result[:authorization][:cancancan]).to be_nil
    end

    context "with has_secure_password in a model" do
      let(:fixture_model) { File.join(Rails.root, "app/models/account.rb") }

      before do
        File.write(fixture_model, <<~RUBY)
          class Account < ApplicationRecord
            has_secure_password
          end
        RUBY
      end

      after { FileUtils.rm_f(fixture_model) }

      it "detects has_secure_password with model name" do
        expect(result[:authentication][:has_secure_password]).to include("Account")
      end
    end

    context "with Devise in a model" do
      let(:fixture_model) { File.join(Rails.root, "app/models/admin.rb") }

      before do
        File.write(fixture_model, <<~RUBY)
          class Admin < ApplicationRecord
            devise :database_authenticatable, :registerable, :recoverable
          end
        RUBY
      end

      after { FileUtils.rm_f(fixture_model) }

      it "detects Devise models with modules" do
        devise_entry = result[:authentication][:devise]&.find { |d| d[:model] == "Admin" }
        expect(devise_entry).not_to be_nil
        expect(devise_entry[:matches].first).to include("database_authenticatable")
      end
    end

    context "with Pundit policies" do
      let(:policies_dir) { File.join(Rails.root, "app/policies") }

      before do
        FileUtils.mkdir_p(policies_dir)
        File.write(File.join(policies_dir, "post_policy.rb"), "class PostPolicy; end")
      end

      after { FileUtils.rm_rf(policies_dir) }

      it "detects Pundit policies" do
        expect(result[:authorization][:pundit]).to include("PostPolicy")
      end
    end

    context "with CSP initializer" do
      let(:csp_file) { File.join(Rails.root, "config/initializers/content_security_policy.rb") }

      before do
        FileUtils.mkdir_p(File.dirname(csp_file))
        File.write(csp_file, "# CSP config")
      end

      after { FileUtils.rm_f(csp_file) }

      it "detects CSP" do
        expect(result[:security][:csp]).to be true
      end
    end

    it "returns devise_modules_per_model as a hash" do
      expect(result[:devise_modules_per_model]).to be_a(Hash)
    end

    context "with Devise modules in a model" do
      let(:fixture_model) { File.join(Rails.root, "app/models/member.rb") }

      before do
        File.write(fixture_model, <<~RUBY)
          class Member < ApplicationRecord
            devise :database_authenticatable, :registerable, :recoverable,
                   :rememberable, :validatable
          end
        RUBY
      end

      after { FileUtils.rm_f(fixture_model) }

      it "extracts Devise modules per model" do
        modules = result[:devise_modules_per_model]["Member"]
        expect(modules).to include("database_authenticatable", "registerable", "recoverable", "rememberable", "validatable")
      end
    end

    context "with no Devise models" do
      it "returns empty hash for devise_modules_per_model" do
        expect(result[:devise_modules_per_model]).to eq({})
      end
    end

    describe "token_auth" do
      it "returns a hash with token auth keys" do
        expect(result[:token_auth]).to be_a(Hash)
        expect(result[:token_auth]).to have_key(:devise_jwt)
        expect(result[:token_auth]).to have_key(:doorkeeper)
        expect(result[:token_auth]).to have_key(:http_token_auth)
      end

      it "returns devise_jwt as not detected when gem is absent" do
        expect(result[:token_auth][:devise_jwt]).to eq({ detected: false })
      end

      it "returns doorkeeper as nil when gem is absent" do
        expect(result[:token_auth][:doorkeeper]).to be_nil
      end

      it "returns empty array for http_token_auth when no controllers use it" do
        expect(result[:token_auth][:http_token_auth]).to eq([])
      end

      context "with devise-jwt gem and initializer" do
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
              config.jwt do |jwt|
                jwt.secret = Rails.application.credentials.devise_jwt_secret_key!
              end
            end
          RUBY
        end

        after do
          FileUtils.rm_f(lock_path)
          FileUtils.rm_f(devise_init)
        end

        it "detects devise-jwt with jwt configuration" do
          expect(result[:token_auth][:devise_jwt]).to eq({ detected: true, jwt_configured: true })
        end
      end

      context "with doorkeeper gem and initializer" do
        let(:lock_path) { File.join(Rails.root, "Gemfile.lock") }
        let(:doorkeeper_init) { File.join(Rails.root, "config/initializers/doorkeeper.rb") }

        before do
          File.write(lock_path, <<~LOCK)
            GEM
              remote: https://rubygems.org/
              specs:
                doorkeeper (5.6.0)

            PLATFORMS
              ruby
          LOCK
          FileUtils.mkdir_p(File.dirname(doorkeeper_init))
          File.write(doorkeeper_init, <<~RUBY)
            Doorkeeper.configure do
              grant_flows %w[authorization_code client_credentials]
              access_token_expires_in 2.hours
            end
          RUBY
        end

        after do
          FileUtils.rm_f(lock_path)
          FileUtils.rm_f(doorkeeper_init)
        end

        it "detects doorkeeper with grant_flows and expiration" do
          dk = result[:token_auth][:doorkeeper]
          expect(dk[:detected]).to be true
          expect(dk[:grant_flows]).to eq(%w[authorization_code client_credentials])
          expect(dk[:access_token_expires_in]).to eq("2.hours")
        end
      end

      context "with http token auth in a controller" do
        let(:controller_file) { File.join(Rails.root, "app/controllers/api_tokens_controller.rb") }

        before do
          File.write(controller_file, <<~RUBY)
            class ApiTokensController < ApplicationController
              before_action :authenticate

              private

              def authenticate
                authenticate_or_request_with_http_token do |token|
                  ApiToken.find_by(token: token)
                end
              end
            end
          RUBY
        end

        after { FileUtils.rm_f(controller_file) }

        it "detects controllers using HTTP token auth" do
          expect(result[:token_auth][:http_token_auth]).to include("app/controllers/api_tokens_controller.rb")
        end
      end
    end

    describe "Rails 8 built-in auth depth" do
      let(:session_model)         { File.join(Rails.root, "app/models/session.rb") }
      let(:current_model)         { File.join(Rails.root, "app/models/current.rb") }
      let(:auth_concern)          { File.join(Rails.root, "app/controllers/concerns/authentication.rb") }
      let(:sessions_controller)   { File.join(Rails.root, "app/controllers/sessions_controller.rb") }
      let(:passwords_controller)  { File.join(Rails.root, "app/controllers/passwords_controller.rb") }
      let(:public_controller)     { File.join(Rails.root, "app/controllers/public_controller.rb") }

      before do
        FileUtils.mkdir_p(File.dirname(auth_concern))
        File.write(session_model, "class Session < ApplicationRecord; end")
        File.write(current_model, "class Current < ActiveSupport::CurrentAttributes; end")
        File.write(auth_concern, "module Authentication; extend ActiveSupport::Concern; end")
        File.write(sessions_controller, "class SessionsController < ApplicationController; end")
        File.write(passwords_controller, "class PasswordsController < ApplicationController; end")
        File.write(public_controller, <<~RUBY)
          class PublicController < ApplicationController
            allow_unauthenticated_access only: %i[index show]
          end
        RUBY
      end

      after do
        [ session_model, current_model, auth_concern, sessions_controller, passwords_controller, public_controller ].each do |f|
          FileUtils.rm_f(f)
        end
      end

      it "detects Rails 8 auth as a hash with full depth" do
        rails_auth = result[:authentication][:rails_auth]
        expect(rails_auth).to be_a(Hash)
        expect(rails_auth[:detected]).to eq(true)
        expect(rails_auth[:authentication_concern]).to eq("app/controllers/concerns/authentication.rb")
        expect(rails_auth[:sessions_controller]).to eq("app/controllers/sessions_controller.rb")
        expect(rails_auth[:passwords_controller]).to eq("app/controllers/passwords_controller.rb")
      end

      it "lists controllers with allow_unauthenticated_access including scope" do
        unauth = result[:authentication][:rails_auth][:allow_unauthenticated_access]
        expect(unauth).to be_an(Array)
        public_entry = unauth.find { |h| h[:file] == "app/controllers/public_controller.rb" }
        expect(public_entry).not_to be_nil
        expect(public_entry[:scope]).to include("only:")
        expect(public_entry[:scope]).to include("index")
      end
    end
  end
end
