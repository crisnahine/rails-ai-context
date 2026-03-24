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
        described_class.instance_variable_set(:@brakeman_available, false)
      end

      it "returns installation instructions" do
        result = described_class.call
        text = result.content.first[:text]
        expect(text).to include("Brakeman is not installed")
        expect(text).to include("gem 'brakeman'")
      end
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
        described_class.instance_variable_set(:@brakeman_available, true)
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

      it "passes specific checks to Brakeman" do
        described_class.call(checks: [ "CheckSQL", "CheckXSS" ])
        expect(Brakeman).to have_received(:run).with(
          hash_including(run_checks: Set.new([ "CheckSQL", "CheckXSS" ]))
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
