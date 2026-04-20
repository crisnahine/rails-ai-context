# frozen_string_literal: true

require "spec_helper"

RSpec.describe RailsAiContext::Introspectors::EnvIntrospector do
  let(:introspector) { described_class.new(Rails.application) }

  describe "#call" do
    subject(:result) { introspector.call }

    it "returns a Hash without error" do
      expect(result).to be_a(Hash)
      expect(result).not_to have_key(:error)
    end

    it "returns set as array" do
      expect(result[:set]).to be_an(Array)
    end

    it "returns unset as array" do
      expect(result[:unset]).to be_an(Array)
    end

    it "returns referenced_in_code as array" do
      expect(result[:referenced_in_code]).to be_an(Array)
    end

    context "when RAILS_ENV is explicitly set" do
      before do
        @original = ENV["RAILS_ENV"]
        ENV["RAILS_ENV"] = "test"
      end

      after { ENV["RAILS_ENV"] = @original }

      it "lists RAILS_ENV as set with value (safe category)" do
        entry = result[:set].find { |e| e[:name] == "RAILS_ENV" }
        expect(entry).not_to be_nil
        expect(entry[:value]).to eq("test")
        expect(entry[:category]).to eq("core")
      end
    end

    context "when a sensitive ENV var is set" do
      before do
        @original = ENV["SECRET_KEY_BASE"]
        ENV["SECRET_KEY_BASE"] = "this-should-never-appear-in-output"
      end

      after { ENV["SECRET_KEY_BASE"] = @original }

      it "lists it as set but redacted, never revealing the value" do
        entry = result[:set].find { |e| e[:name] == "SECRET_KEY_BASE" }
        expect(entry).not_to be_nil
        expect(entry[:redacted]).to eq(true)
        expect(entry).not_to have_key(:value)
        expect(result.inspect).not_to include("this-should-never-appear-in-output")
      end
    end

    context "when a custom ENV var is referenced in code" do
      let(:fixture_path) { File.join(Rails.root, "config/initializers/custom_env.rb") }

      before do
        FileUtils.mkdir_p(File.dirname(fixture_path))
        File.write(fixture_path, <<~RUBY)
          MY_CUSTOM_FLAG = ENV["MY_SPECIAL_APP_FLAG"]
        RUBY
      end

      after { FileUtils.rm_f(fixture_path) }

      it "reports the custom var via scan_env_references" do
        entry = result[:referenced_in_code].find { |e| e[:name] == "MY_SPECIAL_APP_FLAG" }
        expect(entry).not_to be_nil
        expect(entry[:files]).to include("config/initializers/custom_env.rb")
        expect(entry[:set]).to eq(false)
      end
    end
  end
end
