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

  it "does not enter a directory linked from outside a repository" do
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

  context "in a repository that holds the app" do
    around do |example|
      Dir.mktmpdir do |repo|
        @repo = File.realpath(repo)
        @root = File.join(@repo, "apps/web")
        FileUtils.mkdir_p([ File.join(@repo, ".git"), @root ])
        example.run
      end
    end

    it "enters a directory linked in from the repository after the real tree, under the name the app gives it" do
      FileUtils.mkdir_p(File.join(@repo, "packages/js/controllers"))
      File.write(File.join(@repo, "packages/js/controllers/hello_controller.js"), "")
      touch("app/javascript/application.js")
      File.symlink("../../../../packages/js/controllers", File.join(@root, "app/javascript/controllers"))

      expect(described_class.each_file(File.join(@root, "app/javascript"), root: @root).map { |path| path.delete_prefix("#{@root}/") })
        .to eq(%w[app/javascript/application.js app/javascript/controllers/hello_controller.js])
    end

    it "walks a directory once whatever links spell it, and never a link back up over the walk" do
      touch("app/javascript/controllers/a_controller.js")
      File.symlink("controllers", File.join(@root, "app/javascript/alias"))
      File.symlink("..", File.join(@root, "app/javascript/controllers/up"))
      File.symlink(@repo, File.join(@root, "app/javascript/repo"))

      expect(walked).to eq(%w[app/javascript/controllers/a_controller.js])
    end

    it "skips a link to nowhere, and a file a linked-in directory links out of it" do
      FileUtils.mkdir_p(File.join(@repo, "packages/js"))
      File.write(File.join(@repo, "packages/js/kept.js"), "")
      File.write(File.join(@repo, "packages/elsewhere.js"), "")
      File.symlink("missing.js", File.join(@repo, "packages/js/ghost_controller.js"))
      File.symlink("../elsewhere.js", File.join(@repo, "packages/js/out.js"))
      touch("app/models/user.rb")
      File.symlink("missing.rb", File.join(@root, "app/models/ghost.rb"))
      File.symlink("../../../packages/js", File.join(@root, "app/js"))

      expect(walked).to eq(%w[app/js/kept.js app/models/user.rb])
    end
  end

  describe ".glob" do
    it "matches what Dir.glob matches in a tree with no links" do
      touch("app/views/posts/index.html.erb")
      touch("app/views/posts/show.json.jbuilder")
      touch("app/views/posts/_form.html.haml")
      touch("app/views/README")
      dir = File.join(@root, "app/views")

      %w[**/*.{erb,haml} **/_* posts/*.jbuilder * **/*].each do |pattern|
        expect(described_class.glob(dir, pattern, root: @root)).to eq(Dir.glob(File.join(dir, pattern)).select { |path| File.file?(path) }.sort)
      end
    end
  end
end
