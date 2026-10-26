# frozen_string_literal: true

require "spec_helper"

RSpec.describe RailsAiContext::Introspectors::DeclaredConstant do
  it "keeps the raw declaration cache behind .declarations" do
    expect(described_class).not_to respond_to(:declarations_in)
  end

  describe ".lookup" do
    it "reads the later ancestors only when the search reaches them, after the given ones and before the top level" do
      calls = 0
      later = -> { calls += 1; [ "Concern" ] }
      exists = ->(names) { ->(name) { names.include?(name) } }

      expect(described_class.lookup("X", nesting: [ "Mod" ], exists: exists.call(%w[Mod::X Concern::X X]), later_ancestors: later)).to eq("Mod::X")
      expect(calls).to eq(0)
      expect(described_class.lookup("X", nesting: [ "Mod" ], exists: exists.call(%w[Concern::X X]), later_ancestors: later)).to eq("Concern::X")
      expect(described_class.lookup("::X", nesting: [ "Mod" ], exists: exists.call(%w[Concern::X X]), later_ancestors: later)).to eq("X")
      expect(calls).to eq(1)
    end

    it "reach answers what exists said for the constant lookup picks, which can be another module than the spelling" do
      held = { "Mod::Item::Tag" => "Mod::Holder::Tag", "Mod::Item" => "Mod::Item" }
      exists = ->(name) { held[name] }

      expect(described_class.lookup("Tag", nesting: [ "Mod::Item", "Mod" ], exists: exists)).to eq("Mod::Item::Tag")
      expect(described_class.reach("Tag", nesting: [ "Mod::Item", "Mod" ], exists: exists)).to eq("Mod::Holder::Tag")
      expect(described_class.reach("Missing", nesting: [ "Mod" ], exists: exists)).to be_nil
    end

    # [written, Module.nesting, the innermost scope's ancestors, constants the app has, the one Ruby picks]
    [
      [ "Priced", [], [], %w[Priced], "Priced" ],
      [ "Priced", %w[Shop], [], %w[Shop::Priced Priced], "Shop::Priced" ],
      [ "Priced", %w[Shop], [], %w[Priced], "Priced" ],
      [ "::Priced", %w[Shop], [], %w[Shop::Priced Priced], "Priced" ],
      [ "::Priced", %w[Shop], [], %w[Shop::Priced], nil ],
      [ "Guard", %w[Admin::UsersController Admin], [], %w[Admin::Guard Guard], "Admin::Guard" ],
      [ "Taggable", %w[Post], %w[Tracker], %w[Tracker::Taggable Taggable], "Tracker::Taggable" ],
      [ "Taggable", %w[Post], %w[Tracker], %w[Post::Taggable Tracker::Taggable], "Post::Taggable" ],
      [ "Taggable", %w[Shop::Tool Shop], %w[Tracker], %w[Shop::Taggable Tracker::Taggable], "Shop::Taggable" ],
      [ "Taggable", %w[Shop::Tool Shop], %w[Tracker], %w[Tracker::Taggable Taggable], "Tracker::Taggable" ],
      [ "::Taggable", %w[Post], %w[Tracker], %w[Tracker::Taggable Taggable], "Taggable" ],
      [ "Billing::Base", %w[Shop], [], %w[Billing::Base], "Billing::Base" ],
      [ "Billing::Base", %w[Shop], [], %w[Shop::Billing Billing Billing::Base], nil ],
      [ "Billing::Base", %w[Shop], [], %w[Shop::Billing Shop::Billing::Base Billing Billing::Base], "Shop::Billing::Base" ],
      [ "Billing::Base", %w[Shop], [], %w[Billing Billing::Base Shop::Billing::Base], "Shop::Billing::Base" ],
      [ "Billing::Base", %w[Post], %w[Tracker], %w[Tracker::Billing Tracker::Billing::Base Billing Billing::Base], "Tracker::Billing::Base" ],
      [ "::Billing::Base", %w[Shop], [], %w[Shop::Billing Shop::Billing::Base Billing Billing::Base], "Billing::Base" ],
      [ "::Billing::Base", %w[Shop], [], %w[Billing Shop::Billing::Base], nil ],
      [ "Missing", %w[Shop], %w[Tracker], %w[Shop::Priced], nil ]
    ].each do |written, nesting, ancestors, known, expected|
      it "picks #{expected.inspect} for #{written} in #{nesting.inspect} with ancestors #{ancestors.inspect} and #{known.inspect}" do
        found = described_class.lookup(written, nesting: nesting, ancestors: ancestors, exists: ->(name) { known.include?(name) })

        expect(found).to eq(expected)
      end
    end

    # Ruby reads the rest of a path inside the head's superclasses, so `Admin::Tools` with `class Admin < Panel` is `Panel::Tools`.
    it "reads the rest of a qualified name inside each superclass of its head, as Ruby does" do
      ruby = Module.new.module_eval(<<~RUBY, __FILE__, __LINE__ + 1)
        class Panel; module Tools; end; end
        class Admin < Panel; end
        Admin::Tools.name.split("::").last(2).join("::")
      RUBY
      known = %w[Panel Panel::Tools Admin]
      found = described_class.lookup("Admin::Tools", nesting: [], exists: ->(name) { known.include?(name) },
                                                     ancestors_of: ->(name) { name == "Admin" ? %w[Panel] : [] })

      expect(ruby).to eq("Panel::Tools")
      expect(found).to eq(ruby)
      expect(described_class.lookup("Admin::Tools", nesting: [], exists: ->(name) { known.include?(name) })).to be_nil
    end

    # Each later segment is read inside the constant the segment before it resolved to, and that constant's superclasses.
    it "reads each later segment inside the previous segment's superclasses too" do
      ruby = Module.new.module_eval(<<~RUBY, __FILE__, __LINE__ + 1)
        class Board; class Widget; end; end
        module Dash; class Panel < Board; end; end
        Dash::Panel::Widget.name.split("::").last(2).join("::")
      RUBY
      known = %w[Board Board::Widget Dash Dash::Panel]
      found = described_class.lookup("Dash::Panel::Widget", nesting: [], exists: ->(name) { known.include?(name) },
                                                            ancestors_of: ->(name) { name == "Dash::Panel" ? %w[Board] : [] })

      expect(ruby).to eq("Board::Widget")
      expect(found).to eq(ruby)
    end

    # Zeitwerk defines a namespace from its folder, so no file declares it.
    it "reads a path whose head is a namespace the app holds constants under" do
      ruby = Module.new.module_eval(<<~RUBY, __FILE__, __LINE__ + 1)
        module Desk; class Board; class Widget; end; end; class Panel < Board; end; end
        Desk::Panel::Widget.name.split("::").last(3).join("::")
      RUBY
      known = %w[Desk::Board Desk::Board::Widget Desk::Panel]
      found = described_class.lookup("::Desk::Panel::Widget", nesting: %w[Shop], exists: ->(name) { known.include?(name) },
                                                              ancestors_of: ->(name) { name == "Desk::Panel" ? %w[Desk::Board] : [] })

      expect(ruby).to eq("Desk::Board::Widget")
      expect(found).to eq(ruby)
    end

    it "asks nothing past the first constant the app has" do
      asked = []
      described_class.lookup("Priced", nesting: %w[Shop], exists: ->(name) { asked << name })

      expect(asked).to eq(%w[Shop::Priced])
    end
  end

  # A file that declares only a module names a constant too, and the path
  # camelization is wrong for it in exactly the way it is wrong for a class:
  # an app inflection only changes case.
  describe ".own_line_count" do
    let(:source) { "module Jobs\n  class Base\n    def a; end\n  end\n\n  class Scheduled < Base\n    class Inner\n    end\n  end\nend\n" }

    it "counts the lines a class's own declaration spans, a nested class included" do
      expect([ described_class.own_line_count(source, "Jobs::Base"), described_class.own_line_count(source, "Jobs::Scheduled") ]).to eq([ 3, 4 ])
    end

    it "answers nil for a name the source does not declare as a class" do
      expect(described_class.own_line_count(source, "Jobs")).to be_nil
      expect(described_class.own_line_count(source, "Nope")).to be_nil
    end
  end

  describe ".resolve over a file declaring only a module" do
    it "answers the module the file declares, not the camelized path" do
      source = "module ActivityPub\n  module ActorFields\n  end\nend\n"

      expect(described_class.resolve(source, "Activitypub::ActorFields")).to eq("ActivityPub::ActorFields")
    end

    it "keeps the path when the module it declares is a different constant" do
      source = "module Serializers::Shared\nend\n"

      expect(described_class.resolve(source, "SharedFields")).to eq("SharedFields")
    end

    # A class is part of the name of anything inside it, the same way a module
    # is, so a module nested in one is not a top-level constant.
    it "keeps the class in the name of a module declared inside it" do
      source = "class Outer\n  module Inner\n  end\nend\n"

      expect(described_class.declared_module_names(source)).to eq([ "Outer::Inner" ])
    end

    it "answers a module assigned from Module.new the way it answers the module keyword" do
      assigned = "APITrackable = Module.new do\n  def track; end\nend\n"
      keyword = "module APITrackable\n  def track; end\nend\n"

      expect(described_class.resolve(assigned, "ApiTrackable")).to eq("APITrackable")
      expect(described_class.resolve(keyword, "ApiTrackable")).to eq("APITrackable")
      expect(described_class.declared_module_names("module Shop\n  Trackable = Module.new do\n  end\nend\n")).to eq(%w[Shop Shop::Trackable])
    end

    it "prefers a declared class over a declared module" do
      source = "module Wrapper\nend\nclass Widget\nend\n"

      expect(described_class.resolve(source, "Widget")).to eq("Widget")
    end
  end

  # Ruby looks the first segment of `class Shop::Draft` up lexically: inside `module Shop` it is ::Shop, and
  # inside `module Shop; module Admin` an `Admin::Draft` is Shop::Admin::Draft (Module.nesting [Shop::Admin::Draft, Shop::Admin, Shop]).
  describe "a compact path whose first segment names an enclosing scope" do
    it "declares the constant under that scope, with Ruby's nesting" do
      tree = RailsAiContext::AstCache.parse_string("module Shop\n  class Shop::Draft; end\n  module Admin\n    class Admin::Draft; end\n    class Other::Draft; end\n  end\nend\n").value
      expect(described_class.constants(tree).map { |name, _node, nesting| [ name, nesting ] }).to eq(
        [ [ "Shop", %w[Shop] ], [ "Shop::Draft", %w[Shop::Draft Shop] ], [ "Shop::Admin", %w[Shop::Admin Shop] ],
          [ "Shop::Admin::Draft", %w[Shop::Admin::Draft Shop::Admin Shop] ], [ "Shop::Admin::Other::Draft", %w[Shop::Admin::Other::Draft Shop::Admin Shop] ] ]
      )
    end

    it "names the class it declares so" do
      source = "module Shop\n  class Shop::Draft\n    def total; end\n  end\nend\n"
      expect(described_class.declared_names(source)).to eq(%w[Shop::Draft])
      expect(described_class.class_bodies(RailsAiContext::AstCache.parse_string(source).value, "Shop::Draft").map(&:slice)).to eq([ "def total; end" ])
    end

    # Ruby tries Shop::Shop before ::Shop, and takes the first already defined.
    it "reads the first segment as the nearest constant declared above it" do
      nearer = "module Shop\n  module Shop; end\n  class Shop::Draft; end\nend\n"
      below = "module Shop\n  class Shop::Draft; end\n  module Shop; end\nend\n"
      expect(described_class.declared_names(nearer)).to eq(%w[Shop::Shop::Draft])
      expect(described_class.declared_names(below)).to eq(%w[Shop::Draft])
    end

    # Ruby: `Part ||= Class.new do ... end` with Part already set never runs the block, so ::Loose is never opened.
    it "reads no class body inside an `||=` block that never runs" do
      source = "class Gadget < Base\n  Part = Class.new(Base)\n  Part ||= Class.new(Base) do\n    class ::Loose < Base\n      def leak; end\n    end\n  end\nend\n"
      expect(described_class.class_bodies(RailsAiContext::AstCache.parse_string(source).value, "Loose")).to eq([])
    end

    it "names a Class.new written to such a path the same way" do
      source = "module Shop\n  Shop::Draft = Class.new(Base) do\n    def total; end\n  end\nend\n"
      tree = RailsAiContext::AstCache.parse_string(source).value
      expect(described_class.constants(tree, assignments: true).map { |name, *| name }).to eq(%w[Shop Shop::Draft])
      expect(described_class.declarations(source, path_name: "Shop::Draft").map(&:name)).to eq(%w[Shop::Draft])
      expect(described_class.class_bodies(tree, "Shop::Draft").map(&:slice)).to eq([ "def total; end" ])
    end

    # Ruby: `Shop ||= ...` and `Shop, Mall = ...` define A::Shop, so `class Shop::Draft` inside A::B is A::Shop::Draft.
    it "reads the first segment against a constant an `||=` or a multiple assignment wrote" do
      body = "  module B\n    class Shop::Draft < Base; end\n  end\nend\n"
      expect(described_class.declared_names("module A\n  Shop ||= Module.new\n#{body}")).to eq(%w[A::Shop::Draft])
      expect(described_class.declared_names("module A\n  Shop, Mall = Module.new, Module.new\n#{body}")).to eq(%w[A::Shop::Draft])
      # `V1 ||=` inside module V1 finds ::V1 defined and assigns nothing.
      expect(described_class.declared_names("module V1\n  V1 ||= Module.new\n  class V1::Users; end\nend\n")).to eq(%w[V1::Users])
    end

    # Ruby: Foo.const_defined?(:M, false) is false after `M ||=` in Foo < Bar, which finds Bar::M; `class M::Y` is Bar::M::Y.
    it "reads an `||=` and a first segment against the constants of a superclass the file declares" do
      source = "class Bar\n  M = Module.new\nend\nclass Foo < Bar\n  M ||= Module.new\n  class M::Y; end\nend\n"

      expect(described_class.declared_names(source)).to eq(%w[Bar Foo Bar::M::Y])
    end
  end

  # `class ::Foo` inside `module A` declares the top-level Foo, as Ruby reads it.
  describe "a constant named from the root scope" do
    let(:source) { "module A\n  class ::Foo < Base\n    class Bar; end\n  end\n  class Baz; end\nend\n" }

    it "declares it at the top level, and what it nests under it" do
      expect(described_class.declared_names(source)).to eq(%w[Foo Foo::Bar A::Baz])
    end

    it "yields Module.nesting inside each body, innermost first" do
      tree = RailsAiContext::AstCache.parse_string("module A\n  class B; end\nend\nclass A::C; end\n").value
      expect(described_class.constants(tree).map { |name, _node, nesting| [ name, nesting ] })
        .to eq([ [ "A", %w[A] ], [ "A::B", %w[A::B A] ], [ "A::C", %w[A::C] ] ])
    end

    it "names constants the same way" do
      tree = RailsAiContext::AstCache.parse_string(source).value
      expect(described_class.constants(tree).map { |name, _node| name }).to eq(%w[A Foo Foo::Bar A::Baz])
    end
  end

  # Expected values are Ruby's Module.nesting at the include in the whole file.
  describe ".record_nesting over a walked slice" do
    def slice_nesting(source, label)
      tree = RailsAiContext::AstCache.parse_string(source).value
      node = described_class.module_nodes(tree)[label]
      walked = RailsAiContext::Introspectors::SourceIntrospector.walk_source(node.slice, { mixins: RailsAiContext::Introspectors::Listeners::MixinsListener })
      walked[:mixins].map { |mixin| described_class.record_nesting(mixin, described_class.body_nesting(tree, label, node: node), node.constant_path.slice) }
    end

    it "reads a constant nested under a rooted class from the root" do
      source = "module Shop\n  module Tagging\n    class ::Foo\n      module Foo::Bar\n        include M\n      end\n    end\n  end\nend\n"
      expect(slice_nesting(source, "Shop::Tagging")).to eq([ %w[Foo::Bar Foo Shop::Tagging Shop] ])
    end

    it "names the slice's own module as the file declares it" do
      source = "module Shop\n  module Shop::Tagging\n    include M\n    class Inner\n      include M\n    end\n  end\nend\n"
      expect(slice_nesting(source, "Shop::Tagging")).to eq([ %w[Shop::Tagging Shop], %w[Shop::Tagging::Inner Shop::Tagging Shop] ])
    end
  end

  describe ".resolve" do
    it "prefers the constant the source declares over the path" do
      source = "class ActivityPub::CollectionsController < ApplicationController\nend\n"

      expect(described_class.resolve(source, "Activitypub::CollectionsController"))
        .to eq("ActivityPub::CollectionsController")
    end

    it "reads the name through module nesting" do
      source = "module OAuth\n  class TokensController\n  end\nend\n"

      expect(described_class.resolve(source, "Oauth::TokensController")).to eq("OAuth::TokensController")
    end

    # A bare name in a namespaced directory is the shape the path exists for:
    # only the path carries the namespace, so only the path can name the class.
    it "keeps the path name when the source declares fewer segments" do
      source = "class Channel\nend\n"

      expect(described_class.resolve(source, "ApplicationCable::Channel")).to eq("ApplicationCable::Channel")
    end

    it "keeps the path name when the source declares no class" do
      source = "SOME_CONSTANT = 1\n"

      expect(described_class.resolve(source, "Admin::WidgetsController")).to eq("Admin::WidgetsController")
    end

    # Prism recovers from a syntax error into a partial tree, so a half-written
    # file still declares something. Naming the file after it would rename the
    # controller on every reader's screen.
    it "keeps the path name when the declared name is not this file's" do
      source = "class Broken < ApplicationController\n  def index\n" # never closed

      expect(described_class.resolve(source, "BrokenController")).to eq("BrokenController")
    end

    it "keeps the path name when there is no source to read" do
      expect(described_class.resolve(nil, "WidgetsController")).to eq("WidgetsController")
    end

    # An acronym in the last segment is the same defect as one in the
    # namespace: `APIController` in api_controller.rb, `CSVController` in
    # csv_controller.rb.
    it "prefers a declared name that differs from the path only by case" do
      source = "class APIController < ApplicationController\nend\n"

      expect(described_class.resolve(source, "ApiController")).to eq("APIController")
    end

    it "reads a root-scoped declaration" do
      source = "class ::ActivityPub::CollectionsController < ApplicationController\nend\n"

      expect(described_class.resolve(source, "Activitypub::CollectionsController"))
        .to eq("ActivityPub::CollectionsController")
    end

    # A file may open more than one class. Only the one Zeitwerk expects at
    # this path names the file, and it is not always written first.
    it "picks the declared class this path names, not the first one" do
      source = "class Legacy::WidgetsController\nend\n\nclass Admin::WidgetsController\nend\n"

      expect(described_class.resolve(source, "Admin::WidgetsController")).to eq("Admin::WidgetsController")
    end

    it "takes the outermost class when one is nested inside another" do
      source = "class PostsController < ApplicationController\n  class Error < StandardError\n  end\nend\n"

      expect(described_class.resolve(source, "PostsController")).to eq("PostsController")
    end
  end

  # The model and controller walks both drop a class whose name is not its
  # constant path, and they ask the same question here.
  describe ".renamed?" do
    it "is false for a class that lives at its own name" do
      expect(described_class.renamed?(String)).to be(false)
    end

    # Rails names the anonymous join class it builds for a
    # has_and_belongs_to_many through a singleton `name=`, so it answers
    # "HABTM_Tags" while it lives at "Account::HABTM_Tags".
    it "is true for a class whose name is not its constant path" do
      klass = Class.new
      stub_const("Account::HABTM_Tags", klass)
      def klass.name = "HABTM_Tags"

      expect(described_class.renamed?(klass)).to be(true)
    end

    it "is true for a class whose constant was removed" do
      klass = Class.new
      Object.const_set(:GoneClass, klass)
      Object.send(:remove_const, :GoneClass)

      expect(klass.name).to eq("GoneClass")
      expect(described_class.renamed?(klass)).to be(true)
    end

    it "is true for a class whose name another class now carries" do
      old = Class.new
      Object.const_set(:CarriedAgain, old)
      Object.send(:remove_const, :CarriedAgain)
      stub_const("CarriedAgain", Class.new)

      expect(described_class.renamed?(old)).to be(true)
      expect(described_class.renamed?(CarriedAgain)).to be(false)
    end

    it "is true for a class whose name is no constant path, and for one whose path runs through a value that is no module" do
      odd = Class.new
      def odd.name = "tmp_model"
      stub_const("NotAModule", 5)
      inner = Class.new
      def inner.name = "NotAModule::Inner"

      expect(described_class.renamed?(odd)).to be(true)
      expect(described_class.renamed?(inner)).to be(true)
    end

    it "is false for a class whose constant waits to autoload, and loads no file to ask" do
      klass = Class.new
      def klass.name = "WaitingClass"
      Object.autoload(:WaitingClass, "/nowhere/waiting_class.rb")

      expect(described_class.renamed?(klass)).to be(false)
    ensure
      Object.send(:remove_const, :WaitingClass)
    end

    it "is false for a class that answers its own constant path" do
      stub_const("Account", Class.new)

      expect(described_class.renamed?(Account)).to be(false)
    end
  end

  # One tie-break for "which of the classes this file declares is the file
  # named for". Four callers each wrote their own, and they disagreed.
  describe ".declaration_for" do
    let(:declarations) { RailsAiContext::Introspectors::DeclaredConstant.method(:declarations) }

    it "prefers the declaration the path names in full" do
      source = "class Error < StandardError; end\nclass Jobs::AnonymizeUser < Jobs::Base\nend\n"

      picked = described_class.declaration_for(declarations.call(source), "Jobs::AnonymizeUser")

      expect(picked.name).to eq("Jobs::AnonymizeUser")
      expect(picked.superclass).to eq("Jobs::Base")
    end

    it "falls back to the declaration whose last segment the path names" do
      source = "class Regular::AnonymizeUser < Jobs::Base\nend\n"

      expect(described_class.declaration_for(declarations.call(source), "Jobs::AnonymizeUser").name)
        .to eq("Regular::AnonymizeUser")
    end

    # A plugin model sits at an un-namespaced path and declares a namespaced
    # constant, so neither the path nor its last segment matches. With one
    # class in the file there is nothing else it could be named for, and
    # keying it under the path lost its superclass and dropped the model.
    it "answers the only declaration when the file declares one class" do
      source = "class ForumGithubPlugin::GithubCommit < ActiveRecord::Base\nend\n"

      picked = described_class.declaration_for(declarations.call(source), "GithubCommit")

      expect(picked.name).to eq("ForumGithubPlugin::GithubCommit")
      expect(picked.superclass).to eq("ActiveRecord::Base")
    end

    # A plugin's grant_github_badges.rb can sit at a path spelling
    # Scheduled::GrantGithubBadges and declares one class under a name that
    # shares no segment with it, so neither the path nor its last segment
    # matches and the single class is the only answer there is.
    it "answers the only declaration when its name shares no segment with the path" do
      source = "class ForumGithubPlugin::UpdateJob < ::Jobs::Scheduled\nend\n"

      picked = described_class.declaration_for(declarations.call(source), "Scheduled::GrantGithubBadges")

      expect(picked.name).to eq("ForumGithubPlugin::UpdateJob")
      expect(picked.superclass).to eq("Jobs::Scheduled")
    end

    # A class reopened with no superclass is an override or a namespace the
    # file writes something else into, not what the file is named for.
    it "answers nothing when the only class is a namespace holding a module" do
      source = "module ForumRssPolling\n  class RssFeed\n    module FindById\n    end\n  end\nend\n"

      picked = described_class.declaration_for(declarations.call(source), "ForumRssPolling::RssFeed::FindById")

      expect(picked).to be_nil
    end

    # An asset_manager/service_helper.rb can declare a module and one
    # error class inside it; the file is the module.
    it "answers nothing when the only class is nested inside the path's own constant" do
      source = "module AssetManager::ServiceHelper\n  class AssetNotFound < StandardError\n  end\nend\n"

      picked = described_class.declaration_for(declarations.call(source), "AssetManager::ServiceHelper")

      expect(picked).to be_nil
    end

    it "answers nothing when several declarations and none is named for the path" do
      source = "class Alpha; end\nclass Beta; end\n"

      expect(described_class.declaration_for(declarations.call(source), "Gamma")).to be_nil
    end
  end

  # The same pick without the single-class fallback: a concern file that nests
  # a validator class declares one class, and it is not the file's own.
  describe ".declaration_named" do
    it "answers nothing when the one declaration is not the name asked for" do
      source = "module Featurable\n  class FeaturedValidator < ActiveModel::Validator\n  end\nend\n"
      declarations = RailsAiContext::Introspectors::DeclaredConstant.declarations(source)

      expect(described_class.declaration_named(declarations, "Featurable")).to be_nil
    end
  end

  # A model, controller or concern file is asked for its declarations three
  # or four times in one run; the tree walk behind it was redone every time.
  describe "one source asked again" do
    it "walks the tree once" do
      # Its own source, so the parse cache cannot evict an entry another example made first.
      source = "# #{SecureRandom.hex(8)}\nmodule Billing\n  class Invoice < ApplicationRecord\n  end\nend\n"
      walks = 0
      allow(described_class).to receive(:constants).and_wrap_original do |original, root, **options, &block|
        walks += 1 if block
        original.call(root, **options, &block)
      end

      3.times { expect(described_class.declared_names(source)).to eq([ "Billing::Invoice" ]) }
      described_class.declarations(source) << :scratch

      expect(walks).to eq(1)
      expect(described_class.declarations(source).map(&:name)).to eq([ "Billing::Invoice" ])
    end
  end
  describe ".declarations of a Class.new assignment" do
    it "reads the class and its superclass, and skips other constant writes" do
      source = <<~RUBY
        AdminNote = Class.new(ApplicationRecord) do
          belongs_to :note
        end
        module Admin
          Flag = Class.new(::Base)
          Pin = Class.new(Flag)
        end
        Admin::Mark = Class.new(Admin::Flag)
        Plain = Class.new
        LIMIT = 5
        Other = Struct.new(:a)
      RUBY

      names = %w[AdminNote Admin::Flag Admin::Pin Admin::Mark Plain LIMIT Other]
      found = names.flat_map { |name| described_class.declarations(source, path_name: name) }.to_h { |d| [ d.name, [ d.superclass, d.nesting ] ] }

      expect(found).to eq(
        "AdminNote" => [ "ApplicationRecord", [] ],
        "Admin::Flag" => [ "Base", [] ],
        "Admin::Pin" => [ "Flag", [ "Admin" ] ],
        "Admin::Mark" => [ "Admin::Flag", [] ],
        "Plain" => [ nil, [] ]
      )
    end

    it "counts one only when the path names it, so a Class.new error constant is never taken for the file's class" do
      source = <<~RUBY
        module Tenancy
          Missing = Class.new(StandardError)
          class Current < ActiveSupport::CurrentAttributes
          end
        end
      RUBY

      expect(described_class.declarations(source).map(&:name)).to eq([ "Tenancy::Current" ])
      expect(described_class.declared_names(source)).to eq([ "Tenancy::Current" ])
      expect(described_class.declarations(source, path_name: "Tenancy::Current").map(&:name)).to eq([ "Tenancy::Current" ])
      expect(described_class.declarations(source, path_name: "Tenancy::Missing").map(&:name)).to eq([ "Tenancy::Missing", "Tenancy::Current" ])
    end
  end

  describe "a file whose only class is a Class.new assignment" do
    it "declares a class, and resolves to the name the assignment writes" do
      source = "APIKey = Class.new(ApplicationRecord) do\n  has_one_attached :photo\nend\n"

      expect(described_class.declares_class?(source, path_name: "ApiKey")).to be true
      expect(described_class.resolve(source, "ApiKey")).to eq("APIKey")
      expect(described_class.named(source, "ApiKey")).to eq("APIKey")
    end
  end

  describe "a Class.new assignment the path does not name" do
    def file_class(source, path_name)
      described_class.declaration_for(described_class.declarations(source, path_name: path_name), path_name)&.name
    end

    it "is never the file's class, and a named Class.new beats an error class statement" do
      expect(file_class("PaymentError = Class.new(StandardError)\n", "Errors")).to be_nil
      expect(file_class("Missing = Class.new(StandardError)\nclass Current < ActiveSupport::CurrentAttributes\nend\n", "Tenancy")).to eq("Current")
      expect(file_class("class ExportError < StandardError; end\nExportJob = Class.new(ApplicationJob) do\nend\n", "ExportJob")).to eq("ExportJob")
    end

    it "keeps the path test to itself" do
      expect(described_class).not_to respond_to(:path_names?)
    end

    it "never makes a mixin a class file" do
      source = "module Lockable\n  extend ActiveSupport::Concern\n  LockedError = Class.new(StandardError)\nend\n"

      expect(described_class.declares_class?(source, path_name: "Lockable")).to be false
      expect(described_class.declares_class?("module Errors\n  Base = Class.new(StandardError)\nend\n", path_name: "Errors")).to be false
    end
  end

  describe ".class_bodies of a Class.new assignment" do
    it "is the block body, under the name the assignment writes" do
      source = <<~RUBY
        module Admin
          Flag = Class.new(Base) do
            attr_config :a
          end
        end
        Plain = Class.new(Base)
      RUBY
      tree = RailsAiContext::AstCache.parse_string(source).value

      expect(described_class.class_bodies(tree, "Admin::Flag").map(&:slice)).to eq([ "attr_config :a" ])
      expect(described_class.class_bodies(tree, "Flag")).to eq([])
      expect(described_class.class_bodies(tree, "Plain")).to eq([])
    end
  end

  describe ".declarations nesting" do
    def nesting_of(source, name)
      described_class.declarations(source).find { |d| d.name == name }.nesting
    end

    it "is the Module.nesting the superclass is read in, innermost first" do
      expect(nesting_of("module Api\n  class UsersController < BaseController\n  end\nend\n", "Api::UsersController")).to eq(%w[Api])
      expect(nesting_of("class Api::UsersController < BaseController\nend\n", "Api::UsersController")).to eq([])
      expect(nesting_of("module A\n  class B::C < X\n  end\nend\n", "A::B::C")).to eq(%w[A])
    end

    it "is empty for a superclass written from the root" do
      expect(nesting_of("module Api\n  class UsersController < ::BaseController\n  end\nend\n", "Api::UsersController")).to eq([])
    end
  end
end
