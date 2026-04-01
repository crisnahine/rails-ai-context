# frozen_string_literal: true

require "spec_helper"

RSpec.describe RailsAiContext::Tools::Diagnose do
  before { described_class.reset_cache! }

  describe ".call" do
    it "returns an MCP::Tool::Response" do
      result = described_class.call(error: "NoMethodError: undefined method `foo` for nil:NilClass")
      expect(result).to be_a(MCP::Tool::Response)
    end

    it "requires error parameter" do
      result = described_class.call(error: "")
      text = result.content.first[:text]
      expect(text).to include("required")
    end

    it "parses NoMethodError correctly" do
      result = described_class.call(error: "NoMethodError: undefined method `activate` for nil:NilClass")
      text = result.content.first[:text]
      expect(text).to include("NoMethodError")
      expect(text).to include("nil_reference")
      expect(text).to include("Likely Cause")
      expect(text).to include("Suggested Fix")
    end

    it "parses ActiveRecord::RecordNotFound" do
      result = described_class.call(error: "ActiveRecord::RecordNotFound: Couldn't find User with 'id'=999")
      text = result.content.first[:text]
      expect(text).to include("record_not_found")
    end

    it "parses ActiveRecord::RecordInvalid" do
      result = described_class.call(error: "ActiveRecord::RecordInvalid: Validation failed: Name can't be blank")
      text = result.content.first[:text]
      expect(text).to include("validation_failure")
    end

    it "parses ActionController::RoutingError" do
      result = described_class.call(error: "ActionController::RoutingError: No route matches [GET] /nonexistent")
      text = result.content.first[:text]
      expect(text).to include("routing")
    end

    it "parses ParameterMissing" do
      result = described_class.call(error: "ActionController::ParameterMissing: param is missing or the value is empty: cook")
      text = result.content.first[:text]
      expect(text).to include("strong_params")
    end

    it "handles unknown error types gracefully" do
      result = described_class.call(error: "SomeWeirdError happened in production")
      text = result.content.first[:text]
      expect(text).to include("Error Diagnosis")
      expect(text).not_to include("Diagnosis error")
    end

    it "extracts method name from undefined method error" do
      result = described_class.call(error: "NoMethodError: undefined method `process_payment` for nil:NilClass")
      text = result.content.first[:text]
      expect(text).to include("process_payment")
    end

    it "includes Next Steps section" do
      result = described_class.call(
        error: "NoMethodError: undefined method `foo`",
        file: "app/models/cook.rb"
      )
      text = result.content.first[:text]
      expect(text).to include("Next Steps")
    end
  end
end
