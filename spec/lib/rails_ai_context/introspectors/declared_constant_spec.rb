# frozen_string_literal: true

require "spec_helper"

RSpec.describe RailsAiContext::Introspectors::DeclaredConstant do
  # A file that declares only a module names a constant too, and the path
  # camelization is wrong for it in exactly the way it is wrong for a class:
  # an app inflection only changes case.
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

    it "prefers a declared class over a declared module" do
      source = "module Wrapper\nend\nclass Widget\nend\n"

      expect(described_class.resolve(source, "Widget")).to eq("Widget")
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
      source = "class DiscourseGithubPlugin::GithubCommit < ActiveRecord::Base\nend\n"

      picked = described_class.declaration_for(declarations.call(source), "GithubCommit")

      expect(picked.name).to eq("DiscourseGithubPlugin::GithubCommit")
      expect(picked.superclass).to eq("ActiveRecord::Base")
    end

    # discourse-github's grant_github_badges.rb sits at a path spelling
    # Scheduled::GrantGithubBadges and declares one class under a name that
    # shares no segment with it, so neither the path nor its last segment
    # matches and the single class is the only answer there is.
    it "answers the only declaration when its name shares no segment with the path" do
      source = "class DiscourseGithubPlugin::UpdateJob < ::Jobs::Scheduled\nend\n"

      picked = described_class.declaration_for(declarations.call(source), "Scheduled::GrantGithubBadges")

      expect(picked.name).to eq("DiscourseGithubPlugin::UpdateJob")
      expect(picked.superclass).to eq("Jobs::Scheduled")
    end

    # A class reopened with no superclass is an override or a namespace the
    # file writes something else into, not what the file is named for.
    it "answers nothing when the only class is a namespace holding a module" do
      source = "module DiscourseRssPolling\n  class RssFeed\n    module FindById\n    end\n  end\nend\n"

      picked = described_class.declaration_for(declarations.call(source), "DiscourseRssPolling::RssFeed::FindById")

      expect(picked).to be_nil
    end

    # whitehall's asset_manager/service_helper.rb declares a module and one
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
      source = "module Billing\n  class Invoice < ApplicationRecord\n  end\nend\n"
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

      found = described_class.declarations(source, assignments: true).to_h { |d| [ d.name, [ d.superclass, d.nesting ] ] }

      expect(found).to eq(
        "AdminNote" => [ "ApplicationRecord", [] ],
        "Admin::Flag" => [ "Base", [] ],
        "Admin::Pin" => [ "Flag", [ "Admin" ] ],
        "Admin::Mark" => [ "Admin::Flag", [] ],
        "Plain" => [ nil, [] ]
      )
    end

    it "leaves them out by default, so a Class.new error constant is never taken for the file's class" do
      source = <<~RUBY
        module Tenancy
          Missing = Class.new(StandardError)
          class Current < ActiveSupport::CurrentAttributes
          end
        end
      RUBY

      expect(described_class.declarations(source).map(&:name)).to eq([ "Tenancy::Current" ])
      expect(described_class.declared_names(source)).to eq([ "Tenancy::Current" ])
      expect(described_class.declarations(source, assignments: true).map(&:name)).to eq([ "Tenancy::Missing", "Tenancy::Current" ])
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
