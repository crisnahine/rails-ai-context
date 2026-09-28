# frozen_string_literal: true

require "spec_helper"
require "tmpdir"

# The one tool file that had no spec of its own. These drive the dispatcher
# through its public seam; the rules gain coverage as they change.
RSpec.describe RailsAiContext::Tools::ValidateSemantics do
  def with_app_file(relative, content)
    Dir.mktmpdir do |root|
      full = File.join(root, relative)
      FileUtils.mkdir_p(File.dirname(full))
      File.write(full, content)
      yield relative, full
    end
  end

  before do
    allow(described_class).to receive(:cached_context).and_return({
      routes: { by_controller: {} },
      schema: { tables: {} },
      models: {}
    })
  end

  # OFN's Spree views call the engine's helpers bare, and its Spree
  # controllers answer routes in the engine's table.
  describe "routes an app draws into an engine" do
    let(:engine_routes) do
      [ { engine: "Spree::Core::Engine", mount: "/", routes: [
        { verb: "GET", path: "/admin/orders", controller: "spree/admin/orders", action: "index", name: "spree.admin_orders" },
        { verb: "GET", path: "/admin/orders/:id/fire", controller: "spree/admin/orders", action: "fire" }
      ] } ]
    end

    before do
      allow(described_class).to receive(:cached_context).and_return({
        routes: { by_controller: { "posts" => [ { verb: "GET", action: "index", name: "posts" } ] }, engine_routes: engine_routes },
        controllers: { controllers: { "Spree::Admin::OrdersController" => { actions: %w[index] } } },
        schema: { tables: {} }, models: {}
      })
    end

    it "knows the engine's route helpers" do
      with_app_file("app/views/spree/admin/orders/_x.html.erb", "<%= link_to 'x', admin_orders_path %>\n") do |file, path|
        expect(described_class.check_rails_semantics(file, path).join).not_to include("admin_orders_path")
      end
    end

    it "checks an engine controller against the engine's routes" do
      with_app_file("app/controllers/spree/admin/orders_controller.rb",
                    "module Spree\n  module Admin\n    class OrdersController < BaseController\n      def index; end\n    end\n  end\nend\n") do |file, path|
        root = path.delete_suffix(file)
        File.write(File.join(root, "app/controllers/spree/admin/base_controller.rb"),
                   "module Spree\n  module Admin\n    class BaseController < ApplicationController\n    end\n  end\nend\n")
        File.write(File.join(root, "app/controllers/application_controller.rb"), "class ApplicationController < ActionController::Base\nend\n")
        allow(described_class).to receive(:rails_app).and_return(double(root: Pathname.new(root)))

        expect(described_class.check_rails_semantics(file, path).join).to include("fire - action not found")
      end
    end
  end

  # OFN's ApplicationController includes Pagy::Backend, a gem module this
  # check never reads, so it cannot say the gem defines no `show`.
  describe "a routed action no source the app holds defines" do
    def check(app_controller, extra = {}, predicate: false)
      Dir.mktmpdir do |root|
        files = {
          "app/controllers/orders_controller.rb" => "class OrdersController < ApplicationController\n  def index; end\nend\n",
          "app/controllers/application_controller.rb" => app_controller
        }.merge(extra)
        files.each do |relative, body|
          FileUtils.mkdir_p(File.dirname(File.join(root, relative)))
          File.write(File.join(root, relative), body)
        end
        allow(described_class).to receive(:rails_app).and_return(double(root: Pathname.new(root)))
        allow(described_class).to receive(:cached_context).and_return({
          routes: { by_controller: { "orders" => [ { verb: "GET", path: "/orders", action: "index" },
                                                   { verb: "GET", path: "/orders/:id", action: "show" },
                                                   { verb: "GET", path: "/orders/managed", action: predicate ? "managed?" : "managed" } ] } },
          controllers: { controllers: { "OrdersController" => { actions: %w[index] } } },
          schema: { tables: {} }, models: {}
        })
        file = "app/controllers/orders_controller.rb"
        return described_class.check_rails_semantics(file, File.join(root, file)).join("\n")
      end
    end

    it "names it missing when the app holds every ancestor and mixin" do
      text = check("class ApplicationController < ActionController::Base\nend\n")

      expect(text).to include("show - action not found").and include("managed - action not found")
    end

    it "says it is unverified when an ancestor includes a module the app does not hold" do
      text = check("class ApplicationController < ActionController::Base\n  include Pagy::Backend\nend\n")

      expect(text).not_to include("action not found")
      expect(text).to include("show, managed").and include("Pagy::Backend")
    end

    it "says it is unverified when an ancestor is a gem's class" do
      text = check("class ApplicationController < Spree::BaseController\nend\n")

      expect(text).not_to include("action not found")
      expect(text).to include("Spree::BaseController")
    end

    # Mastodon routes `get :merged, to: "requests#merged?"`.
    it "finds a predicate-named action an ancestor defines" do
      text = check("class ApplicationController < ActionController::Base\n  def show; end\n  def managed?; end\nend\n", predicate: true)

      expect(text).not_to match(/show|managed/)
    end

    it "finds an action an app concern included by an ancestor defines, and one a template renders" do
      text = check("class ApplicationController < ActionController::Base\n  include Managing\nend\n",
                   { "app/controllers/concerns/managing.rb" => "module Managing\n  def managed; end\nend\n",
                     "app/views/orders/show.html.erb" => "" })

      expect(text).not_to match(/show|managed/)
    end
  end

  describe "a foreign key over two columns" do
    def fk_warnings(indexes, primary_key: "id")
      context = {
        schema: { tables: { "event_refs" => { columns: [], indexes: indexes, primary_key: primary_key,
                                              foreign_keys: [ { column: %w[event_id event_day], to_table: "events" } ] } } },
        models: { "EventRef" => { table_name: "event_refs", file: "app/models/event_ref.rb", associations: [] } }
      }
      described_class.send(:check_missing_fk_index, "app/models/event_ref.rb", context)
    end

    it "counts an index leading with its columns" do
      expect(fk_warnings([ { columns: %w[event_day event_id] } ])).to eq([])
    end

    # connection.indexes leaves out the primary key's own index.
    it "counts a primary key over its columns" do
      expect(fk_warnings([], primary_key: %w[event_id event_day])).to eq([])
    end

    it "suggests one index over its columns when none leads with them" do
      expect(fk_warnings([]).join).to include("add_index :event_refs, [:event_id, :event_day]")
    end
  end

  describe ".check_rails_semantics" do
    it "answers cleanly for a plain file" do
      with_app_file("app/models/widget.rb", "class Widget < ApplicationRecord\nend\n") do |file, path|
        warnings = described_class.check_rails_semantics(file, path)
        expect(warnings).to eq([])
      end
    end

    it "says which checks were skipped when the AST parse fails, instead of reading as clean" do
      allow(RailsAiContext::AstCache).to receive(:parse_string).and_raise(RuntimeError, "prism exploded")

      with_app_file("app/models/widget.rb", "class Widget < ApplicationRecord\nend\n") do |file, path|
        warnings = described_class.check_rails_semantics(file, path)
        expect(warnings.join).to include("AST parse failed")
        expect(warnings.join).to include("skipped")
      end
    end

    # ActiveModel's AcceptanceValidator defines the reader and the writer
    # when no column exists, so the suggested migration adds a column nobody
    # wants.
    context "a model whose attribute has no column" do
      let(:context_with_schema) do
        {
          routes: { by_controller: {} },
          schema: { tables: { "subscriptions" => { columns: [ { name: "id" }, { name: "account_id" } ] } } },
          models: { "Subscription" => { table_name: "subscriptions", file: "app/models/subscription.rb",
                                        associations: [ { name: "account", foreign_key: "account_id" } ] } }
        }
      end

      before { allow(described_class).to receive(:cached_context).and_return(context_with_schema) }

      it "says nothing about an acceptance attribute" do
        source = <<~RUBY
          class Subscription < ApplicationRecord
            belongs_to :account
            validates :terms_of_use, acceptance: { accept: true }, allow_nil: false, on: :user_create
          end
        RUBY

        with_app_file("app/models/subscription.rb", source) do |file, path|
          expect(described_class.check_rails_semantics(file, path).join).not_to include("terms_of_use")
        end
      end

      it "says nothing about an attribute the model declares itself" do
        source = <<~RUBY
          class Subscription < ApplicationRecord
            attr_accessor :confirm_terms
            attribute :promo_code, :string
            validates :confirm_terms, presence: true
            validates :promo_code, presence: true
          end
        RUBY

        with_app_file("app/models/subscription.rb", source) do |file, path|
          warnings = described_class.check_rails_semantics(file, path).join
          expect(warnings).not_to include("confirm_terms")
          expect(warnings).not_to include("promo_code")
        end
      end

      # Lockbox's `has_encrypted :document_id` keeps a `_ciphertext` column.
      it "says nothing about an encrypted attribute or a store key" do
        source = <<~RUBY
          class Subscription < ApplicationRecord
            has_encrypted :document_id
            encrypts :ssn
            attr_encrypted :tax_id
            store_accessor :settings, :color
            store :prefs, accessors: [ :theme ], coder: JSON
            validates :document_id, :ssn, :tax_id, :color, :theme, presence: true
          end
        RUBY

        with_app_file("app/models/subscription.rb", source) do |file, path|
          warnings = described_class.check_rails_semantics(file, path).join
          %w[document_id ssn tax_id color theme].each { |name| expect(warnings).not_to include(name) }
        end
      end

      it "reads an escaped symbol as the column name the schema carries" do
        context = context_with_schema.dup
        context[:schema] = { tables: { "subscriptions" => { columns: [ { name: "id" }, { name: "first\tname" } ] } } }
        allow(described_class).to receive(:cached_context).and_return(context)
        source = <<~'RUBY'
          class Subscription < ApplicationRecord
            validates :"first\tname", presence: true
          end
        RUBY

        with_app_file("app/models/subscription.rb", source) do |file, path|
          expect(described_class.check_rails_semantics(file, path).join).not_to include("not found")
        end
      end

      it "still flags a column the table does not have" do
        source = <<~RUBY
          class Subscription < ApplicationRecord
            validates :nickname, presence: true
          end
        RUBY

        with_app_file("app/models/subscription.rb", source) do |file, path|
          expect(described_class.check_rails_semantics(file, path).join).to include("nickname")
        end
      end
    end

    # A `<%#` comment body is not code, so an ivar inside one is not used.
    context "a view with a commented-out instance variable" do
      around do |example|
        Dir.mktmpdir do |root|
          @root = root
          FileUtils.mkdir_p(File.join(root, "app/views/widgets"))
          FileUtils.mkdir_p(File.join(root, "app/controllers"))
          File.write(File.join(root, "app/controllers/widgets_controller.rb"),
                     "class WidgetsController < ApplicationController\n  def show\n  end\nend\n")
          example.run
        end
      end

      before do
        allow(RailsAiContext).to receive(:default_app).and_return(RailsAiContext::StaticApp.new(@root))
        allow(described_class).to receive(:cached_context).and_return({
          routes: { by_controller: {} },
          schema: { tables: {} },
          models: {},
          controllers: { controllers: { "WidgetsController" => { file: "app/controllers/widgets_controller.rb" } } }
        })
      end

      def warnings_for(view_source)
        file = "app/views/widgets/show.html.erb"
        full = File.join(@root, file)
        File.write(full, view_source)
        described_class.check_rails_semantics(file, full).join("\n")
      end

      it "says nothing about an ivar that only appears in a comment tag" do
        expect(warnings_for("<%# @ghost %>\n")).not_to include("@ghost")
      end

      it "still flags an ivar the template really reads" do
        expect(warnings_for("<%= @real %>\n")).to include("@real used in view but not set in WidgetsController")
      end
    end

    # The payload lists thirty instance methods, so a callback naming one the
    # model inherits past that cap is not missing. Booted, the loaded class
    # answers; statically, a truncated list cannot say it is absent.
    context "a callback method the capped method list leaves out" do
      let(:source) { "class CallbackWidget < ApplicationRecord\n  before_save :normalize_email\nend\n" }

      def context_with(count)
        {
          routes: { by_controller: {} },
          schema: { tables: {} },
          models: { "CallbackWidget" => { file: "app/models/callback_widget.rb", concerns: [],
                                          instance_methods: (1..30).map { |i| "step_#{i}" },
                                          instance_method_count: count } }
        }
      end

      def warnings_for(context)
        allow(described_class).to receive(:cached_context).and_return(context)
        with_app_file("app/models/callback_widget.rb", source) do |file, path|
          described_class.check_rails_semantics(file, path).join("\n")
        end
      end

      it "asks the loaded class on the booted tier" do
        stub_const("CallbackWidget", Class.new(ActiveRecord::Base) { def normalize_email; end })

        expect(warnings_for(context_with(40))).not_to include("normalize_email")
      end

      # Callbacks run private methods, and a base class usually keeps them
      # private.
      it "counts a private method the class inherits" do
        parent = Class.new(ActiveRecord::Base) do
          self.abstract_class = true

          private

          def normalize_email; end
        end
        stub_const("CallbackWidget", Class.new(parent))

        expect(warnings_for(context_with(40))).not_to include("normalize_email")
      end

      it "still flags a method the loaded class lacks" do
        stub_const("CallbackWidget", Class.new(ActiveRecord::Base))

        expect(warnings_for(context_with(40))).to include("before_save :normalize_email - method not found")
      end

      it "makes no claim from a truncated list on the static tier" do
        allow(RailsAiContext).to receive(:static_tier?).and_return(true)

        expect(warnings_for(context_with(40))).not_to include("normalize_email")
      end

      it "still flags a method a complete list lacks on the static tier" do
        allow(RailsAiContext).to receive(:static_tier?).and_return(true)

        expect(warnings_for(context_with(30))).to include("before_save :normalize_email - method not found")
      end
    end

    it "flags a scope chain that loads every record into memory" do
      source = <<~RUBY
        class WidgetsController < ApplicationController
          def index
            @names = Widget.active.map { |w| w.name }
          end
        end
      RUBY

      with_app_file("app/controllers/widgets_controller.rb", source) do |file, path|
        warnings = described_class.check_rails_semantics(file, path)
        expect(warnings.join).to include("may load all records into memory")
      end
    end
  end
end
