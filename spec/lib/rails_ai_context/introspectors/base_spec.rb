# frozen_string_literal: true

require "spec_helper"

RSpec.describe RailsAiContext::Introspectors::Base do
  let(:app) { double("app", root: Pathname.new("/srv/shop")) }

  it "keeps the app it was built with" do
    expect(described_class.new(app).app).to be(app)
  end

  it "gives a subclass the app root as a string" do
    subclass = Class.new(described_class) { def call = root }

    expect(subclass.new(app).call).to eq("/srv/shop")
  end

  # A subclass that forgets its declaration must not inherit a tier from here.
  it "declares no static tier for a subclass to inherit" do
    subclass = Class.new(described_class) { extend RailsAiContext::Introspectors::StaticTier }

    expect(subclass.static_tier).to be_nil
  end
end
