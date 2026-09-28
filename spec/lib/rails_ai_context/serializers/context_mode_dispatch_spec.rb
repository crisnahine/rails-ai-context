# frozen_string_literal: true

require "spec_helper"

RSpec.describe RailsAiContext::Serializers::ContextModeDispatch do
  let(:full) do
    Class.new do
      def initialize(context) = @context = context
      def call = "full for #{@context[:app]}"
    end
  end

  let(:serializer) do
    full_class = full
    Class.new do
      include RailsAiContext::Serializers::ContextModeDispatch

      attr_reader :context

      define_method(:full_serializer_class) { full_class }
      def initialize(context) = @context = context
      def render_compact = "compact"
    end
  end

  around do |example|
    original = RailsAiContext.configuration.context_mode
    example.run
  ensure
    RailsAiContext.configuration.context_mode = original
  end

  it "renders the compact file by default" do
    RailsAiContext.configuration.context_mode = :compact
    expect(serializer.new(app: "Blog").call).to eq("compact")
  end

  it "hands the context to the full serializer in full mode" do
    RailsAiContext.configuration.context_mode = :full
    expect(serializer.new(app: "Blog").call).to eq("full for Blog")
  end
end
