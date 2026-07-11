# frozen_string_literal: true

require "spec_helper"

RSpec.describe RailsAiContext::StaticApp do
  it "exposes root as a Pathname" do
    app = described_class.new("/tmp/some_app")
    expect(app.root).to be_a(Pathname)
    expect(app.root.to_s).to eq("/tmp/some_app")
  end

  it "accepts a Pathname root" do
    app = described_class.new(Pathname.new("/tmp/some_app"))
    expect(File.join(app.root, "app", "models")).to eq("/tmp/some_app/app/models")
  end
end
