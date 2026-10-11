# frozen_string_literal: true

require "spec_helper"

# The check every call makes before it answers, so it has to see every edit
# Fingerprinter.compute would, at a fraction of the cost.
RSpec.describe RailsAiContext::Fingerprinter::Snapshot do
  let(:root) { Dir.mktmpdir }
  let(:snapshot) { described_class.new(root) }

  def write(path, content)
    full = File.join(root, path)
    FileUtils.mkdir_p(File.dirname(full))
    File.write(full, content)
    full
  end

  # Settled files: their stat says all there is to say.
  def age(path, seconds = 60)
    full = File.join(root, path)
    File.utime(Time.now - seconds, Time.now - seconds, full)
  end

  before do
    write("app/models/post.rb", "class Post\nend\n")
    write("app/models/comment.rb", "class Comment\nend\n")
    write("config/routes.rb", "Rails.application.routes.draw {}\n")
    write("Gemfile", "source 'https://rubygems.org'\n")
    %w[app/models/post.rb app/models/comment.rb config/routes.rb Gemfile].each { |path| age(path) }
    [ "app/models", "app", "config" ].each { |dir| age(dir) }
  end

  after { FileUtils.remove_entry(root) }

  it "only records at its first look" do
    expect(snapshot.changed?).to be(false)
    expect(snapshot.changed?).to be(false)
  end

  context "after a look" do
    before { snapshot.changed? }

    it "sees a file edited in place" do
      write("app/models/post.rb", "class Post\n  has_many :comments\nend\n")

      expect(snapshot.changed?).to be(true)
      expect(snapshot.changed?).to be(false)
    end

    it "sees a file added, and one removed" do
      write("app/models/tag.rb", "class Tag\nend\n")
      expect(snapshot.changed?).to be(true)

      File.delete(File.join(root, "app/models/comment.rb"))
      expect(snapshot.changed?).to be(true)
    end

    it "sees a file moved into a directory of its own" do
      write("app/models/admin/post.rb", File.read(File.join(root, "app/models/post.rb")))
      File.delete(File.join(root, "app/models/post.rb"))

      expect(snapshot.changed?).to be(true)
    end

    it "sees a directory of files removed whole" do
      write("app/services/billing/charge.rb", "class Billing::Charge\nend\n")
      snapshot.changed?

      FileUtils.rm_rf(File.join(root, "app/services/billing"))

      expect(snapshot.changed?).to be(true)
    end

    it "sees a root manifest change" do
      write("Gemfile", "source 'https://rubygems.org'\ngem 'rails'\n")

      expect(snapshot.changed?).to be(true)
    end

    # A second write in the clock tick of the first keeps the mtime, and a
    # same-length edit keeps the size.
    it "sees a rewrite that leaves the stat as it was, while the file is young" do
      path = write("app/models/post.rb", "class Post\n  has_many :aaaa\nend\n")
      snapshot.changed?
      stamp = File.mtime(path)
      File.write(path, "class Post\n  has_many :bbbb\nend\n")
      File.utime(stamp, stamp, path)

      expect(snapshot.changed?).to be(true)
    end

    it "lets a young file settle, reading it no longer" do
      path = write("app/models/post.rb", "class Post\n  has_many :tags\nend\n")
      snapshot.changed?
      age("app/models/post.rb")
      snapshot.changed?

      expect(Digest::SHA256).not_to receive(:file)
      expect(snapshot.changed?).to be(false)
      expect(File.read(path)).to include("has_many :tags")
    end

    it "lists a directory again only once its stat moves" do
      expect(snapshot).not_to receive(:list)
      expect(snapshot.changed?).to be(false)
    end

    it "takes what compute takes, and no more" do
      write("app/models/.post.rb.swp", "x")
      write("app/assets/builds/application.js", "x")
      write("app/models/notes.txt", "x")
      write("log/development.log", "x")

      expect(snapshot.changed?).to be(false)
    end

    it "counts a cassette by its presence alone" do
      cassette = write("spec/vcr_cassettes/stripe.yml", "a: 1\n")
      snapshot.changed?

      File.write(cassette, "a: 2\n")
      expect(snapshot.changed?).to be(false)

      File.delete(cassette)
      expect(snapshot.changed?).to be(true)
    end

    it "does not descend into a symlinked directory, as `**/*` does not" do
      outside = Dir.mktmpdir
      File.write(File.join(outside, "elsewhere.rb"), "class Elsewhere\nend\n")
      File.symlink(outside, File.join(root, "app/models/linked"))
      snapshot.changed?

      File.write(File.join(outside, "elsewhere.rb"), "class Elsewhere\n  X = 1\nend\n")
      expect(snapshot.changed?).to be(false)
    ensure
      FileUtils.remove_entry(outside)
    end
  end

  # Whatever a look reports, compute agrees whether anything moved.
  it "agrees with compute about the same edits" do
    app = RailsAiContext::StaticApp.new(root)
    snapshot.changed?
    before = RailsAiContext::Fingerprinter.compute(app)

    write("app/models/post.rb", "class Post\n  belongs_to :author\nend\n")
    write("app/helpers/posts_helper.rb", "module PostsHelper\nend\n")

    expect(snapshot.changed?).to be(true)
    expect(RailsAiContext::Fingerprinter.compute(app)).not_to eq(before)
  end
end
