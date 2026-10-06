# frozen_string_literal: true

require "spec_helper"
require "prism"

RSpec.describe RailsAiContext::Introspectors::Listeners::ConfigAssignmentListener do
  def assignments(source, *roots)
    parse_and_dispatch(source, *roots).select { |r| r[:assignment] }
  end

  it "reads a flat config assignment" do
    results = assignments("config.timeout_in = 30.minutes")

    expect(results.size).to eq(1)
    expect(results.first[:path]).to eq([ :timeout_in ])
    expect(results.first[:source]).to eq("30.minutes")
  end

  it "reads a config_for call off its node: the arguments as written, the file, the env: literal, and a path or env it cannot read" do
    results = assignments(<<~RUBY)
      config.secret_store = config_for(:vault)
      config.api_token_settings = Rails.application.config_for("tokens", env: "production")
      config.x.stripe = config_for(Rails.root.join("config", "stripe.yml"), env: Rails.env)
      config.other = config_for(Rails.root.join(dir, "x.yml"), env: ENV["DEPLOY_ENV"])
      config.rooted = config_for(config.root.join("config", "rooted.yml"))
      config.gem = config_for(Gem.root.join("config", "gem.yml"))
      config.plain = 3
    RUBY

    expect(results.map { |r| r[:config_for] }).to eq([
      { arguments: ":vault", file: "config/vault.yml" },
      { arguments: '"tokens", env: "production"', file: "config/tokens.yml", env: "production" },
      { arguments: 'Rails.root.join("config", "stripe.yml"), env: Rails.env', file: "config/stripe.yml" },
      { arguments: 'Rails.root.join(dir, "x.yml"), env: ENV["DEPLOY_ENV"]', env: :expression },
      { arguments: 'config.root.join("config", "rooted.yml")', file: "config/rooted.yml" },
      { arguments: 'Gem.root.join("config", "gem.yml")' },
      nil
    ])
  end

  it "keeps a heredoc value's body in its source" do
    results = assignments(<<~RUBY)
      config.banner = <<~TXT.squish
        Scheduled maintenance tonight
      TXT
      config.timeout_in = 30.minutes
    RUBY

    expect(results.first[:source]).to eq("<<~TXT.squish\n  Scheduled maintenance tonight\nTXT\n")
  end

  it "reads Klass.name as the class name, and a value constant's .name as unknown" do
    results = assignments("config.job_class = Cron::CleanupJob.name\nconfig.prefix = APP_SETTINGS.name\nconfig.other = Config::APP.name")

    expect(results.map { |r| r[:value] }).to eq([ "Cron::CleanupJob", RailsAiContext::Confidence::INFERRED, RailsAiContext::Confidence::INFERRED ])
  end

  it "reads self inside an on_load block as that hook's root, and not inside a def" do
    source = <<~RUBY
      ActiveSupport.on_load(:active_record) do
        self.table_name_prefix = "app_"
        def self.helper
          self.ignored = 1
        end
      end
      ActiveSupport.on_load(:action_controller) { self.other = 2 }
      self.outside = 3
    RUBY

    results = assignments(source, "on_load(:active_record)")

    expect(results.map { |r| [ r[:path], r[:value] ] }).to eq([ [ [ :table_name_prefix ], "app_" ] ])
    expect(assignments(source)).to eq([])
  end

  it "reads a rooted ActiveSupport receiver and a block parameter in the on_load hook as its root" do
    source = <<~RUBY
      ::ActiveSupport.on_load(:active_record) { self.table_name_prefix = "x_" }
      ActiveSupport.on_load(:active_record) { |base| base.pluralize_table_names = false }
      ActiveSupport.on_load(:active_record) { _1.primary_key_prefix_type = :table_name }
      ActiveSupport.on_load(:active_record) { it.table_name_suffix = "_y" }
      ActiveSupport.on_load(:active_record) { |(a, b)| a.skipped = 1 }
      ActiveSupport.on_load(:active_record) do |base|
        other = base
        def self.helper(base)
          base.ignored = 1
        end
      end
      base.outside = 3
    RUBY

    results = assignments(source, "on_load(:active_record)")

    expect(results.map { |r| [ r[:path], r[:value] ] }).to eq([ [ [ :table_name_prefix ], "x_" ], [ [ :pluralize_table_names ], false ],
                                                                    [ [ :primary_key_prefix_type ], :table_name ], [ [ :table_name_suffix ], "_y" ] ])
  end

  it "reads neither a class body nor a class_eval block inside the hook as the hook's self" do
    source = <<~RUBY
      ActiveSupport.on_load(:active_record) do
        self.table_name_prefix = "op_"
        Legacy::Record.class_eval do
          self.table_name_suffix = "_bad"
        end
        class Foo
          self.table_name_suffix = "_worse"
        end
        instance_eval { self.pluralize_table_names = false }
      end
    RUBY

    results = assignments(source, "on_load(:active_record)")

    expect(results.map { |r| [ r[:path], r[:value] ] }).to eq([ [ [ :table_name_prefix ], "op_" ], [ [ :pluralize_table_names ], false ] ])
  end

  it "reads a class_eval on the hook's own self, its block param or a root constant as that root" do
    source = <<~RUBY
      ActiveSupport.on_load(:active_record) { self.class_eval { self.table_name_prefix = "ce_" } }
      ActiveSupport.on_load(:active_record) { |base| base.class_eval { self.table_name_suffix = "_ce" } }
      ActiveRecord::Base.class_eval { self.pluralize_table_names = false }
    RUBY

    results = assignments(source, "on_load(:active_record)", "ActiveRecord::Base")

    expect(results.map { |r| [ r[:path], r[:value] ] }).to eq([ [ [ :table_name_prefix ], "ce_" ], [ [ :table_name_suffix ], "_ce" ], [ [ :pluralize_table_names ], false ] ])
  end

  it "reads the hook's block param and a ::ActiveSupport receiver as the hook's root" do
    source = <<~RUBY
      ::ActiveSupport.on_load(:active_record) do |base|
        base.table_name_prefix = "op_"
        [1].each { |base| base.ignored = 1 }
      end
      ActiveSupport.on_load(:active_record, yield: true) { |base| self.not_base = 1; base.schema_format = :sql }
    RUBY

    results = assignments(source, "on_load(:active_record)")

    expect(results.map { |r| [ r[:path], r[:value] ] }).to eq([ [ [ :table_name_prefix ], "op_" ], [ [ :schema_format ], :sql ] ])
  end

  it "reads the param of a block call it is given as a root, whatever each block names it" do
    source = <<~RUBY
      Apartment.configure do |config|
        config.excluded_models = ["User"]
      end
      ::Apartment.configure { |c| c.tenant_names = ["a"] }
      config.outside = 1
    RUBY

    results = assignments(source, "Apartment.configure")

    expect(results.map { |r| r[:path] }).to eq([ [ :excluded_models ], [ :tenant_names ] ])
  end

  it "reads a nested config assignment" do
    results = assignments("config.action_mailer.delivery_method = :smtp")

    expect(results.first[:path]).to eq([ :action_mailer, :delivery_method ])
    expect(results.first[:value]).to eq(:smtp)
  end

  it "extracts literal values" do
    results = assignments(<<~RUBY)
      config.maximum_attempts = 5
      config.lock_strategy = :failed_attempts
      config.reconfirmable = true
      config.mailer_sender = "noreply@example.com"
    RUBY

    expect(results.map { |r| [ r[:path].first, r[:value] ] }).to eq([
      [ :maximum_attempts, 5 ],
      [ :lock_strategy, :failed_attempts ],
      [ :reconfirmable, true ],
      [ :mailer_sender, "noreply@example.com" ]
    ])
  end

  # `source` is redacted at emission; `value` sat beside it unredacted, so the
  # property the comment claims - a new reader of this listener is safe
  # without remembering anything - held for one of the two fields.
  it "redacts the evaluated value of a secret-named setting too" do
    results = parse_and_dispatch(<<~RUBY)
      config.secret_key = "s3cr3t"
    RUBY

    expect(results.first[:value]).to eq("[FILTERED]")
    expect(results.first[:source]).to eq('"[FILTERED]"')
  end

  it "filters an encryption key that only its path marks as a secret" do
    results = parse_and_dispatch(<<~RUBY)
      config.active_record.encryption.primary_key = "deadbeef01234567"
    RUBY

    expect(results.first[:value]).to eq("[FILTERED]")
    expect(results.first[:source]).to eq('"[FILTERED]"')
  end

  it "filters a credential nested under an ordinary setting" do
    results = parse_and_dispatch(<<~RUBY)
      config.action_mailer.smtp_settings = { user_name: "app", password: "hunter2" }
    RUBY

    expect(results.first[:value]).to eq(user_name: "app", password: "[FILTERED]")
  end

  it "leaves an ordinary setting's evaluated value alone" do
    results = parse_and_dispatch(<<~RUBY)
      config.eager_load = true
    RUBY

    expect(results.first[:value]).to be(true)
  end

  it "keeps the raw source for values it cannot evaluate" do
    results = assignments("config.password_length = 6..128")

    expect(results.first[:source]).to eq("6..128")
  end

  it "matches a chain rooted deeper than the receiver" do
    results = assignments("Rails.application.config.assets.paths = paths")

    expect(results.first[:path]).to eq([ :assets, :paths ])
  end

  it "matches the app's own config under any name, and no other library's" do
    results = parse_and_dispatch(<<~RUBY)
      MyApp::Application.config.time_zone = "UTC"
      app.config.eager_load = true
      OmniAuth.config.test_mode = true
      OmniAuth.config.mock_auth[:github] = { uid: "1" }
    RUBY

    expect(results.map { |r| r[:path] }).to eq([ [ :time_zone ], [ :eager_load ] ])
  end

  it "records a bare config reference so block sections are visible" do
    results = parse_and_dispatch(<<~RUBY)
      config.jwt do |jwt|
        jwt.secret = "x"
      end
    RUBY

    jwt = results.find { |r| r[:path] == [ :jwt ] }
    expect(jwt[:assignment]).to be false
  end

  it "records a setting written with <<, a call with arguments, an operator or a block" do
    writes = parse_and_dispatch(<<~RUBY).select { |r| r[:write] }.map { |r| [ r[:path], r[:write] ] }
      config.hosts << "x"
      config.action_dispatch.default_headers["X-Frame-Options"] = "DENY"
      config.session_store :cookie_store
      config.filter_parameters += [:pin]
      config.generators do |g|
        g.test_framework :rspec
      end
      config.x == 1
      config.hosts.include?("y")
    RUBY

    expect(writes).to eq([
      [ [ :hosts, :<< ], :call ], [ [ :action_dispatch, :default_headers, :[]= ], :call ], [ [ :session_store ], :call ], [ [ :filter_parameters ], :operator ],
      [ [ :generators ], :block ]
    ])
  end

  it "records a chained << and a write under a rescue modifier" do
    writes = parse_and_dispatch(<<~RUBY).select { |r| r[:write] }.map { |r| r[:path] }
      config.hosts << "a" << "b"
      config.middleware.push("x") rescue nil
    RUBY

    expect(writes).to eq([ [ :hosts, :<< ], [ :middleware, :push ] ])
  end

  it "records a write through an index read as a write of the indexed setting" do
    writes = parse_and_dispatch(<<~RUBY).select { |r| r[:write] }.map { |r| r[:path] }
      config.paths["config/routes.rb"] << "config/extra_routes.rb"
      config.paths["app/views"].unshift "custom/views"
    RUBY

    expect(writes).to eq([ [ :paths, :<< ], [ :paths, :unshift ] ])
  end

  it "reads a call whose value is used, not run as a statement, as a read" do
    writes = parse_and_dispatch(<<~RUBY).select { |r| r[:write] }.map { |r| r[:path] }
      local_secret_path = config.root.join("tmp/local_secret.txt")
      config.paths["db/migrate"] << config.root.join("db/native").to_s if ENV["NATIVE"]
      File.read(config.root.join("VERSION"))
    RUBY

    expect(writes).to eq([ [ :paths, :<< ] ])
  end

  it "ignores a method parameter that happens to be named config" do
    results = parse_and_dispatch(<<~RUBY)
      module PostgreSQLEarlyExtensions
        def initialize(config)
          config = config.dup
          config[:prepared_statements] = false
          super
        end
      end
      Devise.setup do |config|
        config.timeout_in = 5
      end
    RUBY

    expect(results.map { |r| r[:path] }).to eq([ [ :timeout_in ] ])
  end

  it "ignores assignments on other receivers" do
    expect(assignments("settings.timeout_in = 5")).to be_empty
  end

  it "accepts a custom root name" do
    results = assignments("setup.timeout_in = 5", :setup)

    expect(results.first[:path]).to eq([ :timeout_in ])
  end

  it "reports line locations" do
    results = assignments("\nconfig.timeout_in = 5")

    expect(results.first[:location]).to eq(2)
  end
end
