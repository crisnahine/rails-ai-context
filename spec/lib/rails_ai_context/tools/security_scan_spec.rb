# frozen_string_literal: true

require "spec_helper"
require "tmpdir"
require "fileutils"

RSpec.describe RailsAiContext::Tools::SecurityScan do
  before do
    described_class.reset_cache!
    # Reset memoized brakeman availability between tests
    described_class.instance_variable_set(:@brakeman_available, nil)
  end

  describe ".call" do
    context "when Brakeman is not installed" do
      before do
        allow(described_class).to receive(:load_brakeman).and_return(false)
        allow(described_class).to receive(:brakeman_on_machine).and_return(nil)
      end

      it "returns installation instructions" do
        result = described_class.call
        text = result.content.first[:text]
        expect(text).to include("Brakeman is not installed")
        expect(text).to include("gem 'brakeman'")
      end
    end

    # Booted, the app's bundle is set up and narrows the load path, so a
    # require that succeeds on the static tier raises LoadError here. Both
    # answers used to be "Brakeman is not installed", and editing the Gemfile
    # is not what a reader whose machine already has it needs to do.
    context "when brakeman is on the machine but cannot be run at all" do
      before do
        described_class.instance_variable_set(:@brakeman_available, nil)
        allow(described_class).to receive(:load_brakeman).and_return(false)
        allow(described_class).to receive(:brakeman_on_machine).and_return("8.0.6")
        allow(described_class).to receive(:run_brakeman_unbundled).and_return([ nil, nil ])
      end

      it "names the version it found and says the outside run failed too" do
        text = described_class.call.content.first[:text]

        expect(text).to include("8.0.6")
        expect(text).to include("not in this app's bundle")
        expect(text).to include("outside the bundle produced no report")
        expect(text).to include("gem 'brakeman'")
      end
    end

    # One machine, one scanner: the gem is installed, the app's bundle does
    # not carry it, and the scan runs it from outside the bundle rather than
    # refusing and pointing at another command.
    context "when the app's lockfile carries brakeman and no run answers" do
      it "says to install the locked gem rather than add it" do
        allow(described_class).to receive(:load_brakeman).and_return(false)
        allow(described_class).to receive(:brakeman_on_machine).and_return(nil)
        allow(RailsAiContext::GemLock).to receive(:for).and_return(RailsAiContext::GemLock::Spec.new({ "brakeman" => "8.0.6" }))

        text = described_class.call.content.first[:text]

        expect(text).to include("Gemfile.lock carries brakeman 8.0.6").and include("bundle install")
        expect(text).not_to include("gem 'brakeman'")
      end
    end

    context "when brakeman can only be reached outside the app's bundle" do
      let(:report) do
        {
          "scan_info" => { "checks_performed" => %w[BasicAuth CrossSiteScripting SQL] },
          "warnings" => [
            {
              "warning_type" => "Mass Assignment", "message" => "Potentially dangerous key allowed for mass assignment",
              "file" => "app/controllers/admin/users_controller.rb", "line" => 9, "confidence" => "Medium",
              "link" => "https://brakemanscanner.org/docs/warning_types/mass_assignment/",
              "code" => "params.require(:user).permit(:role)", "cwe_id" => [ 915 ]
            },
            {
              "warning_type" => "Unmaintained Dependency", "message" => "Support for Rails 8.0.5.1 ends on 2026-11-07",
              "file" => "config/routes.rb", "line" => 323, "confidence" => "Weak", "code" => nil, "cwe_id" => [ 1104 ]
            }
          ]
        }
      end

      before do
        allow(described_class).to receive(:load_brakeman).and_return(false)
        allow(described_class).to receive(:brakeman_on_machine).and_return("8.0.6")
        allow(described_class).to receive(:run_brakeman_unbundled).and_return([ report, nil ])
      end

      it "reports the warnings the outside scan found" do
        text = described_class.call.content.first[:text]

        expect(text).to include("**2 warnings** (3 checks run)")
        expect(text).to include("## Mass Assignment")
        expect(text).to include("[Medium] app/controllers/admin/users_controller.rb:9")
      end

      it "sorts them the way the in-process scan does" do
        text = described_class.call.content.first[:text]

        expect(text.index("Mass Assignment")).to be < text.index("Unmaintained Dependency")
      end

      it "says which brakeman answered and where it ran from" do
        text = described_class.call.content.first[:text]

        expect(text).to include("brakeman 8.0.6")
        expect(text).to include("outside the app's bundle")
      end

      # Mastodon locks brakeman 8.0.6; the static run scans from outside only
      # because this process never loads the app's bundle.
      it "does not say the app's bundle lacks a brakeman its lockfile carries" do
        allow(RailsAiContext::GemLock).to receive(:for).and_return(RailsAiContext::GemLock::Spec.new({ "brakeman" => "8.0.6" }))

        text = described_class.call.content.first[:text]

        expect(text).to include("Gemfile.lock carries brakeman 8.0.6")
        expect(text).not_to include("does not carry it")
        expect(text).not_to include("Add it to the Gemfile")
      end

      # With several installed, the newest on disk is not always the one the
      # binstub ran, and the report says which one did.
      it "names the version the report says ran" do
        allow(described_class).to receive(:run_brakeman_unbundled)
          .and_return([ report.merge("scan_info" => report["scan_info"].merge("brakeman_version" => "7.1.0")), nil ])

        text = described_class.call.content.first[:text]

        expect(text).to include("brakeman 7.1.0")
        expect(text).not_to include("8.0.6")
      end

      it "still filters by file" do
        text = described_class.call(files: [ "config/routes.rb" ]).content.first[:text]

        expect(text).to include("Unmaintained Dependency")
        expect(text).not_to include("Mass Assignment")
      end

      it "skips an entry the report holds that is not a warning object" do
        allow(described_class).to receive(:run_brakeman_unbundled)
          .and_return([ report.merge("warnings" => report["warnings"] + [ nil, "oops" ]), nil ])

        text = described_class.call.content.first[:text]

        expect(text).to include("**2 warnings**")
      end

      it "falls back to the two-ways-out message when the outside run fails" do
        allow(described_class).to receive(:run_brakeman_unbundled).and_return([ nil, nil ])

        text = described_class.call.content.first[:text]

        expect(text).to include("not in this app's bundle")
      end

      it "quotes what the outside run said without an absolute path from this machine" do
        root = Rails.root.to_s
        allow(described_class).to receive(:run_brakeman_unbundled)
          .and_return([ nil, "Permission denied @ rb_sysopen - #{root}/app/models/locked.rb" ])

        text = described_class.call.content.first[:text]

        expect(text).to include("It said: `Permission denied @ rb_sysopen - app/models/locked.rb`")
        expect(text).not_to include(root)
      end
    end

    # The two scanners render through one formatter, so a Tracker and the
    # JSON report have to produce the same page.
    context "when the app's bundle carries brakeman" do
      before do
        warning = Struct.new(:warning_type, :confidence, :confidence_name, :file, :line,
                             :message, :cwe_id, :code, :link, keyword_init: true)
        file = Struct.new(:relative, keyword_init: true)
        found = warning.new(warning_type: "Mass Assignment", confidence: 1, confidence_name: "Medium",
                            file: file.new(relative: "app/controllers/admin/users_controller.rb"), line: 9,
                            message: "Potentially dangerous key allowed for mass assignment",
                            cwe_id: [ 915 ], code: nil, link: nil)
        # The short names brakeman's own tracker reports (6.x through 8.x).
        checks = Class.new { def checks_run = %w[SQL MassAssignment] }.new
        tracker = Struct.new(:filtered_warnings, :checks, keyword_init: true)
                        .new(filtered_warnings: [ found ], checks: checks)

        allow(described_class).to receive(:load_brakeman).and_return(true)
        stub_const("Brakeman", Class.new { def self.run(_options); end })
        allow(Brakeman).to receive(:run).and_return(tracker)
      end

      it "renders the in-process result the same way as the outside one" do
        text = described_class.call.content.first[:text]

        expect(text).to include("**1 warning** (2 checks run)")
        expect(text).to include("## Mass Assignment")
        expect(text).to include("[Medium] app/controllers/admin/users_controller.rb:9")
      end

      it "says nothing about running outside the bundle" do
        text = described_class.call.content.first[:text]

        expect(text).not_to include("outside the app's bundle")
      end
    end

    # The binstub a gem manager installs can print to stdout before brakeman
    # does (RVM's executable-hooks writes "Resolving dependencies..."), so a
    # report parsed off stdout died on its first byte and the scan answered
    # "not installed" on a machine that has it. This runs a real child.
    describe "the report the outside run writes" do
      let(:bin_dir) { Dir.mktmpdir }

      after { FileUtils.remove_entry(bin_dir) }

      # Run by this Ruby, as the gem's own script is.
      def fake_brakeman(body)
        script = File.join(bin_dir, "brakeman")
        File.write(script, body)
        allow(described_class).to receive(:brakeman_command).and_return([ RbConfig.ruby, script ])
      end

      it "reads the report even when the executable prints before it" do
        fake_brakeman(<<~RUBY)
          puts "Resolving dependencies..."
          File.write(ARGV[ARGV.index("--output") + 1], '{"scan_info":{"checks_performed":["SQL"]},"warnings":[]}')
        RUBY

        report, failure = described_class.send(:run_brakeman_unbundled, 2, nil)

        expect(failure).to be_nil

        expect(report).to include("warnings" => [])
        expect(report.dig("scan_info", "checks_performed")).to eq([ "SQL" ])
      end

      # Ruby prints an uncaught error, then its backtrace; the last line is a
      # frame, which says where brakeman stopped, not why.
      it "reports brakeman's message rather than the last backtrace frame" do
        fake_brakeman(<<~RUBY)
          warn "/gems/brakeman-8.0.6/lib/brakeman.rb:412:in 'scan': Please supply the path to a Rails application (Brakeman::NoApplication)"
          warn "\tfrom /gems/brakeman-8.0.6/lib/brakeman.rb:77:in 'run'"
          warn "\tfrom /gems/brakeman-8.0.6/bin/brakeman:9:in '<main>'"
          exit 1
        RUBY

        _report, failure = described_class.send(:run_brakeman_unbundled, 2, nil)

        expect(failure).to eq("Please supply the path to a Rails application (Brakeman::NoApplication)")
      end

      it "reports the line brakeman printed when it is not an exception" do
        fake_brakeman(<<~RUBY)
          warn "Loading scanner..."
          warn "No Rails application found in /tmp/app"
          exit 1
        RUBY

        _report, failure = described_class.send(:run_brakeman_unbundled, 2, nil)

        expect(failure).to eq("No Rails application found in /tmp/app")
      end
    end

    # The API counts confidence up from high and the CLI's -w counts down
    # from weak, and the CLI rejects a level it does not know: an uninverted
    # level answered "installed but produced no report" for confidence:"high".
    describe "the command the outside run is given" do
      let(:bin_dir) { Dir.mktmpdir }

      after { FileUtils.remove_entry(bin_dir) }

      # Run by this Ruby, as the gem's own script is.
      def fake_brakeman(body)
        script = File.join(bin_dir, "brakeman")
        File.write(script, body)
        described_class.instance_variable_set(:@brakeman_available, nil)
        allow(described_class).to receive(:load_brakeman).and_return(false)
        allow(described_class).to receive(:brakeman_on_machine).and_return("8.0.6")
        allow(described_class).to receive(:brakeman_command).and_return([ RbConfig.ruby, script ])
      end

      it "passes the CLI's confidence level and the resolved checks" do
        args_file = File.join(bin_dir, "args")
        fake_brakeman(<<~RUBY)
          File.write(#{args_file.inspect}, ARGV.join("\n"))
          File.write(ARGV[ARGV.index("--output") + 1], '{"scan_info":{"checks_performed":["SQL"]},"warnings":[]}')
        RUBY

        described_class.call(confidence: "high", checks: [ "sql" ])
        args = File.read(args_file).split("\n")

        expect(args.each_cons(2).to_a).to include([ "--confidence-level", "3" ], [ "--test", "CheckSQL" ])
        expect(args).to include("--no-exit-on-warn", "--no-exit-on-error")
      end

      # Every way the outside run can fail used to read the same, so the one
      # line brakeman printed about why is the line the answer carries.
      it "carries what brakeman said when it wrote no report" do
        fake_brakeman(%(warn "noise"\nwarn "invalid argument: --confidence-level 0"\nexit 1\n))

        text = described_class.call.content.first[:text]

        expect(text).to include("installed on this machine but not in this app's bundle")
        expect(text).to include("invalid argument: --confidence-level 0")
        expect(text).not_to include("noise")
      end
    end

    # RubyGems writes a gem's binstub to its bindir, outside every gem
    # directory, so the run looked for <gem dir>/bin/brakeman, found nothing
    # on a normal install, and answered "produced no report" while doctor
    # said it scanned. The gem's own script is run instead, by this Ruby.
    describe "the brakeman installed outside the bundle" do
      let(:gem_dir) { Dir.mktmpdir }

      after { FileUtils.remove_entry(gem_dir) }

      # An installed brakeman as RubyGems lays one out: its spec, and its
      # files under gems/, the script in bin/. No binstub anywhere.
      def install_brakeman(version, script)
        FileUtils.mkdir_p(File.join(gem_dir, "specifications"))
        File.write(File.join(gem_dir, "specifications", "brakeman-#{version}.gemspec"), <<~RUBY)
          Gem::Specification.new do |s|
            s.name = "brakeman"
            s.version = "#{version}"
            s.bindir = "bin"
            s.executables = [ "brakeman" ]
          end
        RUBY
        bin = File.join(gem_dir, "gems", "brakeman-#{version}", "bin")
        FileUtils.mkdir_p(bin)
        File.write(File.join(bin, "brakeman"), script)
        allow(Gem).to receive(:path).and_return([ gem_dir ])
        File.join(bin, "brakeman")
      end

      it "runs the newest installed gem's own script with this Ruby" do
        install_brakeman("8.0.6", "")
        script = install_brakeman("8.1.0", "")

        expect(described_class.send(:brakeman_command)).to eq([ RbConfig.ruby, script ])
      end

      it "reads the report the script writes" do
        install_brakeman("8.1.0", <<~RUBY)
          out = ARGV[ARGV.index("--output") + 1]
          File.write(out, '{"scan_info":{"checks_performed":["SQL"],"brakeman_version":"8.1.0"},"warnings":[]}')
        RUBY

        report, failure = described_class.send(:run_brakeman_unbundled, 2, nil)

        expect(failure).to be_nil
        expect(report.dig("scan_info", "checks_performed")).to eq([ "SQL" ])
      end

      it "answers to doctor whether the script runs, as the scan runs it" do
        install_brakeman("8.1.0", %(puts "brakeman 8.1.0"\n))
        expect(described_class.unbundled_failure).to be_nil

        install_brakeman("8.1.0", %(raise LoadError, "cannot load such file -- ruby_parser"\n))
        expect(described_class.unbundled_failure).to eq("cannot load such file -- ruby_parser (LoadError)")
      end
    end

    # A scan that hangs must not hold the tool open: the wait is bounded, and
    # a child that ignores the polite signal gets the other one.
    describe "a scan that does not end" do
      it "returns rather than waiting on a child that ignores SIGTERM" do
        stub_const("#{described_class}::SCAN_TIMEOUT", 1)
        stub_const("#{described_class}::KILL_GRACE", 1)

        started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        output = described_class.send(:capture_with_timeout, [ RbConfig.ruby, "-e", "trap('TERM') {}; sleep 30" ])
        elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started

        expect(output).to be_nil
        expect(elapsed).to be < 10
      end

      # Windows sends no TERM to another process: Process.kill raises EINVAL.
      it "stops the child with KILL alone on Windows" do
        allow(Gem).to receive(:win_platform?).and_return(true)
        allow(Process).to receive(:kill)

        described_class.send(:stop, instance_double(Process::Waiter, pid: 4242))

        expect(Process).to have_received(:kill).with("KILL", 4242)
        expect(Process).not_to have_received(:kill).with("TERM", anything)
      end
    end

    # Brakeman's code line is the expression after it wrote each value it
    # could follow in place of the name: the literal assigned to `api_token`
    # sat in the call with no name beside it for the filter to know it by.
    # The full answer shows the file's own statement, filtered as every slice
    # of the app's source is.
    describe "the code a full answer shows" do
      around do |example|
        Dir.mktmpdir("scan-code") do |root|
          FileUtils.mkdir_p(File.join(root, "app/controllers"))
          FileUtils.mkdir_p(File.join(root, "app/views/posts"))
          File.write(File.join(root, "app/controllers/hooks_controller.rb"), <<~'RUBY')
            class HooksController < ApplicationController
              def ping
                api_token = "tok-FAKE-NOT-REAL-0040"
                system("curl -s -H 'X-Token: #{api_token}' #{params[:url]}")
                head :ok
              end

              def user_params
                params.require(:user).permit(
                  :name,
                  :role
                )
              end

              def search
                @rows = ActiveRecord::Base.connection.execute(
                  "SELECT * FROM posts WHERE title = '#{params[:t]}'"
                )
              end
            end
          RUBY
          File.write(File.join(root, "app/views/posts/show.html.erb"), <<~'ERB')
            <h1>Post</h1>
            <%= raw params[:body] %>
          ERB
          @root = root
          example.run
        end
      end

      def warning(file:, line:, code:, type: "Command Injection")
        { "warning_type" => type, "message" => "Possible #{type.downcase}", "file" => file, "line" => line,
          "confidence" => "High", "code" => code, "cwe_id" => [ 77 ] }
      end

      def full_scan(*warnings)
        allow(described_class).to receive(:rails_app).and_return(RailsAiContext::StaticApp.new(@root))
        allow(described_class).to receive(:load_brakeman).and_return(false)
        allow(described_class).to receive(:brakeman_on_machine).and_return("8.1.0")
        allow(described_class).to receive(:run_brakeman_unbundled)
          .and_return([ { "scan_info" => { "checks_performed" => %w[Execute] }, "warnings" => warnings }, nil ])
        described_class.call(detail: "full").content.first[:text]
      end

      it "shows the line as the file has it, not the value brakeman wrote in place of a name" do
        text = full_scan(warning(file: "app/controllers/hooks_controller.rb", line: 4,
                                 code: %(system("curl -s -H 'X-Token: \#{"tok-FAKE-NOT-REAL-0040"}' \#{params[:url]}"))))

        expect(text).to include(%(  ```ruby\n  system("curl -s -H 'X-Token: \#{api_token}' \#{params[:url]}")\n  ```))
        expect(text).not_to include("tok-FAKE")
      end

      it "shows the whole statement when brakeman names a line inside it" do
        text = full_scan(warning(file: "app/controllers/hooks_controller.rb", line: 11, type: "Mass Assignment",
                                 code: "params.require(:user).permit(:name, :role)"))

        expect(text).to include("  ```ruby\n  params.require(:user).permit(\n    :name,\n    :role\n  )\n  ```")
      end

      # The `#{...}` on the named line holds a statement of its own, and it is
      # the string's, not the code's.
      it "reads past an interpolation to the statement around it" do
        text = full_scan(warning(file: "app/controllers/hooks_controller.rb", line: 17, type: "SQL Injection",
                                 code: %(ActiveRecord::Base.connection.execute("SELECT * FROM posts WHERE title = '\#{params[:t]}'"))))

        expect(text).to include("  ```ruby\n  @rows = ActiveRecord::Base.connection.execute(\n" \
                                "    \"SELECT * FROM posts WHERE title = '\#{params[:t]}'\"\n  )\n  ```")
      end

      it "fences a template's line as the template it is" do
        text = full_scan(warning(file: "app/views/posts/show.html.erb", line: 2, type: "Cross-Site Scripting", code: "params[:body]"))

        expect(text).to include("  ```erb\n  <%= raw params[:body] %>\n  ```")
      end

      it "shows no code it cannot read from the file, rather than brakeman's" do
        text = full_scan(warning(file: "app/controllers/gone_controller.rb", line: 3, code: %(system("\#{"tok-FAKE-NOT-REAL-0040"}"))))

        expect(text).to include("app/controllers/gone_controller.rb:3")
        expect(text).not_to include("**Code:**")
        expect(text).not_to include("tok-FAKE")
      end

      it "reads and filters a file once however many warnings it holds" do
        allow(RailsAiContext::Redaction).to receive(:redact_source_lines).and_call_original

        text = full_scan(warning(file: "app/controllers/hooks_controller.rb", line: 4, code: "system(params[:url])"),
                         warning(file: "app/controllers/hooks_controller.rb", line: 17, code: "execute(params[:t])"))

        expect(text.scan("**Code:**").size).to eq(2)
        expect(RailsAiContext::Redaction).to have_received(:redact_source_lines).once
      end
    end

    context "when brakeman is nowhere on the machine" do
      before do
        described_class.instance_variable_set(:@brakeman_available, nil)
        allow(described_class).to receive(:load_brakeman).and_return(false)
        allow(described_class).to receive(:brakeman_on_machine).and_return(nil)
      end

      it "gives the Gemfile instructions" do
        text = described_class.call.content.first[:text]

        expect(text).to include("Brakeman is not installed")
        expect(text).to include("gem 'brakeman'")
      end
    end

    # The memo was one process-wide boolean, so whichever tier answered first
    # decided for every later call in the process.
    it "does not reuse one tier's availability answer for the other" do
      described_class.instance_variable_set(:@brakeman_available, nil)
      allow(described_class).to receive(:load_brakeman).and_return(false, true)
      allow(described_class).to receive(:brakeman_on_machine).and_return(nil)
      allow(RailsAiContext).to receive(:static_tier?).and_return(false, true)

      expect(described_class.send(:brakeman_available?)).to be(false)
      expect(described_class.send(:brakeman_available?)).to be(true)
    end

    context "when Brakeman is available" do
      let(:mock_file) do
        instance_double("Brakeman::FilePath", relative: "app/controllers/users_controller.rb")
      end

      let(:mock_file_2) do
        instance_double("Brakeman::FilePath", relative: "app/models/user.rb")
      end

      let(:mock_warning_sql) do
        instance_double(
          "Brakeman::Warning",
          confidence: 0,
          confidence_name: "High",
          warning_type: "SQL Injection",
          file: mock_file,
          line: 15,
          message: "Possible SQL injection near line 15",
          code: double(to_s: 'User.where("name = #{params[:name]}")'),
          format_code: 'User.where("name = #{params[:name]}")',
          cwe_id: [ 89 ],
          link: "https://brakemanscanner.org/docs/warning_types/sql_injection/",
          check_name: "CheckSQL"
        )
      end

      let(:mock_warning_xss) do
        instance_double(
          "Brakeman::Warning",
          confidence: 1,
          confidence_name: "Medium",
          warning_type: "Cross-Site Scripting",
          file: mock_file_2,
          line: 42,
          message: "Unescaped model attribute near line 42",
          code: nil,
          format_code: nil,
          cwe_id: [ 79 ],
          link: "https://brakemanscanner.org/docs/warning_types/cross-site_scripting/",
          check_name: "CheckXSS"
        )
      end

      let(:mock_checks) do
        instance_double("Brakeman::Checks", checks_run: Array.new(25, "check"))
      end

      let(:mock_tracker) do
        instance_double(
          "Brakeman::Tracker",
          filtered_warnings: [ mock_warning_sql, mock_warning_xss ],
          checks: mock_checks
        )
      end

      # Define a stub module with .run so RSpec verifying doubles work
      # regardless of whether the real Brakeman gem is installed
      let(:brakeman_stub) do
        Module.new do
          def self.run(options = {}); end
        end
      end

      before do
        allow(described_class).to receive(:load_brakeman).and_return(true)
        stub_const("Brakeman", brakeman_stub)
        allow(Brakeman).to receive(:run).and_return(mock_tracker)
      end

      it "returns warnings in standard format" do
        result = described_class.call
        text = result.content.first[:text]
        expect(text).to include("2 warnings")
        expect(text).to include("SQL Injection")
        expect(text).to include("Cross-Site Scripting")
        expect(text).to include("users_controller.rb:15")
        expect(text).to include("user.rb:42")
      end

      it "returns summary format" do
        result = described_class.call(detail: "summary")
        text = result.content.first[:text]
        expect(text).to include("Summary")
        expect(text).to include("High: 1")
        expect(text).to include("Medium: 1")
        expect(text).to include("SQL Injection: 1")
      end

      it "returns full format with code and links" do
        Dir.mktmpdir do |root|
          FileUtils.mkdir_p(File.join(root, "app/controllers"))
          File.write(File.join(root, "app/controllers/users_controller.rb"), "\n" * 14 + %(    User.where("name = \#{params[:name]}")\n))
          allow(described_class).to receive(:rails_app).and_return(RailsAiContext::StaticApp.new(root))

          result = described_class.call(detail: "full")
          text = result.content.first[:text]
          expect(text).to include("Full")
          expect(text).to include("CWE:** 89")
          expect(text).to include("brakemanscanner.org")
          expect(text).to include(%(```ruby\n  User.where("name = \#{params[:name]}")\n  ```))
        end
      end

      it "filters results by file" do
        result = described_class.call(files: [ "app/models/user.rb" ])
        text = result.content.first[:text]
        expect(text).to include("Cross-Site Scripting")
        expect(text).not_to include("SQL Injection")
      end

      it "filters by confidence level" do
        result = described_class.call(confidence: "high")
        # Brakeman.run is called with min_confidence: 0
        expect(Brakeman).to have_received(:run).with(hash_including(min_confidence: 0))
      end

      it "parses in this process rather than in forked workers" do
        described_class.call
        expect(Brakeman).to have_received(:run).with(hash_including(parallel_checks: false))
      end

      it "passes specific checks to Brakeman with alias resolution" do
        described_class.call(checks: [ "sql", "CheckXSS" ])
        expect(Brakeman).to have_received(:run).with(
          hash_including(run_checks: Set.new([ "CheckSQL", "CheckCrossSiteScripting" ]))
        )
      end

      it "passes through full Brakeman check names unchanged" do
        described_class.call(checks: [ "CheckSQL" ])
        expect(Brakeman).to have_received(:run).with(
          hash_including(run_checks: Set.new([ "CheckSQL" ]))
        )
      end

      it "returns clean message when no warnings" do
        allow(mock_tracker).to receive(:filtered_warnings).and_return([])
        result = described_class.call
        text = result.content.first[:text]
        expect(text).to include("No security warnings found")
        expect(text).to include("25 checks run")
      end

      it "returns scoped clean message when filtering by files" do
        allow(mock_tracker).to receive(:filtered_warnings).and_return([])
        result = described_class.call(files: [ "app/models/user.rb" ])
        text = result.content.first[:text]
        expect(text).to include("No security warnings found")
        expect(text).to include("app/models/user.rb")
      end

      it "handles Brakeman scan errors gracefully" do
        allow(Brakeman).to receive(:run).and_raise(RuntimeError, "parse error in config/routes.rb")
        result = described_class.call
        text = result.content.first[:text]
        expect(text).to include("Brakeman scan failed")
        expect(text).to include("parse error")
      end

      it "quotes a scan error without an absolute path from this machine" do
        root = Rails.root.to_s
        allow(Brakeman).to receive(:run).and_raise(Errno::EACCES, "rb_sysopen - #{root}/app/models/locked.rb")
        text = described_class.call.content.first[:text]

        expect(text).to include("Brakeman scan failed", "app/models/locked.rb")
        expect(text).not_to include(root)
      end

      it "answers with the error when brakeman fails to load a file it needs" do
        allow(Brakeman).to receive(:run).and_raise(LoadError, "cannot load such file -- ruby_parser/legacy")
        text = described_class.call.content.first[:text]

        expect(text).to eq("Brakeman scan failed: cannot load such file -- ruby_parser/legacy")
      end

      it "answers with the error when a file brakeman loads does not parse" do
        allow(Brakeman).to receive(:run).and_raise(SyntaxError, "brakeman/checks/check_x.rb:3: syntax error")
        text = described_class.call.content.first[:text]

        expect(text).to eq("Brakeman scan failed: brakeman/checks/check_x.rb:3: syntax error")
      end

      it "names a file outside the app by its base name in a scan error" do
        allow(Brakeman).to receive(:run).and_raise(RuntimeError, "cannot load such file -- /home/dev/.gems/ruby_parser/lib/ruby_parser.rb, see https://brakemanscanner.org/docs")
        text = described_class.call.content.first[:text]

        expect(text).to include("cannot load such file -- ruby_parser.rb, see https://brakemanscanner.org/docs")
      end

      it "names a file outside the app by its base name when a folder on its path has a space" do
        allow(Dir).to receive(:home).and_return("/home/John Doe")
        allow(Gem).to receive(:path).and_return([ "/Volumes/Macintosh HD/Users/dev/.gem" ])
        allow(Brakeman).to receive(:run).and_raise(RuntimeError,
          "No such file @ rb_sysopen - /home/John Doe/app/x.rb and /Volumes/Macintosh HD/Users/dev/.gem/y.rb")
        text = described_class.call.content.first[:text]

        expect(text).to eq("Brakeman scan failed: No such file @ rb_sysopen - x.rb and y.rb")
      end

      def scan_error(message)
        allow(Brakeman).to receive(:run).and_raise(RuntimeError, message)
        described_class.call.content.first[:text].delete_prefix("Brakeman scan failed: ")
      end

      it "names a file below home by its base name when a folder on its path has a space and the file exists" do
        Dir.mktmpdir do |home|
          FileUtils.mkdir_p(File.join(home, "My Projects/gems"))
          FileUtils.touch(File.join(home, "My Projects/gems/x.rb"))
          allow(Dir).to receive(:home).and_return(home)

          expect(scan_error("Error in #{home}/My Projects/gems/x.rb:3 and /tmp/plain/z.rb")).to eq("Error in x.rb:3 and z.rb")
          expect(scan_error("Error in #{home}/My Projects/gone.rb now")).to eq("Error in My Projects/gone.rb now")

          FileUtils.mkdir_p(File.join(home, "v1.2 build/lib"))
          FileUtils.touch(File.join(home, "v1.2 build/lib/y.rb"))
          expect(scan_error("Error in #{home}/v1.2 build/lib/y.rb:4 then #{home}/My Projects/gems/x.rb")).to eq("Error in y.rb:4 then x.rb")
        end
      end

      it "names a file under a versioned folder by its base name" do
        allow(Dir).to receive(:home).and_return("/home/dev")

        expect(scan_error("cannot load /usr/lib/ruby/3.3.0/set.rb")).to eq("cannot load set.rb")
        expect(scan_error("Error in /opt/bundle/ruby/3.3.0/gems/brakeman-7.0.2/lib/brakeman/scanner.rb:12")).to eq("Error in scanner.rb:12")
        expect(scan_error("No such file - #{Gem.dir}/gems/parser-3.3.0.5/lib/p.rb")).to eq("No such file - p.rb")
        expect(scan_error("Error in /home/dev/.gem/ruby/3.3.0/gems/x-1.0/lib/x.rb")).to eq("Error in x.rb")
      end

      it "keeps the prose after a path that ends in a folder or a file with no extension" do
        root = Rails.root.to_s

        {
          "cannot load such file -- /opt/gems/foo (required by lib/tasks/x.rake)" => "cannot load such file -- foo (required by lib/tasks/x.rake)",
          "Error: /tmp/foo failed while reading the config/app.rb" => "Error: foo failed while reading the config/app.rb",
          "Parse error in /usr/lib/ruby (version 3.4) near lib/foo.rb" => "Parse error in ruby (version 3.4) near lib/foo.rb",
          "Error in /usr/lib/ruby while loading #{root}/app/models/post.rb" => "Error in ruby while loading app/models/post.rb",
          "Brakeman failed under /usr/local/bin because the parser could not read #{root}/app/models/post.rb" =>
            "Brakeman failed under bin because the parser could not read app/models/post.rb",
          "Errno::ENOENT No such file - /usr/local/share/data and also config/routes.rb" => "Errno::ENOENT No such file - data and also config/routes.rb",
          "Error: /usr/bin/ruby exited; see #{root}/log/x.rb" => "Error: ruby exited; see log/x.rb"
        }.each { |message, expected| expect(scan_error(message)).to eq(expected), message }
      end

      it "keeps the prose between a file outside the app and a file in it" do
        root = Rails.root.to_s
        allow(Brakeman).to receive(:run).and_raise(RuntimeError,
          "Error loading /Users/dev/.gem/ruby_parser.rb while scanning #{root}/app/models/user.rb")
        text = described_class.call.content.first[:text]

        expect(text).to eq("Brakeman scan failed: Error loading ruby_parser.rb while scanning app/models/user.rb")
      end
    end
  end
end
