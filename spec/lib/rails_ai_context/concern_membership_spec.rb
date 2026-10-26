# frozen_string_literal: true

require "spec_helper"
require "tmpdir"

RSpec.describe RailsAiContext::ConcernMembership do
  describe ".local_name" do
    def mixin_in(source)
      RailsAiContext::Introspectors::SourceIntrospector.walk_source(source, { mixins: RailsAiContext::Introspectors::Listeners::MixinsListener })[:mixins].first
    end

    let(:app) { %w[Publishable Admin::Publishable] }

    it "names an include inside a namespace by the app's module nearest to it" do
      mixin = mixin_in("module Admin\n  class Post\n    include Publishable\n  end\nend\n")

      expect(described_class.local_name(mixin, {}, exists: ->(name) { app.include?(name) })).to eq("Admin::Publishable")
    end

    it "names an include by the module exists answers with, not the spelling it tried" do
      mixin = mixin_in("module Admin\n  class Post\n    include Publishable\n  end\nend\n")
      exists = ->(name) { "Base::Publishable" if name == "Admin::Post::Publishable" }

      expect(described_class.local_name(mixin, {}, exists: exists)).to eq("Base::Publishable")
    end

    it "names an include written from the root by the top-level module" do
      mixin = mixin_in("module Admin\n  class Post\n    include ::Publishable\n  end\nend\n")

      expect(described_class.local_name(mixin, {}, exists: ->(name) { app.include?(name) })).to eq("Publishable")
    end
  end

  describe ".included_modules and .mixins_with_modules" do
    let(:modules) do
      root = RailsAiContext::AstCache.parse_string(<<~RUBY).value
        class Payment
          module B; end
          module A; end
          module Trackable; end
        end
      RUBY
      RailsAiContext::Introspectors::DeclaredConstant.module_nodes(root)
    end

    it "follows only the mixins that reach the ancestor chain" do
      mixins = [
        { name: "A", owner: [ "Payment" ], nesting: [ "Payment" ], ancestor: true, location: 9 },
        { name: "B", owner: [ "Payment", "A" ], nesting: [ "Payment::A", "Payment" ], ancestor: false, location: 9 },
        { name: "Trackable", owner: [ "Payment", "A" ], nesting: [ "Payment::A", "Payment" ], ancestor: true, location: 9 }
      ]

      expect(described_class.included_modules(mixins, "Payment", [ "Payment" ], modules)).to contain_exactly("Payment::A", "Payment::Trackable")
    end

    it "hands on a mixin whose in-file namesake is defined below the include" do
      root = RailsAiContext::AstCache.parse_string("class Project\n  include Hierarchy\nend\n\nmodule Hierarchy\nend\n").value
      modules = RailsAiContext::Introspectors::DeclaredConstant.module_nodes(root)
      mixins = [ { name: "Hierarchy", owner: [ "Project" ], ancestor: true, location: 2 } ]

      expect(described_class.mixins_with_modules(mixins, "Project", [ "Project" ], modules).map { |m| m[:name] }).to eq([ "Hierarchy" ])
    end

    it "takes no module the file defines below the include as the one included" do
      root = RailsAiContext::AstCache.parse_string("class Project\n  include Hierarchy\nend\n\nmodule Hierarchy\nend\n").value
      modules = RailsAiContext::Introspectors::DeclaredConstant.module_nodes(root)
      mixins = [ { name: "Hierarchy", owner: [ "Project" ], ancestor: true, location: 2 } ]

      expect(described_class.included_modules(mixins, "Project", [ "Project" ], modules)).to be_empty
    end

    # A module's `included do` runs at the class's include, after every module above the class exists.
    it "follows an include written inside an included module whatever its line, and a one-line file" do
      source = "module A\n  included do\n    include B\n  end\nend\n\nmodule B\nend\n\nclass Foo\n  include A\nend\n"
      modules = RailsAiContext::Introspectors::DeclaredConstant.module_nodes(RailsAiContext::AstCache.parse_string(source).value)
      mixins = [ { name: "B", owner: [ "A" ], ancestor: true, location: 3 }, { name: "A", owner: [ "Foo" ], ancestor: true, location: 11 } ]
      expect(described_class.included_modules(mixins, "Foo", [ "Foo" ], modules)).to contain_exactly("A", "B")

      one_line = RailsAiContext::Introspectors::DeclaredConstant.module_nodes(RailsAiContext::AstCache.parse_string("module A; end; class Foo; include A; end\n").value)
      expect(described_class.included_modules([ { name: "A", owner: [ "Foo" ], ancestor: true, location: 1 } ], "Foo", [ "Foo" ], one_line)).to eq([ "A" ])
    end

    it "reads a chained include against the line of the class's include that brought it in" do
      source = "module A\n  included do\n    include Tracked\n  end\nend\n\nclass Payment\n  include A\nend\n\nmodule Tracked\nend\n"
      modules = RailsAiContext::Introspectors::DeclaredConstant.module_nodes(RailsAiContext::AstCache.parse_string(source).value)
      mixins = [ { name: "Tracked", owner: [ "A" ], ancestor: true, location: 3 }, { name: "A", owner: [ "Payment" ], ancestor: true, location: 8 } ]

      expect(described_class.included_modules(mixins, "Payment", [ "Payment" ], modules)).to eq([ "A" ])
      expect(described_class.mixins_with_modules(mixins, "Payment", [ "Payment" ], modules).map { |m| m[:name] }).to eq([ "Tracked" ])
    end

    it "reads a module two includes bring in against the earlier of them" do
      source = "module C\nend\n\nmodule A\nend\n\nmodule B\nend\n\nclass Post\n  include B\nend\n\nmodule D\nend\n\nclass Post\n  include A\nend\n"
      modules = RailsAiContext::Introspectors::DeclaredConstant.module_nodes(RailsAiContext::AstCache.parse_string(source).value)
      mixins = [
        { name: "A", owner: [ "Post" ], ancestor: true, location: 18 }, { name: "B", owner: [ "Post" ], ancestor: true, location: 11 },
        { name: "C", owner: [ "A" ], ancestor: true, location: 5 }, { name: "C", owner: [ "B" ], ancestor: true, location: 8 },
        { name: "D", owner: [ "C" ], ancestor: true, location: 2 }
      ]

      [ mixins, mixins.reverse ].each do |order|
        expect(described_class.included_lines(order, "Post", [ "Post" ], modules)).to eq("A" => 18, "B" => 11, "C" => 11)
      end
    end

    it "hands on only the mixins the file does not define" do
      mixins = [
        { name: "A", owner: [ "Payment" ], nesting: [ "Payment" ], ancestor: true, location: 9 },
        { name: "Trackable", owner: [ "Payment", "A" ], nesting: [ "Payment::A", "Payment" ], ancestor: true, location: 9 },
        { name: "Auditable", owner: [ "Payment", "A" ], nesting: [ "Payment::A", "Payment" ], ancestor: true, location: 9 }
      ]

      expect(described_class.mixins_with_modules(mixins, "Payment", [ "Payment" ], modules).map { |m| m[:name] }).to eq([ "Auditable" ])
    end
  end

  describe ".owned_with_modules" do
    def walk(source)
      introspectors = RailsAiContext::Introspectors
      data = introspectors::SourceIntrospector.walk_source(
        source, { associations: introspectors::Listeners::AssociationsListener, mixins: introspectors::Listeners::MixinsListener }
      )
      tree = RailsAiContext::AstCache.parse_string(source).value
      [ data, introspectors::DeclaredConstant.declarations(source, all: true).map(&:name), introspectors::DeclaredConstant.module_nodes(tree) ]
    end

    # Module.nesting in `module Shop; class ::Order` is [Order, Shop], so `include Trackable` reaches Shop::Trackable.
    it "reads a module a root-opened class includes through the class's nesting" do
      data, classes, modules = walk(<<~RUBY)
        module Shop
          module Trackable
            extend ActiveSupport::Concern
            included do
              has_many :tracks
            end
          end

          class ::Order < ApplicationRecord
            include Trackable
            has_many :lines
          end
        end
      RUBY

      owned = described_class.owned_with_modules(data[:associations], "Order", classes, data[:mixins], modules)
      expect(owned.map { |a| a[:name] }).to contain_exactly(:lines, :tracks)
    end

    # `Shop = Class.new` declares Shop::Shop, so Module.nesting in `class Shop::Draft` is [Shop::Shop::Draft, Shop].
    it "reads a compact path's first segment against a constant written above it" do
      data, classes, modules = walk(<<~RUBY)
        module Shop
          Shop = Class.new
          class Shop::Draft < ApplicationRecord
            module Trackable
              extend ActiveSupport::Concern
              included do
                has_many :tracks
              end
            end
            include Trackable
            has_many :lines
          end
        end
      RUBY

      owned = described_class.owned_with_modules(data[:associations], "Shop::Shop::Draft", classes, data[:mixins], modules)
      expect(owned.map { |a| a[:name] }).to contain_exactly(:lines, :tracks)
    end
  end

  describe ".owned_by" do
    let(:records) { [ { name: "a", owner: [ "Payment" ] }, { name: "b", owner: [ "Legacy", "Payment" ] } ] }

    it "takes the full name first, then every segment of it" do
      expect(described_class.owned_by(records, "Legacy::Payment").map { |r| r[:name] }).to eq([ "b" ])
      expect(described_class.owned_by(records, "Payment").map { |r| r[:name] }).to eq([ "a" ])
    end

    # Inside `module Blog`, Ruby reads the receiver of `Post.include(Flaggable)` as Blog::Post, the nearer Post the file declares.
    it "gives a receiver's mixin to the nearest constant its nesting reaches, never a farther one of the same name" do
      source = "class Post < ApplicationRecord\nend\nmodule Blog\n  class Post\n  end\n  Post.include(Flaggable)\nend\n"
      mixins = RailsAiContext::Introspectors::SourceIntrospector.walk_source(source, { mixins: RailsAiContext::Introspectors::Listeners::MixinsListener })[:mixins]

      expect(described_class.owned_by(mixins, "Post", others: [ "Blog::Post" ])).to be_empty
      expect(described_class.owned_by(mixins, "Blog::Post", others: [ "Post" ]).map { |m| m[:name] }).to eq([ "Flaggable" ])
    end

    # A module read from its outer constant's file is a slice holding only its own name.
    it "reads a shorter owner for a qualified name unless that owner is another class in the file" do
      exportable = [ { name: "download", owner: [ "Exportable" ] } ]
      payment = [ { name: "amount", owner: [ "Payment" ] } ]

      expect(described_class.owned_by(exportable, "Posts::Exportable").map { |r| r[:name] }).to eq([ "download" ])
      expect(described_class.owned_by(payment, "Legacy::Payment", others: [ "Payment" ])).to be_empty
    end
  end

  describe ".payload?" do
    it "keeps app concerns and gem capability modules, namespaced or not" do
      expect(described_class.payload?("Searchable")).to be(true)
      expect(described_class.payload?("Billing::Chargeable")).to be(true)
      expect(described_class.payload?("Discard::Model")).to be(true)
    end

    it "hides the noisy gem families through the default config, tunably" do
      expect(described_class.payload?("Devise::Models::Recoverable")).to be(false)

      original = RailsAiContext.configuration.excluded_concerns
      RailsAiContext.configuration.excluded_concerns = []
      expect(described_class.payload?("Devise::Models::Recoverable")).to be(true)
    ensure
      RailsAiContext.configuration.excluded_concerns = original
    end

    it "drops the stdlib and framework plumbing" do
      expect(described_class.payload?(nil)).to be(false)
      expect(described_class.payload?("Kernel")).to be(false)
      expect(described_class.payload?("JSON")).to be(false)
      expect(described_class.payload?("ActiveRecord::Timestamp")).to be(false)
      expect(described_class.payload?("ActiveSupport::Callbacks")).to be(false)
      expect(described_class.payload?("ActionController::MimeResponds")).to be(false)
      expect(described_class.payload?("AbstractController::Rendering")).to be(false)
      expect(described_class.payload?("Rails::Engine::LazyRouteSet::MountedHelpers")).to be(false)
    end

    it "drops the modules Rails generates inside the class" do
      expect(described_class.payload?("Post::GeneratedAssociationMethods")).to be(false)
      expect(described_class.payload?("GeneratedAttributeMethods")).to be(false)
    end

    it "honours excluded_concerns" do
      original = RailsAiContext.configuration.excluded_concerns
      RailsAiContext.configuration.excluded_concerns = [ /\AAudit/ ]
      expect(described_class.payload?("Auditable")).to be(false)
      expect(described_class.payload?("Searchable")).to be(true)
    ensure
      RailsAiContext.configuration.excluded_concerns = original
    end
  end

  describe ".from_mixins" do
    it "keeps only ancestor-reaching mixins, through the payload rule" do
      mixins = [
        { macro: :include, name: "Searchable", ancestor: true },
        { macro: :extend, name: "ClassLevel", ancestor: false },
        { macro: :include, name: "ActiveSupport::Callbacks", ancestor: true },
        { macro: :include, name: "Searchable", ancestor: true }
      ]

      expect(described_class.from_mixins(mixins)).to eq(%w[Searchable])
    end
  end

  describe ".app_owned" do
    it "keeps the concerns the app has a file for" do
      Dir.mktmpdir do |root|
        FileUtils.mkdir_p(File.join(root, "app", "models", "concerns"))
        File.write(File.join(root, "app", "models", "concerns", "searchable.rb"), "module Searchable\nend\n")

        names = %w[Searchable Devise::Models::Recoverable]
        expect(described_class.app_owned(names, root)).to eq(%w[Searchable])
      end
    end
  end

  # The walk asks the two halves of the payload rule apart: a name the key hid
  # is worth counting, and framework plumbing never was.
  describe ".candidate?" do
    around do |example|
      original = RailsAiContext.configuration.excluded_concerns
      RailsAiContext.configuration.excluded_concerns = [ /\AAudit/ ]
      example.run
      RailsAiContext.configuration.excluded_concerns = original
    end

    it "keeps a name the configured key hides" do
      expect(described_class.candidate?("Auditable")).to be true
      expect(described_class.payload?("Auditable")).to be false
    end

    it "drops framework plumbing, the stdlib and the generated modules" do
      expect(described_class.candidate?("ActiveRecord::Core")).to be false
      expect(described_class.candidate?("Kernel")).to be false
      # A helper can include it, and a reader cannot read the stdlib.
      expect(described_class.candidate?("ERB::Util")).to be false
      expect(described_class.candidate?("Post::GeneratedAttributeMethods")).to be false
    end
  end

  # An app's lib/active_record_like_interface.rb is the app's own: a
  # default matched it because `ActiveRecord` had no namespace boundary.
  describe "the default excluded_concerns" do
    def excluded?(name)
      RailsAiContext::Configuration::DEFAULT_EXCLUDED_CONCERNS.any? { |pattern| name.match?(pattern) }
    end

    it "hides a framework or gem namespace and what sits under it" do
      %w[ActiveRecord ActiveRecord::Core ActiveModel::Validations ActionView::Helpers AbstractController::Callbacks
         Devise::Models::Confirmable Turbo::Broadcastable GlobalID::Identification Rolify::Role
         DEBUGGER__::TrapInterceptor Post::GeneratedAssociationMethods Post::GeneratedAttributeMethods].each do |name|
        expect(excluded?(name)).to be(true), name
      end
    end

    it "leaves an app module whose name only starts like one" do
      %w[ActiveRecordLikeInterface ActiveStorageUploads ActionTextFormatter AbstractControllerHelper
         Devise::ModelsExtra TurboStreamable Reports::GeneratedReport GeneratedAt].each do |name|
        expect(excluded?(name)).to be(false), name
      end
    end
  end
end
