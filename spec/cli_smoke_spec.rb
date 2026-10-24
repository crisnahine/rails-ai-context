# frozen_string_literal: true

require "spec_helper"
require "timeout"
require "open3"
require "json"

# Runtime smoke test: every registered tool must execute via ToolRunner
# against the combustion fixture without raising. Tools are allowed to
# return error-shaped responses (that's a normal outcome for e.g. missing
# params) - but they must not crash.
RSpec.describe "CLI smoke: every tool executes", type: :smoke do
  # The binary runs in a child here, which spec_helper's stub of
  # McpConfigGenerator.windows_shell? does not reach: on Windows the configs
  # it writes start the server through `cmd /c`, as its clients need there.
  def served(*argv)
    Gem.win_platform? ? [ "cmd", "/c", *argv ] : argv
  end

  # An MCP config entry for that command line, as the child writes it.
  def config_entry(*argv, env: nil)
    command, *args = served(*argv)
    { "command" => command, "args" => args, "env" => env }.compact
  end

  RailsAiContext::Server.builtin_tools.each do |tool_class|
    short = RailsAiContext::CLI::ToolRunner.short_name(tool_class.tool_name)

    it "#{tool_class.tool_name} runs via ToolRunner without raising" do
      runner = RailsAiContext::CLI::ToolRunner.new(short, [])
      expect { runner.run }.not_to raise_error
    end
  end

  # --no-boot returned before the "is this a Rails app" guard, so in an empty
  # directory the gem wrote a CLAUDE.md describing an app that is not there -
  # "Migrations: 0 total", "This project has 45 MCP tools" - and exited 0.
  it "refuses --no-boot outside a Rails app" do
    exe = File.expand_path("../exe/rails-ai-context", __dir__)
    lib = File.expand_path("../lib", __dir__)

    Dir.mktmpdir do |dir|
      out = `cd #{dir} && ruby -I #{lib} #{exe} context --no-boot 2>&1`
      status = $?.exitstatus

      expect(status).to eq(1), out
      expect(out).to include("No Rails app found")
      expect(Dir.children(dir)).to be_empty
    end
  end

  # `--environment` is the binary's own RAILS_ENV flag, so it ate the value
  # before env_config saw its `environment` parameter: the answer named prod as
  # the current environment and then listed all three, at exit 0.
  it "gives --environment to a tool that declares the parameter" do
    exe = File.expand_path("../exe/rails-ai-context", __dir__)
    lib = File.expand_path("../lib", __dir__)

    Dir.mktmpdir do |dir|
      FileUtils.mkdir_p(File.join(dir, "config", "environments"))
      File.write(File.join(dir, "config", "application.rb"),
                 "module EnvApp\n  class Application < Rails::Application\n  end\nend\n")
      %w[development test prod].each do |env|
        File.write(File.join(dir, "config", "environments", "#{env}.rb"),
                   "Rails.application.configure do\n  config.log_level = :debug\nend\n")
      end

      out = `cd #{dir} && ruby -I #{lib} #{exe} tool env_config --environment prod --no-boot 2>&1`

      expect(out).to include("## prod"), out
      expect(out).not_to include("## development")
      expect(out).not_to include("## test")
    end
  end

  # Booted, `--environment prod` also became RAILS_ENV and the app failed to
  # boot in an environment it has no database for. For a tool that declares
  # the parameter the flag is the tool's alone; the env var still sets
  # RAILS_ENV.
  describe "--environment after a tool that declares it" do
    def env_app(dir)
      FileUtils.mkdir_p(File.join(dir, "config", "environments"))
      File.write(File.join(dir, "config", "application.rb"),
                 "module EnvApp\n  class Application < Rails::Application\n  end\nend\n")
      %w[development prod].each do |env|
        File.write(File.join(dir, "config", "environments", "#{env}.rb"), "Rails.application.configure do\nend\n")
      end
    end

    let(:exe) { File.expand_path("../exe/rails-ai-context", __dir__) }
    let(:lib) { File.expand_path("../lib", __dir__) }

    it "does not set RAILS_ENV from the flag" do
      Dir.mktmpdir do |dir|
        env_app(dir)
        out = `cd #{dir} && env -u RAILS_ENV -u RACK_ENV ruby -I #{lib} #{exe} tool env_config --environment prod --no-boot 2>&1`

        expect(out).to include("_Current: **development**"), out
        expect(out).to include("## prod")
      end
    end

    it "is the env_config section's alone when config asks for that section" do
      Dir.mktmpdir do |dir|
        env_app(dir)
        out = `cd #{dir} && env -u RAILS_ENV -u RACK_ENV ruby -I #{lib} #{exe} tool config --section env_config --environment prod --no-boot 2>&1`

        expect(out).to include("_Current: **development**"), out
        expect(out).to include("## prod")
        expect(out).not_to include("## development")
      end
    end

    it "reads the section's name in any capitalisation, as the tool does" do
      Dir.mktmpdir do |dir|
        env_app(dir)
        out = `cd #{dir} && env -u RAILS_ENV -u RACK_ENV ruby -I #{lib} #{exe} tool config --section ENV_CONFIG --environment prod --no-boot 2>&1`

        expect(out).to include("_Current: **development**"), out
        expect(out).to include("## prod")
        expect(out).not_to include("## development")
      end
    end

    it "goes by the last section named, as the tool does" do
      Dir.mktmpdir do |dir|
        env_app(dir)
        run = ->(*sections) { `cd #{dir} && env -u RAILS_ENV -u RACK_ENV ruby -I #{lib} #{exe} tool config #{sections.join(' ')} --environment prod --no-boot 2>&1` }

        filtered = run.call("--section app", "--section=env_config")
        expect(filtered).to include("_Current: **development**"), filtered
        expect(filtered).to include("## prod")

        expect(run.call("--section env_config", "section=app")).not_to include("_Current: **development**")
      end
    end

    # Set through the child's environment, not a `VAR=value` prefix, which
    # cmd.exe, the shell backticks run on Windows, reads as a command.
    it "still reads RAILS_ENV from the environment variable" do
      Dir.mktmpdir do |dir|
        env_app(dir)
        out, = Open3.capture2e({ "RAILS_ENV" => "prod" }, "ruby", "-I", lib, exe, "tool", "env_config", "--no-boot", chdir: dir)

        expect(out).to include("_Current: **prod**"), out
      end
    end
  end

  # The binary decides before boot, without the gem loaded, which tools own
  # `--environment`; the list is a constant, so it has to match the schemas.
  it "names exactly the built-in tools and config sections that declare an environment parameter" do
    source = File.read(File.expand_path("../exe/rails-ai-context", __dir__))
    listed = source[/ENVIRONMENT_FILTER_OWNERS = %w\[([^\]]*)\]/, 1].to_s.split
    config = RailsAiContext::Tools::GetConfig
    declared = RailsAiContext::Server.builtin_tools
      .select { |tool| tool != config && (tool.input_schema_value&.to_h || {}).fetch(:properties, {}).key?(:environment) }
      .map { |tool| RailsAiContext::CLI::ToolRunner.short_name(tool.tool_name) }
    declared += config::SECTIONS.select { |section| section.params.include?(:environment) }.map(&:name)

    expect(listed.sort).to eq(declared.sort)
  end

  # An engine keeps its dummy app under spec/dummy, so its root has app/ and
  # no config/. There is real source to read there, and the guard against an
  # empty directory must not take the whole repo shape with it.
  it "still reads an engine repo with --no-boot" do
    exe = File.expand_path("../exe/rails-ai-context", __dir__)
    lib = File.expand_path("../lib", __dir__)

    Dir.mktmpdir do |dir|
      FileUtils.mkdir_p(File.join(dir, "app", "models"))
      File.write(File.join(dir, "app", "models", "widget.rb"), "class Widget < ApplicationRecord\nend\n")

      out = `cd #{dir} && ruby -I #{lib} #{exe} tool model_details --no-boot 2>&1`

      expect($?.exitstatus).to eq(0), out
      expect(out).to include("Widget")
    end
  end

  # The static tier is exactly what a source-only tree gets with --no-boot,
  # so a command that can serve it must not refuse the same tree without it.
  it "serves a source-only tree without --no-boot" do
    exe = File.expand_path("../exe/rails-ai-context", __dir__)
    lib = File.expand_path("../lib", __dir__)

    Dir.mktmpdir do |dir|
      FileUtils.mkdir_p(File.join(dir, "app", "models"))
      File.write(File.join(dir, "app", "models", "widget.rb"), "class Widget < ApplicationRecord\nend\n")

      out = `cd #{dir} && ruby -I #{lib} #{exe} tool model_details 2>&1`

      expect($?.exitstatus).to eq(0), out
      expect(out).to include("Widget")
    end
  end

  # doctor runs the context command at an engine's root into a copy of the
  # files, to see which a run would rewrite; the run there must write
  # nothing else.
  it "writes the context into --output-dir and nothing into the app" do
    exe = File.expand_path("../exe/rails-ai-context", __dir__)
    lib = File.expand_path("../lib", __dir__)

    Dir.mktmpdir do |dir|
      FileUtils.mkdir_p(File.join(dir, "app", "models"))
      File.write(File.join(dir, "app", "models", "widget.rb"), "class Widget < ApplicationRecord\nend\n")
      File.write(File.join(dir, ".rails-ai-context.yml"), "ai_tools:\n- claude\ntool_mode: mcp\ncontext_files: true\n")
      out_dir = File.join(dir, "copy")
      FileUtils.mkdir_p(out_dir)

      out = `cd #{dir} && ruby -I #{lib} #{exe} context --no-mcp-refresh --output-dir #{out_dir} 2>&1`

      expect($?.exitstatus).to eq(0), out
      expect(File).to exist(File.join(out_dir, "CLAUDE.md"))
      expect(Dir.children(dir).sort).to eq(%w[.rails-ai-context.yml app copy])
    end
  end

  # Every command names itself when it enters the gem, so the refusal quotes
  # back the word the user typed and no command reaches the boot path without
  # one.
  it "enters the gem with a command name from every command" do
    exe = File.expand_path("../exe/rails-ai-context", __dir__)
    lib = File.expand_path("../lib", __dir__)

    Dir.mktmpdir do |dir|
      FileUtils.mkdir_p(File.join(dir, "config"))
      File.write(File.join(dir, "config", "application.rb"), "")
      FileUtils.mkdir_p(File.join(dir, "app", "models"))
      File.write(File.join(dir, "app", "models", "widget.rb"), "class Widget < ApplicationRecord\nend\n")

      # Bare `preset` lists and returns before the boot path, so the loop
      # runs a real one. Only serve and watch are left out: both run until
      # interrupted.
      # No command may wait on the runner's own stdin: init prompts. An
      # empty one is given rather than `< /dev/null`, a file Windows lacks:
      # there cmd.exe refused the redirect and ran nothing at all.
      [ "inspect", "facts", "context", "preset architecture", "init", "tool", "doctor" ].each do |command|
        out, = Open3.capture2e("ruby", "-I", lib, exe, *command.split, chdir: dir, stdin_data: "")
        expect(out).not_to include("ArgumentError"), "#{command}: #{out}"
        # preset rescues StandardError, so only the message reaches stderr.
        expect(out).not_to include("missing keyword"), "#{command}: #{out}"
      end

      doctor, status = Open3.capture2e("ruby", "-I", lib, exe, "doctor", chdir: dir)
      expect(status.exitstatus).to eq(1), doctor
      expect(doctor).to include("doctor needs a bootable app: no config/environment.rb")
    end
  end

  # A listing the user asked for belongs on stdout; only the error framing and
  # the listing that follows a rejected name go to stderr. Each stream is read
  # apart rather than one sent to /dev/null, which Windows does not have.
  it "puts the bare preset listing on stdout and a rejected name on stderr" do
    exe = File.expand_path("../exe/rails-ai-context", __dir__)
    lib = File.expand_path("../lib", __dir__)

    Dir.mktmpdir do |dir|
      listing, err, status = Open3.capture3("ruby", "-I", lib, exe, "preset", chdir: dir)
      expect(status.exitstatus).to eq(0), err
      expect(listing).to include("Available presets:")

      _out, rejected, status = Open3.capture3("ruby", "-I", lib, exe, "preset", "bogus", chdir: dir)
      expect(status.exitstatus).to eq(1), rejected
      expect(rejected).to include("Unknown preset: bogus")
      expect(rejected).to include("Available presets:")
    end
  end

  # Thor reads a leading switch as "no command given" and falls back to
  # `help`, so a CI job wrapping `rails-ai-context --app-path <dir> doctor`
  # went green having checked nothing.
  describe "a global option typed before the command" do
    let(:exe) { File.expand_path("../exe/rails-ai-context", __dir__) }
    let(:lib) { File.expand_path("../lib", __dir__) }

    it "runs the command instead of printing usage" do
      Dir.mktmpdir do |dir|
        out = `ruby -I #{lib} #{exe} --app-path #{dir} doctor 2>&1`

        expect($?.exitstatus).to eq(1), out
        expect(out).to include("No Rails app found in ")
        expect(out).to include(File.basename(dir))
        expect(out).not_to include("Usage:\n  rails-ai-context doctor")
      end
    end

    it "carries the value through to the command" do
      Dir.mktmpdir do |dir|
        FileUtils.mkdir_p(File.join(dir, "app", "models"))
        File.write(File.join(dir, "app", "models", "widget.rb"), "class Widget < ApplicationRecord\nend\n")

        out = `ruby -I #{lib} #{exe} --app-path #{dir} tool model_details --no-boot 2>&1`

        expect($?.exitstatus).to eq(0), out
        expect(out).to include("Widget")
      end
    end

    it "accepts the equals spelling" do
      Dir.mktmpdir do |dir|
        FileUtils.mkdir_p(File.join(dir, "app", "models"))
        File.write(File.join(dir, "app", "models", "widget.rb"), "class Widget < ApplicationRecord\nend\n")

        out = `ruby -I #{lib} #{exe} --app-path=#{dir} tool model_details --no-boot 2>&1`

        expect($?.exitstatus).to eq(0), out
        expect(out).to include("Widget")
      end
    end

    # `--no-boot` is declared per command rather than globally, and typing it
    # first is the same mistake with the same silent answer.
    it "moves a command's own switch behind the command too" do
      Dir.mktmpdir do |dir|
        FileUtils.mkdir_p(File.join(dir, "app", "models"))
        File.write(File.join(dir, "app", "models", "widget.rb"), "class Widget < ApplicationRecord\nend\n")

        out = `ruby -I #{lib} #{exe} --app-path #{dir} --no-boot tool model_details 2>&1`

        expect($?.exitstatus).to eq(0), out
        expect(out).to include("Widget")
      end
    end

    it "still answers --version and --help" do
      version = `ruby -I #{lib} #{exe} --version 2>&1`
      expect($?.exitstatus).to eq(0), version
      expect(version).to include("rails-ai-context v")

      help = `ruby -I #{lib} #{exe} --help 2>&1`
      expect($?.exitstatus).to eq(0), help
      expect(help).to include("rails-ai-context doctor")
    end

    it "still refuses a leading unknown switch" do
      out = `ruby -I #{lib} #{exe} --bogus doctor 2>&1`
      expect($?.exitstatus).to eq(1), out
    end
  end

  # Thor answers `help <command>` only: after a command it read --help as an
  # argument the command does not take, and as the name to run for tool and
  # preset.
  describe "a command's --help" do
    let(:exe) { File.expand_path("../exe/rails-ai-context", __dir__) }
    let(:lib) { File.expand_path("../lib", __dir__) }

    %w[tool serve context inspect watch doctor init preset facts version].each do |command|
      it "prints #{command}'s help and exits 0" do
        Dir.mktmpdir do |dir|
          out = `cd #{dir} && ruby -I #{lib} #{exe} #{command} --help 2>&1`

          expect($?.exitstatus).to eq(0), out
          expect(out).to start_with("Usage:\n  rails-ai-context #{command}")
        end
      end
    end

    it "takes -h and a switch before the flag the same way" do
      Dir.mktmpdir do |dir|
        out = `cd #{dir} && ruby -I #{lib} #{exe} tool --app-path #{dir} -h 2>&1`

        expect($?.exitstatus).to eq(0), out
        expect(out).to start_with("Usage:\n  rails-ai-context tool")
      end
    end

    it "leaves a tool's own --help to the tool" do
      Dir.mktmpdir do |dir|
        out = `cd #{dir} && ruby -I #{lib} #{exe} tool schema --help 2>&1`

        expect($?.exitstatus).to eq(0), out
        expect(out).to start_with("rails_get_schema - ")
      end
    end

    it "reads -h after the gem's own --json as the help flag, with no app to boot" do
      Dir.mktmpdir do |dir|
        out, err, status = Open3.capture3("ruby", "-I", lib, exe, "tool", "schema", "--json", "-h", chdir: dir)

        expect(status.exitstatus).to eq(0), err
        expect(out).to start_with("rails_get_schema - ")
      end
    end

    it "reads -h and -j after a value flag as that flag's value" do
      Dir.mktmpdir do |dir|
        FileUtils.mkdir_p(File.join(dir, "config"))
        FileUtils.mkdir_p(File.join(dir, "app", "models"))
        File.write(File.join(dir, "config", "application.rb"), "module Shop\n  class Application < Rails::Application\n  end\nend\n")
        File.write(File.join(dir, "app", "models", "user.rb"), "class User < ApplicationRecord\n  # run with -j and -h flags\nend\n")

        %w[-h -j].each do |flag|
          out, err, status = Open3.capture3("ruby", "-I", lib, exe, "tool", "search_code", "--no-boot", "--pattern", flag, chdir: dir)

          expect(status.exitstatus).to eq(0), err
          expect(out).to include("app/models/user.rb"), "#{flag}: #{out}#{err}"
        end
      end
    end

    it "answers a failed boot as an envelope when a -j is left for the tool to read" do
      Dir.mktmpdir do |dir|
        out, err, status = Open3.capture3("ruby", "-I", lib, exe, "tool", "search_code", "--exact-match", "-j", "--pattern", "User", chdir: dir)

        expect(status.exitstatus).to eq(1), err
        expect(err).to include("No Rails app found")
        expect(JSON.parse(out)).to include("error" => true, "output" => a_string_including("stderr says why")), out
      end
    end

    it "answers in text when the -j it read was a flag's value" do
      Dir.mktmpdir do |dir|
        FileUtils.mkdir_p(File.join(dir, "config"))
        File.write(File.join(dir, "config", "application.rb"), "module Shop\n  class Application < Rails::Application\n  end\nend\n")
        out, err, status = Open3.capture3("ruby", "-I", lib, exe, "tool", "search_code", "--pattern", "-j", "--bogus", "1", "--no-boot", chdir: dir)

        expect(status.exitstatus).to eq(1), err
        expect(out).to eq("")
        expect(err).to include("'--bogus'")
      end
    end

    it "answers each refusal with --json as one envelope on stdout, at exit 1" do
      Dir.mktmpdir do |dir|
        FileUtils.mkdir_p(File.join(dir, "config"))
        File.write(File.join(dir, "config", "application.rb"), "module Shop\n  class Application < Rails::Application\n  end\nend\n")

        {
          %w[search_code --pattern User --limt 5] => "did you mean '--limit'?",
          %w[search_code --pattern] => "'--pattern' takes a string value",
          %w[search_code --pattern User stray] => "'stray' is not a flag",
          %w[shema] => "Did you mean 'schema'?"
        }.each do |words, message|
          out, err, status = Open3.capture3("ruby", "-I", lib, exe, "tool", *words, "--no-boot", "--json", chdir: dir)

          expect(status.exitstatus).to eq(1), "#{words.join(' ')}: #{err}"
          expect(JSON.parse(out)).to include("error" => true, "output" => a_string_including(message)), "#{words.join(' ')}: #{out}#{err}"
        end
      end

      Dir.mktmpdir do |empty|
        out, err, status = Open3.capture3("ruby", "-I", lib, exe, "tool", "schema", "--no-boot", "--json", chdir: empty)

        expect(status.exitstatus).to eq(1), err
        expect(JSON.parse(out)).to include("tool" => "schema", "error" => true)
        expect(err).to include("No Rails app found")
      end
    end

    it "gives a retired tool name the help of its config section" do
      Dir.mktmpdir do |dir|
        out = `cd #{dir} && ruby -I #{lib} #{exe} tool gems --help 2>&1`

        expect($?.exitstatus).to eq(0), out
        expect(out).to start_with("rails_get_gems - runs the `gems` section of rails_get_config")
        expect(out).to include("--category")
        expect(out).not_to include("--locale")
      end
    end

    # The app's configuration file is read with no boot, so the help is for the tool that app serves.
    describe "of a tool, in an app whose configuration file turns sections off" do
      def app_with(dir, skip_tools)
        FileUtils.mkdir_p(File.join(dir, "config"))
        File.write(File.join(dir, "config", "application.rb"), "module HelpApp\n  class Application < Rails::Application\n  end\nend\n")
        File.write(File.join(dir, ".rails-ai-context.yml"), { "skip_tools" => skip_tools }.to_yaml)
      end

      it "says the section is required when app is off, and the default when it is on" do
        Dir.mktmpdir do |dir|
          app_with(dir, %w[rails_get_env])
          expect(`cd #{dir} && ruby -I #{lib} #{exe} tool config --help 2>&1`).to include("Default: app.")

          app_with(dir, %w[rails_get_config])
          out = `cd #{dir} && ruby -I #{lib} #{exe} tool config --help 2>&1`
          expect($?.exitstatus).to eq(0), out
          expect(out).to include("Required: the app section is turned off in this app.")
          expect(out).not_to include("Default: app.")
        end
      end

      it "offers no help for a section the file turns off, from the app or through --app-path" do
        Dir.mktmpdir do |dir|
          app_with(dir, %w[rails_get_env])

          [ "cd #{dir} && ruby -I #{lib} #{exe} tool env --help", "ruby -I #{lib} #{exe} tool env --help --app-path #{dir}" ].each do |command|
            out = `#{command} 2>&1`

            expect($?.exitstatus).to eq(1), out
            expect(out).to include("rails_get_env is turned off in this app: skip_tools lists it")
          end
          expect(`cd #{dir} && ruby -I #{lib} #{exe} tool gems --help 2>&1`).to start_with("rails_get_gems - runs the `gems` section")
        end
      end

      it "prints the help when --app-path is left without a value before --help" do
        Dir.mktmpdir do |dir|
          out = `cd #{dir} && ruby -I #{lib} #{exe} tool config --app-path --help 2>&1`

          expect($?.exitstatus).to eq(0), out
          expect(out).to start_with("rails_get_config")
        end
      end
    end

    it "names inspect as it is typed when it is given an argument it does not take" do
      Dir.mktmpdir do |dir|
        out = `cd #{dir} && ruby -I #{lib} #{exe} inspect extra 2>&1`

        expect($?.exitstatus).to eq(1), out
        expect(out).to include(%("rails-ai-context inspect" was called with arguments ["extra"]))
        expect(out).not_to include("inspect_app")
      end
    end
  end

  # Thor's "was called with arguments" said nothing about why.
  it "refuses doctor --no-boot in words" do
    exe = File.expand_path("../exe/rails-ai-context", __dir__)
    lib = File.expand_path("../lib", __dir__)

    out = `ruby -I #{lib} #{exe} doctor --no-boot 2>&1`

    expect($?.exitstatus).to eq(1), out
    expect(out).to eq("Error: doctor diagnoses the app's boot, so it cannot skip it. Run it without --no-boot.\n")
  end

  # The boot came first, a minute for a hung one, and the refusal named
  # Ruby symbols.
  it "refuses an unknown serve transport before booting, in plain words" do
    exe = File.expand_path("../exe/rails-ai-context", __dir__)
    lib = File.expand_path("../lib", __dir__)

    Dir.mktmpdir do |dir|
      FileUtils.mkdir_p(File.join(dir, "config"))
      File.write(File.join(dir, "config", "environment.rb"), "raise 'booted'\n")

      out = `cd #{dir} && ruby -I #{lib} #{exe} serve --transport bogus 2>&1`

      expect($?.exitstatus).to eq(1), out
      expect(out).to eq("Error: Unknown transport 'bogus'. Use stdio or http.\n")
    end
  end

  # Nine frames of backtrace where a one-line refusal belongs. `tool` already
  # gave one; doctor, inspect and watch did not.
  describe "an --app-path that does not exist" do
    let(:exe) { File.expand_path("../exe/rails-ai-context", __dir__) }
    let(:lib) { File.expand_path("../lib", __dir__) }

    [ "doctor", "inspect", "watch", "tool schema" ].each do |command|
      it "refuses in one line from #{command}" do
        out = `ruby -I #{lib} #{exe} #{command} --app-path /nonexistent-app-path 2>&1`

        expect($?.exitstatus).to eq(1), out
        expect(out).to include("/nonexistent-app-path")
        expect(out).not_to include("(NameError)")
        expect(out).not_to match(/^\s+from /)
      end
    end
  end

  # bin/rails and Bundler both walk up to the app; the binary refused from
  # anywhere but the root, and refused a folder of apps without naming them.
  describe "a command run outside the app root" do
    let(:exe) { File.expand_path("../exe/rails-ai-context", __dir__) }
    let(:lib) { File.expand_path("../lib", __dir__) }

    def rails_app(dir)
      FileUtils.mkdir_p(File.join(dir, "config"))
      FileUtils.mkdir_p(File.join(dir, "app", "models"))
      File.write(File.join(dir, "config", "application.rb"), "module X\n  class Application < Rails::Application\n  end\nend\n")
      File.write(File.join(dir, "app", "models", "widget.rb"), "class Widget < ApplicationRecord\nend\n")
    end

    it "walks up from a subdirectory and says so on stderr only" do
      Dir.mktmpdir do |dir|
        dir = File.realpath(dir)
        rails_app(dir)

        out, err, status = Open3.capture3("ruby", "-I", lib, exe, "tool", "model_details", "--no-boot",
                                          chdir: File.join(dir, "app", "models"))

        expect(status.exitstatus).to eq(0), err
        expect(out).to include("Widget")
        expect(out).not_to include("using app at")
        expect(err).to include("[rails-ai-context] using app at #{dir}")
      end
    end

    it "uses the one app in a folder below" do
      Dir.mktmpdir do |dir|
        rails_app(File.join(dir, "a"))

        out, err, status = Open3.capture3("ruby", "-I", lib, exe, "tool", "model_details", "--no-boot", chdir: dir)

        expect(status.exitstatus).to eq(0), err
        expect(out).to include("Widget")
        expect(err).to include("[rails-ai-context] using app at a/")
      end
    end

    it "names every app in a folder of several, with the command for each" do
      Dir.mktmpdir do |dir|
        rails_app(File.join(dir, "a"))
        rails_app(File.join(dir, "b"))

        out, err, status = Open3.capture3("ruby", "-I", lib, exe, "serve", chdir: dir, stdin_data: "")

        expect(status.exitstatus).to eq(1)
        expect(out).to eq("")
        expect(err).to include("rails-ai-context --app-path a serve\n")
        expect(err).to include("rails-ai-context --app-path b serve\n")
      end
    end

    it "still lists tools in a folder of several apps" do
      Dir.mktmpdir do |dir|
        rails_app(File.join(dir, "a"))
        rails_app(File.join(dir, "b"))

        out, err, status = Open3.capture3("ruby", "-I", lib, exe, "tool", "--list", chdir: dir)

        expect(status.exitstatus).to eq(0), err
        expect(out).to include("schema")
      end
    end

    it "names the app above a wrong --app-path" do
      Dir.mktmpdir do |dir|
        rails_app(dir)

        _out, err, status = Open3.capture3("ruby", "-I", lib, exe, "tool", "schema", "--no-boot",
                                           "--app-path", File.join(dir, "app", "models"))

        expect(status.exitstatus).to eq(1)
        expect(err).to include("No Rails app found in #{File.join(dir, "app", "models")}")
        expect(err).to include("is inside the app at")
      end
    end
  end

  # An editor opened at a folder of apps reads the MCP config there and
  # nowhere below, so init sets the folder up: one server per app in its
  # configs, and each app's own config and context files in the app.
  describe "init in a folder of apps" do
    let(:exe) { File.expand_path("../exe/rails-ai-context", __dir__) }
    let(:lib) { File.expand_path("../lib", __dir__) }

    # A lockfile without the gem makes a standalone install, served by this
    # binary; one with it, an in-Gemfile install, served by bundle exec.
    def rails_app(dir, bundled: false)
      FileUtils.mkdir_p(File.join(dir, "config"))
      FileUtils.mkdir_p(File.join(dir, "app", "models"))
      File.write(File.join(dir, "config", "application.rb"), "module X\n  class Application < Rails::Application\n  end\nend\n")
      File.write(File.join(dir, "app", "models", "widget.rb"), "class Widget < ApplicationRecord\nend\n")
      File.write(File.join(dir, "Gemfile"), "")
      specs = bundled ? "    rails (8.0.0)\n    rails-ai-context (5.32.2)\n" : "    rails (8.0.0)\n"
      File.write(File.join(dir, "Gemfile.lock"), "GEM\n  remote: https://rubygems.org/\n  specs:\n#{specs}\n")
    end

    def init(dir, answers, *flags)
      Open3.capture3("ruby", "-I", lib, exe, "init", "--no-boot", *flags, chdir: dir, stdin_data: answers)
    end

    def servers(dir)
      JSON.parse(File.read(File.join(dir, ".mcp.json")))["mcpServers"]
    end

    it "writes one server per app here and each app's own files in the app" do
      Dir.mktmpdir do |dir|
        rails_app(File.join(dir, "a"))
        rails_app(File.join(dir, "group", "b"))

        _out, err, status = init(dir, "1\n1\n")

        expect(status.exitstatus).to eq(0), err
        expect(servers(dir)).to eq(
          "rails-ai-context-a" => config_entry(*%w[rails-ai-context serve --app-path a],
                                               env: { "RAILS_AI_CONTEXT_SERVER_NAME" => "a-rails-ai-context" }),
          "rails-ai-context-b" => config_entry(*%w[rails-ai-context serve --app-path group/b],
                                               env: { "RAILS_AI_CONTEXT_SERVER_NAME" => "b-rails-ai-context" })
        )
        %w[a group/b].each do |app|
          expect(File.exist?(File.join(dir, app, ".rails-ai-context.yml"))).to be(true), app
          expect(File.read(File.join(dir, app, "CLAUDE.md"))).to include("Widget")
          expect(File.exist?(File.join(dir, app, ".mcp.json"))).to be(false)
        end
        expect(Dir.children(dir).sort).to eq(%w[.mcp.json a group])
        expect(err).to include("rails-ai-context-b -> group/b/")
      end
    end

    it "sets up the one app below the same way" do
      Dir.mktmpdir do |dir|
        rails_app(File.join(dir, "a"))

        _out, err, status = init(dir, "1\n3\n")

        expect(status.exitstatus).to eq(0), err
        expect(servers(dir).keys).to eq(%w[rails-ai-context-a])
        expect(File.exist?(File.join(dir, "a", ".rails-ai-context.yml"))).to be(true)
        expect(File.exist?(File.join(dir, "a", "CLAUDE.md"))).to be(false)
        expect(err).to include("MCP-only setup")
      end
    end

    # A session started here runs the plugin, which serves the one app below.
    it "writes no Claude Code server where the folder's committed settings turn the plugin on and it holds one app" do
      Dir.mktmpdir do |dir|
        rails_app(File.join(dir, "a"))
        FileUtils.mkdir_p(File.join(dir, ".claude"))
        File.write(File.join(dir, ".claude", "settings.json"), JSON.generate("enabledPlugins" => { "rails-ai-context@rails-ai-context" => true }))

        _out, err, status = init(dir, "1\n3\n")

        expect(status.exitstatus).to eq(0), err
        expect(File.exist?(File.join(dir, ".mcp.json"))).to be(false)
        # Claude Code has run on this machine, and never installed the plugin.
        expect(err).to include("Claude Code: no server written into .mcp.json here: .claude/settings.json in this folder turns the " \
                               "rails-ai-context plugin on, but it does not start for you here: doctor names why")
        expect(err).to include("Claude Code: .claude/settings.json in this folder turns the rails-ai-context plugin on, but it does not start for you here")
        expect(err).not_to include("approve each rails-ai-context server")
        # The summary says what serves Claude Code, and lists no server it did not write.
        expect(err).to include("Claude Code      -> the rails-ai-context plugin (off here: see below)")
        expect(err).not_to include("MCP servers, one per app")

        rails_app(File.join(dir, "b"))
        _out, err, = init(dir, "1\n3\n")
        expect(servers(dir).keys).to eq(%w[rails-ai-context-a rails-ai-context-b])
        expect(err).to include("it has nothing to serve here: `claude plugin disable rails-ai-context@rails-ai-context --scope project` turns it off for this folder")
      end
    end

    # The app's sessions read its own .mcp.json, which a context run writes, and the repository's local settings run the plugin there too.
    it "names the app's own .mcp.json below a folder that commits the plugin, and the /mcp step where the plugin runs beside it" do
      config = ENV.fetch("CLAUDE_CONFIG_DIR")
      registry = File.join(config, "plugins", "installed_plugins.json")
      Dir.mktmpdir do |dir|
        rails_app(File.join(dir, "shop"))
        system("git", "init", "-q", dir, out: File::NULL, err: File::NULL)
        FileUtils.mkdir_p([ File.join(dir, ".claude"), File.dirname(registry) ])
        on = JSON.generate("enabledPlugins" => { "rails-ai-context@rails-ai-context" => true })
        File.write(File.join(dir, ".claude", "settings.json"), on)
        File.write(File.join(dir, ".claude", "settings.local.json"), on)
        File.write(registry, JSON.generate("version" => 2, "plugins" => { "rails-ai-context@rails-ai-context" => [ { "scope" => "user" } ] }))

        _out, err, status = init(dir, "1\n1\n")

        expect(status.exitstatus).to eq(0), err
        expect(File.exist?(File.join(dir, ".mcp.json"))).to be(false)
        expect(JSON.parse(File.read(File.join(dir, "shop", ".mcp.json")))["mcpServers"].keys).to eq(%w[rails-ai-context])
        expect(err).to include("Claude Code: no server written into .mcp.json here:")
        expect(err).to include("Claude Code      -> the rails-ai-context plugin, and shop/.mcp.json for sessions started in shop; CLAUDE.md")
        # On Windows the repository's local settings stay in its folder, so the plugin does not run in shop.
        unless Gem.win_platform?
          expect(err).to include("Claude Code: the rails-ai-context plugin already serves this app for you, so turn the .mcp.json server " \
                                 "`rails-ai-context` off with /mcp in a session started in shop, or Claude Code lists every tool twice")
        end
      end
    ensure
      FileUtils.rm_rf(File.dirname(registry))
    end

    # The bare entry serves the folder it starts in, which is no app.
    it "replaces a bare entry left in the folder, and changes nothing on a second run" do
      Dir.mktmpdir do |dir|
        rails_app(File.join(dir, "a"))
        rails_app(File.join(dir, "b"))
        File.write(File.join(dir, ".mcp.json"), JSON.generate("mcpServers" => {
          "rails-ai-context" => { "command" => "rails-ai-context", "args" => [ "serve" ] }, "mine" => { "command" => "x" }
        }))

        init(dir, "1\n3\n")
        first = File.read(File.join(dir, ".mcp.json"))
        _out, err, = init(dir, "1\n3\n")

        expect(servers(dir).keys).to eq(%w[mine rails-ai-context-a rails-ai-context-b])
        expect(File.read(File.join(dir, ".mcp.json"))).to eq(first)
        expect(err).to include(".mcp.json (unchanged)")
      end
    end

    it "names an in-Gemfile app's Gemfile, and fails when its bundle cannot write the context" do
      Dir.mktmpdir do |dir|
        rails_app(File.join(dir, "a"))
        rails_app(File.join(dir, "b"), bundled: true)

        _out, err, status = init(dir, "1\n1\n")

        expect(servers(dir)["rails-ai-context-b"]).to eq(
          config_entry(*%w[bundle exec rails-ai-context serve --app-path b],
                       env: { "BUNDLE_GEMFILE" => "b/Gemfile", "RAILS_AI_CONTEXT_SERVER_NAME" => "b-rails-ai-context" })
        )
        expect(File.exist?(File.join(dir, "a", "CLAUDE.md"))).to be(true)
        expect(status.exitstatus).to eq(1)
        expect(err).to include("Error: no context files for b/")
      end
    end

    # What a client sees: the entry it was given starts a server, from the
    # folder the client was opened at, for the app the entry names. It is
    # started as the entry says - through `cmd /c` on Windows - with this
    # checkout's binary where the entry names the installed one.
    it "writes entries that serve their app from the folder" do
      Dir.mktmpdir do |dir|
        rails_app(File.join(dir, "a"))
        rails_app(File.join(dir, "b"))
        File.write(File.join(dir, "b", "app", "models", "gadget.rb"), "class Gadget < ApplicationRecord\nend\n")
        init(dir, "1\n3\n")
        entry = servers(dir)["rails-ai-context-b"]
        requests = [
          { jsonrpc: "2.0", id: 1, method: "initialize",
            params: { protocolVersion: "2025-06-18", capabilities: {}, clientInfo: { name: "spec", version: "1" } } },
          { jsonrpc: "2.0", method: "notifications/initialized" },
          { jsonrpc: "2.0", id: 2, method: "tools/call", params: { name: "rails_get_model_details", arguments: {} } }
        ].map { |message| "#{JSON.generate(message)}\n" }.join
        command_line = [ entry["command"], *entry["args"] ].flat_map { |word| word == "rails-ai-context" ? [ "ruby", "-I", lib, exe ] : [ word ] }

        out, err, = Open3.capture3(entry["env"], *command_line, "--no-boot", chdir: dir, stdin_data: requests)
        responses = out.lines.filter_map { |line| JSON.parse(line) rescue nil }.to_h { |msg| [ msg["id"], msg ] }

        expect(responses.dig(1, "result", "serverInfo", "name")).to eq("b-rails-ai-context"), err
        expect(responses.dig(2, "result", "content", 0, "text")).to include("Gadget")
      end
    end

    it "warns when an app declares a Ruby other than the one the folder runs" do
      Dir.mktmpdir do |dir|
        rails_app(File.join(dir, "a"))
        rails_app(File.join(dir, "b"))
        File.write(File.join(dir, "b", ".ruby-version"), "2.7.8\n")
        File.write(File.join(dir, "a", ".ruby-version"), "#{RUBY_VERSION}\n")

        _out, err, = init(dir, "1\n3\n")

        expect(err).to include("Warning: b/ declares Ruby 2.7.8; this folder runs #{RUBY_VERSION}.")
        expect(err).not_to include("Warning: a/")
      end
    end

    # A folder holding one app is still a folder of apps: its own files were
    # named as that app's (`a/.mcp.json`, which is no file), and with several
    # apps every .gitignore was named alike.
    it "names the folder's files from the folder and each app's from the app, with one app below or several" do
      Dir.mktmpdir do |dir|
        work = File.join(dir, "work")
        rails_app(File.join(work, "a"))
        FileUtils.mkdir_p(File.join(work, "web"))
        File.write(File.join(work, ".gitignore"), "node_modules\n")
        File.write(File.join(work, "a", ".gitignore"), "/tmp\n")

        _out, err, status = init(work, "1\n3\n")

        expect(status.exitstatus).to eq(0), err
        expect(err).to include("Created/Updated .mcp.json\n", "Updated a/.gitignore\n", "Updated .gitignore\n")
        expect(err).not_to include("a/.mcp.json")

        rails_app(File.join(work, "b"))
        File.write(File.join(work, "b", ".gitignore"), "/tmp\n")
        File.write(File.join(work, ".gitignore"), "node_modules\n")

        _out, err, = init(dir, "1\n3\n", "--app-path", "work")

        expect(err).to include("Updated work/b/.gitignore\n", "Updated work/.gitignore\n", "Created/Updated work/.mcp.json\n")
      end
    end

    # Each app's files come from a child run at the app, which named them
    # from there: its rm line for legacy files, pasted where init ran,
    # removed nothing.
    it "names an app's legacy files, and the rm line for them, from the folder init ran in" do
      Dir.mktmpdir do |dir|
        rails_app(File.join(dir, "a"))
        rails_app(File.join(dir, "b"))
        FileUtils.mkdir_p(File.join(dir, "a", ".claude", "rules"))
        File.write(File.join(dir, "a", ".claude", "rules", "rails-ui-patterns.md"), "old\n")

        _out, err, status = init(dir, "1\n1\n")

        expect(status.exitstatus).to eq(0), err
        expect(err).to include("  rm -f a/.claude/rules/rails-ui-patterns.md\n", "Written: a/CLAUDE.md")
        system("rm -f a/.claude/rules/rails-ui-patterns.md", chdir: dir)
        expect(File.exist?(File.join(dir, "a", ".claude", "rules", "rails-ui-patterns.md"))).to be(false)
      end
    end

    it "sets up the folder of apps --app-path names" do
      Dir.mktmpdir do |dir|
        rails_app(File.join(dir, "work", "a"))
        rails_app(File.join(dir, "work", "b"))

        _out, err, status = init(dir, "1\n3\n", "--app-path", "work")

        expect(status.exitstatus).to eq(0), err
        expect(servers(File.join(dir, "work")).keys).to eq(%w[rails-ai-context-a rails-ai-context-b])
        expect(Dir.children(dir)).to eq(%w[work])
        # From where it was run, not from the folder it set up.
        expect(err).to include("rails-ai-context --app-path work/a tool NAME")
        expect(err).to include("Claude Code      -> .mcp.json in work/;")
      end
    end

    it "lists the apps below a folder --app-path names to any other command" do
      Dir.mktmpdir do |dir|
        rails_app(File.join(dir, "work", "a"))
        rails_app(File.join(dir, "work", "b"))

        _out, err, status = Open3.capture3("ruby", "-I", lib, exe, "--app-path", "work", "tool", "schema", "--no-boot", chdir: dir)

        expect(status.exitstatus).to eq(1)
        expect(err).to include("#{File.join(File.realpath(dir), 'work')} is no Rails app, and holds 2 below it")
        expect(err).to include("rails-ai-context --app-path work/a tool schema --no-boot\n")
      end
    end

    it "drops the entry of an app that is gone when it runs again" do
      Dir.mktmpdir do |dir|
        rails_app(File.join(dir, "a"))
        rails_app(File.join(dir, "b"))
        init(dir, "1\n3\n")
        FileUtils.rm_rf(File.join(dir, "b"))

        _out, err, status = init(dir, "1\n3\n")

        expect(status.exitstatus).to eq(0), err
        expect(servers(dir).keys).to eq(%w[rails-ai-context-a])
      end
    end

    # Two folders named outside ASCII both slug to `app`, so the gem numbers
    # one; its numbered name is its own to drop when that app goes.
    it "drops a numbered entry of its own when its app is gone" do
      Dir.mktmpdir do |dir|
        rails_app(File.join(dir, "\u0431\u043b\u043e\u0433"))
        rails_app(File.join(dir, "\u0448\u043e\u043f"))
        init(dir, "1\n3\n")
        expect(servers(dir).keys).to eq(%w[rails-ai-context-app rails-ai-context-app-2])
        FileUtils.rm_rf(File.join(dir, "\u0431\u043b\u043e\u0433"))

        _out, err, status = init(dir, "1\n3\n")

        expect(status.exitstatus).to eq(0), err
        expect(servers(dir)).to eq("rails-ai-context-app" => servers(dir)["rails-ai-context-app"])
        expect(servers(dir)["rails-ai-context-app"]["args"].last).to eq("\u0448\u043e\u043f")
      end
    end

    # JSON and TOML hold UTF-8 alone; the app named in Latin-1 used to fail
    # every config, the other apps' entries with it.
    it "leaves an app whose folder name is not UTF-8 out of the folder's MCP configs" do
      # NTFS stores a name as UTF-16: the bytes below are taken in the ANSI
      # code page and come back as a valid name.
      skip "Windows names files in UTF-16, so no folder name on disk is bytes that are not UTF-8" if Gem.win_platform?

      Dir.mktmpdir do |dir|
        begin
          rails_app(File.join(dir, "caf\xE9".b))
        rescue Errno::EILSEQ
          skip "this filesystem refuses names that are not UTF-8"
        end
        rails_app(File.join(dir, "plain"))

        _out, err, status = init(dir, "1\n3\n")

        expect(status.exitstatus).to eq(0), err
        expect(servers(dir).keys).to eq(%w[rails-ai-context-plain])
        expect(err.b).to include("is left out of this folder's MCP configs: its folder name is not UTF-8".b)
      end
    end

    # A relative path that starts with a dash would be read as an option.
    it "spells an app folder that starts with a dash from the folder" do
      Dir.mktmpdir do |dir|
        rails_app(File.join(dir, "-api"))
        rails_app(File.join(dir, "web"))

        _out, err, status = init(dir, "1\n3\n")

        expect(status.exitstatus).to eq(0), err
        expect(servers(dir)["rails-ai-context-api"]).to include(config_entry(*%w[rails-ai-context serve --app-path ./-api]))
      end
    end

    it "serves an app with a Gemfile and no lockfile from this binary" do
      Dir.mktmpdir do |dir|
        rails_app(File.join(dir, "a"))
        rails_app(File.join(dir, "b"))
        File.delete(File.join(dir, "b", "Gemfile.lock"))
        File.write(File.join(dir, "b", "Gemfile"), %(source "https://rubygems.org"\ngem "rails"\n))

        _out, err, status = init(dir, "1\n1\n")

        expect(status.exitstatus).to eq(0), err
        expect(servers(dir)["rails-ai-context-b"]).to include(config_entry(*%w[rails-ai-context serve --app-path b]))
        expect(File.exist?(File.join(dir, "b", "CLAUDE.md"))).to be(true)
      end
    end

    it "still sets up only the app --app-path names" do
      Dir.mktmpdir do |dir|
        rails_app(File.join(dir, "a"))
        rails_app(File.join(dir, "b"))

        _out, err, status = init(dir, "1\n3\n", "--app-path", "a")

        expect(status.exitstatus).to eq(0), err
        expect(Dir.children(dir).sort).to eq(%w[a b])
        expect(JSON.parse(File.read(File.join(dir, "a", ".mcp.json")))["mcpServers"].keys).to eq(%w[rails-ai-context])
      end
    end
  end

  # docs/CLI.md lists watch among the commands that take --no-boot, and it
  # died with an uninitialized-constant backtrace.
  it "watches a source-only tree with --no-boot" do
    exe = File.expand_path("../exe/rails-ai-context", __dir__)
    lib = File.expand_path("../lib", __dir__)
    # The child inherits this environment, so it reaches the same `listen`
    # this does. Which of the two outcomes to demand follows from that,
    # rather than from a pattern both of them match.
    listen_reachable = system(RbConfig.ruby, "-e", "require 'listen'", out: File::NULL, err: File::NULL)

    Dir.mktmpdir do |dir|
      FileUtils.mkdir_p(File.join(dir, "app", "models"))
      File.write(File.join(dir, "app", "models", "widget.rb"), "class Widget < ApplicationRecord\nend\n")

      # With `listen` reachable the watcher runs until it is killed, so the
      # child is bounded rather than read to EOF.
      io = IO.popen([ "ruby", "-I", lib, exe, "watch", "--no-boot", "--app-path", dir ], err: %i[child out])
      out = +""
      timed_out = false
      begin
        Timeout.timeout(30) do
          while (line = io.gets)
            out << line
            break if out.include?("Watching for changes")
          end
        end
      rescue Timeout::Error
        timed_out = true
      ensure
        begin
          Process.kill("KILL", io.pid)
        rescue Errno::ESRCH
          nil
        end
        io.close
      end

      expect(timed_out).to be(false), "watch printed nothing for 30s. Output so far:\n#{out}"
      expect(out).not_to include("uninitialized constant")
      if listen_reachable
        # Printed only once the listener is running, so it names a watch that
        # actually started.
        expect(out).to include("Watching for changes")
      else
        expect(out).to include("Error: The `listen` gem is required for watch mode.")
      end
    end
  end

  # `--help` promises "the ambient RAILS_ENV or development", and apps read
  # RAILS_ENV in config/boot.rb before anything else runs. Only the flag set
  # it, so an app that insists on the variable never saw the documented
  # default.
  describe "an app that needs RAILS_ENV set" do
    let(:exe) { File.expand_path("../exe/rails-ai-context", __dir__) }
    let(:lib) { File.expand_path("../lib", __dir__) }

    def build_app(dir, environment_rb)
      FileUtils.mkdir_p(File.join(dir, "config"))
      File.write(File.join(dir, "config", "environment.rb"), environment_rb)
      FileUtils.mkdir_p(File.join(dir, "app", "models"))
      File.write(File.join(dir, "app", "models", "widget.rb"), "class Widget < ApplicationRecord\nend\n")
    end

    it "applies the documented default when the caller set nothing" do
      Dir.mktmpdir do |dir|
        build_app(dir, <<~RUBY)
          File.write(File.join(__dir__, "..", "seen_env.txt"), ENV["RAILS_ENV"].to_s)
          raise "boot needs a database"
        RUBY

        out = `cd #{dir} && env -u RAILS_ENV -u RACK_ENV ruby -I #{lib} #{exe} tool model_details 2>&1`

        expect($?.exitstatus).to eq(0), out
        expect(File.read(File.join(dir, "seen_env.txt"))).to eq("development")
        expect(out).to include("Widget")
      end
    end

    it "still honours an explicit --environment" do
      Dir.mktmpdir do |dir|
        build_app(dir, <<~RUBY)
          File.write(File.join(__dir__, "..", "seen_env.txt"), ENV["RAILS_ENV"].to_s)
          raise "boot needs a database"
        RUBY

        `cd #{dir} && env -u RAILS_ENV -u RACK_ENV ruby -I #{lib} #{exe} tool model_details --environment test 2>&1`

        expect(File.read(File.join(dir, "seen_env.txt"))).to eq("test")
      end
    end

    # Rails resolves its own environment as RAILS_ENV, then RACK_ENV, then
    # development, and treats an empty value as unset. "The ambient RAILS_ENV"
    # the help text promises is that whole answer, not the first term of it.
    it "takes an ambient RACK_ENV before falling back to development" do
      Dir.mktmpdir do |dir|
        build_app(dir, <<~RUBY)
          File.write(File.join(__dir__, "..", "seen_env.txt"), ENV["RAILS_ENV"].to_s)
          raise "boot needs a database"
        RUBY

        `cd #{dir} && env -u RAILS_ENV RACK_ENV=staging ruby -I #{lib} #{exe} tool model_details 2>&1`

        expect(File.read(File.join(dir, "seen_env.txt"))).to eq("staging")
      end
    end

    it "reads an empty RAILS_ENV as unset, the way Rails does" do
      Dir.mktmpdir do |dir|
        build_app(dir, <<~RUBY)
          File.write(File.join(__dir__, "..", "seen_env.txt"), ENV["RAILS_ENV"].to_s)
          raise "boot needs a database"
        RUBY

        `cd #{dir} && env -u RACK_ENV RAILS_ENV= ruby -I #{lib} #{exe} tool model_details 2>&1`

        expect(File.read(File.join(dir, "seen_env.txt"))).to eq("development")
      end
    end

    # An app that calls exit/abort in an initializer is a fifth boot-failure
    # mode. The binary owns this process, and it has a static tier to answer
    # from, so the exit is a boot failure here rather than a process decision.
    it "serves the static tier when the app aborts during boot" do
      Dir.mktmpdir do |dir|
        build_app(dir, %(abort "The RAILS_ENV environment variable is not set."\n))

        out = `cd #{dir} && ruby -I #{lib} #{exe} tool model_details 2>&1`

        expect($?.exitstatus).to eq(0), out
        expect(out).to include("The RAILS_ENV environment variable is not set.")
        expect(out).to include("static tier active")
        expect(out).to include("Widget")
      end
    end
  end

  # The serializer refuses an unknown format, but only after a full
  # introspection has run and written nothing.
  it "refuses an unknown context format before introspecting" do
    exe = File.expand_path("../exe/rails-ai-context", __dir__)
    lib = File.expand_path("../lib", __dir__)

    Dir.mktmpdir do |dir|
      FileUtils.mkdir_p(File.join(dir, "app", "models"))
      File.write(File.join(dir, "app", "models", "widget.rb"), "class Widget < ApplicationRecord\nend\n")

      out = `cd #{dir} && ruby -I #{lib} #{exe} context --format bogus --no-boot 2>&1`

      expect($?.exitstatus).to eq(1), out
      expect(out).to include("Unknown format: bogus. Valid formats: claude, cursor, copilot, opencode, codex, json, all")
      expect(out).not_to include("Introspecting Rails app")
    end
  end

  # One rescue on dispatch answers every command, so what the commands that
  # never had one do, and what Thor's own refusals say, is pinned here.
  describe "commands that carry no rescue of their own" do
    let(:exe) { File.expand_path("../exe/rails-ai-context", __dir__) }
    let(:lib) { File.expand_path("../lib", __dir__) }

    it "prints the version and exits 0" do
      out = `ruby -I #{lib} #{exe} version 2>&1`
      expect($?.exitstatus).to eq(0), out
      expect(out).to include("rails-ai-context v")
    end

    # init given its answers and its directory rather than a shell line: on
    # Windows, backticks run cmd.exe, which has no /dev/null and ends a
    # command at its first newline. Its output and errors, as one.
    def init_in(dir, *args, answers: "")
      Open3.capture2e("ruby", "-I", lib, exe, "init", *args, chdir: dir, stdin_data: answers)
    end

    it "refuses init outside a Rails app in its own words" do
      Dir.mktmpdir do |dir|
        out, status = init_in(dir)
        expect(status.exitstatus).to eq(1), out
        expect(out).to include("No Rails app found in")
        expect(out).to include("Run this command inside a Rails app or a folder holding one (or pass --app-path).")
      end
    end

    # init read Dir.pwd before --app-path was applied: the config, every MCP
    # config and the .gitignore entries went where it was run, the context
    # files into the named app.
    it "sets up only the app --app-path names" do
      Dir.mktmpdir do |dir|
        %w[a b].each do |name|
          FileUtils.mkdir_p(File.join(dir, name, "app", "models"))
          File.write(File.join(dir, name, "app", "models", "widget.rb"), "class Widget < ApplicationRecord\nend\n")
          File.write(File.join(dir, name, ".gitignore"), "*.log\n")
        end

        out, status = init_in(File.join(dir, "a"), "--app-path", "../b", "--no-boot", answers: "1\n3\n")

        expect(status.exitstatus).to eq(0), out
        expect(Dir.children(File.join(dir, "a")).sort).to eq(%w[.gitignore app])
        expect(File.read(File.join(dir, "a", ".gitignore"))).to eq("*.log\n")
        expect(Dir.children(File.join(dir, "b"))).to include(".rails-ai-context.yml", ".mcp.json")
      end
    end

    it "sets up the app --app-path names from a directory that is no app" do
      Dir.mktmpdir do |dir|
        FileUtils.mkdir_p(File.join(dir, "empty"))
        FileUtils.mkdir_p(File.join(dir, "b", "app", "models"))
        File.write(File.join(dir, "b", "app", "models", "widget.rb"), "class Widget < ApplicationRecord\nend\n")

        out, status = init_in(File.join(dir, "empty"), "--app-path", "../b", "--no-boot", answers: "1\n3\n")

        expect(status.exitstatus).to eq(0), out
        expect(Dir.children(File.join(dir, "empty"))).to be_empty
        expect(File.exist?(File.join(dir, "b", ".rails-ai-context.yml"))).to be(true)
      end
    end

    # Typed outside the app, `init --app-path ../b` reported `.mcp.json` and
    # `.rails-ai-context.yml`, which read as files in the folder the user
    # stood in.
    it "names the files it wrote the way --app-path was typed" do
      Dir.mktmpdir do |dir|
        %w[a b].each do |name|
          FileUtils.mkdir_p(File.join(dir, name, "app", "models"))
          File.write(File.join(dir, name, "app", "models", "widget.rb"), "class Widget < ApplicationRecord\nend\n")
        end

        out, status = init_in(File.join(dir, "a"), "--app-path", "../b", "--no-boot", answers: "1\n3\n")

        expect(status.exitstatus).to eq(0), out
        expect(out).to include("Created ../b/.rails-ai-context.yml", "Created/Updated ../b/.mcp.json",
                               "Config: ../b/.rails-ai-context.yml")
      end
    end

    # The commands it prints are run from where init was: without the
    # --app-path they would read that folder instead.
    it "names the app in the commands it prints when --app-path set up another" do
      Dir.mktmpdir do |dir|
        %w[a b].each do |name|
          FileUtils.mkdir_p(File.join(dir, name, "app", "models"))
          File.write(File.join(dir, name, "app", "models", "widget.rb"), "class Widget < ApplicationRecord\nend\n")
        end

        out, status = init_in(File.join(dir, "a"), "--app-path", "../b", "--no-boot", answers: "1\n3\n")

        expect(status.exitstatus).to eq(0), out
        expect(out).to include("rails-ai-context --app-path ../b doctor")
        expect(out).not_to match(/^  rails-ai-context doctor/)
      end
    end

    # A C or POSIX locale tags every path binary or US-ASCII, and the first
    # one outside ASCII - a home directory named after its owner - could be
    # neither compared with nor joined to the gem's own UTF-8 strings.
    # Run outside any bundle, as the installed binary runs: Bundler's own
    # setup trips over such a home directory before any of this gem loads.
    # GEM_PATH unset puts the gem directory under that home on Gem.path.
    it "finds its way under a home directory named outside ASCII in a C locale" do
      Dir.mktmpdir do |dir|
        home = File.join(dir, "jos\u00e9")
        notes = File.join(home, "notes")
        FileUtils.mkdir_p(notes)
        unbundled = %w[RUBYOPT RUBYLIB BUNDLE_GEMFILE BUNDLE_BIN_PATH BUNDLER_SETUP BUNDLER_VERSION GEM_HOME GEM_PATH]
        env = unbundled.to_h { |key| [ key, nil ] }.merge("LANG" => "C", "LC_ALL" => "C", "HOME" => home)
        thor = Gem.loaded_specs.fetch("thor").full_require_paths.flat_map { |path| [ "-I", path ] }

        _out, err, status = Open3.capture3(env, RbConfig.ruby, *thor, "-I", lib, exe, "init", chdir: notes, stdin_data: "")

        expect(err).not_to include("incompatible character encodings")
        expect(status.exitstatus).to eq(1)
        # The folder it stands in, as the system names it: macOS's temp dir is under a symlink.
        expect(err).to include("No Rails app found in #{File.realpath(notes)}")
      end
    end

    # Bytes on disk that are not UTF-8 keep the locale's tags, under which
    # they are read byte by byte, as they always were in a C locale.
    it "reads an app in a folder named in Latin-1 in a C locale, from inside it and through --app-path" do
      Dir.mktmpdir do |dir|
        latin1 = File.join(dir, "caf\xE9".b)
        begin
          FileUtils.mkdir_p(File.join(latin1, "app", "models"))
        rescue Errno::EILSEQ
          skip "this filesystem refuses names that are not UTF-8"
        end
        File.write(File.join(latin1, "app", "models", "widget.rb"), "class Widget < ApplicationRecord\nend\n")
        env = { "LANG" => "C", "LC_ALL" => "C" }

        _out, inside, inside_status = Open3.capture3(env, "ruby", "-I", lib, exe, "tool", "model_details", "--no-boot",
                                                     chdir: latin1, stdin_data: "")
        _out, named, named_status = Open3.capture3(env, "ruby", "-I", lib, exe, "--app-path", "caf\xE9".b, "tool", "model_details",
                                                   "--no-boot", chdir: dir, stdin_data: "")

        expect(inside_status.exitstatus).to eq(0), inside
        expect(named_status.exitstatus).to eq(0), named
      end
    end

    # The generator's initializer holds box-drawing characters, which a C
    # locale cannot read without being told the file is UTF-8.
    it "sets up a folder of apps in a C locale whose initializers hold text outside ASCII" do
      Dir.mktmpdir do |dir|
        %w[a b].each do |name|
          FileUtils.mkdir_p(File.join(dir, "caf\u00e9", name, "config", "initializers"))
          File.write(File.join(dir, "caf\u00e9", name, "config", "application.rb"), "")
          File.write(File.join(dir, "caf\u00e9", name, "config", "initializers", "rails_ai_context.rb"),
                     "# \u2500\u2500 rails-ai-context \u2500\u2500\nRailsAiContext.configure do |config|\n  config.ai_tools = %i[claude]\nend\n")
        end
        env = { "LANG" => "C", "LC_ALL" => "C" }

        _out, err, status = Open3.capture3(env, "ruby", "-I", lib, exe, "init", "--no-boot",
                                           chdir: File.join(dir, "caf\u00e9"), stdin_data: "1\n3\n")

        expect(status.exitstatus).to eq(0), err
        expect(JSON.parse(File.read(File.join(dir, "caf\u00e9", ".mcp.json")))["mcpServers"].keys)
          .to eq(%w[rails-ai-context-a rails-ai-context-b])
      end
    end

    # The initializer wins on read, so a mode init left only in the YAML
    # changed nothing in an app that still had a generator-written one.
    it "records the mode init was given in an initializer that already sets one" do
      Dir.mktmpdir do |dir|
        FileUtils.mkdir_p(File.join(dir, "app", "models"))
        File.write(File.join(dir, "app", "models", "widget.rb"), "class Widget < ApplicationRecord\nend\n")
        FileUtils.mkdir_p(File.join(dir, "config", "initializers"))
        initializer = File.join(dir, "config", "initializers", "rails_ai_context.rb")
        File.write(initializer, "RailsAiContext.configure do |config|\n  config.tool_mode = :mcp\nend\n")

        out = `cd #{dir} && printf '1\\n2\\n' | ruby -I #{lib} #{exe} init --no-boot 2>&1`

        expect(File.read(initializer)).to include("config.tool_mode = :cli")
        # The mode line moved, so the file it is in is named, as for the tools.
        expect(out).to include("Updated config/initializers/rails_ai_context.rb")
      end
    end

    it "warns when the initializer sets the mode in a form init cannot rewrite" do
      Dir.mktmpdir do |dir|
        FileUtils.mkdir_p(File.join(dir, "app", "models"))
        File.write(File.join(dir, "app", "models", "widget.rb"), "class Widget < ApplicationRecord\nend\n")
        FileUtils.mkdir_p(File.join(dir, "config", "initializers"))
        File.write(File.join(dir, "config", "initializers", "rails_ai_context.rb"),
                   "RailsAiContext.configure do |config|\n  config.tool_mode = ENV.fetch(\"MODE\", \"mcp\").to_sym\nend\n")

        out = `cd #{dir} && printf '1\\n2\\n' | ruby -I #{lib} #{exe} init --no-boot 2>&1`

        expect(out).to include("sets config.tool_mode in a form this installer does not rewrite")
      end
    end

    # init wrote its MCP configs and cleaned up JSON configs before the boot,
    # loading this gem's json under the app's pinned copy. Every question
    # now comes first, then the boot, then every write.
    it "asks every question before the app boots, and writes nothing until it has" do
      Dir.mktmpdir do |dir|
        FileUtils.mkdir_p(File.join(dir, "config"))
        File.write(File.join(dir, "config", "application.rb"), "")
        File.write(File.join(dir, "config", "environment.rb"), "$stderr.puts 'APP BOOTING'\nraise 'boom'\n")
        File.write(File.join(dir, ".rails-ai-context.yml"), "ai_tools:\n- claude\n- cursor\ntool_mode: mcp\n")

        _out, err, status = Open3.capture3("ruby", "-I", lib, exe, "init", chdir: dir, stdin_data: "1\n1\ny\n")

        expect(status.exitstatus).to eq(0), err
        asked = err.index("Remove their generated files?")
        booted = err.index("APP BOOTING")
        recorded = err.index("Updated .rails-ai-context.yml")
        expect([ asked, booted, recorded ]).to all(be_an(Integer)), err
        expect(asked).to be < booted
        expect(booted).to be < recorded
      end
    end

    it "boots nothing for an MCP-only setup" do
      Dir.mktmpdir do |dir|
        FileUtils.mkdir_p(File.join(dir, "config"))
        File.write(File.join(dir, "config", "application.rb"), "")
        File.write(File.join(dir, "config", "environment.rb"), "$stderr.puts 'APP BOOTING'\nraise 'boom'\n")

        _out, err, status = Open3.capture3("ruby", "-I", lib, exe, "init", "--mcp-only", chdir: dir, stdin_data: "1\n")

        expect(status.exitstatus).to eq(0), err
        expect(err).not_to include("APP BOOTING")
        expect(err).to include("MCP-only setup: no context files written.")
        expect(File.exist?(File.join(dir, ".mcp.json"))).to be(true)
      end
    end

    # Codex's config copies PATH and the gem variables out of the process,
    # and init writes it after the boot, whose Bundler.setup puts the app's
    # bundle into them.
    it "writes Codex's environment as the binary was started in, not as the app's boot left it" do
      Dir.mktmpdir do |dir|
        FileUtils.mkdir_p(File.join(dir, "app", "models"))
        File.write(File.join(dir, "app", "models", "widget.rb"), "class Widget < ApplicationRecord\nend\n")
        FileUtils.mkdir_p(File.join(dir, "config"))
        File.write(File.join(dir, "config", "application.rb"), "")
        # What Bundler.setup leaves in the environment, then a boot that fails into the static tier.
        File.write(File.join(dir, "config", "environment.rb"), <<~RUBY)
          ENV["BUNDLE_BIN_PATH"] = "/the/bundle/exe/bundle"
          ENV["GEM_HOME"] = "/the/bundle"
          ENV["PATH"] = "/the/bundle/bin" + File::PATH_SEPARATOR + ENV["PATH"]
          raise "boom"
        RUBY

        _out, err, status = Open3.capture3("ruby", "-I", lib, exe, "init", chdir: dir, stdin_data: "5\n1\n")

        expect(status.exitstatus).to eq(0), err
        codex = File.read(File.join(dir, ".codex", "config.toml"))
        expect(codex).not_to include("/the/bundle")
        expect(codex).to include(%(PATH = #{JSON.generate(ENV.fetch("PATH"))}))
      end
    end

    # `rails ai:context` brings the MCP configs up to date on every run; the
    # binary's `context` left an app taken out of its bundle with context
    # files naming the binary beside configs that still started
    # `bundle exec`, which no longer starts.
    it "brings a recorded selection's MCP configs up to date with context, as rails ai:context does" do
      Dir.mktmpdir do |dir|
        FileUtils.mkdir_p(File.join(dir, "app", "models"))
        File.write(File.join(dir, "app", "models", "widget.rb"), "class Widget < ApplicationRecord\nend\n")
        File.write(File.join(dir, "Gemfile"), "source \"https://rubygems.org\"\ngem \"rails\"\n")
        File.write(File.join(dir, ".rails-ai-context.yml"), "ai_tools:\n- claude\ntool_mode: mcp\n")
        File.write(File.join(dir, ".mcp.json"),
                   JSON.generate("mcpServers" => { "rails-ai-context" => { "command" => "bundle", "args" => %w[exec rails-ai-context serve] } }))

        _out, err, status = Open3.capture3("ruby", "-I", lib, exe, "context", "--no-boot", chdir: dir)

        expect(status.exitstatus).to eq(0), err
        expect(JSON.parse(File.read(File.join(dir, ".mcp.json")))["mcpServers"]["rails-ai-context"])
          .to eq(config_entry("rails-ai-context", "serve"))
        expect(err).to include("Created/Updated .mcp.json")
      end
    end

    it "says nothing about legacy rule files on an MCP-only init" do
      Dir.mktmpdir do |dir|
        FileUtils.mkdir_p(File.join(dir, "app", "models"))
        File.write(File.join(dir, "app", "models", "widget.rb"), "class Widget < ApplicationRecord\nend\n")
        FileUtils.mkdir_p(File.join(dir, ".claude", "rules"))
        File.write(File.join(dir, ".claude", "rules", "rails-ui-patterns.md"), "old\n")

        out = `cd #{dir} && printf '1\\n' | ruby -I #{lib} #{exe} init --mcp-only --no-boot 2>&1`

        expect(out).to include("MCP-only setup")
        expect(out).not_to include("Legacy files detected")
      end
    end

    # init wrote its config files and then died in a Ruby backtrace when
    # generating context hit a path it could not write.
    it "answers an unexpected init failure in one line on stderr" do
      Dir.mktmpdir do |dir|
        FileUtils.mkdir_p(File.join(dir, "app", "models"))
        File.write(File.join(dir, "app", "models", "widget.rb"), "class Widget < ApplicationRecord\nend\n")
        FileUtils.mkdir_p(File.join(dir, "CLAUDE.md"))

        _out, err, status = Open3.capture3("ruby", "-I", lib, exe, "init", chdir: dir, stdin_data: "")

        expect(status.exitstatus).to eq(1), err
        expect(err.lines.last).to start_with("Error: Is a directory")
        expect(err).not_to match(/^\s+from /)
        expect(err).not_to include("(Errno::EISDIR)")
      end
    end

    # The one line is the answer; the frames behind it are one env var away,
    # the same way a boot failure spells it.
    it "prints the frames behind that failure under DEBUG" do
      Dir.mktmpdir do |dir|
        FileUtils.mkdir_p(File.join(dir, "app", "models"))
        File.write(File.join(dir, "app", "models", "widget.rb"), "class Widget < ApplicationRecord\nend\n")
        FileUtils.mkdir_p(File.join(dir, "CLAUDE.md"))

        _out, err, status = Open3.capture3({ "DEBUG" => "1" }, "ruby", "-I", lib, exe, "init", chdir: dir, stdin_data: "")

        expect(status.exitstatus).to eq(1), err
        expect(err).to include("Error: Is a directory")
        expect(err).to match(%r{^\s+\S+/lib/rails_ai_context/\S+\.rb:\d+}), err
      end
    end

    it "leaves an unknown command to Thor" do
      out = `ruby -I #{lib} #{exe} bogus 2>&1`
      expect($?.exitstatus).to eq(1), out
      expect(out).to eq(%(Could not find command "bogus".\n))
    end

    it "prints the command list and exits 0" do
      out = `ruby -I #{lib} #{exe} help 2>&1`
      expect($?.exitstatus).to eq(0), out
      expect(out).to include("rails-ai-context version")
    end
  end

  it "documents the static-tier flags" do
    help = `ruby #{File.expand_path('../exe/rails-ai-context', __dir__)} help serve 2>&1`
    expect(help).to include("--no-boot")
    expect(help).to include("--app-path")
    expect(help).to include("--environment")
  end

  # The port the HTTP server announces, read off stderr before it binds.
  describe "serve port" do
    let(:exe) { File.expand_path("../exe/rails-ai-context", __dir__) }
    let(:lib) { File.expand_path("../lib", __dir__) }

    def announced_port(dir, *args)
      Open3.popen3("ruby", "-I", lib, exe, "serve", *args, "--no-boot", chdir: dir) do |stdin, _out, err, wait|
        stdin.close
        Timeout.timeout(60) do
          while (line = err.gets)
            return line[/starting on [^:]+:(\d+)/, 1] if line.include?("starting on")
          end
        end
      ensure
        Process.kill("KILL", wait.pid) rescue nil
      end
    end

    def app_dir(dir, yaml = nil)
      FileUtils.mkdir_p(File.join(dir, "app", "models"))
      File.write(File.join(dir, "app", "models", "widget.rb"), "class Widget\nend\n")
      File.write(File.join(dir, ".rails-ai-context.yml"), yaml) if yaml
    end

    # The stdio server is started by its client; the HTTP one is started by hand, like any other command.
    it "tells the stdio server's client, and whoever runs the HTTP server, where the pinned Ruby must be active" do
      Dir.mktmpdir do |dir|
        app_dir(dir)
        FileUtils.mkdir_p(File.join(dir, "config"))
        File.write(File.join(dir, "config", "environment.rb"), "require 'shop_native_ext'\n")
        File.write(File.join(dir, ".ruby-version"), "1.9.3\n")

        _out, stdio, = Open3.capture3("ruby", "-I", lib, exe, "serve", chdir: dir, stdin_data: "")
        expect(stdio).to include("pins Ruby 1.9.3 (.ruby-version)").and include("Start the client where that Ruby is active")

        http = +""
        Open3.popen3("ruby", "-I", lib, exe, "serve", "--transport", "http", "--port", "6126", chdir: dir) do |stdin, _o, err, wait|
          stdin.close
          Timeout.timeout(60) { (http << err.gets.to_s) until http.include?("starting on") || err.eof? }
        ensure
          Process.kill("KILL", wait.pid) rescue nil
        end
        expect(http).to include("pins Ruby 1.9.3 (.ruby-version)").and include("Run it where that Ruby is active")
      end
    end

    it "honours --port under the streamable_http alias" do
      Dir.mktmpdir do |dir|
        app_dir(dir)
        expect(announced_port(dir, "--transport", "streamable_http", "--port", "6123")).to eq("6123")
      end
    end

    it "reads http_port from the config file when --port is left out" do
      Dir.mktmpdir do |dir|
        app_dir(dir, "http_port: 6124\n")
        expect(announced_port(dir, "--transport", "http")).to eq("6124")
      end
    end

    it "lets an explicit --port beat the config file" do
      Dir.mktmpdir do |dir|
        app_dir(dir, "http_port: 6124\n")
        expect(announced_port(dir, "--transport", "http", "--port", "6125")).to eq("6125")
      end
    end

    it "falls back to 6029" do
      Dir.mktmpdir do |dir|
        app_dir(dir)
        expect(announced_port(dir, "--transport", "http")).to eq("6029")
      end
    end
  end

  # The install an agent or a script runs: every answer on the command line,
  # and stdin holding answers that would pick otherwise, to prove none is read.
  describe "init and uninstall answered by flags" do
    let(:exe) { File.expand_path("../exe/rails-ai-context", __dir__) }
    let(:lib) { File.expand_path("../lib", __dir__) }
    let(:decoy) { "5\n3\ny\ny\n" }

    def rails_app(dir)
      FileUtils.mkdir_p(File.join(dir, "config"))
      FileUtils.mkdir_p(File.join(dir, "app", "models"))
      File.write(File.join(dir, "config", "application.rb"), "module X\n  class Application < Rails::Application\n  end\nend\n")
      File.write(File.join(dir, "app", "models", "widget.rb"), "class Widget < ApplicationRecord\nend\n")
      File.write(File.join(dir, ".gitignore"), "*.log\n")
      # A bundle without the gem: a standalone install.
      File.write(File.join(dir, "Gemfile"), "")
      File.write(File.join(dir, "Gemfile.lock"), "GEM\n  remote: https://rubygems.org/\n  specs:\n    rails (8.0.0)\n\n")
    end

    def run_cli(dir, *argv, stdin: decoy)
      Open3.capture3("ruby", "-I", lib, exe, *argv, chdir: dir, stdin_data: stdin)
    end

    def tree(dir)
      Dir.glob("**/*", File::FNM_DOTMATCH, base: dir).reject { |path| path.end_with?(".") }.sort
    end

    it "sets up the named tools in CLI mode without asking" do
      Dir.mktmpdir do |dir|
        rails_app(dir)

        _out, err, status = run_cli(dir, "init", "--no-boot", "--tools", "cursor,claude", "--cli")

        expect(status.exitstatus).to eq(0), err
        expect(err).not_to include("Which AI tools", "What should rails-ai-context write?")
        expect(err).to include("Selected: Claude Code, Cursor", "Selected: Context files only (CLI mode, no MCP server)")
        expect(File.read(File.join(dir, ".rails-ai-context.yml"))).to include("- claude\n- cursor\n", "tool_mode: cli")
        expect(File.exist?(File.join(dir, "CLAUDE.md"))).to be(true)
        expect(File.exist?(File.join(dir, ".cursorrules"))).to be(true)
        expect(File.exist?(File.join(dir, ".mcp.json"))).to be(false)
      end
    end

    it "closes with each tool's next step in the MCP setup, and none in the CLI setup" do
      Dir.mktmpdir do |dir|
        rails_app(dir)

        _out, err, = run_cli(dir, "init", "--no-boot", "--tools", "claude,codex", "--defaults")
        expect(err).to include("Next step", "Claude Code: start a new Claude Code session", "Codex CLI: trust this folder")
        expect(err).not_to include("No manual config needed")

        _out, err, = run_cli(dir, "init", "--no-boot", "--tools", "claude", "--cli", "--prune")
        expect(err).not_to include("Next step")
      end
    end

    # Typed in a folder inside the app, the plugin's note names the folder whose sessions start it.
    it "names the app's folder in the committed plugin's note when init runs inside the app" do
      Dir.mktmpdir do |dir|
        dir = File.realpath(dir)
        rails_app(dir)
        FileUtils.mkdir_p(File.join(dir, ".claude"))
        File.write(File.join(dir, ".claude", "settings.json"), JSON.generate("enabledPlugins" => { "rails-ai-context@rails-ai-context" => true }))
        system("git", "init", "-q", dir, out: File::NULL, err: File::NULL)

        models = File.join(dir, "app", "models")
        _out, err, = run_cli(models, "init", "--no-boot", "--tools", "claude", "--defaults")
        expect(err).to include("no server written into #{File.join(dir, ".mcp.json")}: #{File.join(dir, ".claude", "settings.json")} turns the " \
                               "rails-ai-context plugin on, but it does not start for you in #{dir}: doctor names why")

        # Where Claude Code never ran, the committed setting is the whole setup.
        _out, err, = Open3.capture3({ "CLAUDE_CONFIG_DIR" => File.join(dir, "never-ran") }, "ruby", "-I", lib, exe, "init", "--no-boot", "--tools",
                                    "claude", "--defaults", chdir: models, stdin_data: "")
        expect(err).to include("the rails-ai-context plugin serves this app for sessions started in #{dir}")
      end
    end

    # Typed above the app, each step names the folder to start the client in.
    it "names the app's folder in each next step when --app-path picks the app from above" do
      Dir.mktmpdir do |dir|
        rails_app(File.join(dir, "shop"))

        _out, err, = run_cli(dir, "init", "--no-boot", "--app-path", "shop", "--tools", "claude,codex", "--defaults")

        expect(err).to include("Claude Code: start a new Claude Code session in shop and approve",
                               "Codex CLI: trust shop when Codex CLI asks", "then start a new codex session in shop")
      end
    end

    it "closes a folder of apps with each tool's next step" do
      Dir.mktmpdir do |dir|
        rails_app(File.join(dir, "a"))
        rails_app(File.join(dir, "b"))

        _out, err, = run_cli(dir, "init", "--no-boot", "--tools", "cursor", "--mcp-only")

        expect(err).to include("Next step", "Cursor: restart Cursor")
      end
    end

    it "stops on a bad flag before writing anything" do
      Dir.mktmpdir do |dir|
        rails_app(dir)
        before = tree(dir)

        _out, err, status = run_cli(dir, "init", "--no-boot", "--tools", "vim")
        expect(status.exitstatus).to eq(1)
        expect(err).to include('"vim" is not an AI tool')

        _out, err, status = run_cli(dir, "init", "--no-boot", "--cli", "--mcp-only")
        expect(status.exitstatus).to eq(1)
        expect(err).to include("--cli and --mcp-only")
        expect(tree(dir)).to eq(before)
      end
    end

    it "switches back to MCP config + context files under --mcp" do
      Dir.mktmpdir do |dir|
        rails_app(dir)
        run_cli(dir, "init", "--no-boot", "--tools", "claude", "--cli")

        _out, err, status = run_cli(dir, "init", "--no-boot", "--mcp", "--defaults")

        expect(status.exitstatus).to eq(0), err
        expect(File.read(File.join(dir, ".rails-ai-context.yml"))).to include("tool_mode: mcp", "context_files: true")
        expect(File.read(File.join(dir, ".mcp.json"))).to include("rails-ai-context")
      end
    end

    it "keeps the recorded tools and setup under --defaults on a re-run" do
      Dir.mktmpdir do |dir|
        rails_app(dir)
        run_cli(dir, "init", "--no-boot", "--tools", "cursor", "--cli")

        _out, err, status = run_cli(dir, "init", "--no-boot", "--defaults")

        expect(status.exitstatus).to eq(0), err
        record = File.read(File.join(dir, ".rails-ai-context.yml"))
        expect(record).to include("- cursor\n", "tool_mode: cli")
        expect(record).not_to include("- claude")
        expect(File.exist?(File.join(dir, ".cursor/mcp.json"))).to be(false)
      end
    end

    it "takes every default under --defaults" do
      Dir.mktmpdir do |dir|
        rails_app(dir)

        _out, err, status = run_cli(dir, "init", "--no-boot", "--defaults")

        expect(status.exitstatus).to eq(0), err
        expect(File.read(File.join(dir, ".rails-ai-context.yml"))).to include("- codex\n", "tool_mode: mcp")
        expect(File.exist?(File.join(dir, "CLAUDE.md"))).to be(true)
      end
    end

    it "keeps a dropped tool's files under --defaults, and removes them under --prune" do
      Dir.mktmpdir do |dir|
        rails_app(dir)
        run_cli(dir, "init", "--no-boot", "--tools", "claude,cursor")

        _out, err, = run_cli(dir, "init", "--no-boot", "--tools", "claude", "--defaults")
        expect(File.exist?(File.join(dir, ".cursorrules"))).to be(true), err

        run_cli(dir, "init", "--no-boot", "--tools", "claude,cursor", "--defaults")
        _out, err, status = run_cli(dir, "init", "--no-boot", "--tools", "claude", "--prune")
        expect(status.exitstatus).to eq(0), err
        expect(File.exist?(File.join(dir, ".cursorrules"))).to be(false)
        expect(File.exist?(File.join(dir, ".cursor"))).to be(false)
        expect(File.exist?(File.join(dir, "CLAUDE.md"))).to be(true)
      end
    end

    it "takes the gem out of the MCP configs on a switch to CLI mode under --prune" do
      Dir.mktmpdir do |dir|
        rails_app(dir)
        run_cli(dir, "init", "--no-boot", "--tools", "claude")

        _out, err, status = run_cli(dir, "init", "--no-boot", "--tools", "claude", "--cli", "--prune")

        expect(status.exitstatus).to eq(0), err
        expect(File.exist?(File.join(dir, ".mcp.json"))).to be(false)
      end
    end

    it "takes the generated context files out on a switch to MCP only under --prune, and keeps them under --defaults" do
      Dir.mktmpdir do |dir|
        rails_app(dir)
        run_cli(dir, "init", "--no-boot", "--tools", "claude,cursor")

        _out, err, = run_cli(dir, "init", "--no-boot", "--tools", "claude,cursor", "--mcp-only", "--defaults")
        expect(File.exist?(File.join(dir, ".cursorrules"))).to be(true), err
        expect(err).to include("would go stale")

        _out, err, status = run_cli(dir, "init", "--no-boot", "--tools", "claude,cursor", "--mcp-only", "--prune")
        expect(status.exitstatus).to eq(0), err
        %w[.cursorrules .cursor/rules CLAUDE.md .claude .ai-context.json].each do |path|
          expect(File.exist?(File.join(dir, path))).to be(false), path
        end
        expect(File.read(File.join(dir, ".mcp.json"))).to include("rails-ai-context")
        expect(File.read(File.join(dir, ".cursor/mcp.json"))).to include("rails-ai-context")
        expect(err).not_to include("Left alone on purpose")
      end
    end

    it "takes a folder of apps' generated context files out on a switch to MCP only under --prune" do
      Dir.mktmpdir do |dir|
        rails_app(File.join(dir, "a"))
        rails_app(File.join(dir, "b"))
        run_cli(dir, "init", "--no-boot", "--tools", "claude")

        _out, err, status = run_cli(dir, "init", "--no-boot", "--tools", "claude", "--mcp-only", "--prune")

        expect(status.exitstatus).to eq(0), err
        expect(File.exist?(File.join(dir, "a", "CLAUDE.md"))).to be(false)
        expect(File.exist?(File.join(dir, "b", ".claude"))).to be(false)
      end
    end

    it "deletes legacy files under --prune" do
      Dir.mktmpdir do |dir|
        rails_app(dir)
        FileUtils.mkdir_p(File.join(dir, ".claude", "rules"))
        File.write(File.join(dir, ".claude", "rules", "rails-ui-patterns.md"), "# stale")

        _out, err, status = run_cli(dir, "init", "--no-boot", "--tools", "claude", "--prune")

        expect(status.exitstatus).to eq(0), err
        expect(File.exist?(File.join(dir, ".claude", "rules", "rails-ui-patterns.md"))).to be(false)
      end
    end

    it "refuses to guess under --defaults when a folder's apps recorded different setups" do
      Dir.mktmpdir do |dir|
        rails_app(File.join(dir, "a"))
        rails_app(File.join(dir, "b"))
        run_cli(File.join(dir, "a"), "init", "--no-boot", "--tools", "claude", "--cli")
        run_cli(File.join(dir, "b"), "init", "--no-boot", "--tools", "claude", "--mcp-only")
        before = File.read(File.join(dir, "a", ".rails-ai-context.yml"))

        _out, err, status = run_cli(dir, "init", "--no-boot", "--defaults")

        expect(status.exitstatus).to eq(1)
        expect(err).to include("recorded different setups", "--mcp, --cli or --mcp-only")
        expect(File.read(File.join(dir, "a", ".rails-ai-context.yml"))).to eq(before)

        _out, err, status = run_cli(dir, "init", "--no-boot", "--cli", "--defaults")
        expect(status.exitstatus).to eq(0), err
      end
    end

    it "sets up a folder of apps from flags" do
      Dir.mktmpdir do |dir|
        rails_app(File.join(dir, "a"))
        rails_app(File.join(dir, "b"))

        _out, err, status = run_cli(dir, "init", "--no-boot", "--tools", "claude", "--mcp-only")

        expect(status.exitstatus).to eq(0), err
        expect(JSON.parse(File.read(File.join(dir, ".mcp.json")))["mcpServers"].keys)
          .to eq(%w[rails-ai-context-a rails-ai-context-b])
        expect(File.exist?(File.join(dir, "a", "CLAUDE.md"))).to be(false)
      end
    end

    it "uninstalls back to the files the app had" do
      Dir.mktmpdir do |dir|
        rails_app(dir)
        before = tree(dir)
        run_cli(dir, "init", "--no-boot", "--defaults")
        expect(tree(dir)).not_to eq(before)

        out, err, status = run_cli(dir, "uninstall")

        expect(status.exitstatus).to eq(0), err
        expect(tree(dir)).to eq(before)
        expect(File.read(File.join(dir, ".gitignore"))).to eq("*.log\n")
        expect(out).to eq("")
        expect(err).to include("gem uninstall rails-ai-context")
      end
    end

    it "keeps what the user wrote in a shared context file" do
      Dir.mktmpdir do |dir|
        rails_app(dir)
        File.write(File.join(dir, "CLAUDE.md"), "# Mine\n\nHouse rules.\n")
        run_cli(dir, "init", "--no-boot", "--tools", "claude")
        expect(File.read(File.join(dir, "CLAUDE.md"))).to include("BEGIN rails-ai-context")

        _out, err, status = run_cli(dir, "uninstall")

        expect(status.exitstatus).to eq(0), err
        expect(File.read(File.join(dir, "CLAUDE.md"))).to eq("# Mine\n\nHouse rules.\n")
      end
    end

    it "keeps another server in a shared MCP config, and names a mounted engine" do
      Dir.mktmpdir do |dir|
        rails_app(dir)
        File.write(File.join(dir, ".mcp.json"), JSON.generate("mcpServers" => { "mine" => { "command" => "x" } }))
        File.write(File.join(dir, "config", "routes.rb"),
                   "Rails.application.routes.draw do\n  mount RailsAiContext::Engine, at: \"/mcp\"\nend\n")
        run_cli(dir, "init", "--no-boot", "--tools", "claude")

        _out, err, status = run_cli(dir, "uninstall")

        expect(status.exitstatus).to eq(0), err
        expect(JSON.parse(File.read(File.join(dir, ".mcp.json")))["mcpServers"].keys).to eq(%w[mine])
        expect(err).to include("config/routes.rb:2 mounts RailsAiContext::Engine")
      end
    end

    it "takes out the HTTP entry under the gem's name, which only the gem's endpoint answers" do
      Dir.mktmpdir do |dir|
        rails_app(dir)
        File.write(File.join(dir, ".mcp.json"), JSON.generate("mcpServers" => {
          "rails-ai-context" => { "type" => "http", "url" => "http://localhost:3000/mcp" }, "mine" => { "url" => "http://x" }
        }))

        _out, err, status = run_cli(dir, "uninstall")

        expect(status.exitstatus).to eq(0), err
        expect(JSON.parse(File.read(File.join(dir, ".mcp.json")))["mcpServers"].keys).to eq(%w[mine])
      end
    end

    # Releases before v5.14.0 wrote the JSON cache's note with a Unicode dash.
    it "takes out the .gitignore lines an earlier release wrote" do
      Dir.mktmpdir do |dir|
        rails_app(dir)
        File.write(File.join(dir, ".gitignore"),
                   "*.log\n\n# rails-ai-context (JSON cache \u2014 markdown files should be committed)\n.ai-context.json\n")

        _out, err, status = run_cli(dir, "uninstall")

        expect(status.exitstatus).to eq(0), err
        expect(File.read(File.join(dir, ".gitignore"))).to eq("*.log\n")
      end
    end

    # The plugin runs the installed gem, so removing the gem first leaves it failing to start.
    # A local disable wins over every other setting; an uninstall goes by the install's scope, in its project.
    it "names the command that takes out the Claude Code plugin installed for the app, before the gem" do
      registry = File.join(ENV.fetch("CLAUDE_CONFIG_DIR"), "plugins", "installed_plugins.json")
      Dir.mktmpdir do |dir|
        rails_app(dir)
        system("git", "init", "-q", dir, out: File::NULL, err: File::NULL)
        FileUtils.mkdir_p([ File.join(dir, ".claude"), File.dirname(registry) ])
        File.write(File.join(dir, ".claude", "settings.json"), JSON.generate("enabledPlugins" => { "rails-ai-context@rails-ai-context" => true }))
        File.write(registry, JSON.generate("version" => 2, "plugins" => {
          "rails-ai-context@rails-ai-context" => [ { "scope" => "project", "projectPath" => File.realpath(dir) } ]
        }))

        _out, err, status = run_cli(dir, "uninstall")
        expect(status.exitstatus).to eq(0), err
        expect(err).to include("take it out before the gem: `claude plugin disable rails-ai-context@rails-ai-context --scope local` turns it off " \
                               "for this app, or `claude plugin uninstall rails-ai-context@rails-ai-context --scope project` takes it out of " \
                               ".claude/settings.json for everyone.")
        expect(err.index("claude plugin disable")).to be < err.index("gem uninstall rails-ai-context")

        _out, err, = run_cli(File.join(dir, "app", "models"), "uninstall")
        expect(err).to include("`claude plugin disable rails-ai-context@rails-ai-context --scope local` run in #{File.realpath(dir)} turns it off " \
                               "for this app, or `claude plugin uninstall rails-ai-context@rails-ai-context --scope project` run in " \
                               "#{File.realpath(dir)} takes it out of .claude/settings.json for everyone.")

        # With a second install, no one uninstall takes it out.
        File.write(registry, JSON.generate("version" => 2, "plugins" => {
          "rails-ai-context@rails-ai-context" => [ { "scope" => "project", "projectPath" => File.realpath(dir) }, { "scope" => "user" } ]
        }))
        _out, err, = run_cli(dir, "uninstall")
        expect(err).to include("`claude plugin disable rails-ai-context@rails-ai-context --scope local` turns it off for this app.")
      end
    ensure
      FileUtils.rm_rf(File.dirname(registry))
    end

    # One local disable per project covers each session that runs it, the user's own settings included.
    it "names every project whose sessions run a plugin the user's settings and the app's turn on" do
      config = ENV.fetch("CLAUDE_CONFIG_DIR")
      registry = File.join(config, "plugins", "installed_plugins.json")
      Dir.mktmpdir do |dir|
        dir = File.realpath(dir)
        shop = File.join(dir, "mid", "shop")
        rails_app(shop)
        rails_app(File.join(dir, "other"))
        system("git", "init", "-q", shop, out: File::NULL, err: File::NULL)
        FileUtils.mkdir_p([ File.join(shop, ".claude"), File.dirname(registry) ])
        on = JSON.generate("enabledPlugins" => { "rails-ai-context@rails-ai-context" => true })
        File.write(File.join(shop, ".claude", "settings.json"), on)
        File.write(File.join(config, "settings.json"), on)
        File.write(registry, JSON.generate("version" => 2, "plugins" => { "rails-ai-context@rails-ai-context" => [ { "scope" => "user" } ] }))

        _out, err, status = run_cli(shop, "uninstall")

        expect(status.exitstatus).to eq(0), err
        # Outside a repository, mid's local settings reach only sessions started in mid itself.
        expect(err).to include("take it out before the gem: `claude plugin disable rails-ai-context@rails-ai-context --scope local` run here " \
                               "and in #{File.join(dir, "mid")} turns it off for this app and sessions started there, or " \
                               "`claude plugin uninstall rails-ai-context@rails-ai-context --scope user` takes it out everywhere.")
      end
    ensure
      FileUtils.rm_rf(File.dirname(registry))
      FileUtils.rm_f(File.join(config, "settings.json"))
    end

    # Never installed here, the plugin runs nothing the gem's removal could break.
    it "says nothing of a plugin the app turns on but this machine never installed" do
      Dir.mktmpdir do |dir|
        rails_app(dir)
        FileUtils.mkdir_p(File.join(dir, ".claude"))
        File.write(File.join(dir, ".claude", "settings.json"), JSON.generate("enabledPlugins" => { "rails-ai-context@rails-ai-context" => true }))

        _out, err, status = run_cli(dir, "uninstall")

        expect(status.exitstatus).to eq(0), err
        expect(err).not_to include("claude plugin")
      end
    end

    # Every session there runs the plugin's server, and a .mcp.json one would list each tool twice.
    it "writes no Claude Code server where the app's committed settings turn the plugin on" do
      Dir.mktmpdir do |dir|
        rails_app(dir)
        FileUtils.mkdir_p(File.join(dir, ".claude"))
        File.write(File.join(dir, ".claude", "settings.json"), JSON.generate("enabledPlugins" => { "rails-ai-context@rails-ai-context" => true }))

        _out, err, status = run_cli(dir, "init", "--no-boot", "--tools", "claude,cursor", "--mcp")

        expect(status.exitstatus).to eq(0), err
        expect(File.exist?(File.join(dir, ".mcp.json"))).to be(false)
        expect(File.exist?(File.join(dir, ".cursor", "mcp.json"))).to be(true)
        expect(err).to include("Claude Code: the app's .claude/settings.json turns the rails-ai-context plugin on, but it does not start for you here")
        expect(err).not_to include("approve each rails-ai-context server")
        expect(err).to include("Claude Code      -> the rails-ai-context plugin (off here: see below); CLAUDE.md + .claude/rules/")

        _out, err, = run_cli(dir, "init", "--no-boot", "--tools", "claude", "--mcp-only")
        expect(err).to include("Claude Code      -> the rails-ai-context plugin (off here: see below)\n")
        expect(err).not_to include("-> MCP config only")
      end
    end

    # Typed from the folder above, the files and the folder a session starts in are named from there.
    it "names the committed plugin's files from where init --app-path was typed" do
      Dir.mktmpdir do |dir|
        app = File.join(dir, "shop")
        rails_app(app)
        FileUtils.mkdir_p(File.join(app, ".claude"))
        File.write(File.join(app, ".claude", "settings.json"), JSON.generate("enabledPlugins" => { "rails-ai-context@rails-ai-context" => true }))
        File.write(File.join(app, ".mcp.json"), JSON.generate("mcpServers" => { "rails-ai-context" => { "command" => "rails-ai-context", "args" => [ "serve" ] } }))

        _out, err, status = run_cli(dir, "init", "--app-path", "shop", "--no-boot", "--tools", "claude", "--mcp-only")

        expect(status.exitstatus).to eq(0), err
        expect(err).to include("Claude Code: no server written into shop/.mcp.json: shop/.claude/settings.json turns the rails-ai-context plugin on, " \
                               "but it does not start for you in shop: doctor names why")
        expect(err).to include("Claude Code: shop/.claude/settings.json turns the rails-ai-context plugin on, but it does not start for you in shop")
        expect(err).not_to include(" .mcp.json", " .claude/settings.json")
      end
    end

    it "says so when there is nothing to uninstall" do
      Dir.mktmpdir do |dir|
        rails_app(dir)

        _out, err, status = run_cli(dir, "uninstall")

        expect(status.exitstatus).to eq(0), err
        expect(err).to include("Nothing of rails-ai-context's was found")
        expect(err).not_to include("is uninstalled")
      end
    end

    it "removes the pre-commit hook it wrote, and names one changed by hand" do
      Dir.mktmpdir do |dir|
        rails_app(dir)
        system("git", "init", "-q", dir, out: File::NULL, err: File::NULL)
        hook = File.join(dir, ".git", "hooks", "pre-commit")
        File.write(hook, RailsAiContext::Install::ValidationHook.script([ "." ], standalone: true))

        _out, err, status = run_cli(dir, "uninstall")
        expect(status.exitstatus).to eq(0), err
        expect(File.exist?(hook)).to be(false)

        File.write(hook, RailsAiContext::Install::ValidationHook.script([ "." ], standalone: true) + "echo mine\n")
        _out, err, = run_cli(dir, "uninstall")
        expect(File.exist?(hook)).to be(true)
        expect(err).to include("changed by hand")
      end
    end

    it "uninstalls a folder of apps" do
      Dir.mktmpdir do |dir|
        rails_app(File.join(dir, "a"))
        rails_app(File.join(dir, "b"))
        before = tree(dir)
        run_cli(dir, "init", "--no-boot", "--defaults")

        _out, err, status = run_cli(dir, "uninstall")

        expect(status.exitstatus).to eq(0), err
        expect(tree(dir)).to eq(before)
      end
    end

    # A client the gem writes no config for (Claude Desktop, Windsurf, Zed)
    # starts its servers from its own folder, with its own PATH.
    it "prints an MCP entry that starts the server from any folder, with a bare environment" do
      # The prism canary bundles prism from git, which only bundler can see.
      skip "prism comes from a git checkout" if Gem.loaded_specs["prism"]&.source.is_a?(Bundler::Source::Git)

      Dir.mktmpdir do |dir|
        rails_app(dir)

        out, err, status = run_cli(dir, "mcp-entry")

        expect(status.exitstatus).to eq(0), err
        entry = JSON.parse(out).fetch("mcpServers").fetch("rails-ai-context")
        expect(entry["command"]).to eq(RbConfig.ruby)
        expect(entry["args"].last(3)).to eq([ "serve", "--app-path", File.realpath(dir) ])

        request = [
          { jsonrpc: "2.0", id: 1, method: "initialize",
            params: { protocolVersion: "2025-06-18", capabilities: {}, clientInfo: { name: "t", version: "1" } } },
          { jsonrpc: "2.0", method: "notifications/initialized" },
          { jsonrpc: "2.0", id: 2, method: "tools/list" }
        ].map(&:to_json).join("\n") + "\n"
        # The entry's args name the installed wrapper; this checkout's binary
        # stands in for it here, run the same way.
        args = [ "-I", lib, exe, *entry["args"].drop(1) ]
        env = entry.fetch("env", {}).merge("RAILS_AI_CONTEXT_NO_UPDATE_CHECK" => "1")
        served, = Open3.capture2(env, entry["command"], *args,
                                 chdir: Dir.home, unsetenv_others: true, stdin_data: request)

        tools = served.lines.filter_map { |line| JSON.parse(line) rescue nil }.find { |m| m["id"] == 2 }
        expect(tools&.dig("result", "tools")&.size).to be > 30
      end
    end

    it "prints a bundle exec entry with the app's Gemfile for an in-Gemfile app" do
      Dir.mktmpdir do |dir|
        rails_app(dir)
        File.write(File.join(dir, "Gemfile.lock"),
                   "GEM\n  remote: https://rubygems.org/\n  specs:\n    rails (8.0.0)\n    rails-ai-context (5.35.0)\n\n")

        out, err, status = run_cli(dir, "mcp-entry")

        expect(status.exitstatus).to eq(0), err
        entry = JSON.parse(out).fetch("mcpServers").fetch("rails-ai-context")
        expect(entry["command"]).to eq(RbConfig.ruby)
        expect(entry["args"].first).to eq(Gem.bin_path("bundler", "bundle"))
        expect(entry["args"].drop(1)).to eq([ "exec", "rails-ai-context", "serve", "--app-path", File.realpath(dir) ])
        expect(entry["env"]["BUNDLE_GEMFILE"]).to eq(File.join(File.realpath(dir), "Gemfile"))
      end
    end

    it "prints the standalone entry for an app with no Gemfile" do
      Dir.mktmpdir do |dir|
        rails_app(dir)
        File.delete(File.join(dir, "Gemfile"), File.join(dir, "Gemfile.lock"))

        out, err, status = run_cli(dir, "mcp-entry")

        expect(status.exitstatus).to eq(0), err
        entry = JSON.parse(out).fetch("mcpServers").fetch("rails-ai-context")
        expect(entry["args"]).not_to include("exec")
        expect(entry["env"]).not_to have_key("BUNDLE_GEMFILE")
      end
    end

    it "refuses mcp-entry outside a Rails app" do
      Dir.mktmpdir do |dir|
        _out, err, status = run_cli(dir, "mcp-entry")

        expect(status.exitstatus).to eq(1)
        expect(err).to include("No Rails app found")
      end
    end

    it "refuses uninstall outside a Rails app" do
      Dir.mktmpdir do |dir|
        _out, err, status = run_cli(dir, "uninstall")

        expect(status.exitstatus).to eq(1)
        expect(err).to include("No Rails app found")
      end
    end
  end
end
