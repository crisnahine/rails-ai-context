# frozen_string_literal: true

require "spec_helper"
require "tmpdir"
require "fileutils"

# What a class declares through its bases, its concerns and the class methods it calls, booted and
# static. Each app is written to disk for the static tier and loaded into this process, where Rails
# reflection says what the class really declares; every tier must agree with it.
RSpec.describe "What a class declares, booted and static" do
  around do |example|
    tops = %i[Tracker Shop]
    tops.each { |top| raise "already defined: #{top}" if Object.const_defined?(top, false) }

    Dir.mktmpdir("class-declarations-tiers") do |dir|
      @dir = dir
      example.run
    ensure
      tops.each { |top| Object.send(:remove_const, top) if Object.const_defined?(top, false) }
    end
  end

  def app(files)
    @paths = {}
    files.each do |relative, source|
      path = File.join(@dir, relative)
      FileUtils.mkdir_p(File.dirname(path))
      File.write(path, source)
      TOPLEVEL_BINDING.eval(source, path) unless relative.start_with?("config/", "Gemfile")
      RailsAiContext::Introspectors::DeclaredConstant.declarations(source, all: true).each { |d| @paths[d.name] ||= path }
    end
    RailsAiContext::StaticApp.new(@dir)
  end

  def static_models(static) = RailsAiContext::Introspectors::ModelIntrospector.new(static).static_call

  def booted_model(static, klass)
    introspector = RailsAiContext::Introspectors::ModelIntrospector.new(static)
    allow(introspector).to receive(:model_source_path) { |model| @paths[model.name] }
    introspector.send(:extract_model_details, klass)
  end

  # The chain as `--no-boot` answers it: the static tier places what the source declares.
  def static_chain(static, name, action)
    previous = RailsAiContext.tier
    RailsAiContext.tier = :static
    payload = RailsAiContext::Introspectors::ControllerIntrospector.new(static).static_call
    RailsAiContext::ActionFilters.for({ controllers: payload }, name, action, root: @dir)[:chain].map { |filter| filter[:name] }
  ensure
    RailsAiContext.tier = previous
  end

  # What the app's classes add: an app on load_defaults gives ActionController::Base its forgery protection callbacks.
  def booted_chain(klass) = filter_names(klass) - filter_names(ActionController::Base)

  def filter_names(klass) = klass._process_action_callbacks.map { |callback| callback.filter.to_s }

  let(:store) do
    {
      "app/controllers/concerns/tracker/authentication.rb" => <<~RUBY,
        module Tracker
          module Authentication
            extend ActiveSupport::Concern
            included do
              before_action :require_login
              after_action :track
            end
          end
        end
      RUBY
      "app/controllers/tracker/store_controller.rb" => <<~RUBY
        module Tracker
          class StoreController < ActionController::Base
            include Authentication
            before_action :set_locale
          end
        end
      RUBY
    }
  end

  it "puts a filter declared with prepend: true at the head of the chain, as Rails does" do
    static = app(store.merge(
                   "app/controllers/concerns/tracker/tenant_scoped.rb" => <<~RUBY,
                     module Tracker
                       module TenantScoped
                         extend ActiveSupport::Concern
                         included do
                           before_action :tenant_first, prepend: true
                         end
                       end
                     end
                   RUBY
                   "app/controllers/tracker/gadgets_controller.rb" => <<~RUBY
                     module Tracker
                       class GadgetsController < StoreController
                         include TenantScoped
                         before_action :g1
                         before_action :g0, prepend: true
                         after_action :ga, prepend: true
                         def index; end
                       end
                     end
                   RUBY
                 ))

    booted = booted_chain(Tracker::GadgetsController)
    expect(booted).to eq(%w[ga g0 tenant_first require_login track set_locale g1])
    expect(static_chain(static, "Tracker::GadgetsController", "index")).to eq(booted)
  end

  it "runs a concern a parent already included only once, so a skip between them holds" do
    static = app(store.merge(
                   "app/controllers/tracker/admin_controller.rb" => <<~RUBY,
                     module Tracker
                       class AdminController < StoreController
                         skip_after_action :track
                       end
                     end
                   RUBY
                   "app/controllers/tracker/settings_controller.rb" => <<~RUBY
                     module Tracker
                       class SettingsController < AdminController
                         include Authentication
                         def update; end
                       end
                     end
                   RUBY
                 ))

    booted = booted_chain(Tracker::SettingsController)
    expect(booted).to eq(%w[require_login set_locale])
    expect(static_chain(static, "Tracker::SettingsController", "update")).to eq(booted)
  end

  # Ruby reads `AdminController::Base` inside AdminController's superclass when AdminController holds no Base.
  it "follows a superclass written through a class whose own superclass holds it" do
    static = app(
      "app/controllers/tracker/panel_controller.rb" => "module Tracker\n  class PanelController < ActionController::Base\n  end\nend\n",
      "app/controllers/tracker/panel_controller/base.rb" =>
        "module Tracker\n  class PanelController\n    class Base < ActionController::Base\n      before_action :from_base\n    end\n  end\nend\n",
      "app/controllers/tracker/admin_controller.rb" => "module Tracker\n  class AdminController < PanelController\n  end\nend\n",
      "app/controllers/tracker/gadgets_controller.rb" =>
        "module Tracker\n  class GadgetsController < AdminController::Base\n    before_action :own\n    def index; end\n  end\nend\n"
    )

    expect(Tracker::GadgetsController.superclass.name).to eq("Tracker::PanelController::Base")
    booted = booted_chain(Tracker::GadgetsController)
    expect(booted).to eq(%w[from_base own])
    expect(static_chain(static, "Tracker::GadgetsController", "index")).to eq(booted)
  end

  it "follows a rooted superclass written through a class whose own superclass holds it" do
    static = app(
      "app/controllers/tracker/panel_controller.rb" => "module Tracker\n  class PanelController < ActionController::Base\n  end\nend\n",
      "app/controllers/tracker/panel_controller/base.rb" =>
        "module Tracker\n  class PanelController\n    class Base < ActionController::Base\n      before_action :from_base\n    end\n  end\nend\n",
      "app/controllers/tracker/admin_controller.rb" => "module Tracker\n  class AdminController < PanelController\n  end\nend\n",
      "app/controllers/tracker/gadgets_controller.rb" =>
        "module Tracker\n  class GadgetsController < ::Tracker::AdminController::Base\n    before_action :own\n    def index; end\n  end\nend\n"
    )

    expect(Tracker::GadgetsController.superclass.name).to eq("Tracker::PanelController::Base")
    booted = booted_chain(Tracker::GadgetsController)
    expect(booted).to eq(%w[from_base own])
    expect(static_chain(static, "Tracker::GadgetsController", "index")).to eq(booted)
    payload = RailsAiContext::Introspectors::ControllerIntrospector.new(static).static_call
    parent = payload[:controllers]["Tracker::GadgetsController"][:parent_class]
    expect(RailsAiContext::Introspectors::ActionResolver.resolve_entry_name(payload[:controllers], parent, "Tracker::GadgetsController"))
      .to eq(Tracker::GadgetsController.superclass.name)
  end

  # Ruby reads the head of `Shop::BaseController` from the class's nesting before the top level.
  it "reads a qualified superclass's head from the nesting before the top level" do
    static = app(
      "app/controllers/shop/base_controller.rb" => "module Shop\n  class BaseController < ActionController::Base\n    before_action :top_gate\n  end\nend\n",
      "app/controllers/tracker/shop/base_controller.rb" =>
        "module Tracker\n  module Shop\n    class BaseController < ActionController::Base\n      before_action :nested_gate\n    end\n  end\nend\n",
      "app/controllers/tracker/gadgets_controller.rb" =>
        "module Tracker\n  class GadgetsController < Shop::BaseController\n    def index; end\n  end\nend\n"
    )

    expect(Tracker::GadgetsController.superclass.name).to eq("Tracker::Shop::BaseController")
    booted = booted_chain(Tracker::GadgetsController)
    expect(booted).to eq(%w[nested_gate])
    expect(static_chain(static, "Tracker::GadgetsController", "index")).to eq(booted)
    payload = RailsAiContext::Introspectors::ControllerIntrospector.new(static).static_call
    parent = payload[:controllers]["Tracker::GadgetsController"][:parent_class]
    expect(RailsAiContext::Introspectors::ActionResolver.resolve_entry_name(payload[:controllers], parent, "Tracker::GadgetsController"))
      .to eq(Tracker::GadgetsController.superclass.name)
  end

  # Ruby reads `AdminController::Tools` inside AdminController's superclass when AdminController holds no Tools.
  it "reads a concern named through a class whose own superclass holds it" do
    static = app(
      "app/controllers/tracker/panel_controller.rb" => "module Tracker\n  class PanelController < ActionController::Base\n  end\nend\n",
      "app/controllers/tracker/panel_controller/tools.rb" =>
        "module Tracker\n  class PanelController\n    module Tools\n      extend ActiveSupport::Concern\n      included do\n        before_action :tooled\n      end\n    end\n  end\nend\n",
      "app/controllers/tracker/admin_controller.rb" => "module Tracker\n  class AdminController < PanelController\n  end\nend\n",
      "app/controllers/tracker/gadgets_controller.rb" =>
        "module Tracker\n  class GadgetsController < ActionController::Base\n    include AdminController::Tools\n    def index; end\n  end\nend\n"
    )

    booted = booted_chain(Tracker::GadgetsController)
    expect(booted).to eq(%w[tooled])
    expect(static_chain(static, "Tracker::GadgetsController", "index")).to eq(booted)
  end

  # A plain module's self.included runs on every include, so a subclass including it again re-adds its filter
  # at the end; a Concern's included block runs once.
  it "runs a plain module's included hook on each include, a Concern's block once" do
    static = app(
      "app/controllers/concerns/tracker/hooky.rb" => "module Tracker\n  module Hooky\n    def self.included(base)\n      base.before_action :hooked\n    end\n  end\nend\n",
      "app/controllers/concerns/tracker/conc.rb" =>
        "module Tracker\n  module Conc\n    extend ActiveSupport::Concern\n    included do\n      before_action :conc\n    end\n  end\nend\n",
      "app/controllers/tracker/store_controller.rb" => "module Tracker\n  class StoreController < ActionController::Base\n    include Hooky\n    include Conc\n  end\nend\n",
      "app/controllers/tracker/admin_controller.rb" =>
        "module Tracker\n  class AdminController < StoreController\n    include Hooky\n    include Conc\n    def index; end\n  end\nend\n"
    )

    expect(booted_chain(Tracker::StoreController)).to eq(%w[hooked conc])
    booted = booted_chain(Tracker::AdminController)
    expect(booted).to eq(%w[conc hooked])
    expect(static_chain(static, "Tracker::AdminController", "index")).to eq(booted)
  end

  it "lists validations base first, in the order Rails runs them, on both tiers" do
    static = app(
      "app/models/concerns/tracker/sluggy.rb" =>
        "module Tracker\n  module Sluggy\n    extend ActiveSupport::Concern\n    included do\n      validates :slug, presence: true\n    end\n  end\nend\n",
      "app/models/tracker/record.rb" =>
        "module Tracker\n  class Record < ActiveRecord::Base\n    self.abstract_class = true\n    validates :title, presence: true\n    validate :base_check\n  end\nend\n",
      "app/models/tracker/note.rb" =>
        "module Tracker\n  class Note < Record\n    self.table_name = \"posts\"\n    validates :body, presence: true\n    include Sluggy\n    validate :custom\n  end\nend\n"
    )
    validators = Tracker::Note.validators.map { |validator| validator.attributes.map(&:to_s) }
    expect(validators).to eq([ %w[title], %w[body], %w[slug] ])
    custom = Tracker::Note._validate_callbacks.map(&:filter).grep(Symbol).map(&:to_s) - Tracker::Record.superclass._validate_callbacks.map(&:filter).grep(Symbol).map(&:to_s)
    expect(custom).to eq(%w[base_check custom])

    [ booted_model(static, Tracker::Note), static_models(static)["Tracker::Note"] ].each do |model|
      expect(model[:validations].reject { |v| v[:kind] == "custom" }.map { |v| v[:attributes] }).to eq(validators)
      expect(model[:custom_validates]).to eq(custom)
    end
  end

  it "leaves to an anonymous class what a block it is built with declares" do
    static = app(
      "app/models/concerns/tracker/detailed.rb" => <<~RUBY,
        module Tracker
          module Detailed
            extend ActiveSupport::Concern
            class_methods do
              def has_detail(name)
                detail_class
                has_one name, class_name: "Tracker::Detail"
              end

              private

              def detail_class
                Class.new(ActiveRecord::Base) do
                  belongs_to :owner
                end
              end
            end
          end
        end
      RUBY
      "app/models/tracker/holder.rb" => <<~RUBY
        module Tracker
          class Holder < ActiveRecord::Base
            self.table_name = "posts"
            include Detailed
            has_detail :extra
          end
        end
      RUBY
    )

    reflected = Tracker::Holder.reflect_on_all_associations.map { |a| a.name.to_s }
    expect(reflected).to eq(%w[extra])
    expect(static_models(static)["Tracker::Holder"][:associations].map { |a| a[:name].to_s }).to eq(reflected)
  end

  it "names the polymorphic role a has_many or has_one fills, on both tiers" do
    static = app(
      "app/models/tracker/writer.rb" => <<~RUBY
        module Tracker
          class Writer < ActiveRecord::Base
            self.table_name = "users"
            has_many :comments, as: :author
            has_one :badge, as: :holder
            has_many :posts
          end
        end
      RUBY
    )
    reflected = Tracker::Writer.reflect_on_all_associations.to_h { |a| [ a.name.to_s, a.options[:as]&.to_s ] }
    expect(reflected).to eq("comments" => "author", "badge" => "holder", "posts" => nil)

    [ booted_model(static, Tracker::Writer), static_models(static)["Tracker::Writer"] ].each do |model|
      expect(model[:associations].to_h { |a| [ a[:name].to_s, a[:as] ] }).to eq(reflected)
    end
  end

  it "reads the prefix and suffix a table name interpolates from the superclass chain, as Rails does" do
    static = app(
      "app/models/shop/record.rb" => "module Shop\n  class Record < ActiveRecord::Base\n    self.abstract_class = true\n    self.table_name_prefix = \"s_\"\n    self.table_name_suffix = \"_v2\"\n  end\nend\n",
      "app/models/shop/thing.rb" => "module Shop\n  class Thing < Record\n    self.table_name = \"\#{table_name_prefix}things\#{table_name_suffix}\"\n  end\nend\n"
    )

    expect(Shop::Thing.table_name).to eq("s_things_v2")
    expect(static_models(static)["Shop::Thing"][:table_name]).to eq("s_things_v2")
  end

  it "lists a base macro called with arguments it cannot bind as a computed association, not a conditional one" do
    static = app(
      "app/models/shop/record.rb" => "module Shop\n  class Record < ActiveRecord::Base\n    self.abstract_class = true\n    def self.has_notes(name) = has_many(name, as: :notable)\n  end\nend\n",
      "app/models/shop/thing.rb" => "module Shop\n  class Thing < Record\n    self.table_name = \"posts\"\n    %i[a_notes b_notes].each { |n| has_notes n }\n  end\nend\n"
    )

    expect(Shop::Thing.reflect_on_all_associations.map { |a| a.name.to_s }).to eq(%w[a_notes b_notes])
    thing = static_models(static)["Shop::Thing"]
    expect(thing[:associations]).to match([ a_hash_including(type: "has_many", computed_name: true) ])
    expect(thing[:conditional_declarations]).to be_blank
  end

  it "reads a habtm join_table that interpolates the affixes through the superclass chain, as Rails does" do
    static = app(
      "app/models/shop/record.rb" => "module Shop\n  class Record < ActiveRecord::Base\n    self.abstract_class = true\n    self.table_name_prefix = \"s_\"\n    self.table_name_suffix = \"_v2\"\n  end\nend\n",
      "app/models/shop/thing.rb" => "module Shop\n  class Thing < Record\n    has_and_belongs_to_many :tags, join_table: \"\#{table_name_prefix}tags_things\#{table_name_suffix}\"\n  end\nend\n"
    )

    expect(Shop::Thing.reflect_on_association(:tags).join_table).to eq("s_tags_things_v2")
    expect(static_models(static)["Shop::Thing"][:associations].first[:join_table]).to eq("s_tags_things_v2")
    expect(RailsAiContext::Introspectors::HabtmJoinTables.declared(@dir, static_models(static))).to include("s_tags_things_v2")
  end

  describe "a job's chain" do
    let(:jobs) do
      {
        "app/jobs/tracker/base_job.rb" => <<~RUBY,
          module Tracker
            class BaseJob < ActiveJob::Base
              queue_as :low
              retry_on Timeout::Error, wait: 5.seconds, attempts: 3
              discard_on ActiveJob::DeserializationError
            end
          end
        RUBY
        "app/jobs/tracker/reports_job.rb" => <<~RUBY,
          module Tracker
            class ReportsJob < BaseJob
              discard_on ArgumentError
            end
          end
        RUBY
        "app/jobs/tracker/daily_job.rb" => <<~RUBY,
          module Tracker
            class DailyJob < ReportsJob
              def perform; end
            end
          end
        RUBY
        "app/jobs/tracker/prefixed_job.rb" => <<~RUBY
          module Tracker
            class PrefixedJob < BaseJob
              self.queue_name_prefix = "app"
              queue_as :mail
              def perform; end
            end
          end
        RUBY
      }
    end

    def static_job(static, name) = RailsAiContext::Introspectors::JobIntrospector.new(static).static_call[:jobs].find { |job| job[:name] == name }

    def booted_job(static, name) = RailsAiContext::Introspectors::JobIntrospector.new(static).call[:jobs].find { |job| job[:name] == name }

    it "lists the retry and discard handlers it inherits, in the order Rails keeps them" do
      static = app(jobs)
      handlers = Tracker::DailyJob.rescue_handlers.map(&:first)
      expect(handlers).to eq(%w[Timeout::Error ActiveJob::DeserializationError ArgumentError])

      named = ->(job) { Array(job[:retries]).map { |entry| entry[/\A(?:retry|discard)_on (\S+?)(?:,|\z)/, 1] } }
      expect(named.call(booted_job(static, "Tracker::DailyJob"))).to eq(handlers)
      expect(named.call(static_job(static, "Tracker::DailyJob"))).to eq(handlers)
    end

    it "lists its callbacks in the order Rails keeps each chain, prepend: true first" do
      static = app(jobs.merge("app/jobs/tracker/hooked_job.rb" => <<~RUBY))
        module Tracker
          class HookedJob < BaseJob
            before_perform :a
            after_perform :b
            before_enqueue :e
            before_perform :c, prepend: true
            def perform; end
          end
        end
      RUBY
      kept = %i[perform enqueue].flat_map { |chain| Tracker::HookedJob.__callbacks[chain].map(&:filter).grep(Symbol).map(&:to_s) }
      expect(kept).to eq(%w[c a b e])

      names = ->(job) { Array(job[:callbacks]).map { |text| text[/\A\w+ :(\w+)/, 1] } }
      expect(names.call(booted_job(static, "Tracker::HookedJob"))).to eq(kept)
      expect(names.call(static_job(static, "Tracker::HookedJob"))).to eq(kept)
    end

    it "lists the callbacks its base and its concerns declare, in the order Rails keeps each chain" do
      static = app(
        "app/jobs/concerns/tracker/audited.rb" => <<~RUBY,
          module Tracker
            module Audited
              extend ActiveSupport::Concern
              included do
                before_perform :audit
                around_enqueue :wrap, prepend: true
                after_perform { |job| job }
              end
            end
          end
        RUBY
        "app/jobs/tracker/hooks_base_job.rb" => <<~RUBY,
          module Tracker
            class HooksBaseJob < ActiveJob::Base
              after_perform :base_after
              before_enqueue :base_enqueue
              after_enqueue { |job| job.class }
            end
          end
        RUBY
        "app/jobs/tracker/audited_job.rb" => <<~RUBY
          module Tracker
            class AuditedJob < HooksBaseJob
              before_perform :own, if: -> { true }
              include Audited
              before_perform :first, prepend: true
              def perform; end
            end
          end
        RUBY
      )
      # ActiveJob registers blocks of its own; the app's are the ones written in its files.
      mine = ->(filter) { filter.is_a?(Symbol) ? filter.to_s : ("block" if filter.source_location&.first&.start_with?(@dir)) }
      kept = %i[perform enqueue].flat_map { |chain| Tracker::AuditedJob.__callbacks[chain].filter_map { |callback| mine.call(callback.filter) } }
      expect(kept).to eq(%w[first base_after own audit block wrap base_enqueue block])

      names = ->(job) { Array(job[:callbacks]).map { |text| text[/\A\w+ :(\w+)/, 1] || "block" } }
      expect(names.call(booted_job(static, "Tracker::AuditedJob"))).to eq(kept)
      expect(names.call(static_job(static, "Tracker::AuditedJob"))).to eq(kept)
      expect(static_job(static, "Tracker::AuditedJob")[:callbacks]).to include("before_perform :own, if: -> { true }", "after_perform { |job| job }", "after_enqueue { |job| job.class }")
    end

    it "writes a callback a concern nested in another file declares as that concern writes it" do
      # The padding puts the class's own callback at the byte offset Local's has within Local's own text.
      static = app("app/jobs/tracker/local_job.rb" => <<~RUBY)
        module Tracker
          class LocalJob < ActiveJob::Base
            # xxxxxxxxxxxxxx
            after_perform :own
            module Local
              extend ActiveSupport::Concern
              included do
                after_perform :local, if: -> { true }
                around_perform Wrapper
                after_perform do |job|
                  job.class
                end
              end
            end
            class Wrapper
              def self.around_perform(_job) = yield
            end
            include Local
            def perform; end
          end
        end
      RUBY
      mine = ->(filter) { filter.is_a?(Proc) ? ("block" if filter.source_location.first.start_with?(@dir)) : filter.to_s }
      kept = Tracker::LocalJob.__callbacks[:perform].filter_map { |callback| mine.call(callback.filter) }
      expect(kept).to eq(%w[own local Tracker::LocalJob::Wrapper block])

      expect(static_job(static, "Tracker::LocalJob")[:callbacks])
        .to eq([ "after_perform :own", "after_perform :local, if: -> { true }", "around_perform Wrapper", "after_perform do |job| job.class; end" ])
    end

    it "writes a callback a class method declares as the call runs it, its arguments bound" do
      static = app(
        "app/jobs/tracker/called_job.rb" => <<~RUBY,
          module Tracker
            class CalledJob < ActiveJob::Base
              # xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx
              def self.tracked(name) = after_perform name, if: -> { true }
              tracked :logit
              def perform; end
            end
          end
        RUBY
        "app/jobs/tracker/nested_job.rb" => <<~RUBY
          module Tracker
            class NestedJob < ActiveJob::Base
              # xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx
              module Local
                extend ActiveSupport::Concern
                class_methods do
                  def tracked(name)
                    after_perform name
                  end
                end
                included do
                  tracked :logit
                end
              end
              include Local
              def perform; end
            end
          end
        RUBY
      )
      called = Tracker::CalledJob.__callbacks[:perform].select { |callback| callback.filter.is_a?(Symbol) }
      expect(called.map(&:filter)).to eq(%i[logit])
      expect(called.first.instance_variable_get(:@if).first.source_location)
        .to eq([ File.join(@dir, "app/jobs/tracker/called_job.rb"), 4 ])
      expect(Tracker::NestedJob.__callbacks[:perform].map(&:filter).grep(Symbol)).to eq(%i[logit])

      expect(static_job(static, "Tracker::CalledJob")[:callbacks]).to eq([ "after_perform :logit, if: -> { true }" ])
      expect(static_job(static, "Tracker::NestedJob")[:callbacks]).to eq([ "after_perform :logit" ])
    end

    it "writes a callback whose arguments run across lines on one line, as it writes other macros" do
      static = app("app/jobs/tracker/spread_job.rb" => <<~RUBY)
        module Tracker
          class SpreadJob < ActiveJob::Base
            before_perform(
              :a,
              :b,
            )
            def perform; end
          end
        end
      RUBY
      expect(Tracker::SpreadJob.__callbacks[:perform].map(&:filter).grep(Symbol)).to eq(%i[a b])

      expect(booted_job(static, "Tracker::SpreadJob")[:callbacks]).to eq([ "before_perform(:a, :b)" ])
      expect(static_job(static, "Tracker::SpreadJob")[:callbacks]).to eq([ "before_perform(:a, :b)" ])
    end

    it "lists a callback a plain module's included hook declares on the class mixing it in" do
      static = app(
        "app/jobs/tracker/hooking.rb" => <<~RUBY,
          module Tracker
            module Hooking
              def self.included(base)
                base.after_perform :hooked
              end
            end

            module Klassed
              def self.included(klass)
                klass.after_perform :viaklass
                self.class
              end
            end
          end
        RUBY
        "app/jobs/tracker/hooking_job.rb" => <<~RUBY
          module Tracker
            class HookingJob < ActiveJob::Base
              after_perform :own
              include Hooking
              include Klassed
              def perform; end
            end
          end
        RUBY
      )
      kept = Tracker::HookingJob.__callbacks[:perform].map(&:filter).grep(Symbol).map(&:to_s)
      expect(kept).to eq(%w[own hooked viaklass])

      written = kept.map { |name| "after_perform :#{name}" }
      expect(booted_job(static, "Tracker::HookingJob")[:callbacks]).to eq(written)
      expect(static_job(static, "Tracker::HookingJob")[:callbacks]).to eq(written)
    end

    # Ruby reads `AdminJob::Base` inside AdminJob's superclass PanelJob, so the job is an ActiveJob with Base's handler.
    it "reads its kind and its chain through one superclass resolution" do
      static = app(
        "app/jobs/tracker/panel_job.rb" => "module Tracker\n  class PanelJob < ActiveJob::Base\n    class Base < ActiveJob::Base\n      retry_on Timeout::Error\n    end\n  end\nend\n",
        "app/jobs/tracker/admin_job.rb" => "module Tracker\n  class AdminJob < PanelJob\n  end\nend\n",
        "app/jobs/tracker/gadget_job.rb" => "module Tracker\n  class GadgetJob < AdminJob::Base\n    def perform; end\n  end\nend\n"
      )
      expect(Tracker::GadgetJob.superclass.name).to eq("Tracker::PanelJob::Base")
      expect(Tracker::GadgetJob.rescue_handlers.map(&:first)).to eq(%w[Timeout::Error])

      job = static_job(static, "Tracker::GadgetJob")
      expect(job[:active_job]).to be(true)
      expect(Array(job[:retries]).map { |entry| entry[/\Aretry_on (\S+?)(?:,|\z)/, 1] }).to eq(%w[Timeout::Error])
    end

    it "reads a class's own queue_name_prefix into the queue it names" do
      static = app(jobs)
      expect(Tracker::PrefixedJob.new.queue_name).to eq("app_mail")

      expect(booted_job(static, "Tracker::PrefixedJob")[:queue]).to eq(Tracker::PrefixedJob.new.queue_name)
      expect(static_job(static, "Tracker::PrefixedJob")[:queue]).to eq(Tracker::PrefixedJob.new.queue_name)
    end
  end

  it "lists a set_callback callback in the chain where Rails puts it, on both tiers" do
    static = app(
      "app/models/tracker/item.rb" => <<~RUBY
        module Tracker
          class Item < ActiveRecord::Base
            self.table_name = "posts"
            after_save :first_after
            set_callback :save, :after, :set_one
            after_save :second_after
            set_callback :save, :after, :set_two
            set_callback :save, :before, :set_before
          end
        end
      RUBY
    )
    mine = %w[first_after set_one second_after set_two set_before]
    chain = Tracker::Item._save_callbacks.select { |callback| mine.include?(callback.filter.to_s) }
    # After callbacks run from the chain's end.
    booted = { "after_save" => chain.select { |c| c.kind == :after }.map { |c| c.filter.to_s }.reverse,
               "before_save" => chain.select { |c| c.kind == :before }.map { |c| c.filter.to_s } }
    expect(booted).to eq("after_save" => %w[set_two set_one first_after second_after], "before_save" => %w[set_before])

    expect(static_models(static)["Tracker::Item"][:callbacks]).to eq(booted)
    expect(booted_model(static, Tracker::Item)[:callbacks]).to eq(booted)
  end

  it "reads a strong params method from the concern Ruby finds it in before the parent's" do
    static = app(
      "app/controllers/tracker/store_controller.rb" => <<~RUBY,
        module Tracker
          class StoreController < ActionController::Base
            private

            def post_params
              params.require(:post).permit(:body)
            end
          end
        end
      RUBY
      "app/controllers/concerns/tracker/postable.rb" => <<~RUBY,
        module Tracker
          module Postable
            extend ActiveSupport::Concern

            private

            def post_params
              params.require(:post).permit(:title)
            end
          end
        end
      RUBY
      "app/controllers/tracker/posts_controller.rb" => <<~RUBY
        module Tracker
          class PostsController < StoreController
            include Postable

            def create
              post_params
            end
          end
        end
      RUBY
    )
    owner = Tracker::PostsController.instance_method(:post_params).owner.name
    expect(owner).to eq("Tracker::Postable")

    payload = RailsAiContext::Introspectors::ControllerIntrospector.new(static).static_call
    found = payload[:controllers]["Tracker::PostsController"][:strong_params].map { |sp| [ sp[:name], sp[:from], Array(sp[:permits]).map(&:to_s) ] }
    expect(found).to eq([ [ "post_params", owner, %w[title] ] ])
  end

  it "reads a strong params method two concerns define from the one included last" do
    concern = ->(name, field) { "module Tracker\n  module #{name}\n    private\n\n    def post_params\n      params.require(:post).permit(:#{field})\n    end\n  end\nend\n" }
    static = app(
      "app/controllers/concerns/tracker/titled.rb" => concern.call("Titled", "title"),
      "app/controllers/concerns/tracker/bodied.rb" => concern.call("Bodied", "body"),
      "app/controllers/tracker/posts_controller.rb" => "module Tracker\n  class PostsController < ActionController::Base\n    include Titled\n    include Bodied\n\n    def create = post_params\n  end\nend\n"
    )
    owner = Tracker::PostsController.instance_method(:post_params).owner.name
    expect(owner).to eq("Tracker::Bodied")

    payload = RailsAiContext::Introspectors::ControllerIntrospector.new(static).static_call
    found = payload[:controllers]["Tracker::PostsController"][:strong_params].map { |sp| [ sp[:name], sp[:from], Array(sp[:permits]).map(&:to_s) ] }
    expect(found).to eq([ [ "post_params", owner, %w[body] ] ])
  end

  # `include A, B` adds B first, so A is nearer: ancestors [C, A, B], and B's included block runs first.
  describe "an include line naming two modules" do
    let(:concern) do
      lambda do |name, field|
        "module Tracker\n  module #{name}\n    extend ActiveSupport::Concern\n    included do\n      before_action :#{field}_gate\n    end\n\n" \
          "    private\n\n    def post_params\n      params.require(:post).permit(:#{field})\n    end\n  end\nend\n"
      end
    end

    def answers(static, name)
      payload = RailsAiContext::Introspectors::ControllerIntrospector.new(static).static_call
      [ payload[:controllers][name][:strong_params].map { |sp| [ sp[:name], sp[:from], Array(sp[:permits]).map(&:to_s) ] }, static_chain(static, name, "create") ]
    end

    it "reads the class's methods and filters in Ruby's order, written in the class or in a module it includes" do
      static = app(
        "app/controllers/concerns/tracker/titled.rb" => concern.call("Titled", "title"),
        "app/controllers/concerns/tracker/bodied.rb" => concern.call("Bodied", "body"),
        "app/controllers/concerns/tracker/wrapped.rb" => "module Tracker\n  module Wrapped\n    extend ActiveSupport::Concern\n    include Titled, Bodied\n  end\nend\n",
        "app/controllers/tracker/posts_controller.rb" => "module Tracker\n  class PostsController < ActionController::Base\n    include Titled, Bodied\n\n    def create = post_params\n  end\nend\n",
        "app/controllers/tracker/notes_controller.rb" => "module Tracker\n  class NotesController < ActionController::Base\n    include Wrapped\n\n    def create = post_params\n  end\nend\n"
      )

      expect(Tracker::PostsController.ancestors.first(3).map(&:name)).to eq(%w[Tracker::PostsController Tracker::Titled Tracker::Bodied])
      expect(Tracker::NotesController.ancestors.first(4).map(&:name)).to eq(%w[Tracker::NotesController Tracker::Wrapped Tracker::Titled Tracker::Bodied])
      %w[Tracker::PostsController Tracker::NotesController].each do |name|
        klass = Object.const_get(name)
        expect(klass.instance_method(:post_params).owner.name).to eq("Tracker::Titled")
        expect(answers(static, name)).to eq([ [ [ "post_params", "Tracker::Titled", %w[title] ] ], booted_chain(klass) ])
      end
      expect(booted_chain(Tracker::PostsController)).to eq(%w[body_gate title_gate])
    end
  end

  describe "a strong params method a module and a class both define" do
    let(:postable) do
      "module Tracker\n  module Postable\n    extend ActiveSupport::Concern\n\n    private\n\n    def post_params\n      params.require(:post).permit(:title)\n    end\n  end\nend\n"
    end
    let(:bodied) { "    private\n\n    def post_params\n      params.require(:post).permit(:body)\n    end\n" }

    def strong_params(static, name)
      payload = RailsAiContext::Introspectors::ControllerIntrospector.new(static).static_call
      payload[:controllers][name][:strong_params].map { |sp| [ sp[:name], sp[:from], Array(sp[:permits]).map(&:to_s) ] }
    end

    it "keeps the parent's method when the class includes again a module the parent included" do
      static = app(
        "app/controllers/concerns/tracker/postable.rb" => postable,
        "app/controllers/tracker/store_controller.rb" => "module Tracker\n  class StoreController < ActionController::Base\n    include Postable\n\n#{bodied}  end\nend\n",
        "app/controllers/tracker/posts_controller.rb" => "module Tracker\n  class PostsController < StoreController\n    include Postable\n\n    def create = post_params\n  end\nend\n"
      )
      owner = Tracker::PostsController.instance_method(:post_params).owner.name
      expect(owner).to eq("Tracker::StoreController")
      expect(strong_params(static, "Tracker::PostsController")).to eq([ [ "post_params", owner, %w[body] ] ])
    end

    it "reads it from a module the class prepends before the class's own" do
      static = app(
        "app/controllers/concerns/tracker/postable.rb" => postable,
        "app/controllers/tracker/posts_controller.rb" => "module Tracker\n  class PostsController < ActionController::Base\n    prepend Postable\n\n    def create = post_params\n\n#{bodied}  end\nend\n"
      )
      owner = Tracker::PostsController.instance_method(:post_params).owner.name
      expect(owner).to eq("Tracker::Postable")
      expect(strong_params(static, "Tracker::PostsController")).to eq([ [ "post_params", owner, %w[title] ] ])
    end
  end

  it "gives the class the methods a class_methods block includes as class methods, not actions" do
    static = app(
      "app/controllers/concerns/tracker/klassy.rb" => "module Tracker\n  module Klassy\n    def klass_only; end\n  end\nend\n",
      "app/controllers/concerns/tracker/searchable.rb" => "module Tracker\n  module Searchable\n    extend ActiveSupport::Concern\n\n    class_methods do\n      include Klassy\n    end\n  end\nend\n",
      "app/controllers/tracker/posts_controller.rb" => "module Tracker\n  class PostsController < ActionController::Base\n    include Searchable\n\n    def index; end\n  end\nend\n"
    )
    expect(Tracker::PostsController).to respond_to(:klass_only)
    booted = Tracker::PostsController.action_methods.to_a.sort
    expect(booted).to eq(%w[index])

    payload = RailsAiContext::Introspectors::ControllerIntrospector.new(static).static_call
    expect(payload[:controllers]["Tracker::PostsController"][:actions]).to eq(booted)
  end

  describe "a class method macro a base defines" do
    let(:files) do
      {
        "app/models/tracker/record.rb" => <<~RUBY,
          module Tracker
            class Record < ActiveRecord::Base
              self.abstract_class = true

              def self.has_req(name)
                has_many name, as: :notable, class_name: "Tracker::Note"
                after_initialize :"init_\#{name}"
              end

              def self.has_opt(name = :opts)
                has_many name, as: :notable, class_name: "Tracker::Note"
              end

              def self.has_kw(name:)
                has_many name, as: :notable, class_name: "Tracker::Note"
              end
            end
          end
        RUBY
        "app/models/tracker/holder.rb" => <<~RUBY
          module Tracker
            class Holder < Record
              self.table_name = "posts"
              has_req :reqs
              has_opt :given
              has_opt
              has_kw name: :kws
            end
          end
        RUBY
      }
    end

    it "binds each call's arguments, on both tiers" do
      static = app(files)
      reflected = Tracker::Holder.reflect_on_all_associations.map { |a| [ a.name.to_s, a.options.slice(:as, :class_name).transform_values(&:to_s) ] }
      expect(reflected).to eq(%w[reqs given opts kws].map { |name| [ name, { as: "notable", class_name: "Tracker::Note" } ] })
      callbacks = Tracker::Holder._initialize_callbacks.map { |callback| callback.filter.to_s }
      expect(callbacks).to eq(%w[init_reqs])

      booted = booted_model(static, Tracker::Holder)
      read = ->(a) { [ a[:name], { as: a.dig(:declared_options, "as").to_s.delete_prefix(":"), class_name: a[:class_name] } ] }
      expect(booted[:associations].map(&read)).to eq(reflected)
      expect(booted[:callbacks]).to eq("after_initialize" => callbacks)
      model = static_models(static)["Tracker::Holder"]
      expect(model[:associations].map { |a| [ a[:name].to_s, a[:options].slice(:as, :class_name).transform_values(&:to_s) ] }).to eq(reflected)
      expect(model[:callbacks]).to eq("after_initialize" => callbacks)
    end
  end

  # On macOS /tmp is a link to /private/tmp, and a project folder can be a link too.
  it "answers alike whether the app's root is spelled through a link or as its real path" do
    app(
      "app/controllers/concerns/tracker/guarded.rb" => "module Tracker\n  module Guarded\n    extend ActiveSupport::Concern\n    included do\n      before_action { true }\n    end\n  end\nend\n",
      "app/controllers/tracker/store_controller.rb" => <<~RUBY,
        module Tracker
          class StoreController < ActionController::Base
            include Guarded
            include I18n
            def self.requires_plugin(name)
              before_action do
                name
              end
            end
          end
        end
      RUBY
      "app/controllers/tracker/items_controller.rb" => "module Tracker\n  class ItemsController < StoreController\n    requires_plugin :shop\n    def index; end\n  end\nend\n",
      "app/models/concerns/tracker/stamped.rb" => "module Tracker\n  module Stamped\n    extend ActiveSupport::Concern\n    included do\n      before_save { true }\n    end\n  end\nend\n",
      "app/models/tracker/record.rb" => <<~RUBY,
        module Tracker
          class Record < ActiveRecord::Base
            self.abstract_class = true
            def self.audited(name) = after_save { name }
          end
        end
      RUBY
      "app/models/tracker/item.rb" => "module Tracker\n  class Item < Record\n    include Stamped\n    audited :item\n  end\nend\n",
      "app/jobs/tracker/base_job.rb" => <<~RUBY,
        module Tracker
          class BaseJob < ActiveJob::Base
            def self.tracked(name) = after_perform { name }
          end
        end
      RUBY
      "app/jobs/tracker/items_job.rb" => "module Tracker\n  class ItemsJob < BaseJob\n    tracked :items\n    def perform; end\n  end\nend\n"
    )
    real = File.realpath(@dir)
    Dir.mktmpdir("linked-root") do |links|
      link = File.join(links, "app")
      File.symlink(real, link)
      answers = [ real, link ].map do |root|
        static = RailsAiContext::StaticApp.new(root)
        RailsAiContext::RunCache.around_app(static) do
          [ RailsAiContext::Introspectors::ModelIntrospector.new(static).static_call,
            RailsAiContext::Introspectors::ControllerIntrospector.new(static).static_call,
            RailsAiContext::Introspectors::JobIntrospector.new(static).static_call ]
        end
      end
      controller = answers.first[1][:controllers]["Tracker::ItemsController"]
      expect(controller[:filters].map { |filter| filter[:name] }).to eq([ "block (line 6 of app/controllers/tracker/store_controller.rb)" ])
      expect(controller[:concerns_unread]).to eq(%w[I18n])
      expect(answers.last).to eq(answers.first)
    end
  end
end
