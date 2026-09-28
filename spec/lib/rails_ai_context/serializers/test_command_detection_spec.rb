# frozen_string_literal: true

require "spec_helper"

RSpec.describe RailsAiContext::Serializers::TestCommandDetection do
  let(:test_class) do
    Class.new do
      include RailsAiContext::Serializers::TestCommandDetection

      attr_reader :context

      def initialize(context)
        @context = context
      end

      # Expose private method for testing
      public :detect_test_command
    end
  end

  describe "#detect_test_command" do
    it "returns rspec command when framework is rspec" do
      helper = test_class.new({ tests: { framework: "rspec" } })
      expect(helper.detect_test_command).to eq("bundle exec rspec")
    end

    it "runs rspec when the app runs both suites" do
      helper = test_class.new({ tests: { framework: "rspec, minitest" } })
      expect(helper.detect_test_command).to eq("bundle exec rspec")
    end

    it "returns rails test when framework is minitest" do
      helper = test_class.new({ tests: { framework: "minitest" } })
      expect(helper.detect_test_command).to eq("rails test")
    end

    it "defaults to rails test when framework is unknown" do
      helper = test_class.new({ tests: { framework: "cucumber" } })
      expect(helper.detect_test_command).to eq("rails test")
    end

    it "defaults to rails test when tests key is missing" do
      helper = test_class.new({})
      expect(helper.detect_test_command).to eq("rails test")
    end

    it "defaults to rails test when tests is nil" do
      helper = test_class.new({ tests: nil })
      expect(helper.detect_test_command).to eq("rails test")
    end

    it "defaults to rails test when tests is not a hash" do
      helper = test_class.new({ tests: "rspec" })
      expect(helper.detect_test_command).to eq("rails test")
    end

    it "defaults to rails test when framework key is nil" do
      helper = test_class.new({ tests: { framework: nil } })
      expect(helper.detect_test_command).to eq("rails test")
    end
  end
end
