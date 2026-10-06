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

    it "lists keys set with <<, +=, a method call or a block, and not the receivers of a deeper assignment" do
      File.write(File.join(env_dir, "staging.rb"), <<~RUBY)
        Rails.application.configure do
          config.hosts << "staging.example.com"
          config.action_dispatch.default_headers["X-Frame-Options"] = "DENY"
          config.middleware.use Rack::Deflater
          config.session_store :cookie_store, key: "_x"
          config.filter_parameters += [:pin_code]
          config.log_tags ||= [:request_id]
          config.generators do |g|
            g.test_framework :rspec
          end
          config.after_initialize do
            Rails.logger.info("boot")
          end
          config.x.payments.provider = "acme"
          config.cache_store = :redis_cache_store, { url: ENV["REDIS_URL"] }
        end
      RUBY

      staging = result[:environments].find { |e| e[:name] == "staging" }
      expect(staging[:config_keys]).to eq(%w[
        action_dispatch.default_headers after_initialize cache_store filter_parameters generators hosts log_tags middleware session_store x.payments.provider
      ])
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

    it "reads an assignment whose value spans lines" do
      File.write(File.join(env_dir, "staging.rb"), <<~RUBY)
        Rails.application.configure do
          config.cache_store = :redis_cache_store, {
            url: "redis://cache.internal:6379/0",
            pool_size: 5
          }
        end
      RUBY

      staging = result[:environments].find { |e| e[:name] == "staging" }
      expect(staging[:config_keys]).to include("cache_store")
      # The value is the whole expression, not the fragment before the first
      # newline, and it renders on one line.
      expect(staging[:notable]["cache_store"]).to include("redis://cache.internal")
      expect(staging[:notable]["cache_store"]).not_to include("\n")
    end

    it "reads an assignment indented inside a nested block" do
      File.write(File.join(env_dir, "staging.rb"), <<~RUBY)
        Rails.application.configure do
          if ENV["SSL"]
            config.force_ssl = true
          end
        end
      RUBY

      staging = result[:environments].find { |e| e[:name] == "staging" }
      expect(staging[:config_keys]).to include("force_ssl")
      expect(staging[:notable]["force_ssl"]).to eq("true")
    end

    it "reads an assignment written on the fully qualified receiver" do
      File.write(File.join(env_dir, "staging.rb"), <<~RUBY)
        Rails.application.config.log_level = :warn
      RUBY

      staging = result[:environments].find { |e| e[:name] == "staging" }
      expect(staging[:config_keys]).to include("log_level")
      expect(staging[:notable]["log_level"]).to eq(":warn")
    end

    it "ignores a config-shaped assignment that is only a comment" do
      File.write(File.join(env_dir, "staging.rb"), <<~RUBY)
        Rails.application.configure do
          # config.force_ssl = true
          config.log_level = :info
        end
      RUBY

      staging = result[:environments].find { |e| e[:name] == "staging" }
      expect(staging[:config_keys]).to eq(%w[log_level])
    end

    it "keeps the other environments when one file will not parse" do
      File.write(File.join(env_dir, "staging.rb"), <<~RUBY)
        Rails.application.configure do
          config.force_ssl = true
        # no end
      RUBY

      expect(result[:environments].map { |e| e[:name] }).to include("development", "production")
      expect(result).not_to have_key(:error)
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

  # Rails' own generated development.rb assigns perform_caching in both
  # halves of one `if`. Reporting the first made this tool say `true` where
  # the running app, and `rails_get_config`, said `false`.
  describe "a key assigned in more than one branch" do
    let(:tmpdir) { Dir.mktmpdir }
    let(:app) { double("app", root: tmpdir) }

    before do
      FileUtils.mkdir_p(File.join(tmpdir, "config", "environments"))
      File.write(File.join(tmpdir, "config", "environments", "development.rb"), <<~RUBY)
        Rails.application.configure do
          if Rails.root.join('tmp', 'caching-dev.txt').exist?
            config.action_controller.perform_caching = true
            config.cache_store = :memory_store
          else
            config.action_controller.perform_caching = false
            config.cache_store = :null_store
          end
          config.eager_load = false
        end
      RUBY
    end

    after { FileUtils.rm_rf(tmpdir) }

    let(:notable) { introspector.call[:environments].first[:notable] }

    it "names every value with the branch it belongs to" do
      expect(notable["cache_store"]).to eq(":memory_store if Rails.root.join('tmp', 'caching-dev.txt').exist?, else :null_store")
    end

    it "leaves an unconditional assignment alone" do
      expect(notable["eager_load"]).to eq("false")
    end
  end

  # Two unconditional assignments of one key are not a tuple value: Rails
  # runs both lines and the second wins, and the comma-joined rendering was
  # indistinguishable from `:mem_cache_store, { pool_size: 5 }`.
  describe "a key assigned twice unconditionally" do
    let(:tmpdir) { Dir.mktmpdir }
    let(:app) { double("app", root: tmpdir) }

    before do
      FileUtils.mkdir_p(File.join(tmpdir, "config", "environments"))
      File.write(File.join(tmpdir, "config", "environments", "production.rb"), <<~RUBY)
        Rails.application.configure do
          config.action_mailer.delivery_method = :file
          config.cache_store = :mem_cache_store, { pool_size: 5 }
          config.action_mailer.delivery_method = :smtp
        end
      RUBY
    end

    after { FileUtils.rm_rf(tmpdir) }

    let(:notable) { introspector.call[:environments].find { |e| e[:name] == "production" }[:notable] }

    it "names the assignment that wins, and says what it overrode" do
      expect(notable["action_mailer.delivery_method"]).to eq(":smtp (overrides :file)")
    end

    # Rails runs every line, so the last one wins however many times the key
    # was set before it.
    it "names the last assignment even when an earlier value repeats" do
      File.write(File.join(tmpdir, "config", "environments", "production.rb"), <<~RUBY)
        Rails.application.configure do
          config.action_mailer.delivery_method = :file
          config.action_mailer.delivery_method = :smtp
          config.action_mailer.delivery_method = :file
        end
      RUBY

      expect(notable["action_mailer.delivery_method"]).to eq(":file (overrides :smtp)")
    end

    # The unconditional assignment runs after the conditional one, so reading
    # it first says the conditional value is the one in force.
    it "keeps the assignments in the order the file runs them" do
      File.write(File.join(tmpdir, "config", "environments", "production.rb"), <<~RUBY)
        Rails.application.configure do
          config.cache_store = :null_store if ENV["NO_CACHE"]
          config.cache_store = :mem_cache_store
        end
      RUBY

      expect(notable["cache_store"]).to eq(":null_store if ENV[\"NO_CACHE\"], :mem_cache_store")
    end

    it "leaves a single assignment whose value holds a comma unchanged" do
      expect(notable["cache_store"]).to eq(":mem_cache_store, { pool_size: 5 }")
    end
  end

  describe "static tier" do
    it "is declared files-only, so call serves the same data unbooted" do
      expect(described_class.static_tier).to eq(:files_only)
      expect(introspector.call[:count]).to eq(2)
    end
  end

  describe "config/application.rb" do
    def application(files)
      Dir.mktmpdir do |dir|
        files.each do |path, body|
          FileUtils.mkdir_p(File.dirname(File.join(dir, path)))
          File.write(File.join(dir, path), body)
        end
        described_class.new(RailsAiContext::StaticApp.new(dir)).call[:application]
      end
    end

    let(:application_rb) do
      <<~RUBY
        module App
          class Application < Rails::Application
            config.load_defaults 7.1
            config.active_record.pluralize_table_names = false
            config.active_job.queue_name_prefix = "myapp"
            config.x.payments.provider = "stripe"
            config.payment = config_for(:payment)
            config.mail = Rails.application.config_for("mail")
          end
        end
      RUBY
    end

    it "lists the keys it sets for every environment, config.x included" do
      result = application("config/application.rb" => application_rb)

      expect(result[:file]).to eq("config/application.rb")
      expect(result[:config_keys]).to include("active_record.pluralize_table_names", "active_job.queue_name_prefix",
                                              "x.payments.provider", "payment", "load_defaults")
    end

    it "names the keys each config_for file gives the running environment, shared merged in, never the values" do
      result = application(
        "config/application.rb" => application_rb,
        "config/payment.yml" => "shared:\n  currency: usd\ntest:\n  key: dev\nproduction:\n  key: <%= ENV[\"PAYMENT_KEY\"] %>\n  secret: x\n"
      )

      expect(result[:config_for]).to eq([
        { key: "payment", call: ":payment", file: "config/payment.yml", keys: %w[currency key] },
        { key: "mail", call: '"mail"', file: "config/mail.yml", missing: true }
      ])
    end

    it "reads the keys of the environment a literal env: names, and no keys when env: is an expression" do
      result = application(
        "config/application.rb" => <<~RUBY,
          module App
            class Application < Rails::Application
              config.feature = config_for(:feature, env: "production")
              config.other = config_for(:feature, env: ENV["DEPLOY_ENV"])
              config.same = config_for(:feature, env: Rails.env)
            end
          end
        RUBY
        "config/feature.yml" => "shared:\n  flag_a: true\ntest:\n  dev_only: 1\nproduction:\n  prod_only: 2\n"
      )

      expect(result[:config_for]).to eq([
        { key: "feature", call: ":feature", file: "config/feature.yml", environment: "production", keys: %w[flag_a prod_only] },
        { key: "other", call: ":feature", file: "config/feature.yml", environment_unread: true },
        { key: "same", call: ":feature", file: "config/feature.yml", keys: %w[dev_only flag_a] }
      ])
    end

    it "lets a failure reading config/application.rb raise, for the introspector loop to record" do
      allow(RailsAiContext::Introspectors::SourceIntrospector).to receive(:walk).and_raise(ArgumentError, "File too large")

      expect { application("config/application.rb" => application_rb) }.to raise_error(ArgumentError, "File too large")
    end

    it "is nil for an app without config/application.rb" do
      expect(application({})).to be_nil
    end

    it "reads a config_for file that is not YAML as unreadable rather than failing" do
      result = application("config/application.rb" => application_rb, "config/payment.yml" => "shared: [unclosed\n")

      expect(result[:config_for].first).to eq({ key: "payment", call: ":payment", file: "config/payment.yml", unreadable: true })
    end

    it "reads a config_for under a secret-shaped key, and a Pathname path, off the node" do
      result = application(
        "config/application.rb" => <<~RUBY,
          module App
            class Application < Rails::Application
              config.secret_store = config_for(:vault)
              config.x.stripe = config_for(Rails.root.join("config", "stripe.yml"))
              config.other = config_for(Rails.root.join(dir, "x.yml"))
            end
          end
        RUBY
        "config/vault.yml" => "shared:\n  address: x\n",
        "config/stripe.yml" => "test:\n  publishable_key: x\n"
      )

      expect(result[:config_for]).to eq([
        { key: "secret_store", call: ":vault", file: "config/vault.yml", keys: %w[address] },
        { key: "x.stripe", call: 'Rails.root.join("config", "stripe.yml")', file: "config/stripe.yml", keys: %w[publishable_key] },
        { key: "other", call: 'Rails.root.join(dir, "x.yml")', path_unread: true }
      ])
    end

    it "does not read a config_for file on sensitive_patterns, and says so" do
      result = application(
        "config/application.rb" => "module App\n  class Application < Rails::Application\n    config.redis = config_for(:redis)\n  end\nend\n",
        "config/redis.yml" => "shared:\n  url: redis://x\n"
      )

      expect(result[:config_for]).to eq([ { key: "redis", call: ":redis", file: "config/redis.yml", withheld: true } ])
    end
  end
end
