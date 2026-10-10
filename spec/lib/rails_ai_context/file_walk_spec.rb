# frozen_string_literal: true

require "spec_helper"
require "tmpdir"

RSpec.describe RailsAiContext::FileWalk do
  around { |example| Dir.mktmpdir { |dir| @root = dir; example.run } }

  def touch(rel)
    path = File.join(@root, rel)
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, "")
  end

  def walked(**options)
    described_class.each_file(@root, **options).map { |path| path.delete_prefix("#{@root}/") }.sort
  end

  it "yields every file under the directory" do
    touch("a.rb")
    touch("app/models/user.rb")

    expect(walked).to eq(%w[a.rb app/models/user.rb])
  end

  it "never enters a skipped directory" do
    touch("app/x.rb")
    touch("node_modules/pkg/index.js")

    expect(walked(skip: %w[node_modules])).to eq(%w[app/x.rb])
  end

  it "skips dotfiles and dot directories" do
    touch(".env")
    touch(".git/config")
    touch("kept.rb")

    expect(walked).to eq(%w[kept.rb])
  end

  it "does not follow a symlinked directory" do
    Dir.mktmpdir do |outside|
      File.write(File.join(outside, "secret.rb"), "")
      File.symlink(outside, File.join(@root, "linked"))
      touch("kept.rb")

      expect(walked).to eq(%w[kept.rb])
    end
  end

  it "yields a linked file only when it stays inside the root" do
    Dir.mktmpdir do |outside|
      File.write(File.join(outside, "secret.js"), "")
      touch("app/javascript/shared.js")
      touch("app/javascript/controllers/own_controller.js")
      File.symlink(File.join(outside, "secret.js"), File.join(@root, "app/javascript/controllers/leak_controller.js"))
      File.symlink("../shared.js", File.join(@root, "app/javascript/controllers/shared_controller.js"))

      walked = described_class.each_file(File.join(@root, "app/javascript/controllers"), root: @root)
        .map { |path| File.basename(path) }.sort
      expect(walked).to eq(%w[own_controller.js shared_controller.js])
    end
  end

  it "answers an enumerator without a block, and nothing for a missing directory" do
    expect(described_class.each_file(File.join(@root, "missing")).to_a).to eq([])
  end
end
