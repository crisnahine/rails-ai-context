# frozen_string_literal: true

require "spec_helper"
require "tmpdir"

RSpec.describe "RailsAiContext.generate_context" do
  let(:serializer) { RailsAiContext::Serializers::ContextFileSerializer }
  let(:app) { Rails.application }

  it "generates the recorded selection when no format is given, and all when nothing is recorded" do
    Dir.mktmpdir do |dir|
      allow(RailsAiContext.configuration).to receive(:output_dir_for).and_return(dir)

      allow(RailsAiContext.configuration).to receive(:ai_tools).and_return(%i[claude])
      expect(serializer).to receive(:new).with(anything, format: %i[claude]).and_call_original
      RailsAiContext.generate_context(app)

      allow(RailsAiContext.configuration).to receive(:ai_tools).and_return(nil)
      expect(serializer).to receive(:new).with(anything, format: :all).and_call_original
      RailsAiContext.generate_context(app)

      allow(RailsAiContext.configuration).to receive(:ai_tools).and_return([])
      expect(serializer).to receive(:new).with(anything, format: :all).and_call_original
      RailsAiContext.generate_context(app)
    end
  end

  it "lets an explicit format override the recorded selection" do
    Dir.mktmpdir do |dir|
      allow(RailsAiContext.configuration).to receive(:output_dir_for).and_return(dir)
      allow(RailsAiContext.configuration).to receive(:ai_tools).and_return(%i[claude])

      expect(serializer).to receive(:new).with(anything, format: :cursor).and_call_original
      RailsAiContext.generate_context(app, format: :cursor)
    end
  end
end
