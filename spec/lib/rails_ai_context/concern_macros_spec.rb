# frozen_string_literal: true

require "spec_helper"
require "tmpdir"
require "fileutils"

RSpec.describe RailsAiContext::ConcernMacros do
  let(:tmpdir) { Dir.mktmpdir }
  let(:concern_dir) { File.join(tmpdir, "app", "models", "concerns") }

  before { FileUtils.mkdir_p(concern_dir) }
  after { FileUtils.remove_entry(tmpdir) }

  def singleton_lookup(found)
    described_class::SingletonLookup.new(-> { described_class::SingletonLookup::Read.new(found, {}, []) })
  end

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

  # Ruby resolves `prepend Wrapper` inside DryRunnable from the enclosing
  # namespace outward, so it names DryRunnable::Wrapper, which lives in the
  # concern's own file. Looking for a file of its own called it unread.
  it "reads a module the concern declares inside itself and mixes in" do
    File.write(File.join(concern_dir, "dry_runnable.rb"), <<~RUBY)
      module DryRunnable
        extend ActiveSupport::Concern

        included do
          prepend Wrapper
        end

        module Wrapper
          extend ActiveSupport::Concern

          included do
            has_many :dry_runs
          end
        end
      end
    RUBY

    collected, unresolved = described_class.collect(tmpdir, mixin("DryRunnable"), keys: %i[associations])

    expect(unresolved).to be_empty
    expect(collected[:associations].map { |a| [ a[:name], a[:from_concern] ] })
      .to include([ :dry_runs, "DryRunnable::Wrapper" ])
  end

  # An app that adds lib to its autoload paths has a mixin there autoloaded
  # like any concern; one that does not has it unread, honestly.
  it "reads a mixin from an autoload root the app declares, and only then" do
    FileUtils.mkdir_p(File.join(tmpdir, "lib"))
    File.write(File.join(tmpdir, "lib", "rdbms_functions.rb"), "module RdbmsFunctions\n  has_many :functions\nend\n")

    _, unresolved = described_class.collect(tmpdir, mixin("RdbmsFunctions"), keys: %i[associations])
    expect(unresolved).to eq([ "RdbmsFunctions" ])

    other = Dir.mktmpdir
    FileUtils.cp_r(File.join(tmpdir, "."), other)
    FileUtils.mkdir_p(File.join(other, "config"))
    File.write(File.join(other, "config", "application.rb"), <<~RUBY)
      module Huginn
        class Application < Rails::Application
          config.autoload_paths += %W[\#{config.root}/lib]
        end
      end
    RUBY

    collected, unresolved = described_class.collect(other, mixin("RdbmsFunctions"), keys: %i[associations])
    expect(unresolved).to be_empty
    expect(collected[:associations].map { |a| a[:name] }).to eq([ :functions ])
  ensure
    FileUtils.remove_entry(other) if other
  end

  # OpenProject's ApplicationRecord includes Acts::Watchable, whose
  # `has_many :watchers` sits in `def acts_as_watchable ... class_eval do`
  # and runs only for the eleven models that call it. Collecting it gave
  # every model four associations it does not have.
  it "leaves out what a mixin declares inside a method body" do
    File.write(File.join(concern_dir, "watchable.rb"), <<~RUBY)
      module Watchable
        extend ActiveSupport::Concern

        included do
          has_many :watch_logs
          include Tracker
        end

        has_one :primary_watcher

        class_methods do
          def acts_as_watchable
            class_eval do
              has_many :watchers
              validates :watchers, presence: true
              after_create :notify_watchers
              include Notifier
            end
          end
        end

        module ClassMethods
          def acts_as_favoritable
            has_many :favorites
          end
        end
      end
    RUBY
    File.write(File.join(concern_dir, "tracker.rb"), "module Tracker\n  has_many :tracks\nend\n")
    File.write(File.join(concern_dir, "notifier.rb"), "module Notifier\n  has_many :notifications\nend\n")

    collected, unresolved = described_class.collect(tmpdir, mixin("Watchable"), keys: %i[associations validations callbacks])

    expect(unresolved).to be_empty
    expect(collected[:associations].map { |a| a[:name] }).to contain_exactly(:watch_logs, :primary_watcher, :tracks)
    expect(collected.keys).to eq([ :associations ])
  end

  it "keeps what a class method declares for a class that calls it" do
    File.write(File.join(concern_dir, "rate_limitable.rb"), <<~RUBY)
      module RateLimitable
        extend ActiveSupport::Concern

        class_methods do
          def rate_limit(options = {})
            after_create do
              record!
            end
          end

          def unused_macro
            has_many :never
          end
        end
      end
    RUBY

    collected, = described_class.collect(tmpdir, mixin("RateLimitable"), keys: %i[associations callbacks],
                                         calls: singleton_lookup(%w[rate_limit]))

    expect(collected[:callbacks].map { |c| c[:type] }).to eq([ "after_create" ])
    expect(collected.keys).to eq([ :callbacks ])
  end

  # OpenProject's WorkPackage includes WorkPackage::Validations, kept at
  # app/models/work_package/validations.rb: app/models is a Zeitwerk root, so
  # that is where the constant lives, and no concerns directory holds it.
  it "reads a mixin from an app/* autoload root, resolved from the including class's namespace" do
    FileUtils.mkdir_p(File.join(tmpdir, "app", "models", "work_package"))
    File.write(File.join(tmpdir, "app", "models", "work_package", "validations.rb"), <<~RUBY)
      module WorkPackage::Validations
        extend ActiveSupport::Concern

        included do
          validates :subject, presence: true
        end
      end
    RUBY

    collected, unresolved = described_class.collect(tmpdir, mixin("Validations"), keys: %i[validations],
                                                    within: "WorkPackage")

    expect(unresolved).to be_empty
    expect(collected[:validations].first[:from_concern]).to eq("Validations")
    expect(collected[:validations].first[:attributes]).to eq([ "subject" ])
  end

  # A nested class's include is the nested class's: Huginn's Event was told
  # its concerns included Enumerable, and called it unread.
  it "follows only the includes of the concern's own body" do
    File.write(File.join(concern_dir, "liquid_droppable.rb"), <<~RUBY)
      module LiquidDroppable
        class Drop
          include Enumerable
          include Tracked
        end
      end
    RUBY
    File.write(File.join(concern_dir, "tracked.rb"), "module Tracked\n  has_many :tracks\nend\n")

    collected, unresolved = described_class.collect(tmpdir, mixin("LiquidDroppable"), keys: %i[associations])

    expect(unresolved).to be_empty
    expect(collected).to eq({})
  end

  # `included do` runs in the includer's class, so a class method it calls
  # is called by every class that includes the concern - and by every class
  # that includes a concern whose own `included do` includes this one.
  it "applies a method's macros when a concern's included block calls it" do
    File.write(File.join(concern_dir, "watchable.rb"), <<~RUBY)
      module Watchable
        module ClassMethods
          def acts_as_watchable
            has_many :watchers
          end
        end
      end
    RUBY
    File.write(File.join(concern_dir, "journalized.rb"), <<~RUBY)
      module Journalized
        extend ActiveSupport::Concern

        included do
          acts_as_watchable
        end

        def later
          acts_as_never_called
        end
      end
    RUBY
    File.write(File.join(concern_dir, "trackable.rb"), <<~RUBY)
      module Trackable
        extend ActiveSupport::Concern

        included do
          include Journalized
        end
      end
    RUBY

    mixins = [ *mixin("Watchable"), *mixin("Trackable") ]
    collected, unresolved = described_class.collect(tmpdir, mixins, keys: %i[associations])

    expect(unresolved).to be_empty
    expect(collected[:associations].map { |a| a[:name] }).to eq([ :watchers ])
  end

  # OpenProject's Redmine::Acts::Attachable keeps InstanceMethods in its own
  # file; that module's `included do` declares an after_save for the classes
  # acts_as_attachable sends it to, and for no other. Read as the outer
  # module's body, it gave the callback to every model.
  it "reads a nested module's body only when the nested module is mixed in" do
    File.write(File.join(concern_dir, "attachable.rb"), <<~RUBY)
      module Attachable
        extend ActiveSupport::Concern

        module ClassMethods
          def acts_as_attachable
            has_many :attachments
            send :include, Attachable::InstanceMethods
          end
        end

        module InstanceMethods
          extend ActiveSupport::Concern

          included do
            after_save :persist_attachments_claimed
          end
        end
      end
    RUBY

    uncalled, = described_class.collect(tmpdir, mixin("Attachable"), keys: %i[associations callbacks])
    expect(uncalled).to eq({})

    called, = described_class.collect(tmpdir, mixin("Attachable"), keys: %i[associations callbacks],
                                      calls: singleton_lookup(%w[acts_as_attachable]))
    expect(called[:associations].map { |a| a[:name] }).to eq([ :attachments ])
    expect(called[:callbacks].map { |c| [ c[:method], c[:from_concern] ] })
      .to eq([ [ "persist_attachments_claimed", "Attachable::InstanceMethods" ] ])
  end

  # Diaspora's Relayable, Fields::Guid and Taggable declare everything in
  # `def self.included(model) model.class_eval do ... end end`. Ruby runs that
  # hook on every include, so its body belongs to every includer; read as an
  # uncalled method it was dropped, and Comment lost its author and likes.
  it "applies what a mixin hook declares to every includer" do
    File.write(File.join(concern_dir, "relayable.rb"), <<~RUBY)
      module Relayable
        def self.included(model)
          model.class_eval do
            belongs_to :author
            validates :parent, presence: true
            after_initialize :set_guid
          end
        end

        def self.prepended(model)
          model.has_many :prepended_likes
        end

        def self.append_features(model)
          super
          model.class_eval { has_many :likes }
        end

        def root
          has_many :never
        end
      end
    RUBY

    collected, = described_class.collect(tmpdir, mixin("Relayable"), keys: %i[associations validations callbacks])

    # `prepended` runs on prepend, not on this include.
    expect(collected[:associations].map { |a| a[:name] }).to eq(%i[author likes])
    expect(collected[:validations].size).to eq(1)
    expect(collected[:callbacks].map { |c| c[:method] }).to eq([ "set_guid" ])
  end

  # One call the expansion cannot read costs that method alone, named as
  # unread, and not every other called method of the module.
  it "names a called method it could not read, and keeps the module's other methods" do
    File.write(File.join(concern_dir, "settings.rb"), <<~RUBY)
      module Settings
        def self.included(base)
          base.extend ClassMethods
        end

        module ClassMethods
          def plugin_settings(*names)
            has_many :settings
          end

          def owned
            has_many :owners
          end
        end
      end
    RUBY
    allow(RailsAiContext::Introspectors::CallSiteExpansion).to receive(:entries).and_call_original
    allow(RailsAiContext::Introspectors::CallSiteExpansion).to receive(:entries)
      .with(having_attributes(name: :plugin_settings), anything, anything).and_raise(NoMethodError, "each_char for nil")

    collected, unresolved = described_class.collect(tmpdir, mixin("Settings"), keys: %i[associations],
                                                    calls: singleton_lookup(%w[plugin_settings owned]))

    expect(collected[:associations].map { |a| a[:name] }).to eq([ :owners ])
    expect(unresolved).to eq([ "Settings::ClassMethods#plugin_settings" ])
  end

  # A hook that calls a helper macro declares what the helper declares, on
  # every includer, with the hook's arguments.
  it "reads the helper macros a mixin hook calls" do
    File.write(File.join(concern_dir, "hooked.rb"), <<~RUBY)
      module Hooked
        def self.included(base)
          base.extend ClassMethods
          base.class_eval { setup_hooked :hook_items }
          base.hooked_too :hook_owner
        end

        module ClassMethods
          def setup_hooked(name)
            has_many name
          end

          def hooked_too(name)
            has_one name
          end

          def never_called
            has_many :never
          end
        end
      end
    RUBY

    collected, = described_class.collect(tmpdir, mixin("Hooked"), keys: %i[associations])

    expect(collected[:associations].map { |a| [ a[:type], a[:name] ] })
      .to contain_exactly([ "has_many", :hook_items ], [ "has_one", :hook_owner ])
  end

  # Ruby runs `included` on include and `extended` on extend, and each hook's
  # body belongs to the class it ran for, `base.scope` and `base.delegate` too.
  describe "a module with a hook for each way it can be mixed in" do
    before do
      File.write(File.join(concern_dir, "dual.rb"), <<~RUBY)
        module Dual
          def self.included(base)
            base.has_many :included_items
            base.scope :recent, -> { order(:created_at) }
            base.delegate :owner_name, to: :owner
          end

          def self.extended(base)
            base.has_many :extended_items
          end
        end
      RUBY
    end

    it "applies the included hook to an includer, and not the extended one" do
      collected, = described_class.collect(tmpdir, mixin("Dual"), keys: %i[associations scopes macros])

      expect(collected[:associations].map { |a| a[:name] }).to eq([ :included_items ])
      expect(collected[:scopes].map { |scope| scope[:name] }).to eq([ "recent" ])
      expect(collected[:macros].map { |m| m[:macro] }).to include(:delegate)
    end

    it "applies the extended hook to a class that extends it, and not the included one" do
      path = File.join(concern_dir, "dual.rb")
      extra = [ RailsAiContext::BaseMixins::Mixin.new("Dual", path, :extend) ]
      collected, = described_class.collect(tmpdir, [], keys: %i[associations], extra: extra)

      expect(collected[:associations].map { |a| a[:name] }).to eq([ :extended_items ])
    end
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
    allow(RailsAiContext::Introspectors::SourceIntrospector).to receive(:walk).and_call_original

    2.times { described_class.collect(tmpdir, mixin("Publishable"), keys: %i[associations], cache: cache) }
    collected, = described_class.collect(tmpdir, mixin("Publishable"), keys: %i[associations], cache: cache)

    expect(RailsAiContext::Introspectors::SourceIntrospector).to have_received(:walk).once
    expect(collected[:associations].map { |a| a[:name] }).to eq([ :revisions ])
  end

  # Canvas mixes one 2,000-line initializer's modules into every model, and
  # each model's walk searched that tree three more ways: 12s of a static run.
  it "searches a concern file's tree once per run when a cache is passed" do
    File.write(File.join(concern_dir, "publishable.rb"), <<~RUBY)
      module Publishable
        extend ActiveSupport::Concern
        module Stamps
          extend ActiveSupport::Concern
          included do
            before_save :stamp
          end
        end
        include Stamps
        included do
          has_many :revisions
        end
      end
    RUBY
    cache = {}
    tree_walks = 0
    allow(RailsAiContext::Introspectors::AstWalk).to receive(:each).and_wrap_original do |original, *args|
      tree_walks += 1
      original.call(*args)
    end
    indexes = 0
    allow(RailsAiContext::Introspectors::DeclaredConstant).to receive(:module_nodes).and_wrap_original do |original, *args|
      indexes += 1 if args.size == 1
      original.call(*args)
    end

    keys = %i[associations callbacks]
    described_class.collect(tmpdir, mixin("Publishable"), keys: keys, within: "Post", cache: cache)
    before = tree_walks
    cached = %w[Comment Article].map do |owner|
      described_class.collect(tmpdir, mixin("Publishable"), keys: keys, within: owner, cache: cache).first
    end
    walks_for_two = tree_walks - before
    indexes_in_run = indexes
    uncached = %w[Comment Article].map do |owner|
      described_class.collect(tmpdir, mixin("Publishable"), keys: keys, within: owner).first
    end

    expect(cached).to eq(uncached)
    expect(walks_for_two).to eq(0)
    expect(indexes_in_run).to eq(1)
  end

  # Every model walked its bases' concerns again with its own calls, though
  # most walks never meet a method the class calls: on Huginn that loop was a
  # fifth of a tool call.
  describe "a walk kept across classes in one run" do
    before do
      File.write(File.join(concern_dir, "trackable.rb"), <<~RUBY)
        module Trackable
          extend ActiveSupport::Concern
          included do
            has_many :events
          end
          class_methods do
            def tracks(name)
              has_many name
            end
          end
        end
      RUBY
    end

    def collect_for(calls, cache)
      described_class.collect(tmpdir, mixin("Trackable"), keys: %i[associations], within: "Base",
                              cache: cache, calls: singleton_lookup(calls))
    end

    it "is walked once for classes that call none of the methods it asked about, and again for one that does" do
      cache = {}
      runs = 0
      allow(described_class::Run).to receive(:new).and_wrap_original { |original, *args| runs += 1; original.call(*args) }

      first, = collect_for([ "validates" ], cache)
      second, = collect_for([ "scope" ], cache)
      expect(runs).to eq(1)
      expect(second).to eq(first)

      calling, = collect_for({ "tracks" => [ nil ] }, cache)
      expect(runs).to eq(2)
      expect(calling).to eq(described_class.collect(tmpdir, mixin("Trackable"), keys: %i[associations], within: "Base",
                                                    calls: singleton_lookup({ "tracks" => [ nil ] })).first)
    end
  end

  # The exclusion is applied inside the walk, so the walk is the only place
  # that knows which concerns it skipped for that reason, at any depth.
  describe "a concern excluded_concerns hides" do
    around do |example|
      original = RailsAiContext.configuration.excluded_concerns
      RailsAiContext.configuration.excluded_concerns = [ /\AAuditable\z/ ]
      example.run
      RailsAiContext.configuration.excluded_concerns = original
    end

    it "is named apart from the ones it could not read" do
      File.write(File.join(concern_dir, "auditable.rb"), "module Auditable\n  has_many :audits\nend\n")

      collected, unresolved, hidden = described_class.collect(tmpdir, mixin("Auditable"), keys: %i[associations])

      expect(hidden).to eq([ "Auditable" ])
      expect(unresolved).to be_empty
      expect(collected).to eq({})
    end

    it "is not named when the app has no file for it" do
      _collected, _unresolved, hidden = described_class.collect(tmpdir, mixin("Auditable"), keys: %i[associations])

      expect(hidden).to be_empty
    end

    it "is named when it is nested inside a concern the walk reads" do
      File.write(File.join(concern_dir, "outer.rb"), "module Outer\n  include Auditable\n  has_many :things\nend\n")
      File.write(File.join(concern_dir, "auditable.rb"), "module Auditable\n  has_many :audits\nend\n")

      collected, _unresolved, hidden = described_class.collect(tmpdir, mixin("Outer"), keys: %i[associations])

      expect(hidden).to eq([ "Auditable" ])
      expect(collected[:associations].map { |a| a[:name] }).to eq([ :things ])
    end

    # The walk resolves a namespace-relative include against the enclosing
    # constant; a count derived from the bare name would miss the file.
    it "is named through the namespace the include sits in" do
      FileUtils.mkdir_p(File.join(concern_dir, "billing"))
      File.write(File.join(concern_dir, "billing", "auditable.rb"), "module Billing\n  module Auditable\n  end\nend\n")
      RailsAiContext.configuration.excluded_concerns = [ /Auditable\z/ ]

      _collected, _unresolved, hidden = described_class.collect(
        tmpdir, mixin("Auditable"), keys: %i[associations], within: "Billing"
      )

      expect(hidden).to eq([ "Auditable" ])
    end
  end

  # Three causes look the same in `unresolved`: a permission bit, a directory
  # in place of a file, and a bug in a listener. The booted walk names the
  # cause under DEBUG for that reason.
  it "names why it could not read a concern, under DEBUG" do
    path = File.join(concern_dir, "publishable.rb")
    File.write(path, "module Publishable\nend\n")
    allow(RailsAiContext::Introspectors::SourceIntrospector).to receive(:walk)
      .with(path, anything).and_raise(NoMethodError, "undefined method 'name' for nil")

    errors = StringIO.new
    original = $stderr
    $stderr = errors
    original_debug = ENV["DEBUG"]
    ENV["DEBUG"] = "1"
    begin
      _collected, unresolved = described_class.collect(tmpdir, mixin("Publishable"), keys: %i[associations])
    ensure
      $stderr = original
      original_debug.nil? ? ENV.delete("DEBUG") : ENV["DEBUG"] = original_debug
    end

    expect(unresolved).to eq([ "Publishable" ])
    expect(errors.string).to include("undefined method")
    expect(errors.string).to include(path)
  end

  # The lookup alone: class methods from parsed defs, sites from parsed calls.
  describe "SingletonLookup, the class-method lookup" do
    let(:klass) { RailsAiContext::ConcernMacros::SingletonLookup }

    def node(source) = Prism.parse(source).value.statements.body.first

    def definition(owner, source) = klass.definition(owner, node(source))

    # A module reached at `at` (or inside the body `inside` names) giving the class methods `source` defines.
    def mixin(label, at, source = nil, inside: nil, hook_defs: nil)
      defs = source ? [ definition(label, source) ] : []
      klass::Mixin.new(label, :include, defs, hook_defs ? [ definition(label, hook_defs) ] : [], at, inside, false)
    end

    def lookup(sites, own, outer: 1)
      found = sites.group_by { |_, site| site.name.to_s }.transform_values { |pairs| pairs.map(&:last) }
      ranks = sites.to_h { |rank, site| [ site.__id__, rank ] }
      klass.new(-> { klass::Read.new(found, ranks, own, outer) })
    end

    def placed(calls, definer, line, site = nil)
      calls.placed({}, definer, [ line ], site).map { |entry| [ entry[:rank], entry[:chain_at] ] }
    end

    def mixed_in(calls, label, rank, line, hook: false)
      calls.mixed_in({ from_concern: label, location: line, hook: hook }, rank).map { |entry| [ entry[:rank], entry[:chain_at] ] }
    end

    it "runs the class's own def, then what its super reaches, at the super" do
      call = node("\n\n\n\n\n\n\nstamp")
      calls = lookup([ [ 0, call ] ], [ definition(0, "\n\ndef self.stamp\n  super\n  own\nend") ])
      calls.add(0, {}, {}, [ mixin("Stampy", [ 2, 0 ], "def stamp\n  s\nend") ])

      expect(placed(calls, [ 0, 3 ], 5)).to eq([ [ 0, [ 8, -1, 5 ] ] ])
      expect(placed(calls, [ "Stampy", 1 ], 2)).to eq([ [ 0, [ 8, -1, 4, 2 ] ] ])
    end

    it "reaches the concern included last, and no definition that exists only after the call" do
      call = node("\n\n\n\nstamp")
      calls = lookup([ [ 0, call ] ], [ definition(0, "\n" * 8 + "def self.stamp\nend") ])
      calls.add(0, {}, {}, [ mixin("Stampy", [ 2, 0 ], "def stamp\nend"), mixin("Stampy2", [ 3, 0 ], "def stamp\nend") ])

      expect(placed(calls, [ "Stampy2", 1 ], 1)).to eq([ [ 0, [ 5, -1, 1 ] ] ])
      expect(placed(calls, [ "Stampy", 1 ], 1)).to eq([])
      expect(placed(calls, [ 0, 9 ], 1)).to eq([])
    end

    it "resolves a base's call from the base outward, never into the child" do
      base_call = node("\n\nstamp")
      calls = lookup([ [ 1, base_call ] ], [ definition(1, "def self.stamp\nend") ], outer: 2)
      calls.add(0, {}, {}, [ mixin("Stampy", [ 2, 0 ], "def stamp\nend") ])
      calls.add(1, {}, {}, [])

      expect(placed(calls, [ 1, 1 ], 1)).to eq([ [ 1, [ 3, -1, 1 ] ] ])
      expect(placed(calls, [ "Stampy", 1 ], 1)).to eq([])
    end

    it "runs a Concern's block once in the outermost class including it, and a plain hook in each" do
      block_call = node("loud!")
      hook_call = node("base.loud!")
      calls = lookup([], [ definition(0, "def self.loud!\nend"), definition(1, "def self.loud!\nend") ], outer: 2)
      blocks = { block_call.__id__ => [ "Hooky", false ], hook_call.__id__ => [ "Hk", true ] }
      calls.add(0, { "loud!" => [ block_call, hook_call ] }, blocks, [ mixin("Hooky", [ 4, 0 ]), mixin("Hk", [ 6, 1 ]) ])
      calls.add(1, { "loud!" => [ block_call, hook_call ] }, blocks, [ mixin("Hooky", [ 2, 0 ]), mixin("Hk", [ 3, 1 ]) ])

      expect(placed(calls, [ 1, 1 ], 1, block_call)).to eq([ [ 1, [ 2, 0, 1, 1 ] ] ])
      expect(placed(calls, [ 0, 1 ], 1, block_call)).to eq([])
      expect(placed(calls, [ 0, 1 ], 1, hook_call)).to eq([ [ 0, [ 6, 1, 1, 1 ] ] ])
      expect(placed(calls, [ 1, 1 ], 1, hook_call)).to eq([ [ 1, [ 3, 1, 1, 1 ] ] ])
      expect(mixed_in(calls, "Hooky", 0, 9)).to eq([])
      expect(mixed_in(calls, "Hooky", 1, 9)).to eq([ [ 1, [ 2, 0, 9 ] ] ])
      expect(mixed_in(calls, "Hk", 0, 9, hook: true)).to eq([ [ 0, [ 6, 1, 9 ] ] ])
    end

    it "adds a module a method includes at the first call reaching that method, and gives its methods to calls after" do
      setup = node("\n\n\n\nsetup")
      stamp_before = node("\n\n\nstamp")
      stamp_after = node("\n\n\n\n\nstamp")
      second = node("\n\n\n\n\n\nsetup")
      calls = lookup([ [ 0, setup ], [ 0, stamp_before ], [ 0, stamp_after ], [ 0, second ] ], [ definition(0, "def self.setup\n  include Tb\nend") ])
      calls.add(0, {}, {}, [ mixin("Tb", [ 2, 0 ], "def stamp\nend", inside: [ 0, 1 ]), mixin("Stampy", [ 1, 0 ], "def stamp\nend") ])

      expect(mixed_in(calls, "Tb", 0, 9)).to eq([ [ 0, [ 5, -1, 2, 0, 9 ] ] ])
      expect(placed(calls, [ "Tb", 1 ], 1, stamp_before)).to eq([])
      expect(placed(calls, [ "Tb", 1 ], 1, stamp_after)).to eq([ [ 0, [ 6, -1, 1 ] ] ])
    end

    it "resolves a plain hook's call again at each include, as of that include" do
      hook_call = node("base.loud!")
      first_setup = node("\n\n\n\nsetup")
      second_setup = node("\n\n\n\n\n\nsetup")
      calls = lookup([ [ 0, first_setup ], [ 0, second_setup ] ], [ definition(0, "def self.setup\n  include Hk\nend") ])
      calls.add(0, { "loud!" => [ hook_call ] }, { hook_call.__id__ => [ "Hk", true ] },
                [ mixin("Hk", [ 2, 0 ], inside: [ 0, 1 ]), mixin("Louder", [ 6, 0 ], "def loud!\nend") ])

      expect(placed(calls, [ "Louder", 1 ], 1, hook_call)).to eq([ [ 0, [ 7, -1, 2, 0, 1, 1 ] ] ])
    end

    it "adds no module a method includes when every call runs another definition" do
      setup = node("\n\n\n\nsetup")
      calls = lookup([ [ 0, setup ] ], [ definition(0, "\n\ndef self.setup\nend") ])
      calls.add(0, {}, {}, [ mixin("SetupC", [ 1, 0 ], "def setup\n  include HelperC\nend"), mixin("HelperC", [ 2, 0 ], inside: [ "SetupC", 1 ]) ])

      expect(mixed_in(calls, "HelperC", 0, 9)).to eq([])
    end

    it "reads a hook's def on the class as the class's own from that include, and an alias as what its name ran there" do
      call = node("\n\n\n\n\nstamp")
      own = [ definition(0, "def self.stamp\nend"), klass::Def.new(0, "stamp_without", 3, nil, {}, "stamp") ]
      aliased = node("\n\n\n\n\n\nstamp_without")
      calls = lookup([ [ 0, call ], [ 0, aliased ] ], own)
      calls.add(0, {}, {}, [ mixin("Icm", [ 2, 0 ], hook_defs: "\ndef stamp\nend") ])

      expect(placed(calls, [ "Icm", 2 ], 1, call)).to eq([ [ 0, [ 6, -1, 1 ] ] ])
      expect(placed(calls, [ "Icm", 2 ], 1, aliased)).to eq([ [ 0, [ 7, -1, 1 ] ] ])
      expect(placed(calls, [ 0, 1 ], 1, call)).to eq([])
    end

    it "makes a reached body's calls from where its own call stands" do
      call = node("\n\n\n\n\nsetup")
      own = [ definition(0, "def self.setup\n  loud!\nend"), definition(0, "\n\n\ndef self.loud!\nend") ]
      calls = lookup([ [ 0, call ] ], own)

      expect(calls.sites_by_name.keys).to contain_exactly("setup", "loud!")
      expect(placed(calls, [ 0, 4 ], 4)).to eq([ [ 0, [ 6, -1, 2, 4 ] ] ])
    end

    it "places a call made in a body a super reached after what ran before that super" do
      call = node("\n\n\n\n\n\n\nstamp")
      own = [ definition(0, "\n\ndef self.stamp\n  own\n  super\nend"), definition(0, "def self.loud!\nend") ]
      calls = lookup([ [ 0, call ] ], own)
      calls.add(0, {}, {}, [ mixin("Stampy", [ 2, 0 ], "def stamp\n  loud!\nend") ])

      expect(placed(calls, [ 0, 3 ], 4)).to eq([ [ 0, [ 8, -1, 4 ] ] ])
      expect(placed(calls, [ 0, 1 ], 21)).to eq([ [ 0, [ 8, -1, 5, 2, 21 ] ] ])
    end
  end

  it "exposes collect and the body lookup its classes share" do
    expect(described_class.singleton_methods(false)).to contain_exactly(:collect, :enclosing)
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
