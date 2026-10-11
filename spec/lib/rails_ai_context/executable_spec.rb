# frozen_string_literal: true

require "spec_helper"

RSpec.describe RailsAiContext::Executable do
  it "finds an executable on the given PATH, and no other file" do
    Dir.mktmpdir do |dir|
      name = Gem.win_platform? ? "tool.exe" : "tool"
      File.write(File.join(dir, name), "")
      File.chmod(0o755, File.join(dir, name))
      File.write(File.join(dir, "plain"), "")

      expect(described_class.on_path?("tool", path: dir)).to be(true)
      expect(described_class.on_path?("missing", path: dir)).to be(false)
      expect(described_class.on_path?("tool", path: "")).to be(false)
      expect(described_class.on_path?("plain", path: dir)).to be(false) unless Gem.win_platform?
    end
  end
end
