# frozen_string_literal: true

require "spec_helper"
require "tmpdir"

RSpec.describe RailsAiContext::PackageJson do
  around { |example| Dir.mktmpdir { |dir| @root = dir; example.run } }

  def write(contents)
    File.write(File.join(@root, "package.json"), contents)
  end

  it "merges dependencies and devDependencies and ignores every other block" do
    write(JSON.generate(
      "dependencies" => { "vite" => "^5.0.0" },
      "devDependencies" => { "typescript" => "^5.0.0" },
      "overrides" => { "esbuild" => "^0.25.0" },
      "peerDependencies" => { "react" => "^18.0.0" },
      "scripts" => { "build" => "esbuild app.js" }
    ))

    expect(described_class.deps(@root).keys).to contain_exactly("vite", "typescript")
    expect(described_class.present?(@root, "esbuild")).to be(false)
    expect(described_class.present?(@root, "vite")).to be(true)
  end

  it "counts a tool reached through its own scope" do
    write(JSON.generate("devDependencies" => { "@tailwindcss/vite" => "^4.0.0" }))

    expect(described_class.present?(@root, "tailwindcss")).to be(true)
    expect(described_class.present?(@root, "vite")).to be(false)
  end

  it "answers an empty hash for a missing or unparseable file" do
    expect(described_class.deps(@root)).to eq({})
    write("{ not json")
    expect(described_class.deps(@root)).to eq({})
  end
end
