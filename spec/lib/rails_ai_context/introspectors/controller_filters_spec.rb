# frozen_string_literal: true

require "spec_helper"
require "tmpdir"
require "fileutils"

RSpec.describe RailsAiContext::Introspectors::ControllerFilters do
  describe ".with_concerns" do
    def concern(dir, name, body)
      File.write(File.join(dir, "app", "controllers", "concerns", "#{name.underscore}.rb"), <<~RUBY)
        module #{name}
          extend ActiveSupport::Concern
          #{body}
        end
      RUBY
    end

    # Ruby adds a module to the ancestors once, where it is first included,
    # so a concern reached through two includes runs its filters once.
    it "adds a concern reached through two includes once, at its first include" do
      Dir.mktmpdir do |dir|
        FileUtils.mkdir_p(File.join(dir, "app", "controllers", "concerns"))
        concern(dir, "AccountLookup", "included do\n    before_action :set_account\n  end")
        concern(dir, "Owned", "include AccountLookup\n  included do\n    before_action :check_owner\n  end")
        source = <<~RUBY
          class PostsController < ApplicationController
            include Owned
            before_action :authenticate!
            include AccountLookup
          end
        RUBY

        filters, unread = described_class.with_concerns(source, root: dir, within: "PostsController")

        expect(filters.map { |f| [ f[:name], f[:from_concern] ] })
          .to eq([ [ "set_account", "AccountLookup" ], [ "check_owner", "Owned" ], [ "authenticate!", nil ] ])
        expect(unread).to eq([])
      end
    end

    # The block opens in the method's file; the expansion re-reads the method's body on its own.
    it "names a block a class method declares by its line in the file that defines the method, and that file when it is not the class's" do
      Dir.mktmpdir do |dir|
        FileUtils.mkdir_p(File.join(dir, "app", "controllers", "concerns"))
        concern(dir, "CacheConcern", <<~BODY.strip)
          class_methods do
              def vary_by(value, **kwargs)
                before_action(**kwargs) do
                  response.headers["Vary"] = value
                end
              end
            end
        BODY
        source = <<~RUBY
          class PostsController < ApplicationController
            include CacheConcern
            def self.timed(**options)
              around_action(**options) do |_controller, action|
                action.call
              end
            end
            vary_by "Accept"
            timed only: :index
          end
        RUBY

        filters, = described_class.with_concerns(source, root: dir, within: "PostsController")

        expect(filters.map { |f| [ f[:kind], f[:name], f[:only] ] })
          .to eq([ [ "before", "block (line 5 of app/controllers/concerns/cache_concern.rb)", nil ], [ "around", "block (line 4)", [ "index" ] ] ])
      end
    end

    it "names a block a module nested in the controller's file declares by its line in that file, once" do
      Dir.mktmpdir do |dir|
        FileUtils.mkdir_p(File.join(dir, "app", "controllers", "concerns"))
        source = <<~RUBY
          class WidgetsController < ApplicationController
            module Gate
              extend ActiveSupport::Concern

              included do
                x = 1
                y = 2
                before_action { head :forbidden }
              end

              class_methods do
                def gate(**opts)
                  before_action(**opts) { head :forbidden }
                end
              end
            end

            include Gate
            gate only: :show
          end
        RUBY
        File.write(File.join(dir, "app", "controllers", "widgets_controller.rb"), source)

        filters, = described_class.with_concerns(source, root: dir, within: "WidgetsController")

        expect(filters.map { |f| [ f[:name], f[:only], f[:from_concern] ] })
          .to eq([ [ "block (line 8)", nil, "WidgetsController::Gate" ], [ "block (line 13)", [ "show" ], nil ] ])
      end
    end

    # Mastodon registers the acronym ActivityPub, so its base sits in activitypub/, not activity_pub/.
    it "follows a base whose directory an app acronym spells" do
      Dir.mktmpdir do |dir|
        FileUtils.mkdir_p(File.join(dir, "app", "controllers", "concerns"))
        FileUtils.mkdir_p(File.join(dir, "app", "controllers", "activitypub"))
        concern(dir, "CacheConcern", <<~BODY.strip)
          class_methods do
              def vary_by(value, **kwargs)
                before_action(**kwargs) { response.headers["Vary"] = value }
              end
            end
        BODY
        File.write(File.join(dir, "app", "controllers", "application_controller.rb"),
                   "class ApplicationController < ActionController::Base\n  include CacheConcern\nend\n")
        File.write(File.join(dir, "app", "controllers", "activitypub", "base_controller.rb"),
                   "class ActivityPub::BaseController < ApplicationController\nend\n")
        source = "class ActivityPub::OutboxesController < ActivityPub::BaseController\n  vary_by \"Signature\"\nend\n"

        filters, = described_class.with_concerns(source, root: dir, within: "ActivityPub::OutboxesController")

        expect(filters.map { |f| f[:name] }).to eq([ "block (line 5 of app/controllers/concerns/cache_concern.rb)" ])
      end
    end

    it "expands a class method of a module nested in a concern once, at its line in the concern's file" do
      Dir.mktmpdir do |dir|
        FileUtils.mkdir_p(File.join(dir, "app", "controllers", "concerns"))
        concern(dir, "SubGate", <<~BODY.strip)
          module Inner
              extend ActiveSupport::Concern

              class_methods do
                def inner_gate(**opts)
                  before_action(**opts) { head :forbidden }
                end
              end
            end

            include Inner
        BODY
        source = <<~RUBY
          class GadgetsController < ApplicationController
            include SubGate
            inner_gate only: :index
          end
        RUBY

        filters, = described_class.with_concerns(source, root: dir, within: "GadgetsController")

        expect(filters.map { |f| [ f[:name], f[:only] ] })
          .to eq([ [ "block (line 8 of app/controllers/concerns/sub_gate.rb)", [ "index" ] ] ])
      end
    end

    # Mastodon: WebAppControllerConcern's included block calls vary_by, which CacheConcern gives ApplicationController.
    it "reads a base's class method an included concern's block calls, where that concern is included" do
      Dir.mktmpdir do |dir|
        FileUtils.mkdir_p(File.join(dir, "app", "controllers", "concerns"))
        concern(dir, "CacheConcern", <<~BODY.strip)
          class_methods do
              def vary_by(value, **kwargs)
                before_action(**kwargs) { response.headers["Vary"] = value }
              end
            end
        BODY
        concern(dir, "WebApp", "included do\n    vary_by \"Accept\"\n    before_action :set_referer\n  end")
        File.write(File.join(dir, "app", "controllers", "application_controller.rb"),
                   "class ApplicationController < ActionController::Base\n  include CacheConcern\nend\n")
        source = <<~RUBY
          class PostsController < ApplicationController
            before_action :authenticate!
            include WebApp
            vary_by "Cookie", only: :show
          end
        RUBY

        filters, = described_class.with_concerns(source, root: dir, within: "PostsController")

        block = "block (line 5 of app/controllers/concerns/cache_concern.rb)"
        expect(filters.map { |f| [ f[:name], f[:from_concern], f[:only] ] })
          .to eq([ [ "authenticate!", nil, nil ], [ block, "WebApp", nil ], [ "set_referer", "WebApp", nil ], [ block, nil, [ "show" ] ] ])
      end
    end

    # Decidim's NeedsOrganization: the hook hands its base to a method that class_evals the filter onto it.
    it "reads a filter a mixin hook adds through a method it hands the including class to" do
      Dir.mktmpdir do |dir|
        FileUtils.mkdir_p(File.join(dir, "app", "controllers", "concerns"))
        File.write(File.join(dir, "app", "controllers", "concerns", "needs_organization.rb"), <<~RUBY)
          module NeedsOrganization
            def self.enhance_controller(instance_or_module)
              instance_or_module.class_eval do
                before_action :verify_organization
              end
            end

            def self.included(base)
              enhance_controller(base)
            end
          end
        RUBY
        source = "class PagesController < ApplicationController\n  include NeedsOrganization\nend\n"

        filters, = described_class.with_concerns(source, root: dir, within: "PagesController")

        expect(filters.map { |f| [ f[:name], f[:from_concern] ] }).to eq([ [ "verify_organization", "NeedsOrganization" ] ])
      end
    end

    # A macro inside a `def` runs when the method runs: never for a method nobody
    # calls, and with the call's options where the body calls it.
    it "reads a filter inside a method only where the class calls the method" do
      Dir.mktmpdir do |dir|
        FileUtils.mkdir_p(File.join(dir, "app", "controllers", "concerns"))
        source = <<~RUBY
          class PostsController < ApplicationController
            def self.public_actions(*names) = skip_before_action(:authenticate!, only: names)
            def self.unused = skip_before_action(:audit)
            def helper = before_action(:never)

            before_action :authenticate!
            public_actions :index, :show
          end
        RUBY

        filters, = described_class.with_concerns(source, root: dir, within: "PostsController")

        expect(filters.map { |f| [ f[:name], f[:skipped], f[:only] ] })
          .to eq([ [ "authenticate!", nil, nil ], [ "authenticate!", true, %w[index show] ] ])
        expect(described_class.from_source(source).map { |f| f[:name] }).to eq([ "authenticate!" ])
      end
    end
  end
  describe ".from_source" do
    it "marks a filter declared only under a condition with it" do
      filters = described_class.from_source(<<~RUBY)
        class ApplicationController < ActionController::Base
          before_action :clear_js_env if Rails.env.test?
          if Rails.env.development?
            before_action :dev_banner, if: :html?
          end
          before_action :require_user
        end
      RUBY

      expect(filters.map { |f| [ f[:name], f[:condition], f[:if] ] }).to eq(
        [ [ "clear_js_env", "if Rails.env.test?", nil ], [ "dev_banner", "if Rails.env.development?", :html? ], [ "require_user", nil, nil ] ]
      )
    end

    # actionpack's callbacks.rb defines every one of these, and a block or a
    # lambda becomes a callback of its own beside the names the call gives.
    it "reads every filter macro Rails defines, each name a call gives, and a block filter" do
      source = <<~RUBY
        class UsersController < ApplicationController
          prepend_after_action :pa
          prepend_around_action :par
          append_around_action :aar
          before_action :load_user, :audit
          before_action(only: :index) { |c| c.head(:forbidden) unless c.request.local? }
          after_action -> { log }, except: :index
        end
      RUBY

      expect(described_class.from_source(source).map { |f| [ f[:kind], f[:name], f[:only] || f[:except] ] })
        .to eq([ [ "after", "pa", nil ], [ "around", "par", nil ], [ "around", "aar", nil ],
                 [ "before", "load_user", nil ], [ "before", "audit", nil ],
                 [ "before", "block (line 6)", [ "index" ] ], [ "after", "block (line 7)", [ "index" ] ] ])
    end

    # callbacks.rb _insert_callbacks: the positional callbacks in order, then the block.
    it "lists a call's callbacks in argument order, the block last" do
      source = "class C < ApplicationController\n  before_action -> { x }, :a, -> { y }, :b do end\nend\n"

      expect(described_class.from_source(source).map { |f| f[:name] })
        .to eq([ "block (line 2)", "a", "block (line 2)", "b", "block (line 2)" ])
    end

    it "keeps a filter that shares a line with a def or follows a delegation" do
      expect(described_class.from_source("class C < ApplicationController; def index; end; before_action :x; end").map { |f| f[:name] })
        .to eq([ "x" ])
      expect(described_class.from_source("class C < ApplicationController\n  before_action :a; def index = head(:ok)\nend\n").map { |f| f[:name] })
        .to eq([ "a" ])
      expect(described_class.from_source("class C < ApplicationController\n  delegate :x, to: :y; before_action :b\nend\n").map { |f| f[:name] })
        .to eq([ "b" ])
      expect(described_class.from_source("class C < ApplicationController; def index; before_action :c; end; end")).to eq([])
    end

    # request_forgery_protection.rb: `skip_before_action :verify_authenticity_token, options.reverse_merge(raise: false)`.
    it "reads skip_forgery_protection as the skip of verify_authenticity_token it is" do
      source = "class WebhooksController < ApplicationController\n  skip_forgery_protection only: :create\nend\n"

      expect(described_class.from_source(source))
        .to eq([ { name: "verify_authenticity_token", kind: "before", skipped: true, only: [ "create" ] } ])
    end
  end

  # cancancan's controller_additions.rb and acts_as_tenant's controller
  # extensions add callbacks under their own macro names.
  describe "filters a gem's macro adds" do
    it "reads cancancan's and acts_as_tenant's macros as the callbacks they add" do
      source = <<~RUBY
        class PostsController < ApplicationController
          set_current_tenant_by_subdomain(:account, :subdomain)
          load_and_authorize_resource
          authorize_resource :comment, prepend: true, except: :index
          check_authorization
          skip_authorization_check only: :index
          def index; end
        end
      RUBY

      expect(described_class.from_source(source)).to eq([
        { name: "find_tenant_by_subdomain", kind: "before", declared: true },
        { name: "load_and_authorize_resource", kind: "before", declared: true },
        { name: "authorize_resource", kind: "before", declared: true, except: [ "index" ] },
        { name: "check_authorization", kind: "after", declared: true },
        { name: "skip_authorization_check", kind: "before", declared: true, only: [ "index" ] }
      ])
    end
  end
end
