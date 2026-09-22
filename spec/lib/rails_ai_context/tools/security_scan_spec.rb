# frozen_string_literal: true

require "spec_helper"

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
        allow(described_class).to receive(:run_brakeman_unbundled).and_return(nil)
      end

      it "says where it is and how to run it" do
        text = described_class.call.content.first[:text]

        expect(text).to include("8.0.6")
        expect(text).to include("not in this app's bundle")
        expect(text).to include("--no-boot")
      end
    end

    # One machine, one scanner: the gem is installed, the app's bundle does
    # not carry it, and the scan runs it from outside the bundle rather than
    # refusing and pointing at another command.
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
        allow(described_class).to receive(:run_brakeman_unbundled).and_return(report)
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

      it "still filters by file" do
        text = described_class.call(files: [ "config/routes.rb" ]).content.first[:text]

        expect(text).to include("Unmaintained Dependency")
        expect(text).not_to include("Mass Assignment")
      end

      it "falls back to the two-ways-out message when the outside run fails" do
        allow(described_class).to receive(:run_brakeman_unbundled).and_return(nil)

        text = described_class.call.content.first[:text]

        expect(text).to include("not in this app's bundle")
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
        checks = Class.new { def checks_run = [ "Brakeman::Checks::CheckSQL", "Brakeman::Checks::CheckMassAssignment" ] }.new
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
        result = described_class.call(detail: "full")
        text = result.content.first[:text]
        expect(text).to include("Full")
        expect(text).to include("CWE:** 89")
        expect(text).to include("brakemanscanner.org")
        expect(text).to include("```ruby")
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
    end
  end
end
