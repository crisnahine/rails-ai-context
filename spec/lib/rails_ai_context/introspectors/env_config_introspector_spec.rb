# frozen_string_literal: true

require "spec_helper"
require "tmpdir"
require "fileutils"

RSpec.describe RailsAiContext::Introspectors::EnvConfigIntrospector do
  let(:app) { Rails.application }
  let(:introspector) { described_class.new(app) }
  let(:env_dir) { File.join(app.root.to_s, "config", "environments") }

  before do
    FileUtils.mkdir_p(env_dir)

    File.write(File.join(env_dir, "development.rb"), <<~RUBY)
      Rails.application.configure do
        config.enable_reloading = true
        config.eager_load = false
        config.consider_all_requests_local = true
        config.cache_store = :memory_store
        config.active_job.queue_adapter = :async
        config.action_mailer.delivery_method = :letter_opener
        config.action_mailer.raise_delivery_errors = false
      end
    RUBY

    File.write(File.join(env_dir, "production.rb"), <<~RUBY)
      Rails.application.configure do
        config.enable_reloading = false
        config.eager_load = true
        config.consider_all_requests_local = false
        config.force_ssl = true # redirect to https
        config.log_level = :info
        config.cache_store = :solid_cache_store
        config.active_job.queue_adapter = :solid_queue
        config.action_controller.perform_caching = true
      end
    RUBY
  end

  after do
    FileUtils.rm_rf(env_dir)
  end

  describe "#call" do
    subject(:result) { introspector.call }

    it "returns one entry per environment file" do
      expect(result[:count]).to eq(2)
      expect(result[:environments].map { |e| e[:name] }).to eq(%w[development production])
    end

    it "reports relative file paths" do
      files = result[:environments].map { |e| e[:file] }
      expect(files).to include("config/environments/development.rb", "config/environments/production.rb")
    end

    it "extracts assigned config keys sorted and unique" do
      dev = result[:environments].find { |e| e[:name] == "development" }
      expect(dev[:config_keys]).to include("eager_load", "cache_store", "active_job.queue_adapter")
      expect(dev[:config_keys]).to eq(dev[:config_keys].sort.uniq)
    end

    it "captures config keys deeper than two segments" do
      File.write(File.join(env_dir, "staging.rb"), <<~RUBY)
        Rails.application.configure do
          config.active_record.encryption.primary_key = "x"
        end
      RUBY

      staging = result[:environments].find { |e| e[:name] == "staging" }
      expect(staging[:config_keys]).to include("active_record.encryption.primary_key")
    end

    it "lifts notable values per environment" do
      prod = result[:environments].find { |e| e[:name] == "production" }
      expect(prod[:notable]["force_ssl"]).to eq("true")
      expect(prod[:notable]["eager_load"]).to eq("true")
      expect(prod[:notable]["log_level"]).to eq(":info")
      expect(prod[:notable]["action_controller.perform_caching"]).to eq("true")
    end

    it "strips trailing comments from notable values" do
      prod = result[:environments].find { |e| e[:name] == "production" }
      expect(prod[:notable]["force_ssl"]).not_to include("redirect")
    end

    it "does not strip a ' #' inside a string literal" do
      File.write(File.join(env_dir, "staging.rb"), <<~RUBY)
        Rails.application.configure do
          config.cache_store = :mem_cache_store, { namespace: "team #2" }
        end
      RUBY

      staging = result[:environments].find { |e| e[:name] == "staging" }
      expect(staging[:notable]["cache_store"]).to include('namespace: "team #2"')
    end

    it "redacts URI credentials from notable values" do
      File.write(File.join(env_dir, "staging.rb"), <<~RUBY)
        Rails.application.configure do
          config.cache_store = :redis_cache_store, { url: "redis://:secretpass@redis.internal:6379/0" }
        end
      RUBY

      staging = result[:environments].find { |e| e[:name] == "staging" }
      expect(staging[:notable]["cache_store"]).not_to include("secretpass")
      expect(staging[:notable]["cache_store"]).to include("redis://[FILTERED]@")
    end

    it "redacts credentials even when truncation would cut before the host" do
      File.write(File.join(env_dir, "staging.rb"), <<~RUBY)
        Rails.application.configure do
          config.cache_store = :redis_cache_store, { url: "redis://:thisisaverylongsecretpassword@redis.internal:6379/0" }
        end
      RUBY

      staging = result[:environments].find { |e| e[:name] == "staging" }
      expect(staging[:notable]["cache_store"]).not_to include("thisisaverylongsecretpassword")
      expect(staging[:notable]["cache_store"]).to include("[FILTERED]")
    end

    it "redacts password-style option values" do
      File.write(File.join(env_dir, "staging.rb"), <<~RUBY)
        Rails.application.configure do
          config.cache_store = :redis_cache_store, { password: "hunter2" }
        end
      RUBY

      staging = result[:environments].find { |e| e[:name] == "staging" }
      expect(staging[:notable]["cache_store"]).not_to include("hunter2")
      expect(staging[:notable]["cache_store"]).to include('password: "[FILTERED]"')
    end

    it "redacts underscore-prefixed credential keys" do
      File.write(File.join(env_dir, "staging.rb"), <<~RUBY)
        Rails.application.configure do
          config.cache_store = :redis_cache_store, { auth_token: "tok_secret_123" }
        end
      RUBY

      staging = result[:environments].find { |e| e[:name] == "staging" }
      expect(staging[:notable]["cache_store"]).not_to include("tok_secret_123")
      expect(staging[:notable]["cache_store"]).to include("[FILTERED]")
    end

    it "leaves non-credential values untouched" do
      File.write(File.join(env_dir, "staging.rb"), <<~RUBY)
        Rails.application.configure do
          config.cache_store = :redis_cache_store, { namespace: "tokens", pool_size: 5 }
        end
      RUBY

      staging = result[:environments].find { |e| e[:name] == "staging" }
      expect(staging[:notable]["cache_store"]).to include('namespace: "tokens"')
      expect(staging[:notable]["cache_store"]).not_to include("[FILTERED]")
    end

    it "reports the current environment" do
      expect(result[:current]).to eq(Rails.env.to_s)
    end

    it "does not raise on a fresh Rails app" do
      expect(result).not_to have_key(:error)
    end

    context "when no environments directory exists" do
      let(:tmpdir) { Dir.mktmpdir }
      let(:app) { double("app", root: tmpdir) }

      # The outer before writes fixtures into app.root - here that IS the
      # tmpdir, so remove them to simulate an app without environments.
      before { FileUtils.rm_rf(env_dir) }
      after { FileUtils.rm_rf(tmpdir) }

      it "returns an empty list rather than an error" do
        expect(result[:count]).to eq(0)
        expect(result[:environments]).to eq([])
        expect(result).not_to have_key(:error)
      end
    end
  end

  describe "#static_call" do
    it "serves the same file-based data without a booted app" do
      expect(introspector.static_call[:count]).to eq(2)
    end
  end
end
