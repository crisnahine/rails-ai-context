# frozen_string_literal: true

require "spec_helper"

RSpec.describe RailsAiContext::Serializers::Base do
  it "keeps the context it renders from, for a subclass too" do
    context = { app_name: "Shop" }
    subclass = Class.new(described_class) { def call = context[:app_name] }

    expect(described_class.new(context).context).to be(context)
    expect(subclass.new(context).call).to eq("Shop")
  end
end
