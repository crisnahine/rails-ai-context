# frozen_string_literal: true

require "spec_helper"

RSpec.describe RailsAiContext::InitializerSettings do
  around do |example|
    config = RailsAiContext.configuration
    saved = described_class::KEYS.to_h { |key| [ key, config.public_send(key).dup ] }
    Dir.mktmpdir do |dir|
      @root = dir
      example.run
    end
  ensure
    saved.each { |key, value| config.public_send(:"#{key}=", value) }
  end

  let(:config) { RailsAiContext.configuration }

  def write(relative, source)
    path = File.join(@root, relative)
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, source)
  end

  def apply
    described_class.apply!(@root)
  end

  it "adds every literal a configure block writes to a security setting, in each write form" do
    write("config/initializers/rails_ai_context.rb", <<~RUBY)
      # frozen_string_literal: true

      if defined?(RailsAiContext) && RailsAiContext.respond_to?(:configure)
        RailsAiContext.configure do |config|
          config.ai_tools = %i[claude]
          config.sensitive_patterns += %w[config/partner_keys.rb]
          config.sensitive_patterns << "config/vault.yml" << "config/vault2.yml"
          config.sensitive_patterns.push("a.secret", *%w[b.secret])
          # config.sensitive_patterns += %w[commented.yml]
          config.excluded_paths.concat(%w[private_data])
          config.skip_tools = %i[rails_read_logs].freeze
          config.skip_tools |= ["rails_query"] if Rails.env.production?
          config.excluded_paths = Rails.env.test? ? %w[fixtures_private] : []
        end
      end
    RUBY
    apply

    expect(config.sensitive_patterns).to include("config/partner_keys.rb", "config/vault.yml", "config/vault2.yml", "a.secret", "b.secret", "config/master.key")
    expect(config.sensitive_patterns).not_to include("commented.yml")
    expect(config.excluded_paths).to include("private_data", "fixtures_private", "node_modules")
    expect(config.skip_tools).to include("rails_read_logs", "rails_query")
  end

  it "reads a block param of any name, a numbered or `it` param, and the configuration called by name" do
    write("config/initializers/a.rb", "RailsAiContext.configure { |c| c.sensitive_patterns << 'one.yml' }\n")
    write("config/initializers/b.rb", "RailsAiContext.configure { _1.sensitive_patterns << 'two.yml' }\n")
    write("config/initializers/c.rb", "::RailsAiContext.configuration.sensitive_patterns += %w[three.yml]\n")
    write("config/initializers/nested/d.rb", "RailsAiContext.configure do |config|\n  config.skip_tools << :rails_get_env\nend\n")
    apply

    expect(config.sensitive_patterns).to include("one.yml", "two.yml", "three.yml")
    expect(config.skip_tools).to include("rails_get_env")
  end

  it "keeps what a removal would drop, as the stricter reading" do
    write("config/initializers/rails_ai_context.rb", <<~RUBY)
      RailsAiContext.configure do |config|
        config.sensitive_patterns -= %w[config/database.yml]
        config.sensitive_patterns.delete(".env")
      end
    RUBY
    apply

    expect(config.sensitive_patterns).to include("config/database.yml", ".env")
  end

  # A block in config/application.rb runs before the YAML, and assigning a key there keeps the YAML off it.
  it "adds the defaults back under a key a block assigns before the YAML loads" do
    config.sensitive_patterns = %w[only.yml]
    write("config/application.rb", <<~RUBY)
      module Shop
        class Application < Rails::Application
          RailsAiContext.configure { |c| c.sensitive_patterns += %w[extra.yml] }
        end
      end
    RUBY
    apply

    expect(config.sensitive_patterns).to include("only.yml", "extra.yml", "config/master.key")
  end

  it "refuses a write it cannot read, naming the file and line" do
    {
      "config.sensitive_patterns += SECRET_FILES" => "sensitive_patterns",
      "config.excluded_paths += Dir['private/*']" => "excluded_paths",
      "config.sensitive_patterns += %W[\#{Rails.root}/x]" => "sensitive_patterns",
      "patterns = config.sensitive_patterns" => "sensitive_patterns",
      "config.sensitive_patterns.map!(&:upcase)" => "sensitive_patterns",
      "add_secrets(config)" => "config",
      "config.instance_eval { self.skip_tools = [] }" => "config"
    }.each do |line, named|
      write("config/initializers/rails_ai_context.rb", "RailsAiContext.configure do |config|\n  #{line}\nend\n")

      expect { apply }.to raise_error(RailsAiContext::ConfigurationError) { |error|
        expect(error.message).to include("config/initializers/rails_ai_context.rb:2", "`#{named}`", ".rails-ai-context.yml")
      }, line
    end
  end

  it "reads no file that does not name the gem, and none the app does not run as it boots" do
    write("config/initializers/other.rb", "config.sensitive_patterns += SECRET_FILES\n")
    %w[db/seeds.rb spec/support/ai.rb test/test_helper.rb vendor/bundle/ruby/3.4.0/gems/x/lib/x.rb tmp/x.rb].each do |path|
      write(path, "RailsAiContext.configuration.sensitive_patterns += SECRET_FILES\n")
    end
    write("lib/mcp_tools/pattern_count.rb", <<~RUBY)
      class PatternCount < RailsAiContext::Tools::BaseTool
        def self.call(server_context: nil)
          RailsAiContext.log_warn("counting") if RailsAiContext.static_tier?
          names = RailsAiContext.configuration.sensitive_patterns.map { |p| p.upcase }
          text_response(names.size.to_s) if RailsAiContext.configuration.excluded_paths.any? { |path| path.start_with?("x") }
        end
      end
    RUBY
    # Files the app holds mid-edit, or in shapes this reader never visits, when they do not name the gem.
    write("config/initializers/loader.rb", "module Loader\n  def self.go = require\nend\n")
    write("config/initializers/wip.rb", "require(\n")
    write("config/initializers/deep.rb", "TOTAL = #{Array.new(5000, '1').join(' + ')}\n")

    expect { apply }.not_to raise_error
  end

  it "reads every Ruby file of the app that names the gem, however it is loaded" do
    write("app/models/x.rb", "RailsAiContext.configuration.sensitive_patterns << \"app.yml\"\n")
    write("shared_init/harden.rb", "require File.expand_path(\"../../lib/ai_hardening\", __dir__)\n")
    write("lib/ai_hardening.rb", "RailsAiContext.configure { |c| c.sensitive_patterns << \"expand.yml\" }\n")
    write("app/services/ai_settings.rb", "module AiSettings\n  def self.apply\n    RailsAiContext.configure { |c| c.excluded_paths << \"service_data\" }\n  end\nend\n")
    write("engines/billing/config/initializers/ai.rb", "RailsAiContext.configure { |c| c.skip_tools << :rails_query }\n")
    write("shared_init/rac.rb", "RailsAiContext.configure { |c| c.sensitive_patterns << \"linked.yml\" }\n")
    FileUtils.mkdir_p(File.join(@root, "config"))
    File.symlink(File.join(@root, "shared_init"), File.join(@root, "config/initializers"))
    apply

    expect(config.sensitive_patterns).to include("app.yml", "expand.yml", "linked.yml")
    expect(config.excluded_paths).to include("service_data")
    expect(config.skip_tools).to include("rails_query")

    write("app/models/x.rb", "RailsAiContext.configuration.sensitive_patterns += SECRET_FILES\n")
    expect { apply }.to raise_error(RailsAiContext::ConfigurationError, %r{app/models/x\.rb:1})
  end

  # Outside config/ a file is read for what it writes: a tool or a helper that only reads the settings runs at request time.
  it "reads code outside config/ for its writes only, and refuses one it cannot read" do
    write("app/tools/guard_tool.rb", <<~RUBY)
      class GuardTool < RailsAiContext::Tools::BaseTool
        def self.call(path:, server_context: nil)
          blocked = RailsAiContext.configuration.sensitive_patterns.any? { |pat| File.fnmatch?(pat, path) }
          list = RailsAiContext.configuration.sensitive_patterns.map { |p| "- \#{p}" }.join("\n")
          RailsAiContext.configuration.skip_tools.each { |t| Rails.logger.info(t) }
          text_response([ blocked, list, RailsAiContext.configuration.excluded_paths.first ].inspect)
        end

        def self.patterns = RailsAiContext.configuration.sensitive_patterns
      end
    RUBY
    write("lib/ai_more.rb", "RailsAiContext.configuration.sensitive_patterns << \"lib_more.yml\"\n")
    apply
    expect(config.sensitive_patterns).to include("lib_more.yml")

    {
      "RailsAiContext.configuration.sensitive_patterns.concat(ENV['X'].split(','))" => "sensitive_patterns",
      "RailsAiContext.configuration.sensitive_patterns.each { |p| p << '.rb' }" => "sensitive_patterns",
      "RailsAiContext.configuration.sensitive_patterns.map!(&:upcase)" => "sensitive_patterns",
      "RailsAiContext.send(:configuration).sensitive_patterns << 'x.yml'" => "RailsAiContext",
      "class RailsAiContext::Configuration; end" => "RailsAiContext::Configuration"
    }.each do |line, named|
      write("lib/ai_more.rb", "#{line}\n")
      expect { apply }.to raise_error(RailsAiContext::ConfigurationError, /lib\/ai_more\.rb:1: .*`#{Regexp.escape(named)}`/), line
    end
  end

  # A file's top level and class bodies run as it loads, at boot when the boot requires it; a method runs when called.
  it "reads the top level of a file outside config/ strictly, and only a method's body for its writes" do
    {
      "RailsAiContext.configuration.sensitive_patterns.last << '.rb'" => 1,
      "RailsAiContext.configure do |config|\n  config.sensitive_patterns.last << '.rb'\nend" => 2,
      "RailsAiContext.configuration.sensitive_patterns.find { |p| p.end_with?('keys') } << '.rb'" => 1,
      "RailsAiContext.configuration.sensitive_patterns.each { |p| q = p; q << '.rb' }" => 1,
      "list = RailsAiContext.configuration.sensitive_patterns\nlist << 'config/partner_keys.rb'" => 1
    }.each do |source, line|
      write("lib/ai_settings.rb", "#{source}\n")

      expect { apply }.to raise_error(RailsAiContext::ConfigurationError, /lib\/ai_settings\.rb:#{line}: .*`sensitive_patterns`/), source
    end
  end

  it "reads an add in any Rails hook's block, and refuses one a call keeps the value of" do
    write("config/application.rb", "class Application < Rails::Application\n  config.before_configuration do\n    config.rails_ai_context.sensitive_patterns << \"before.yml\"\n  end\nend\n")
    write("config/initializers/routes_hook.rb", "Rails.application.config.after_routes_loaded do\n  RailsAiContext.configuration.sensitive_patterns << \"routes.yml\"\nend\n")
    write("config/initializers/eager.rb", "Rails.application.config.before_eager_load { RailsAiContext.configuration.sensitive_patterns << \"eager.yml\" }\n")
    write("config/initializers/engine.rb", "class Lab < Rails::Application\n  initializer \"lab.ai\" do |app|\n    app.config.rails_ai_context.sensitive_patterns << \"engine.yml\"\n  end\nend\n")
    write("config/initializers/notify.rb", "ActiveSupport::Notifications.subscribe(\"x\") { RailsAiContext.configuration.skip_tools.push(:rails_query) }\n")
    apply
    expect(config.sensitive_patterns).to include("eager.yml", "engine.yml")
    expect(config.skip_tools).to include("rails_query")
    expect(config.sensitive_patterns).to include("before.yml", "routes.yml")

    write("config/initializers/routes_hook.rb", "list = [1].map { RailsAiContext.configuration.sensitive_patterns << 'a.yml' }\n")
    expect { apply }.to raise_error(RailsAiContext::ConfigurationError, /routes_hook\.rb:1: .*`sensitive_patterns`/)
  end

  it "reads no gem source, engine test app or generator template the app holds" do
    bad = "RailsAiContext.configuration.sensitive_patterns += SECRET_FILES\n"
    write("vendor/ruby/3.4.0/gems/rails-ai-context-5.36.7/lib/rails_ai_context/x.rb", bad)
    write("vendor/gems/rails-ai-context/lib/rails_ai_context/x.rb", bad)
    write("vendor/cache/x.rb", bad)
    write("engines/foo/spec/dummy/config/initializers/rails_ai_context.rb", bad)
    write("engines/foo/test/dummy/config/initializers/rails_ai_context.rb", bad)
    write("lib/generators/ai/templates/initializer.rb", "RailsAiContext.configure do |config|\n  config.cache_ttl = <%= ttl %>\nend\n")
    write("engines/billing/config/initializers/ai.rb", "RailsAiContext.configure { |c| c.skip_tools << :rails_query }\n")

    expect { apply }.not_to raise_error
    expect(config.skip_tools).to include("rails_query")
  end

  it "refuses in config/ what keeps a pattern or the list where it can be changed unseen" do
    {
      "config.sensitive_patterns.each { |p| p.to_s << '.rb' }" => "sensitive_patterns",
      "config.sensitive_patterns.each { |p| (+p).concat('.rb') }" => "sensitive_patterns",
      "config.sensitive_patterns.map(&:itself).last << '.rb'" => "sensitive_patterns",
      "config.sensitive_patterns.map { |p| p.to_s }.last.concat('.rb')" => "sensitive_patterns",
      "copy = config.sensitive_patterns.dup" => "sensitive_patterns",
      "(Rails.env ? config.sensitive_patterns << 'a.yml' : nil) << 'b.yml'" => "sensitive_patterns",
      "list = 1.then { config.sensitive_patterns << 'a.yml' }" => "sensitive_patterns",
      "config.sensitive_patterns.each { |p| config.skip_tools.each { |t| p << '.yml' } }" => "sensitive_patterns",
      "kept = Mutex.new.synchronize { config.sensitive_patterns << 'a.yml' }" => "sensitive_patterns",
      "kept = ENV.fetch('X') { config.sensitive_patterns << 'a.yml' }" => "sensitive_patterns"
    }.each do |line, named|
      write("config/initializers/rails_ai_context.rb", "RailsAiContext.configure do |config|\n  #{line}\nend\n")

      expect { apply }.to raise_error(RailsAiContext::ConfigurationError, /rails_ai_context\.rb:2: .*`#{Regexp.escape(named)}`/), line
    end

    write("config/initializers/rails_ai_context.rb", "module AiHardening\n  def self.patterns\n    RailsAiContext.configuration.sensitive_patterns << 'a.yml'\n  end\nend\n")
    expect { apply }.to raise_error(RailsAiContext::ConfigurationError, /rails_ai_context\.rb:3: .*`sensitive_patterns`/)

    write("config/initializers/rails_ai_context.rb", "RailsAiContext.configure do |config|\n  begin\n    config.sensitive_patterns << 'a.yml'\n  end << 'b.yml'\nend\n")
    apply
    expect(config.sensitive_patterns).to include("a.yml", "b.yml")
  end

  # A method runs when called, so its reads pass, but what it changes in a pattern is still a change.
  it "refuses a pattern a method changes in place through the list's element" do
    %w[first last dup.last take(1).first reverse.first to_a.last values_at(0).first].each do |getter|
      write("app/tools/key_tool.rb", "class KeyTool\n  def self.call\n    RailsAiContext.configuration.sensitive_patterns.#{getter} << '.yml'\n  end\nend\n")
      expect { apply }.to raise_error(RailsAiContext::ConfigurationError, /key_tool\.rb:3: .*`sensitive_patterns`/), getter
    end
  end

  it "reads deep nesting with many reads in time that grows with them" do
    blocks = (1..200).map { |i| "config.sensitive_patterns.each { |p#{i}|" }.join("\n")
    write("config/initializers/rails_ai_context.rb", "RailsAiContext.configure do |config|\n#{blocks}\nzz = 1\n#{"zz\n" * 100_000}#{'}' * 200}\nend\n")
    cpu = Process.const_defined?(:CLOCK_PROCESS_CPUTIME_ID) ? Process::CLOCK_PROCESS_CPUTIME_ID : Process::CLOCK_MONOTONIC
    started = Process.clock_gettime(cpu)
    apply rescue RailsAiContext::ConfigurationError
    expect(Process.clock_gettime(cpu) - started).to be < 5
  end

  it "reads a long run of calls on a pattern in time that grows with it" do
    write("config/initializers/rails_ai_context.rb", "RailsAiContext.configure do |config|\n  config.sensitive_patterns.each do |p|\n#{"    p#{'.to_s' * 900}\n" * 100}  end\nend\n")
    cpu = Process.const_defined?(:CLOCK_PROCESS_CPUTIME_ID) ? Process::CLOCK_PROCESS_CPUTIME_ID : Process::CLOCK_MONOTONIC
    started = Process.clock_gettime(cpu)
    apply rescue RailsAiContext::ConfigurationError
    expect(Process.clock_gettime(cpu) - started).to be < 3
  end

  it "refuses a chain or a nesting too deep to read, quickly" do
    write("config/initializers/rails_ai_context.rb", "RailsAiContext.configure do |config|\n  config.sensitive_patterns#{'.clear.concat(%w[a])' * 8000}\nend\n")
    cpu = Process.const_defined?(:CLOCK_PROCESS_CPUTIME_ID) ? Process::CLOCK_PROCESS_CPUTIME_ID : Process::CLOCK_MONOTONIC
    started = Process.clock_gettime(cpu)

    expect { apply }.to raise_error(RailsAiContext::ConfigurationError, /the static tier cannot read this file/)
    expect(Process.clock_gettime(cpu) - started).to be < 5
  end

  it "lists the same files with ripgrep and without it" do
    skip "requires ripgrep" unless RailsAiContext::Executable.on_path?("rg")

    %w[app/a.rb engines/e/spec/b.rb lib/.hidden/c.rb lib/.d.rb spec/x.rb vendor/bundle/y.rb vendor/engines/z.rb config/initializers/i.rb lib/plain.rb].each do |path|
      write(path, path == "lib/plain.rb" ? "x = 1\n" : "RailsAiContext.log_warn('x')\n")
    end
    write("big.rb", "#{'#' * 100}\nRailsAiContext.log_warn('x')\n")
    write("lib/nul.rb", "RailsAiContext.log_warn('x')\n# \0 note\n")
    # Windows refuses a newline in a file name.
    newline_named = Gem.win_platform? ? [] : [ "app/my\ntool.rb" ]
    newline_named.each { |path| write(path, "RailsAiContext.log_warn('x')\n") }
    File.symlink(File.join(@root, "app"), File.join(@root, "linked_app"))
    File.symlink(File.join(@root, "app/a.rb"), File.join(@root, "lib/linked.rb"))
    with_rg = described_class.boot_files(@root)
    allow(RailsAiContext::Executable).to receive(:on_path?).with("rg").and_return(false)

    expect(described_class.boot_files(@root)).to eq(with_rg)
    expect(with_rg).to eq([ "app/a.rb", *newline_named, "big.rb", "config/initializers/i.rb", "lib/nul.rb", "vendor/engines/z.rb" ])
  end

  it "refuses a file that names the gem when it does not parse or is too deep to read, and does not stop" do
    write("config/initializers/rails_ai_context.rb", "RailsAiContext.configure do |config|\n  config.sensitive_patterns << (\nend\n")
    expect { apply }.to raise_error(RailsAiContext::ConfigurationError, /rails_ai_context\.rb:\d+: the static tier cannot read this file/)

    write("config/initializers/rails_ai_context.rb", "RailsAiContext.configure { |c| c.sensitive_patterns << #{Array.new(6000, '"a"').join(' << ')} }\n")
    expect { apply }.to raise_error(RailsAiContext::ConfigurationError, /rails_ai_context\.rb:1: the static tier cannot read this file/)
  end

  it "reads a chain through a removal and parentheses, and a block that only reads each pattern" do
    write("config/initializers/rails_ai_context.rb", <<~RUBY)
      RailsAiContext.configure do |config|
        config.sensitive_patterns.clear.concat(%w[a.yml .env*])
        config.sensitive_patterns.keep_if { |p| p.end_with?(".yml") } << "b.yml"
        (config.sensitive_patterns << "c.yml") << "d.yml"
        config.excluded_paths.delete_if { |path| path.start_with?("tmp") }
        Rails.logger.info(config.skip_tools.map(&:to_s).join(","))
      end
    RUBY
    apply

    expect(config.sensitive_patterns).to include("a.yml", ".env*", "b.yml", "c.yml", "d.yml", "config/master.key")
  end

  it "lets the gem's name stand where it reaches no setting: a guard, a log tag, the app's own config.x" do
    write("config/initializers/rails_ai_context.rb", <<~RUBY)
      if Object.const_defined?(:RailsAiContext) && Object.const_defined?("RailsAiContext")
        RailsAiContext.configure { |config| config.sensitive_patterns += %w[guarded.yml] }
      end
    RUBY
    write("config/initializers/log.rb", "Rails.application.config.log_tags = [:request_id, \"RailsAiContext\", :rails_ai_context]\n")
    write("config/initializers/x.rb", "Rails.application.config.x.rails_ai_context.enabled = ENV[\"AI_CTX\"] == \"1\"\n")
    apply

    expect(config.sensitive_patterns).to include("guarded.yml")
  end

  it "lets a setting other than the three be written any way, and the module and the configuration be asked things" do
    write("config/initializers/rails_ai_context.rb", <<~RUBY)
      RailsAiContext.configure do |config|
        config.excluded_models += %w[AdminUser InternalThing]
        config.query_redacted_columns += %w[my_app_specific_secret]
        config.introspectors += %i[views turbo]
        config.cache_ttl ||= 30
        config.ai_tools = %i[claude] if config.respond_to?(:ai_tools=)
      end
      RailsAiContext.log_warn("configured") unless RailsAiContext.static_tier?
    RUBY

    expect { apply }.not_to raise_error
  end

  it "reads the gem's settings wherever Rails runs them from config and the files it requires, and lets ordinary uses be" do
    write("config/environment.rb", "require_relative \"application\"\nRailsAiContext.configure { |c| c.sensitive_patterns << \"env.yml\" }\nRails.application.initialize!\n")
    write("config/initializers/harden.rb", "require_relative \"../../lib/hardening\"\n")
    write("lib/hardening.rb", "RailsAiContext.configure do |config|\n  config.sensitive_patterns = config.sensitive_patterns + %w[lib.yml]\nend\n")
    write("config/initializers/after.rb", "Rails.application.config.after_initialize { Rails.application.config.rails_ai_context.sensitive_patterns << \"after.yml\" }\n")
    write("config/initializers/after2.rb", "Rails.application.config.after_initialize do\n  Rails.configuration.rails_ai_context.sensitive_patterns << \"after2.yml\"\n  cfg = Rails.application.config\n  cfg.rails_ai_context.sensitive_patterns << \"after3.yml\"\nend\n")
    write("config/initializers/loadpath.rb", "require \"hardening2\"\n")
    write("lib/hardening2.rb", "RailsAiContext.configure { |c| c.sensitive_patterns << \"lib2.yml\" }\n::Object::RailsAiContext.configuration.sensitive_patterns << \"object.yml\"\n")
    write("config/routes.rb", "Rails.application.routes.draw do\n  mount RailsAiContext::Engine => \"/mcp\" if defined?(RailsAiContext::Engine)\nend\n")
    write("config/initializers/log.rb", "if defined?(RailsAiContext) && RailsAiContext.respond_to?(:configure)\n  Rails.logger.info(\"patterns: \#{RailsAiContext.configuration.sensitive_patterns.size}\")\nend\n")
    apply

    expect(config.sensitive_patterns).to include("env.yml", "lib.yml", "after.yml", "after2.yml", "after3.yml", "lib2.yml", "object.yml")
  end

  it "refuses every other way to the settings: a call the API does not name, an unread block shape, the module or its class used otherwise" do
    {
      "config.send(:sensitive_patterns=, %w[x.yml])" => "config",
      "config.public_send(:sensitive_patterns) << 'x.yml'" => "config",
      "config.instance_variable_get(:@sensitive_patterns) << 'x.yml'" => "config",
      "config.method(:sensitive_patterns).call << 'x.yml'" => "config",
      "config.extend(Module.new)" => "config",
      "RAC = RailsAiContext" => "RailsAiContext",
      "RailsAiContext.configuration = RailsAiContext::Configuration.new" => "RailsAiContext",
      "RailsAiContext::Configuration.load_config_file!(Rails.root.join('config/x'))" => "RailsAiContext::Configuration",
      "Rails.logger.info(config.sensitive_patterns)" => "sensitive_patterns",
      "config.sensitive_patterns.last.replace('x.yml')" => "sensitive_patterns",
      "Object.const_get(:RailsAiContext).configuration.sensitive_patterns << 'x.yml'" => "RailsAiContext",
      "\"RailsAiContext\".constantize.configuration.sensitive_patterns << 'x.yml'" => "RailsAiContext",
      "RailsAiContext.send(:configuration).sensitive_patterns << 'x.yml'" => "RailsAiContext",
      "RailsAiContext.public_send(:configuration).sensitive_patterns << 'x.yml'" => "RailsAiContext",
      "RailsAiContext.instance_variable_get(:@configuration).sensitive_patterns << 'x.yml'" => "RailsAiContext",
      "RailsAiContext.method(:configuration).call.sensitive_patterns << 'x.yml'" => "RailsAiContext",
      "RailsAiContext.itself.configuration.sensitive_patterns << 'x.yml'" => "RailsAiContext",
      "RailsAiContext.tap { |m| m.configuration.sensitive_patterns << 'x.yml' }" => "RailsAiContext",
      "Rails.application.config.public_send(:rails_ai_context).sensitive_patterns << 'x.yml'" => "RailsAiContext",
      "list = config.sensitive_patterns << 'a.yml'" => "sensitive_patterns",
      "config.sensitive_patterns.delete_if { |p| p << '.rb' if p == 'x' }" => "sensitive_patterns",
      "config.sensitive_patterns.each { |p| p.concat('.bak') }" => "sensitive_patterns",
      "config.sensitive_patterns.map(&:upcase!)" => "sensitive_patterns",
      "config.sensitive_patterns.select { |p| p.end_with?('.yml') }.each { |p| p << 'x' }" => "sensitive_patterns",
      "binding.local_variable_get(:config).sensitive_patterns << 'x.yml'" => "binding",
      "eval('config').sensitive_patterns << 'x.yml'" => "eval"
    }.each do |line, named|
      write("config/initializers/rails_ai_context.rb", "RailsAiContext.configure do |config|\n  #{line}\nend\n")

      expect { apply }.to raise_error(RailsAiContext::ConfigurationError, /rails_ai_context\.rb:2: .*`#{Regexp.escape(named)}`/), line
    end

    { "|*args|" => "args.first", "|c = nil|" => "c", "|(c)|" => "c", "|c, d|" => "c" }.each do |params, use|
      write("config/initializers/rails_ai_context.rb", "RailsAiContext.configure do #{params}\n  #{use}.sensitive_patterns << 'x.yml'\nend\n")

      expect { apply }.to raise_error(RailsAiContext::ConfigurationError, /rails_ai_context\.rb:1: the static tier cannot read the parameters of this configure block/), params
    end

    write("config/initializers/rails_ai_context.rb", "class RailsAiContext::Configuration\n  def sensitive_patterns = []\nend\n")
    expect { apply }.to raise_error(RailsAiContext::ConfigurationError, /`RailsAiContext::Configuration`/)
  end

  it "refuses a file too large to read whole when it names the gem, and passes over one that does not" do
    stub_const("#{described_class}::MAX_SOURCE", 100)
    write("config/initializers/big.rb", "# #{'x' * 200}\n")
    expect { apply }.not_to raise_error

    write("config/initializers/rails_ai_context.rb", "# #{'x' * 200}\nRailsAiContext.configure { |c| c.sensitive_patterns << 'x.yml' }\n")
    expect { apply }.to raise_error(RailsAiContext::ConfigurationError, /rails_ai_context\.rb:1: the static tier cannot read this file/)
  end
end
