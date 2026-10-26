# frozen_string_literal: true

require "spec_helper"
require "tmpdir"
require "fileutils"

# Each app below is written to disk for the static tier and loaded into this process, where Rails
# reflection says which constant each written name reached. The two answers must agree.
RSpec.describe "The constant a written name means, booted and static" do
  def top_level = %i[StoreRecord Shop Priced Tracker Taggable Gadget Forum Publishable Billing Social Guard StoreController Extra]

  around do |example|
    clashing = top_level.select { |name| Object.const_defined?(name, false) }
    raise "already defined: #{clashing.join(", ")}" if clashing.any?

    Dir.mktmpdir("constant-lookup-tiers") do |dir|
      @dir = dir
      example.run
    ensure
      top_level.each { |name| Object.send(:remove_const, name) if Object.const_defined?(name, false) }
    end
  end

  # Writes the app for the static tier and runs the same files here, in the order given.
  def app(files)
    files.each do |relative, source|
      path = File.join(@dir, relative)
      FileUtils.mkdir_p(File.dirname(path))
      File.write(path, source)
      TOPLEVEL_BINDING.eval(source, path) unless relative.start_with?("config/")
    end
    RailsAiContext::StaticApp.new(@dir)
  end

  def static_models(files)
    RailsAiContext::Introspectors::ModelIntrospector.new(app(files)).static_call
  end

  def static_chain(static, name, action)
    payload = RailsAiContext::Introspectors::ControllerIntrospector.new(static).static_call
    RailsAiContext::ActionFilters.for({ controllers: payload }, name, action, root: @dir)[:chain].map { |filter| filter[:name] }
  end

  def priced(name, filter)
    "#{"module Shop\n" if name.start_with?("Shop")}module #{name.split("::").last}\n  extend ActiveSupport::Concern\n  included do\n    before_save :#{filter}\n  end\nend\n#{"end\n" if name.start_with?("Shop")}"
  end

  let(:store_record) { { "app/models/store_record.rb" => "class StoreRecord < ActiveRecord::Base\n  self.abstract_class = true\nend\n" } }

  it "reads an include written from the root inside a namespace as the top-level module" do
    files = store_record.merge(
      "app/models/concerns/priced.rb" => priced("Priced", "top_priced"),
      "app/models/concerns/shop/priced.rb" => priced("Shop::Priced", "shop_priced"),
      "app/models/shop/tool.rb" => "module Shop\n  class Tool < StoreRecord\n    include ::Priced\n  end\nend\n"
    )
    models = static_models(files)
    sources = files.map { |relative, source| [ File.join(@dir, relative), source ] }
    includers = RailsAiContext::Introspectors::Includers.of(@dir, sources, %w[Priced Shop::Priced])

    booted = Shop::Tool._save_callbacks.map { |callback| callback.filter.to_s }
    expect(booted).to eq(%w[top_priced])
    expect(models["Shop::Tool"][:callbacks]).to eq("before_save" => booted)
    expect(models["Shop::Tool"][:concerns]).to eq((Shop::Tool.included_modules & [ Priced, Shop::Priced ]).map(&:name))
    expect(includers).to eq([ Priced, Shop::Priced ].to_h { |mod| [ mod.name, [ Shop::Tool ].select { |klass| klass < mod }.map(&:name) ] }.reject { |_, found| found.empty? })
  end

  it "reads an include through the modules the superclass mixes in before the top level" do
    models = static_models(
      "app/models/concerns/tracker.rb" => "module Tracker\n  extend ActiveSupport::Concern\n\n  module Taggable\n    extend ActiveSupport::Concern\n    included do\n      has_many :tracker_tags\n    end\n  end\nend\n",
      "app/models/concerns/taggable.rb" => "module Taggable\n  extend ActiveSupport::Concern\n  included do\n    has_many :top_tags\n  end\nend\n",
      "app/models/store_record.rb" => "class StoreRecord < ActiveRecord::Base\n  self.abstract_class = true\n  include Tracker\nend\n",
      "app/models/gadget.rb" => "class Gadget < StoreRecord\n  include Taggable\nend\n"
    )

    booted = Gadget.reflect_on_all_associations.map { |reflection| reflection.name.to_s }
    expect(booted).to eq(%w[tracker_tags])
    expect(models["Gadget"][:associations].map { |association| association[:name] }).to eq(booted)
  end

  it "names a module reached through a superclass's mixin by the module it is, and credits its includer" do
    files = store_record.merge(
      "app/models/concerns/tracker/holdy.rb" => "module Tracker\n  module Holdy\n    extend ActiveSupport::Concern\n\n    module Taggable\n      def holdy_tag; end\n    end\n  end\nend\n",
      "app/models/concerns/taggable.rb" => "module Taggable\n  def top_tag; end\nend\n",
      "app/models/tracker/record.rb" => "module Tracker\n  class Record < StoreRecord\n    self.abstract_class = true\n    include Holdy\n  end\nend\n",
      "app/models/tracker/item.rb" => "module Tracker\n  class Item < Record\n    include Taggable\n  end\nend\n",
      "app/models/extra.rb" => "module Extra\nend\n",
      "app/models/concerns/tracker/extend.rb" => "module Tracker\n  Item::Taggable.include(Extra)\nend\n"
    )
    models = static_models(files)
    sources = files.map { |relative, source| [ File.join(@dir, relative), source ] }
    names = %w[Tracker::Holdy::Taggable Taggable Extra]
    includers = RailsAiContext::Introspectors::Includers.of(@dir, sources, names)

    booted = (Tracker::Item.included_modules & [ Tracker::Holdy::Taggable, Taggable ]).map(&:name)
    expect(booted).to eq(%w[Tracker::Holdy::Taggable])
    expect(models["Tracker::Item"][:concerns] & [ *names, "Tracker::Item::Taggable" ]).to eq(booted)
    expect(includers).to eq("Tracker::Holdy::Taggable" => %w[Tracker::Item], "Extra" => %w[Tracker::Holdy::Taggable])
    expect(Tracker::Holdy::Taggable.include?(Extra)).to be(true)
  end

  it "picks a constant the enclosing namespace declares before one reached through a superclass's mixin" do
    files = store_record.merge(
      "app/models/concerns/tracker/holdy.rb" => "module Tracker\n  module Holdy\n    extend ActiveSupport::Concern\n\n    module Taggable\n    end\n  end\nend\n",
      "app/models/concerns/tracker/taggable.rb" => "module Tracker\n  module Taggable\n  end\nend\n",
      "app/models/tracker/record.rb" => "module Tracker\n  class Record < StoreRecord\n    self.abstract_class = true\n    include Holdy\n  end\nend\n",
      "app/models/tracker/item.rb" => "module Tracker\n  class Item < Record\n    include Taggable\n  end\nend\n"
    )
    models = static_models(files)
    sources = files.map { |relative, source| [ File.join(@dir, relative), source ] }
    names = %w[Tracker::Holdy::Taggable Tracker::Taggable]

    booted = (Tracker::Item.included_modules & [ Tracker::Holdy::Taggable, Tracker::Taggable ]).map(&:name)
    expect(booted).to eq(%w[Tracker::Taggable])
    expect(models["Tracker::Item"][:concerns] & names).to eq(booted)
    expect(RailsAiContext::Introspectors::Includers.of(@dir, sources, names)).to eq("Tracker::Taggable" => %w[Tracker::Item])
  end

  it "names a concern by the module the model's namespace holds" do
    models = static_models(store_record.merge(
      "app/models/concerns/publishable.rb" => "module Publishable\n  extend ActiveSupport::Concern\nend\n",
      "app/models/concerns/forum/publishable.rb" => "module Forum\n  module Publishable\n    extend ActiveSupport::Concern\n  end\nend\n",
      "app/models/forum/post.rb" => "module Forum\n  class Post < StoreRecord\n    include Publishable\n  end\nend\n"
    ))

    expect(Forum::Post.ancestors[1]).to eq(Forum::Publishable)
    expect(models["Forum::Post"][:concerns]).to eq([ Forum::Post.ancestors[1].name ])
  end

  it "names a mounted app by the constant Ruby picks where the mount is written" do
    routes = "module Forum\n  StoreController::ROUTES.draw do\n    mount UI => \"/ui\"\n  end\nend\n"
    Object.const_set(:StoreController, Module.new)
    StoreController.const_set(:ROUTES, ActionDispatch::Routing::RouteSet.new)
    static = app(
      "app/lib/forum/ui.rb" => "module Forum\n  class UI\n    def self.call(_env) = [ 200, {}, [] ]\n  end\nend\n",
      "config/routes.rb" => routes.sub("StoreController::ROUTES", "Rails.application.routes")
    )
    TOPLEVEL_BINDING.eval(routes)

    booted = StoreController::ROUTES.routes.map { |route| [ route.app.app.name, route.path.spec.to_s ] }
    expect(booted).to eq([ [ "Forum::UI", "/ui" ] ])
    mounts = RailsAiContext::Introspectors::RouteIntrospector.new(static).static_call[:mounted_engines]
    expect(mounts.map { |mount| [ mount[:engine], mount[:path] ] }).to eq(booted)
  end

  it "reads each controller's skips from its own class body when two share a file" do
    static = app(
      "app/controllers/billing/base_controller.rb" => "module Billing\n  class BaseController < ActionController::API\n    before_action :auth_token\n  end\nend\n",
      "app/controllers/billing/things_controller.rb" => <<~RUBY
        module Billing
          class ThingsController < BaseController
            def index; end
          end

          class OtherThingsController < ThingsController
            skip_before_action :auth_token
            def show; end
          end
        end
      RUBY
    )

    booted = [ Billing::ThingsController, Billing::OtherThingsController ].map { |klass| klass._process_action_callbacks.map { |callback| callback.filter.to_s } }
    expect(booted).to eq([ %w[auth_token], [] ])
    expect([ static_chain(static, "Billing::ThingsController", "index"), static_chain(static, "Billing::OtherThingsController", "show") ]).to eq(booted)
  end

  it "reads a controller's include through the modules its parent mixes in before the top level" do
    static = app(
      "app/controllers/concerns/social.rb" => "module Social\n  extend ActiveSupport::Concern\n\n  module Guard\n    extend ActiveSupport::Concern\n    included do\n      before_action :inner_guard\n    end\n  end\nend\n",
      "app/controllers/concerns/guard.rb" => "module Guard\n  extend ActiveSupport::Concern\n  included do\n    before_action :top_guard\n  end\nend\n",
      "app/controllers/store_controller.rb" => "class StoreController < ActionController::Base\n  include Social\nend\n",
      "app/controllers/forum/posts_controller.rb" => "module Forum\n  class PostsController < StoreController\n    include Guard\n    def index; end\n  end\nend\n"
    )

    # An app on load_defaults gives ActionController::Base its forgery protection callbacks.
    booted = [ Forum::PostsController, ActionController::Base ].map { |klass| klass._process_action_callbacks.map { |callback| callback.filter.to_s } }.reduce(:-)
    expect(booted).to eq(%w[inner_guard])
    expect(static_chain(static, "Forum::PostsController", "index")).to eq(booted)
  end
end
