# frozen_string_literal: true

require "spec_helper"
require "timeout"

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

    # Outside a repository only the app's root bounds a link, as it does for the readers.
    it "does not descend into a directory linked in from outside the app, as the readers do not" do
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

  # A monorepo's app links in a package from elsewhere in its repository, and
  # every reader walks it (FileWalk): the look missed an edit there, so the
  # call after it was answered from before the edit until cache_ttl ran out.
  context "with a directory linked in from the app's repository" do
    around do |example|
      Dir.mktmpdir do |repo|
        @repo = repo
        FileUtils.mkdir_p([ File.join(repo, ".git"), File.join(repo, "shared/controllers") ])
        example.run
      end
    end

    let(:root) { File.join(@repo, "apps/web").tap { |dir| FileUtils.mkdir_p(dir) } }
    let(:linked) { File.join(@repo, "shared/controllers/fancy_controller.js") }

    before do
      write("app/javascript/controllers/hello_controller.js", %(import { Controller } from "@hotwired/stimulus"\n))
      File.write(linked, %(export default class extends Controller {\n  static targets = ["alpha"]\n}\n))
      File.symlink("../../../../../shared/controllers", File.join(root, "app/javascript/controllers/shared"))
      snapshot.changed?
    end

    it "sees an edit inside it at the next look" do
      File.write(linked, %(export default class extends Controller {\n  static targets = ["alpha", "beta"]\n}\n))

      expect(snapshot.changed?).to be(true)
      expect(snapshot.changed?).to be(false)
    end

    it "sees a file added there, and the link removed" do
      File.write(File.join(@repo, "shared/controllers/other_controller.js"), "x\n")
      expect(snapshot.changed?).to be(true)

      File.delete(File.join(root, "app/javascript/controllers/shared"))
      expect(snapshot.changed?).to be(true)
    end

    # A link that names a directory not there yet sits in a listing that
    # nothing restamps when the directory appears.
    it "enters a link once the directory it names appears" do
      File.symlink("../../../../shared/later", File.join(root, "app/models/later"))
      age("app/models")
      snapshot.changed?

      FileUtils.mkdir_p(File.join(@repo, "shared/later"))
      File.write(File.join(@repo, "shared/later/report.rb"), "class Report\nend\n")
      expect(snapshot.changed?).to be(true)
    end

    it "walks each directory once whatever spells it, a link back over the walk or round in a circle included" do
      FileUtils.mkdir_p([ File.join(@repo, "shared/a"), File.join(@repo, "shared/b"), File.join(root, "app/helpers") ])
      File.write(File.join(@repo, "shared/b/billing.rb"), "class Billing\nend\n")
      File.symlink("../b", File.join(@repo, "shared/a/to_b"))
      File.symlink("../a", File.join(@repo, "shared/b/to_a"))
      File.symlink("../../../../shared/a", File.join(root, "app/models/a"))
      File.symlink("../../../../shared/a", File.join(root, "app/helpers/also_a"))
      File.symlink("..", File.join(root, "app/models/up"))
      fresh = described_class.new(root)
      listed = []
      allow(fresh).to receive(:list).and_wrap_original do |list, path|
        listed << File.realpath(path)
        list.call(path)
      end

      Timeout.timeout(10) { fresh.changed? }
      expect(listed).to eq(listed.uniq)
      expect(listed).to include(File.realpath(File.join(@repo, "shared/a")), File.realpath(File.join(@repo, "shared/b")))

      File.write(File.join(@repo, "shared/b/billing.rb"), "class Billing\n  X = 1\nend\n")
      expect(fresh.changed?).to be(true)
    end
  end

  # Bootsnap's compile cache knows a file by its size and the second of its
  # mtime, so a save in the second of the one before that keeps the size
  # gets the earlier save's code back from it.
  describe "#same_stat_rewrites" do
    let(:second) { Time.now.to_i }
    let(:path) { File.join(root, "app/models/post.rb") }

    def save(content, millisecond, second: self.second)
      File.write(path, content)
      time = Time.at(second, millisecond, :millisecond)
      File.utime(time, time, path)
    end

    before do
      save("class Post\n  has_many :aaaa\nend\n", 100)
      snapshot.changed?
    end

    it "names a file saved again in that second at that size, until it is saved in another" do
      save("class Post\n  has_many :bbbb\nend\n", 600)
      expect(snapshot.changed?).to be(true)
      expect(snapshot.same_stat_rewrites).to eq([ path ])

      expect(snapshot.changed?).to be(false)
      expect(snapshot.same_stat_rewrites).to eq([ path ])

      save("class Post\n  has_many :cccc\nend\n", 0, second: second + 1)
      expect(snapshot.changed?).to be(true)
      expect(snapshot.same_stat_rewrites).to be_empty
    end

    it "names no save that changed the size, or left the content as it was" do
      save("class Post\n  has_many :bbbbb\nend\n", 600)
      snapshot.changed?
      expect(snapshot.same_stat_rewrites).to be_empty

      save("class Post\n  has_many :bbbbb\nend\n", 800)
      snapshot.changed?
      expect(snapshot.same_stat_rewrites).to be_empty
    end

    it "names one the next look comes to only after the file settled" do
      save("class Post\n  has_many :bbbb\nend\n", 600)
      allow(Time).to receive(:now).and_return(Time.at(second + 30))

      expect(snapshot.changed?).to be(true)
      expect(snapshot.same_stat_rewrites).to eq([ path ])
    end

    it "lets a removed file go" do
      save("class Post\n  has_many :bbbb\nend\n", 600)
      snapshot.changed?
      File.delete(path)

      snapshot.changed?
      expect(snapshot.same_stat_rewrites).to be_empty
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
