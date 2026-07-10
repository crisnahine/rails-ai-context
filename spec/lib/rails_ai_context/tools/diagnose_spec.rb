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
      result = described_class.call(error: "ActionController::ParameterMissing: param is missing or the value is empty: post")
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
        file: "app/models/post.rb"
      )
      text = result.content.first[:text]
      expect(text).to include("Next Steps")
    end

    it "classifies NameError: uninitialized constant as name_error, not nil_reference" do
      result = described_class.call(error: "NameError: uninitialized constant MyService")
      text = result.content.first[:text]
      expect(text).to include("name_error")
      expect(text).not_to include("nil_reference")
      expect(text).to include("typo in class/module name")
      expect(text).not_to include("safe navigation")
    end

    it "classifies generic NameError as name_error" do
      result = described_class.call(error: "NameError: undefined local variable or method `foo'")
      text = result.content.first[:text]
      expect(text).to include("name_error")
      expect(text).not_to include("nil_reference")
    end

    it "still classifies NoMethodError as nil_reference" do
      result = described_class.call(error: "NoMethodError: undefined method `bar` for nil:NilClass")
      text = result.content.first[:text]
      expect(text).to include("nil_reference")
      expect(text).not_to include("name_error")
    end

    it "classifies an undefined method on a model against its real associations and columns" do
      result = described_class.call(error: "undefined method 'bogus_assoc' for an instance of Post")
      text = result.content.first[:text]
      expect(text).to include("undefined_method_on_model")
      expect(text).to include("No association/column named `bogus_assoc` on Post")
    end

    it "handles the pre-3.3 receiver-inspect NoMethodError phrasing" do
      result = described_class.call(error: "NoMethodError: undefined method `bogus_assoc' for #<Post id: 1>")
      text = result.content.first[:text]
      expect(text).to include("undefined_method_on_model")
    end

    it "falls back to nil_reference when the method is a real association" do
      result = described_class.call(error: "NoMethodError: undefined method `comments` for an instance of Post")
      text = result.content.first[:text]
      expect(text).to include("nil_reference")
      expect(text).not_to include("undefined_method_on_model")
    end

    it "falls back to nil_reference when the receiver is not a model" do
      result = described_class.call(error: "NoMethodError: undefined method `bogus` for an instance of SomeRandomClass")
      text = result.content.first[:text]
      expect(text).to include("nil_reference")
      expect(text).not_to include("undefined_method_on_model")
    end

    it "truncates oversized output to within MAX_TOTAL_OUTPUT" do
      # Stub gather_context to return a very large section
      allow(described_class).to receive(:gather_context).and_return(
        [ "## Controller Context", "x" * 50_000, "" ]
      )
      allow(described_class).to receive(:gather_git_context).and_return([])
      allow(described_class).to receive(:gather_log_context).and_return([])

      result = described_class.call(error: "NoMethodError: undefined method `foo` for nil:NilClass")
      text = result.content.first[:text]
      # The total output should not exceed MAX_TOTAL_OUTPUT + the truncation message
      expect(text.length).to be <= 20_200
      expect(text).to include("truncated")
    end

    it "truncates individual sections exceeding their max" do
      large_content = "y" * 5_000
      allow(described_class).to receive(:gather_context).and_return(
        [ "## Controller Context", large_content, "" ]
      )
      allow(described_class).to receive(:gather_git_context).and_return([])
      allow(described_class).to receive(:gather_log_context).and_return([])

      result = described_class.call(error: "NoMethodError: undefined method `foo` for nil:NilClass")
      text = result.content.first[:text]
      # The controller context section should be truncated to ~3000 chars
      expect(text).to include("section truncated")
      expect(text).not_to include(large_content)
    end
  end
end
