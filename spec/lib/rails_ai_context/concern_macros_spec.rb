# frozen_string_literal: true

require "spec_helper"
require "tmpdir"
require "fileutils"

RSpec.describe RailsAiContext::ConcernMacros do
  let(:tmpdir) { Dir.mktmpdir }
  let(:concern_dir) { File.join(tmpdir, "app", "models", "concerns") }

  before { FileUtils.mkdir_p(concern_dir) }
  after { FileUtils.remove_entry(tmpdir) }

  def mixin(name)
    [ { name: name, kind: :include, ancestor: true } ]
  end

  it "collects the macros a concern declares inside included do" do
    File.write(File.join(concern_dir, "publishable.rb"), <<~RUBY)
      module Publishable
        extend ActiveSupport::Concern

        included do
          has_many :revisions
          validates :body, presence: true
          scope :published, -> { where(published: true) }
          before_save :stamp
        end
      end
    RUBY

    collected, unresolved = described_class.collect(tmpdir, mixin("Publishable"), keys: %i[associations validations scopes callbacks])

    expect(unresolved).to be_empty
    expect(collected[:associations].map { |a| a[:name] }).to eq([ :revisions ])
    expect(collected[:validations].size).to eq(1)
    expect(collected[:scopes].map { |s| s[:name] }).to eq([ "published" ])
    expect(collected[:callbacks].map { |c| c[:method] }).to eq([ "stamp" ])
  end

  it "tags every entry with the concern it came from" do
    File.write(File.join(concern_dir, "wired.rb"), "module Wired\n  has_many :wires\nend\n")

    collected, = described_class.collect(tmpdir, mixin("Wired"), keys: %i[associations])

    expect(collected[:associations].first[:from_concern]).to eq("Wired")
  end

  # The walk accumulates into a Hash with a default block; a caller that
  # probed a key it never asked for used to grow one on read.
  it "hands back a plain hash, so reading a key the walk never produced adds none" do
    File.write(File.join(concern_dir, "wired.rb"), "module Wired\n  has_many :wires\nend\n")

    collected, = described_class.collect(tmpdir, mixin("Wired"), keys: %i[associations])
    collected[:enums]

    expect(collected.keys).to eq([ :associations ])
  end

  it "follows a concern that includes another concern" do
    File.write(File.join(concern_dir, "outer.rb"), <<~RUBY)
      module Outer
        include Inner
        has_many :outers
      end
    RUBY
    File.write(File.join(concern_dir, "inner.rb"), "module Inner\n  has_many :inners\nend\n")

    collected, = described_class.collect(tmpdir, mixin("Outer"), keys: %i[associations])

    expect(collected[:associations].map { |a| a[:name] }).to contain_exactly(:outers, :inners)
  end

  it "stops at a mutual include instead of recursing forever" do
    File.write(File.join(concern_dir, "left.rb"), "module Left\n  include Right\n  has_many :lefts\nend\n")
    File.write(File.join(concern_dir, "right.rb"), "module Right\n  include Left\n  has_many :rights\nend\n")

    collected, = described_class.collect(tmpdir, mixin("Left"), keys: %i[associations])

    expect(collected[:associations].map { |a| a[:name] }).to contain_exactly(:lefts, :rights)
  end

  it "names a concern whose file it cannot find" do
    _collected, unresolved = described_class.collect(tmpdir, mixin("Discard::Model"), keys: %i[associations])

    expect(unresolved).to eq([ "Discard::Model" ])
  end

  # A concern the walk cannot read costs its own declarations. It used to
  # raise out of the walk, and the section-level rescue above it turned one
  # unreadable file into an error for every model in the app.
  it "names a concern whose file it cannot read" do
    path = File.join(concern_dir, "publishable.rb")
    File.write(path, "module Publishable\n  has_many :revisions\nend\n")
    make_unreadable(path)

    collected, unresolved = described_class.collect(tmpdir, mixin("Publishable"), keys: %i[associations])

    expect(unresolved).to eq([ "Publishable" ])
    expect(collected).to eq({})
  ensure
    File.chmod(0o644, path) if path && File.exist?(path)
  end

  # Not only a permission bit: a path that stats but does not read bites the
  # same way for a user who can read everything.
  it "names a concern whose path is not a readable file" do
    FileUtils.mkdir_p(File.join(concern_dir, "publishable.rb"))

    collected, unresolved = described_class.collect(tmpdir, mixin("Publishable"), keys: %i[associations])

    expect(unresolved).to eq([ "Publishable" ])
    expect(collected).to eq({})
  end

  it "keeps walking the concerns it can read" do
    File.write(File.join(concern_dir, "readable.rb"), "module Readable\n  has_many :notes\nend\n")
    FileUtils.mkdir_p(File.join(concern_dir, "blocked.rb"))
    mixins = mixin("Blocked") + mixin("Readable")

    collected, unresolved = described_class.collect(tmpdir, mixins, keys: %i[associations])

    expect(unresolved).to eq([ "Blocked" ])
    expect(collected[:associations].map { |a| a[:name] }).to eq([ :notes ])
  end

  # A model tier walks the same concern once per model that includes it, and
  # AstCache caches the parse but not the listener dispatch.
  it "walks a concern file once per run when a cache is passed" do
    File.write(File.join(concern_dir, "publishable.rb"), "module Publishable\n  has_many :revisions\nend\n")
    cache = {}
    allow(RailsAiContext::Introspectors::SourceIntrospector).to receive(:call).and_call_original

    2.times { described_class.collect(tmpdir, mixin("Publishable"), keys: %i[associations], cache: cache) }
    collected, = described_class.collect(tmpdir, mixin("Publishable"), keys: %i[associations], cache: cache)

    expect(RailsAiContext::Introspectors::SourceIntrospector).to have_received(:call).once
    expect(collected[:associations].map { |a| a[:name] }).to eq([ :revisions ])
  end

  it "exposes collect alone" do
    expect(described_class.singleton_methods(false)).to eq([ :collect ])
  end

  it "does not reach outside the owner kind's concerns directory" do
    FileUtils.mkdir_p(File.join(tmpdir, "app", "controllers", "concerns"))
    File.write(File.join(tmpdir, "app", "controllers", "concerns", "searchable.rb"),
      "module Searchable\n  before_action :require_login\nend\n")
    File.write(File.join(concern_dir, "searchable.rb"), "module Searchable\n  scope :search, -> { all }\nend\n")

    collected, = described_class.collect(tmpdir, mixin("Searchable"), keys: %i[scopes], prefer: "model")

    expect(collected[:scopes].map { |s| s[:name] }).to eq([ "search" ])
  end
end
