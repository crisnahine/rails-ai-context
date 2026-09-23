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
