# frozen_string_literal: true

require "spec_helper"
require "tmpdir"
require "fileutils"

RSpec.describe RailsAiContext::ConfigYaml do
  around do |example|
    Dir.mktmpdir do |dir|
      @root = dir
      FileUtils.mkdir_p(File.join(dir, "config"))
      example.run
    end
  end

  it "reads string keys, an output tag as the marker when asked, else as empty" do
    File.write(File.join(@root, "config/deploy.yml"), "env:\n  :HOST: <%= ENV['X'] %>\n")

    expect(described_class.read(@root, "config/deploy.yml", label: "Kamal")).to eq("env" => { "HOST" => nil })
    marked = described_class.read(@root, "config/deploy.yml", label: "Kamal", marker: described_class::ERB_OUTPUT)
    expect(described_class.marked?(marked.dig("env", "HOST"))).to be true
  end

  it "logs a failure under the caller's label and answers nil" do
    File.write(File.join(@root, "config/settings.yml"), "a: [unclosed\n")
    expect(RailsAiContext).to receive(:debug_fail).with(kind_of(Exception), nil, label: "config gem settings config/settings.yml").and_call_original

    expect(described_class.read(@root, "config/settings.yml", label: "config gem settings")).to be_nil
  end
end
