# frozen_string_literal: true

require "spec_helper"

RSpec.describe RailsAiContext::Tools::GenerateTest do
  # A suite that calls `create(:post)` bare includes FactoryBot's methods.
  def factory_syntax = [ "FactoryBot::Syntax::Methods" ]

  # Every `is_expected.to belong_to(...)` line is a shoulda-matchers matcher,
  # so the generator only writes them for an app that bundles it.
  def bundling_shoulda
    allow(RailsAiContext::GemLock).to receive(:for)
      .and_return(RailsAiContext::GemLock::Spec.new({ "shoulda-matchers" => "6.4.0" }))
  end

  before { described_class.reset_cache! }

  # Every file any example here generates must parse as Ruby.
  before do
    allow(described_class).to receive(:call).and_wrap_original do |original, *args, **kwargs|
      original.call(*args, **kwargs).tap do |response|
        response.content.first[:text].scan(/```ruby\n(.*?)```/m).flatten.each do |source|
          expect(Prism.parse(source).success?).to be(true), source
        end
      end
    end
  end

  describe ".call" do
    it "returns an MCP::Tool::Response" do
      result = described_class.call(model: "NonExistent")
      expect(result).to be_a(MCP::Tool::Response)
    end

    it "requires at least one parameter" do
      result = described_class.call
      text = result.content.first[:text]
      expect(text).to include("Provide at least one")
      expect(result.error?).to be(true)
    end

    it "returns not-found for unknown model" do
      result = described_class.call(model: "ZzzNonexistentModel")
      text = result.content.first[:text]
      expect(text).to include("not found")
    end

    it "generates rspec-style output when framework is rspec" do
      bundling_shoulda
      allow(described_class).to receive(:cached_context).and_return({
        tests: { framework: "rspec", factories: { count: 1 }, factory_names: {} },
        models: {
          "User" => {
            associations: [ { type: "has_many", name: "posts" } ],
            validations: [ { kind: "presence", attributes: %w[ email ] } ],
            scopes: [ { name: "active", body: "where(active: true)" } ],
            enums: {},
            callbacks: {}
          }
        }
      })

      result = described_class.call(model: "User")
      text = result.content.first[:text]
      expect(text).to include("RSpec.describe User")
      expect(text).to include("associations")
      expect(text).to include("validations")
      expect(text).to include("validate_presence_of(:email)")
      expect(text).to include("have_many(:posts)")
      expect(text).to include(".active")
    end

    it "heads the generated file with its path, fence and helper require" do
      allow(described_class).to receive(:cached_context).and_return({
        tests: { framework: "rspec", factories: { count: 0 }, factory_names: {} },
        models: { "User" => { associations: [], validations: [], scopes: [], enums: {}, callbacks: {} } }
      })

      text = described_class.call(model: "User").content.first[:text]

      expect(text).to include(<<~MD)
        # spec/models/user_spec.rb

        ```ruby
        # frozen_string_literal: true

        require "rails_helper"

        RSpec.describe User, type: :model do
      MD
    end

    it "names no guessed table for a model whose table the source computes" do
      allow(described_class).to receive(:cached_context).and_return({
        tests: { framework: "minitest", fixtures: {}, factory_names: {} },
        models: { "Archive" => { table_set_by: "Archive.table_name", associations: [], validations: [], scopes: [], enums: {}, callbacks: {} } }
      })

      expect(described_class.call(model: "Archive").content.first[:text]).to include("# TODO: no Archive fixture found; build a valid record here")
    end

    it "heads a minitest file with its path, fence and test_helper require" do
      allow(described_class).to receive(:cached_context).and_return({
        tests: { framework: "minitest", fixtures: {}, factory_names: {} },
        models: { "User" => { table_name: "users", associations: [], validations: [], scopes: [], enums: {}, callbacks: {} } }
      })

      text = described_class.call(model: "User").content.first[:text]

      expect(text).to include(<<~MD)
        # test/models/user_test.rb

        ```ruby
        # frozen_string_literal: true

        require "test_helper"

        class UserTest < ActiveSupport::TestCase
      MD
    end

    # The blog's `length: { minimum: 10 }, allow_blank: true` got `body = ""`,
    # a value it allows, and the test failed on a valid record.
    it "breaks a length validation with a value it rejects" do
      validations = [
        { kind: "length", attributes: %w[body], options: { minimum: 10, allow_blank: true } },
        { kind: "length", attributes: %w[title], options: { maximum: 120 } },
        { kind: "length", attributes: %w[code], options: { is: 6 } },
        { kind: "length", attributes: %w[handle], options: { in: "3..20" } },
        { kind: "length", attributes: %w[name], options: { minimum: 1 } },
        { kind: "length", attributes: %w[nickname], options: { minimum: 1, allow_blank: true } }
      ]
      allow(described_class).to receive(:cached_context).and_return({
        tests: { framework: "minitest", fixtures: {}, factory_names: {} },
        models: { "User" => { table_name: "users", associations: [], validations: validations, scopes: [], enums: {}, callbacks: {} } }
      })

      text = described_class.call(model: "User").content.first[:text]

      expect(text).to include("@user.body = \"a\" * 9\n", "@user.title = \"a\" * 121\n", "@user.code = \"a\" * 7\n",
                              "@user.handle = \"a\" * 21\n", "@user.name = \"\"\n")
      expect(text).to include("  test \"validates length of nickname\" do\n    skip \"set nickname to a length the validation rejects\"\n  end")
    end

    # Some apps keep model tests in test/unit/app/models and controller tests
    # in test/functional. A generated file headed test/models/... lands where
    # the app does not look.
    it "writes a model test where the app already keeps its model tests" do
      Dir.mktmpdir do |root|
        FileUtils.mkdir_p(File.join(root, "test", "unit", "app", "models"))
        File.write(File.join(root, "test", "unit", "app", "models", "person_test.rb"), "class PersonTest < ActiveSupport::TestCase\nend\n")
        allow(described_class).to receive(:rails_app).and_return(double(root: Pathname.new(root)))
        allow(described_class).to receive(:cached_context).and_return({
          tests: { framework: "minitest", fixtures: {}, factory_names: {} },
          models: {
            "Organisation" => { table_name: "organisations", associations: [], validations: [], scopes: [], enums: {}, callbacks: {} },
            "Person" => { table_name: "people", associations: [], validations: [], scopes: [], enums: {}, callbacks: {} }
          }
        })

        text = described_class.call(model: "Organisation").content.first[:text]

        expect(text).to include("# test/unit/app/models/organisation_test.rb")
      end
    end

    it "writes a controller test where the app already keeps its controller tests" do
      Dir.mktmpdir do |root|
        FileUtils.mkdir_p(File.join(root, "test", "functional", "admin"))
        File.write(File.join(root, "test", "functional", "admin", "organisations_controller_test.rb"),
                   "class Admin::OrganisationsControllerTest < ActionController::TestCase\nend\n")
        allow(described_class).to receive(:rails_app).and_return(double(root: Pathname.new(root)))
        allow(described_class).to receive(:cached_context).and_return({
          tests: { framework: "minitest", fixtures: {}, factory_names: {} },
          controllers: { controllers: {
            "Admin::EditionsController" => { actions: %w[index] },
            "Admin::OrganisationsController" => { actions: %w[index] }
          } },
          routes: { routes: [] }
        })

        text = described_class.call(controller: "Admin::EditionsController").content.first[:text]

        expect(text).to include("# test/functional/admin/editions_controller_test.rb")
      end
    end

    describe "an app that names its tests its own way" do
      def app_with_tests(root, files)
        files.each do |rel|
          FileUtils.mkdir_p(File.dirname(File.join(root, rel)))
          File.write(File.join(root, rel), "describe Thing do\n  it \"works\" do\n  end\nend\n")
        end
        allow(described_class).to receive(:rails_app).and_return(double(root: Pathname.new(root)))
      end

      let(:model) { { associations: [], validations: [], scopes: [], enums: {}, callbacks: {} } }

      # An app that names its model specs user_model_spec.rb.
      it "takes the file-name suffix from the app's own model tests" do
        Dir.mktmpdir do |root|
          app_with_tests(root, %w[spec/models/user_model_spec.rb spec/models/order_model_spec.rb])
          allow(described_class).to receive(:cached_context).and_return({
            tests: { framework: "rspec", factories: { count: 0 }, factory_names: {} },
            models: { "User" => model, "Order" => model, "Invoice" => model }
          })

          text = described_class.call(model: "Invoice").content.first[:text]

          expect(text).to include("# spec/models/invoice_model_spec.rb")
        end
      end

      it "names an engine's test from its test/dummy relative to the dummy, as analyze_feature does" do
        Dir.mktmpdir do |engine|
          dummy = File.join(engine, "test", "dummy")
          FileUtils.mkdir_p(dummy)
          app_with_tests(engine, %w[test/models/widget_test.rb])
          allow(described_class).to receive(:rails_app).and_return(double(root: Pathname.new(dummy)))
          allow(RailsAiContext::PathResolver).to receive(:enclosing_engine_roots).and_return([ engine ])
          allow(described_class).to receive(:cached_context).and_return({
            tests: { framework: "minitest", fixtures: nil },
            models: { "Widget" => model, "Gadget" => model }
          })

          expect(described_class.call(model: "Widget").content.first[:text]).to include("../models/widget_test.rb already exists")
          expect(described_class.call(model: "Gadget").content.first[:text]).to include("# ../models/gadget_test.rb")
        end
      end

      # `rails g model` writes the test file, so for most models it exists, and
      # "it exists" alone gave nothing to add to it.
      it "addresses the cases to a model's existing test rather than a second file" do
        Dir.mktmpdir do |root|
          app_with_tests(root, %w[spec/models/invoice_model_spec.rb spec/models/order_model_spec.rb])
          allow(described_class).to receive(:cached_context).and_return({
            tests: { framework: "rspec", factories: { count: 0 }, factory_names: {} },
            models: { "Invoice" => model, "Order" => model }
          })

          text = described_class.call(model: "Invoice").content.first[:text]

          expect(text).to start_with("spec/models/invoice_model_spec.rb already exists. Add the cases below that it lacks to it")
          expect(text).to include("# spec/models/invoice_model_spec.rb\n")
          expect(text).to include("RSpec.describe Invoice, type: :model do")
        end
      end

      # An app can name its system specs after controllers (spec/system/admin/
      # budgets_spec.rb) and has more of them than controller specs. A system
      # spec is not where a controller's spec goes.
      it "does not take a system spec named after a controller as its spec" do
        Dir.mktmpdir do |root|
          app_with_tests(root, %w[spec/system/admin/budgets_spec.rb spec/system/admin/polls_spec.rb spec/system/admin/users_spec.rb
                             spec/controllers/admin/polls_controller_spec.rb])
          allow(described_class).to receive(:cached_context).and_return({
            tests: { framework: "rspec", factories: { count: 0 }, factory_names: {} },
            controllers: { controllers: {
              "Admin::BudgetsController" => { actions: %w[index] },
              "Admin::PollsController" => { actions: %w[index] },
              "Admin::UsersController" => { actions: %w[index] }
            } },
            routes: { routes: [] }
          })

          text = described_class.call(controller: "Admin::BudgetsController").content.first[:text]

          expect(text).to include("# spec/controllers/admin/budgets_controller_spec.rb")
          expect(text).not_to include("spec/system")
        end
      end

      # An app that keeps controller specs in spec/controllers, not spec/requests.
      it "writes a controller spec where the app keeps its controller specs" do
        Dir.mktmpdir do |root|
          app_with_tests(root, %w[spec/controllers/api/v1/users_controller_spec.rb spec/controllers/api/v1/orders_controller_spec.rb])
          allow(described_class).to receive(:cached_context).and_return({
            tests: { framework: "rspec", factories: { count: 0 }, factory_names: {} },
            controllers: { controllers: {
              "Api::V1::UsersController" => { actions: %w[index] },
              "Api::V1::OrdersController" => { actions: %w[index] },
              "Api::V1::InvoicesController" => { actions: %w[index] }
            } },
            routes: { routes: [] }
          })

          text = described_class.call(controller: "Api::V1::InvoicesController").content.first[:text]

          expect(text).to include("# spec/controllers/api/v1/invoices_controller_spec.rb")
        end
      end
    end

    # An app that keeps its controller specs in spec/controllers. A request spec
    # written there sits among them in another style; a controller spec
    # among controller specs names the action, not the URL.
    it "writes a controller spec, not a request spec, among the app's controller specs" do
      Dir.mktmpdir do |root|
        FileUtils.mkdir_p(File.join(root, "spec", "controllers", "api", "v1"))
        %w[users orders].each do |name|
          File.write(File.join(root, "spec", "controllers", "api", "v1", "#{name}_controller_spec.rb"),
                     "RSpec.describe Api::V1::#{name.camelize}Controller, type: :controller do\nend\n")
        end
        allow(described_class).to receive(:rails_app).and_return(double(root: Pathname.new(root)))
        allow(described_class).to receive(:cached_context).and_return({
          tests: { framework: "rspec", factories: { count: 2 }, factory_names: { "spec/factories/all.rb" => %w[invoice account] } },
          models: { "Invoice" => { table_name: "invoices", associations: [ { type: "belongs_to", name: "account" } ] } },
          controllers: { controllers: {
            "Api::V1::UsersController" => { actions: %w[index] },
            "Api::V1::OrdersController" => { actions: %w[index] },
            "Api::V1::InvoicesController" => { actions: %w[index show] }
          } },
          routes: { by_controller: { "api/v1/invoices" => [
            { verb: "GET", path: "/api/v1/accounts/:account_id/invoices", action: "index", name: "api_v1_account_invoices" },
            { verb: "GET", path: "/api/v1/accounts/:account_id/invoices/:id", action: "show", name: "api_v1_account_invoice" }
          ] } }
        })

        text = described_class.call(controller: "Api::V1::InvoicesController").content.first[:text]

        expect(text).to include("# spec/controllers/api/v1/invoices_controller_spec.rb")
        expect(text).to include("RSpec.describe Api::V1::InvoicesController, type: :controller do")
        expect(text).to include("get :index, params: { account_id: account }")
        expect(text).to include("get :show, params: { account_id: account, id: invoice }")
        expect(text).not_to include("type: :request")
        expect(text).not_to include("_url")
      end
    end

    # In one app 106 of 107 functional tests are ActionController::TestCase
    # and build their records with factories. An integration test that skips
    # every member action for want of a fixture follows neither.
    it "writes a controller test in the test class and data style the app's own use" do
      Dir.mktmpdir do |root|
        FileUtils.mkdir_p(File.join(root, "test", "functional", "admin"))
        %w[organisations people].each do |name|
          File.write(File.join(root, "test", "functional", "admin", "#{name}_controller_test.rb"),
                     "class Admin::#{name.camelize}ControllerTest < ActionController::TestCase\n" \
                     "  setup do\n    @record = create(:#{name.singularize})\n  end\nend\n")
        end
        allow(described_class).to receive(:rails_app).and_return(double(root: Pathname.new(root)))
        allow(described_class).to receive(:cached_context).and_return({
          tests: { framework: "minitest", test_helper_setup: factory_syntax, factories: { location: "test/factories", count: 3 },
                   factory_names: { "test/factories/editions.rb" => [ "edition" ] } },
          models: { "Edition" => { table_name: "editions" } },
          controllers: { controllers: {
            "Admin::EditionsController" => { actions: %w[index show] },
            "Admin::OrganisationsController" => { actions: %w[index] },
            "Admin::PeopleController" => { actions: %w[index] }
          } },
          routes: { by_controller: { "admin/editions" => [
            { verb: "GET", path: "/admin/editions", action: "index", name: "admin_editions" },
            { verb: "GET", path: "/admin/editions/:id", action: "show", name: "admin_edition" }
          ] } }
        })

        text = described_class.call(controller: "Admin::EditionsController").content.first[:text]

        expect(text).to include("class Admin::EditionsControllerTest < ActionController::TestCase")
        expect(text).to include("@edition = create(:edition)")
        expect(text).to include("get :index")
        expect(text).to include("get :show, params: { id: @edition }")
        expect(text).not_to include("skip")
      end
    end

    # A Node's table can be `node` while its fixtures are nodes.yml. Looking the
    # fixture up by table name found none and wrote a TODO and Node.new.
    describe "a fixture set not named after the table" do
      def singular_table_app(root, helper: nil)
        FileUtils.mkdir_p(File.join(root, "test", "fixtures"))
        File.write(File.join(root, "test", "test_helper.rb"), helper.to_s)
        allow(described_class).to receive(:rails_app).and_return(double(root: Pathname.new(root)))
      end

      it "finds the fixtures under the pluralized class name" do
        Dir.mktmpdir do |root|
          singular_table_app(root)
          File.write(File.join(root, "test", "fixtures", "nodes.yml"), "one:\n  title: A\n")
          allow(described_class).to receive(:cached_context).and_return({
            tests: { framework: "minitest", fixture_names: { "nodes" => [ "one" ] }, factory_names: {} },
            models: { "Node" => { table_name: "node", associations: [], validations: [], scopes: [], enums: {}, callbacks: {} } }
          })

          text = described_class.call(model: "Node").content.first[:text]

          expect(text).to include("@node = nodes(:one)")
          expect(text).not_to include("no node fixture found")
        end
      end

      it "finds the fixtures set_fixture_class maps to the model" do
        Dir.mktmpdir do |root|
          singular_table_app(root, helper: "class ActiveSupport::TestCase\n  set_fixture_class drupal_users: User\nend\n")
          File.write(File.join(root, "test", "fixtures", "drupal_users.yml"), "bob:\n  name: Bob\n")
          allow(described_class).to receive(:cached_context).and_return({
            tests: { framework: "minitest", fixture_names: { "drupal_users" => [ "bob" ] }, factory_names: {} },
            models: { "User" => { table_name: "rusers", associations: [], validations: [], scopes: [], enums: {}, callbacks: {} } }
          })

          text = described_class.call(model: "User").content.first[:text]

          expect(text).to include("@user = drupal_users(:bob)")
        end
      end

      it "reads no fixture label through a fixture file symlinked out of the app" do
        Dir.mktmpdir do |outside|
          Dir.mktmpdir do |root|
            singular_table_app(root)
            File.write(File.join(outside, "nodes.yml"), "secret_label:\n  title: A\n")
            File.symlink(File.join(outside, "nodes.yml"), File.join(root, "test", "fixtures", "nodes.yml"))
            allow(described_class).to receive(:cached_context).and_return({
              tests: { framework: "minitest", fixture_names: {}, factory_names: {} },
              models: { "Node" => { table_name: "node", associations: [], validations: [], scopes: [], enums: {}, callbacks: {} } }
            })

            text = described_class.call(model: "Node").content.first[:text]

            expect(text).not_to include("secret_label")
          end
        end
      end
    end

    # A TestCase request names the action, so every dynamic path segment is
    # a param: contacts can sit under organisations, or a route can be
    # `graph/file/:uid/:id`. Passing only :id raises UrlGenerationError.
    describe "a TestCase for a controller with more path segments than :id" do
      def testcase_app(root, routes, fixture_names: {}, factories: true)
        FileUtils.mkdir_p(File.join(root, "test", "functional", "admin"))
        File.write(File.join(root, "test", "functional", "admin", "people_controller_test.rb"),
                   "class Admin::PeopleControllerTest < ActionController::TestCase\n" \
                   "  setup { #{factories ? "@p = create(:person)" : "@p = people(:one)"} }\nend\n")
        allow(described_class).to receive(:rails_app).and_return(double(root: Pathname.new(root)))
        allow(described_class).to receive(:cached_context).and_return({
          tests: { framework: "minitest", test_helper_setup: factory_syntax, factories: { location: "test/factories", count: 3 },
                   factory_names: { "test/factories/all.rb" => %w[contact organisation] }, fixture_names: fixture_names },
          models: { "Contact" => { table_name: "contacts" } },
          controllers: { controllers: {
            "Admin::ContactsController" => { actions: %w[index show] },
            "Admin::PeopleController" => { actions: %w[index] }
          } },
          routes: { by_controller: { "admin/contacts" => routes } }
        })
      end

      it "builds a nested parent once and passes its id alongside the record's" do
        Dir.mktmpdir do |root|
          testcase_app(root, [
            { verb: "GET", path: "/admin/organisations/:organisation_id/contacts", action: "index", name: "admin_organisation_contacts" },
            { verb: "GET", path: "/admin/organisations/:organisation_id/contacts/:id", action: "show", name: "admin_organisation_contact" }
          ])

          text = described_class.call(controller: "Admin::ContactsController").content.first[:text]

          expect(text).to include("@organisation = create(:organisation)")
          expect(text).to include("get :index, params: { organisation_id: @organisation }")
          expect(text).to include("get :show, params: { organisation_id: @organisation, id: @contact }")
        end
      end

      # A controller can find the contact through its own contactable, and its
      # contact factory attaches none, so the record is built under the
      # parent the route names: any other parent 404s every member action.
      it "attaches the record to the parent it is found through" do
        Dir.mktmpdir do |root|
          testcase_app(root, [
            { verb: "GET", path: "/admin/organisations/:organisation_id/contacts/:id", action: "show", name: "admin_organisation_contact" }
          ])
          ctx = described_class.cached_context
          ctx[:models]["Contact"][:associations] = [ { type: "belongs_to", name: "contactable", polymorphic: true } ]
          allow(described_class).to receive(:cached_context).and_return(ctx)

          text = described_class.call(controller: "Admin::ContactsController").content.first[:text]

          expect(text).to include("@organisation = create(:organisation)")
          expect(text).to include("@contact = create(:contact, contactable: @organisation)")
          expect(text).to include("get :show, params: { organisation_id: @organisation, id: @contact }")
        end
      end

      # A fixture row already carries its owner's key.
      it "takes a fixture record's parent from the record itself" do
        Dir.mktmpdir do |root|
          testcase_app(root, [
            { verb: "GET", path: "/admin/organisations/:organisation_id/contacts/:id", action: "show", name: "admin_organisation_contact" }
          ], fixture_names: { "contacts" => [ "one" ] }, factories: false)
          ctx = described_class.cached_context
          ctx[:tests][:factory_names] = {}
          ctx[:tests].delete(:factories)
          ctx[:models]["Contact"][:associations] = [ { type: "belongs_to", name: "organisation" } ]
          allow(described_class).to receive(:cached_context).and_return(ctx)

          text = described_class.call(controller: "Admin::ContactsController").content.first[:text]

          expect(text).to include("get :show, params: { organisation_id: @contact.organisation, id: @contact }")
        end
      end

      # A route like `/openid/:username(/:provider)`: :provider is optional,
      # so it is neither required of the test nor named as missing.
      it "asks only for the segments a route requires" do
        Dir.mktmpdir do |root|
          testcase_app(root, [ { verb: "GET", path: "/admin/contacts/:uid(/:provider)(.:format)", action: "show", name: "admin_contact_page" } ])

          text = described_class.call(controller: "Admin::ContactsController").content.first[:text]

          expect(text).to include("skip \"TODO: pass :uid for GET /admin/contacts/:uid(/:provider)(.:format)\"")
        end
      end

      it "skips, naming the segment, when a segment cannot be filled" do
        Dir.mktmpdir do |root|
          testcase_app(root, [ { verb: "GET", path: "/admin/contacts/:uid/:id", action: "show", name: "admin_contact_file" } ])

          text = described_class.call(controller: "Admin::ContactsController").content.first[:text]

          expect(text).to include(":uid")
          expect(text).to include("skip")
          expect(text).not_to include("get :show, params: { id: @contact }")
        end
      end
    end

    # The same holds for a request spec: one parent, the record built under it.
    it "builds a request spec's nested parent once and attaches the record to it" do
      allow(described_class).to receive(:cached_context).and_return({
        tests: { framework: "rspec", test_helper_setup: factory_syntax, factories: { count: 2 }, factory_names: { "spec/factories/all.rb" => %w[contact organisation] } },
        models: { "Contact" => { table_name: "contacts", associations: [ { type: "belongs_to", name: "organisation" } ] } },
        controllers: { controllers: { "ContactsController" => { actions: %w[show] } } },
        routes: { by_controller: { "contacts" => [
          { verb: "GET", path: "/organisations/:organisation_id/contacts/:id", action: "show", name: "organisation_contact" }
        ] } }
      })

      text = described_class.call(controller: "ContactsController").content.first[:text]

      expect(text).to include("let(:organisation) { create(:organisation) }")
      expect(text).to include("let(:contact) { create(:contact, organisation: organisation) }")
      expect(text).to include("organisation_contact_url(organisation, contact)")
    end

    # A factory-built integration test takes its parent from a factory too,
    # not from a fixture file the app does not keep.
    it "builds a nested parent with a factory in a factory-style integration test" do
      Dir.mktmpdir do |root|
        FileUtils.mkdir_p(File.join(root, "test", "controllers"))
        File.write(File.join(root, "test", "controllers", "people_controller_test.rb"),
                   "class PeopleControllerTest < ActionDispatch::IntegrationTest\n  setup { @p = create(:person) }\nend\n")
        allow(described_class).to receive(:rails_app).and_return(double(root: Pathname.new(root)))
        allow(described_class).to receive(:cached_context).and_return({
          tests: { framework: "minitest", test_helper_setup: factory_syntax, factories: { location: "test/factories", count: 3 },
                   factory_names: { "test/factories/all.rb" => %w[contact organisation] } },
          models: { "Contact" => { table_name: "contacts" } },
          controllers: { controllers: { "ContactsController" => { actions: %w[index] }, "PeopleController" => { actions: %w[index] } } },
          routes: { by_controller: { "contacts" => [
            { verb: "GET", path: "/organisations/:organisation_id/contacts", action: "index", name: "organisation_contacts" }
          ] } }
        })

        text = described_class.call(controller: "ContactsController").content.first[:text]

        expect(text).to include("@organisation = create(:organisation)")
        expect(text).to include("get organisation_contacts_url(@organisation)")
        expect(text).not_to include("skip")
      end
    end

    # A factory builds no owner unless told, so a factory-built record's
    # parent is never read off the record.
    it "does not read a factory-built record's parent off the record" do
      Dir.mktmpdir do |root|
        FileUtils.mkdir_p(File.join(root, "test", "controllers"))
        File.write(File.join(root, "test", "controllers", "people_controller_test.rb"),
                   "class PeopleControllerTest < ActionDispatch::IntegrationTest\n  setup { @p = create(:person) }\nend\n")
        allow(described_class).to receive(:rails_app).and_return(double(root: Pathname.new(root)))
        allow(described_class).to receive(:cached_context).and_return({
          tests: { framework: "minitest", factories: { location: "test/factories", count: 3 },
                   factory_names: { "test/factories/all.rb" => %w[contact] } },
          models: { "Contact" => { table_name: "contacts", associations: [ { type: "belongs_to", name: "organisation" } ] } },
          controllers: { controllers: { "ContactsController" => { actions: %w[show] }, "PeopleController" => { actions: %w[index] } } },
          routes: { by_controller: { "contacts" => [
            { verb: "GET", path: "/organisations/:organisation_id/contacts/:id", action: "show", name: "organisation_contact" }
          ] } }
        })

        text = described_class.call(controller: "ContactsController").content.first[:text]

        expect(text).not_to include("@contact.organisation")
        expect(text).to include("skip")
      end
    end

    # Rails names the accessor for test/fixtures/admin/users.yml admin_users.
    # `admin/users(:one)` and `@admin/user` are both Ruby division.
    it "names a namespaced model's fixture accessor and variable the way Rails does" do
      Dir.mktmpdir do |root|
        FileUtils.mkdir_p(File.join(root, "test", "fixtures", "admin"))
        File.write(File.join(root, "test", "fixtures", "admin", "users.yml"), "one:\n  name: A\n")
        allow(described_class).to receive(:rails_app).and_return(double(root: Pathname.new(root)))
        allow(described_class).to receive(:cached_context).and_return({
          tests: { framework: "minitest", factory_names: {} },
          models: { "Admin::User" => { table_name: "admin_users", associations: [], validations: [], scopes: [], enums: {}, callbacks: {},
                                       file: "app/models/admin/user.rb" } }
        })

        text = described_class.call(model: "Admin::User").content.first[:text]

        expect(text).to include("@admin_user = admin_users(:one)")
        expect(text).not_to include("@admin/user")
      end
    end

    it "names a namespaced model's let the way Ruby can read it" do
      Dir.mktmpdir do |root|
        FileUtils.mkdir_p(File.join(root, "spec", "models"))
        File.write(File.join(root, "spec", "models", "post_spec.rb"), "let(:post) { create(:post) }\nlet(:a) { create(:post) }\n")
        allow(described_class).to receive(:rails_app).and_return(double(root: Pathname.new(root)))
        allow(described_class).to receive(:cached_context).and_return({
          tests: { framework: "rspec", test_helper_setup: factory_syntax, factories: { count: 1 }, factory_names: { "spec/factories/admin.rb" => %w[admin_user] } },
          models: { "Admin::User" => { associations: [], validations: [], scopes: [], enums: {}, callbacks: {}, file: "app/models/admin/user.rb" },
                    "Post" => { associations: [], validations: [], scopes: [], enums: {}, callbacks: {} } }
        })

        text = described_class.call(model: "Admin::User").content.first[:text]

        expect(text).to include("let(:admin_user) { create(:admin_user) }")
      end
    end

    # The mapping can live in any file test_helper loads, and name the class
    # from the root scope.
    it "reads set_fixture_class from a support file, whatever the class's scope" do
      Dir.mktmpdir do |root|
        FileUtils.mkdir_p(File.join(root, "test", "fixtures"))
        FileUtils.mkdir_p(File.join(root, "test", "support"))
        File.write(File.join(root, "test", "test_helper.rb"), "Dir[File.expand_path(\"support/*.rb\", __dir__)].each { |f| require f }\n")
        File.write(File.join(root, "test", "support", "fixtures.rb"),
                   "class ActiveSupport::TestCase\n  set_fixture_class drupal_users: ::User\nend\n")
        File.write(File.join(root, "test", "fixtures", "drupal_users.yml"), "bob:\n  name: Bob\n")
        allow(described_class).to receive(:rails_app).and_return(double(root: Pathname.new(root)))
        allow(described_class).to receive(:cached_context).and_return({
          tests: { framework: "minitest", fixture_names: { "drupal_users" => [ "bob" ] }, factory_names: {} },
          models: { "User" => { table_name: "rusers", associations: [], validations: [], scopes: [], enums: {}, callbacks: {} } }
        })

        text = described_class.call(model: "User").content.first[:text]

        expect(text).to include("@user = drupal_users(:bob)")
      end
    end

    # A bare `assert_not valid?` on a valid fixture can never pass, so every
    # kind either makes the record invalid first or says it cannot.
    it "makes the record invalid before asserting each validation kind in a minitest" do
      validation = ->(kind, attr, options = {}) { { kind: kind, attributes: [ attr ], options: options } }
      allow(described_class).to receive(:cached_context).and_return({
        tests: { framework: "minitest", fixture_names: { "volumes" => [ "one" ] }, factory_names: {} },
        models: { "Volume" => { table_name: "volumes", validations: [
          validation.call("absence", "legacy_code"),
          validation.call("confirmation", "password"),
          validation.call("exclusion", "slug", { in: %w[admin root] }),
          validation.call("exclusion", "code", { in: "RESERVED" }),
          validation.call("acceptance", "terms"),
          validation.call("comparison", "ends_on", { greater_than: :starts_on })
        ] } }
      })

      text = described_class.call(model: "Volume").content.first[:text]
      body = ->(name) { text[/test "validates #{name}" do\n(.*?)\n  end/m, 1].to_s }

      expect(body.call("absence of legacy_code")).to include('@volume.legacy_code = "present"')
      expect(body.call("confirmation of password")).to include('@volume.password = "secret"')
        .and include('@volume.password_confirmation = "different"')
      expect(body.call("exclusion of slug")).to include('@volume.slug = "admin"')
      expect(body.call("exclusion of code")).to include("skip")
      expect(body.call("acceptance of terms")).to include('@volume.terms = "0"')
      expect(body.call("comparison of ends_on")).to include("skip")
      expect(body.call("comparison of ends_on")).not_to include("assert_not")
    end

    # With no named route the URL is spelled out, and an optional group left
    # in it is a literal parenthesis and an undefined variable.
    it "spells an unnamed route's URL without its optional parts" do
      allow(described_class).to receive(:cached_context).and_return({
        tests: { framework: "minitest", fixture_names: { "users" => [ "one" ] } },
        models: { "User" => { table_name: "users" } },
        controllers: { controllers: { "OpenidController" => { actions: %w[user_page] } } },
        routes: { by_controller: { "openid" => [
          { verb: "GET", path: "/openid/:user_id(/:provider)(.:format)", action: "user_page", name: nil }
        ] } }
      })

      text = described_class.call(controller: "OpenidController").content.first[:text]

      expect(text).to include('get "/openid/#{user_id}"')
      expect(text).not_to include("provider")
    end

    it "names the model where its controller's tests would name a table the source computes" do
      allow(described_class).to receive(:cached_context).and_return({
        tests: { framework: "minitest", fixture_names: {} },
        models: { "Archive" => { table_set_by: "Archive.table_name", associations: [], validations: [], scopes: [], enums: {}, callbacks: {} } },
        controllers: { controllers: { "ArchivesController" => { actions: %w[index show update destroy] } } },
        routes: { by_controller: { "archives" => [
          { verb: "GET", path: nil, action: "index" },
          { verb: "GET", path: "/archives/:id(.:format)", action: "show", name: "archive" },
          { verb: "PATCH", path: "/archives/:id(.:format)", action: "update" },
          { verb: "DELETE", path: "/archives/:id(.:format)", action: "destroy" }
        ] } }
      })

      text = described_class.call(controller: "ArchivesController").content.first[:text]

      expect(text.scan(/skip "TODO: (Archive has[^"]*)"/).flatten.uniq).to eq([ "Archive has a table name the source computes, so its columns are unknown here; supply the attributes it needs" ])
      expect(text).not_to include('get "/"')
    end

    it "requests a route that answers several verbs with one of them" do
      allow(described_class).to receive(:cached_context).and_return({
        tests: { framework: "minitest", fixture_names: {} },
        models: {},
        controllers: { controllers: { "UserinfoController" => { actions: %w[index new] } } },
        routes: { by_controller: { "userinfo" => [
          { verb: "GET|POST", path: "/userinfo(.:format)", action: "index", name: "userinfo" },
          { verb: "ANY", path: "/userinfo/new(.:format)", action: "new", name: "new_userinfo" }
        ] } }
      })

      text = described_class.call(controller: "UserinfoController").content.first[:text]

      expect(text).to include("get userinfo_url").and include("get new_userinfo_url")
      expect(text).not_to match(/get\|post|\bany\b/)
    end

    # An app can route `resources :contacts` while ContactsController has no
    # show method and no show template: a show test would fail with an
    # AbstractController::ActionNotFound the moment it ran.
    describe "a routed action the controller does not implement" do
      def contacts_app(root, actions:, templates: [], extend_with: nil, include: nil)
        FileUtils.mkdir_p(File.join(root, "app", "controllers"))
        File.write(File.join(root, "app", "controllers", "application_controller.rb"),
                   "class ApplicationController < ActionController::Base\nend\n")
        File.write(File.join(root, "app", "controllers", "contacts_controller.rb"),
                   "class ContactsController < ApplicationController\n#{"  extend #{extend_with}\n" if extend_with}" \
                   "#{"  include #{include}\n" if include}#{Array(actions).map { |a| "  def #{a}; end\n" }.join}end\n")
        templates.each do |action|
          FileUtils.mkdir_p(File.join(root, "app", "views", "contacts"))
          File.write(File.join(root, "app", "views", "contacts", "#{action}.html.erb"), "")
        end
        allow(described_class).to receive(:rails_app).and_return(double(root: Pathname.new(root)))
        allow(described_class).to receive(:cached_context).and_return({
          tests: { framework: "minitest", fixture_names: { "contacts" => [ "one" ] } },
          models: { "Contact" => { table_name: "contacts" } },
          controllers: { controllers: { "ContactsController" => { actions: actions } } },
          routes: { by_controller: { "contacts" => [
            { verb: "GET", path: "/contacts", action: "index", name: "contacts" },
            { verb: "GET", path: "/contacts/:id", action: "show", name: "contact" },
            { verb: "GET", path: "/contacts/:id/edit", action: "edit", name: "edit_contact" }
          ] } }
        })
      end

      it "writes no test for it and names it" do
        Dir.mktmpdir do |root|
          contacts_app(root, actions: %w[index edit])

          text = described_class.call(controller: "ContactsController").content.first[:text]

          expect(text).to include("should get index")
          expect(text).to include("should get edit")
          expect(text).not_to include("should show contact")
          expect(text).to include("# Not tested: show is routed, but ContactsController defines no show method or template.")
        end
      end

      it "does not call a controller with only unimplemented routes unrouted" do
        Dir.mktmpdir do |root|
          contacts_app(root, actions: [])

          text = described_class.call(controller: "ContactsController").content.first[:text]

          expect(text).not_to include("no routes found")
          expect(text).to include("none of the routed actions (index, show, edit) is implemented")
        end
      end

      # A ContactsController can get reorder_for_home_page from a class
      # macro that builds it with define_method. The source-read action list
      # cannot see it, so its absence is not proven and it is not skipped.
      it "keeps an action something defines with define_method" do
        Dir.mktmpdir do |root|
          FileUtils.mkdir_p(File.join(root, "app", "controllers"))
          File.write(File.join(root, "app", "controllers", "home_page_list_controller.rb"), <<~RUBY)
            module HomePageListController
              def is_home_page_list_controller_for(name)
                include(Module.new { define_method(:reorder_for_home_page) { head :ok } })
              end
            end
          RUBY
          contacts_app(root, actions: %w[index edit], extend_with: "HomePageListController")
          ctx = described_class.cached_context
          ctx[:routes][:by_controller]["contacts"] << { verb: "GET", path: "/contacts/reorder_for_home_page", action: "reorder_for_home_page", name: "reorder_for_home_page_contacts" }
          allow(described_class).to receive(:cached_context).and_return(ctx)

          text = described_class.call(controller: "ContactsController").content.first[:text]

          expect(text).not_to include("Not tested: reorder_for_home_page")
          expect(text).to include("reorder_for_home_page")
          expect(text).to include("Not tested: show")
        end
      end

      it "keeps an action a concern it includes defines" do
        Dir.mktmpdir do |root|
          FileUtils.mkdir_p(File.join(root, "app", "controllers", "concerns"))
          File.write(File.join(root, "app", "controllers", "concerns", "showable.rb"),
                     "module Showable\n  def show\n  end\nend\n")
          contacts_app(root, actions: %w[index edit], include: "Showable")

          text = described_class.call(controller: "ContactsController").content.first[:text]

          expect(text).to include("should show contact")
          expect(text).not_to include("Not tested")
        end
      end

      # A controller under a gem's controller (Devise's SessionsController)
      # inherits actions no app file shows. Their absence is unproven.
      it "keeps every route of a controller whose ancestor comes from a gem" do
        Dir.mktmpdir do |root|
          FileUtils.mkdir_p(File.join(root, "app", "controllers", "users"))
          File.write(File.join(root, "app", "controllers", "users", "sessions_controller.rb"),
                     "class Users::SessionsController < Devise::SessionsController\n  def create\n    super\n  end\nend\n")
          allow(described_class).to receive(:rails_app).and_return(double(root: Pathname.new(root)))
          allow(described_class).to receive(:cached_context).and_return({
            tests: { framework: "minitest", fixture_names: {} },
            models: {},
            controllers: { controllers: { "Users::SessionsController" => {
              actions: %w[create], file: "app/controllers/users/sessions_controller.rb", parent_class: "Devise::SessionsController"
            } } },
            routes: { by_controller: { "users/sessions" => [
              { verb: "GET", path: "/users/sign_in", action: "new", name: "new_user_session" },
              { verb: "POST", path: "/users/sign_in", action: "create", name: "user_session" },
              { verb: "DELETE", path: "/users/sign_out", action: "destroy", name: "destroy_user_session" }
            ] } }
          })

          text = described_class.call(controller: "Users::SessionsController").content.first[:text]

          expect(text).not_to include("Not tested")
          expect(text).to include("should get new")
        end
      end

      it "tests an action a template implements without a method" do
        Dir.mktmpdir do |root|
          contacts_app(root, actions: %w[index edit], templates: %w[show])

          text = described_class.call(controller: "ContactsController").content.first[:text]

          expect(text).to include("should show contact")
          expect(text).not_to include("Not tested")
        end
      end

      it "tests every route when the controller's actions are unknown" do
        Dir.mktmpdir do |root|
          contacts_app(root, actions: nil)

          text = described_class.call(controller: "ContactsController").content.first[:text]

          expect(text).to include("should show contact")
        end
      end
    end

    # A route `graph/file/:uid/:id` to csvfiles#delete, where csvfiles has
    # a uid column: the record the test builds fills the segment itself.
    describe "a custom segment a record's column fills" do
      def files_app(extra_columns: [], routes:, parents: {})
        allow(described_class).to receive(:cached_context).and_return({
          tests: { framework: "minitest", fixture_names: { "csvfiles" => [ "one" ] } },
          models: { "Csvfile" => { table_name: "csvfiles" } },
          schema: { tables: { "csvfiles" => { columns: [ { name: "id", type: "bigint" }, { name: "uid", type: "integer" } ] + extra_columns } } },
          controllers: { controllers: { "CsvfilesController" => { actions: routes.map { |route| route[:action] } } } },
          routes: { by_controller: { "csvfiles" => routes } }
        })
      end

      it "passes the record's own attribute for the segment" do
        files_app(routes: [ { verb: "GET", path: "/graph/file/:uid/:id", action: "delete", name: nil } ])

        text = described_class.call(controller: "CsvfilesController").content.first[:text]

        expect(text).to include('get "/graph/file/#{uid}/#{id}"')
        expect(text).to include("uid = @csvfile.uid")
        expect(text).not_to include("skip")
      end

      it "passes a route parent's attribute when the parent has the column" do
        Dir.mktmpdir do |root|
          FileUtils.mkdir_p(File.join(root, "test", "controllers"))
          File.write(File.join(root, "test", "controllers", "people_controller_test.rb"),
                     "class PeopleControllerTest < ActionController::TestCase\n  setup { @p = create(:person) }\nend\n")
          allow(described_class).to receive(:rails_app).and_return(double(root: Pathname.new(root)))
          allow(described_class).to receive(:cached_context).and_return({
            tests: { framework: "minitest", factories: { count: 2 }, factory_names: { "test/factories/all.rb" => %w[contact organisation] } },
            models: { "Contact" => { table_name: "contacts" }, "Organisation" => { table_name: "organisations" } },
            schema: { tables: { "contacts" => { columns: [ { name: "id", type: "bigint" } ] },
                                "organisations" => { columns: [ { name: "id", type: "bigint" }, { name: "region", type: "string" } ] } } },
            controllers: { controllers: { "ContactsController" => { actions: %w[index] }, "PeopleController" => { actions: %w[index] } } },
            routes: { by_controller: { "contacts" => [
              { verb: "GET", path: "/organisations/:organisation_id/regions/:region/contacts", action: "index", name: "organisation_region_contacts" }
            ] } }
          })

          text = described_class.call(controller: "ContactsController").content.first[:text]

          expect(text).to include("get :index, params: { organisation_id: @organisation, region: @organisation.region }")
        end
      end

      it "still skips a segment no column names" do
        files_app(routes: [ { verb: "GET", path: "/graph/file/:token/:id", action: "delete", name: nil } ])

        text = described_class.call(controller: "CsvfilesController").content.first[:text]

        expect(text).to include("skip")
      end
    end

    it "tests an engine controller from the routes the app draws into the engine" do
      allow(described_class).to receive(:cached_context).and_return({
        tests: { framework: "minitest", fixture_names: {} },
        models: {},
        controllers: { controllers: { "Store::Admin::OrdersController" => { actions: %w[index] } } },
        routes: { by_controller: {}, engine_routes: [ { engine: "Store::Core::Engine", mount: "/", routes: [
          { verb: "GET", path: "/admin/orders", controller: "store/admin/orders", action: "index", name: "store.admin_orders" }
        ] } ] }
      })

      text = described_class.call(controller: "Store::Admin::OrdersController").content.first[:text]

      expect(text).to include("get store.admin_orders_url")
    end

    # A shortlink action can redirect when the user exists and raise when not;
    # verify_email always redirects to /login. Asserting :success on either
    # is a test that fails the first time it runs.
    describe "the response an action gives, read from its body" do
      let(:controller_source) do
        <<~RUBY
          class UsersController < ApplicationController
            def profile
            end

            def verify_email
              user_id = User.validate_token(params[:token])
              flash[:notice] = "checked" if user_id != 0
              redirect_to "/login", flash: { notice: "done" }
            end

            def shortlink
              @user = User.find_by_username(params[:username])
              if @user
                redirect_to @user.path
              else
                raise ActiveRecord::RecordNotFound
              end
            end

            def ping
              head :no_content
            end

            def stats
              render json: { users: 1 }
            end

            def home
              redirect_to root_path
            end

            def leave
              redirect_to back_path
            end

            private

            def back_path
              "/"
            end
          end
        RUBY
      end

      def generated(framework:)
        Dir.mktmpdir do |root|
          FileUtils.mkdir_p(File.join(root, "app", "controllers"))
          File.write(File.join(root, "app", "controllers", "users_controller.rb"), controller_source)
          allow(described_class).to receive(:rails_app).and_return(double(root: Pathname.new(root)))
          actions = %w[profile verify_email shortlink ping stats home leave]
          allow(described_class).to receive(:cached_context).and_return({
            tests: { framework: framework, fixture_names: {}, factory_names: {} },
            models: {},
            controllers: { controllers: { "UsersController" => { actions: actions, file: "app/controllers/users_controller.rb" } } },
            routes: { by_controller: {
              "users" => actions.map { |action| { verb: "GET", path: "/users/#{action}", action: action, name: "users_#{action}" } },
              "pages" => [ { verb: "GET", path: "/", action: "index", name: "root" } ]
            } }
          })
          return described_class.call(controller: "UsersController").content.first[:text]
        end
      end

      def example_for(text, action)
        text[/(?:test|it) "[^"]*#{action}[^"]*" do\n(?:(?!\n  (?:end|test|it) ).)*/m]
      end

      it "asserts what each action answers in a minitest" do
        text = generated(framework: "minitest")

        expect(example_for(text, "profile")).to include("assert_response :success")
        expect(example_for(text, "verify_email")).to include("assert_response :redirect")
        expect(example_for(text, "verify_email")).to include('assert_redirected_to "/login"')
        expect(example_for(text, "shortlink")).to include("assert_operator response.status, :<, 500")
        expect(example_for(text, "shortlink")).not_to include(":success")
        expect(example_for(text, "ping")).to include("assert_response :no_content")
        expect(example_for(text, "stats")).to include('assert_equal "application/json", response.media_type')
        expect(example_for(text, "home")).to include("assert_redirected_to root_path")
      end

      # A private method ending in _path is no route helper, and the test cannot call it.
      it "names a redirect target only when it is one of the app's routes" do
        text = generated(framework: "minitest")

        expect(example_for(text, "leave")).to include("assert_response :redirect")
        expect(example_for(text, "leave")).not_to include("back_path")
      end

      # An app whose actions answer through render helpers defined
      # in an ApplicationController the controller listing leaves out.
      it "reads a helper from an ancestor the controller listing leaves out" do
        Dir.mktmpdir do |root|
          FileUtils.mkdir_p(File.join(root, "app", "controllers"))
          File.write(File.join(root, "app", "controllers", "application_controller.rb"), <<~RUBY)
            class ApplicationController < ActionController::Base
              def render_failure(messages, status)
                render json: { errors: messages }, status: status
              end
            end
          RUBY
          File.write(File.join(root, "app", "controllers", "keys_controller.rb"), <<~RUBY)
            class KeysController < ApplicationController
              def show
                render_failure(["gone"], :gone)
              end
            end
          RUBY
          allow(described_class).to receive(:rails_app).and_return(double(root: Pathname.new(root)))
          allow(described_class).to receive(:cached_context).and_return({
            tests: { framework: "minitest", fixture_names: {}, factory_names: {} },
            models: {},
            controllers: { controllers: { "KeysController" => { actions: %w[show], file: "app/controllers/keys_controller.rb",
                                                               parent_class: "ApplicationController" } } },
            routes: { by_controller: { "keys" => [ { verb: "GET", path: "/keys/show", action: "show", name: "keys_show" } ] } }
          })

          text = described_class.call(controller: "KeysController").content.first[:text]

          expect(text).to include("assert_operator response.status, :<, 500")
          expect(text).not_to include("assert_response :success")
        end
      end

      it "asserts what each action answers in a request spec" do
        text = generated(framework: "rspec")

        expect(text).to include("expect(response).to have_http_status(:redirect)")
        expect(text).to include('expect(response).to redirect_to("/login")')
        expect(text).to include("expect(response.status).to be < 500")
        expect(text).to include("expect(response).to have_http_status(:no_content)")
        expect(text).to include('expect(response.media_type).to eq("application/json")')
      end
    end

    # An API create answers `render json:, status: :created` and a destroy
    # `head :no_content`; the scaffold's redirect assertion fails both.
    describe "create, update and destroy, read from their bodies" do
      let(:api_source) do
        <<~RUBY
          class Api::PostsController < ApplicationController
            def create
              @post = Post.new(post_params)
              if @post.save
                render json: @post, status: :created
              else
                render json: @post.errors, status: :unprocessable_entity
              end
            end

            def update
              if @post.update(post_params)
                render json: @post
              else
                render json: @post.errors, status: :unprocessable_entity
              end
            end

            def destroy
              @post.destroy
              head :no_content
            end
          end
        RUBY
      end

      let(:html_source) do
        <<~RUBY
          class PostsController < ApplicationController
            def create
              @post = Post.new(post_params)
              respond_to do |format|
                if @post.save
                  format.html { redirect_to post_url(@post), notice: "Created." }
                  format.json { render :show, status: :created }
                else
                  format.html { render :new, status: :unprocessable_entity }
                end
              end
            end

            def destroy
              @post.destroy!
              redirect_to posts_path, status: :see_other
            end
          end
        RUBY
      end

      def generated(source, controller:, key:, framework:, json:)
        Dir.mktmpdir do |root|
          file = "app/controllers/#{key}_controller.rb"
          FileUtils.mkdir_p(File.dirname(File.join(root, file)))
          File.write(File.join(root, file), source)
          allow(described_class).to receive(:rails_app).and_return(double(root: Pathname.new(root)))
          base = "/#{key}"
          allow(described_class).to receive(:cached_context).and_return({
            tests: { framework: framework, fixture_names: { "posts" => [ "one" ] }, factories: { count: 1 },
                     factory_names: { "spec/factories/posts.rb" => %w[post] } },
            models: { "Post" => { table_name: "posts" } },
            schema: { tables: { "posts" => { columns: [ { name: "title", type: "string" } ] } } },
            controllers: { controllers: { controller => { actions: %w[create update destroy], file: file, api_controller: json,
                                                          strong_params: [ { name: "post_params", requires: "post", permits: [ "title" ] } ] } } },
            conventions: { architecture: json ? %w[api_only] : [] },
            routes: { by_controller: { key => [
              { verb: "POST", path: base, action: "create", name: key.tr("/", "_") },
              { verb: "PATCH", path: "#{base}/:id", action: "update", name: key.tr("/", "_").singularize },
              { verb: "DELETE", path: "#{base}/:id", action: "destroy", name: key.tr("/", "_").singularize }
            ] } }
          })
          return described_class.call(controller: controller).content.first[:text]
        end
      end

      it "asserts an API controller's created and no-content answers" do
        text = generated(api_source, controller: "Api::PostsController", key: "api/posts", framework: "minitest", json: true)

        expect(text).to include("assert_response :created")
        expect(text).to include("assert_response :no_content")
        expect(text).not_to include("assert_response :redirect")
        expect(text).to include("# Asserts the branch valid params take.")
      end

      it "asserts the same in a request spec" do
        text = generated(api_source, controller: "Api::PostsController", key: "api/posts", framework: "rspec", json: true)

        expect(text).to include("expect(response).to have_http_status(:created)")
        expect(text).to include("expect(response).to have_http_status(:no_content)")
        expect(text).not_to include("have_http_status(:redirect)")
      end

      it "keeps the redirect where an HTML body redirects, reading the html format" do
        text = generated(html_source, controller: "PostsController", key: "posts", framework: "minitest", json: false)

        create = text[/test "should create post" do.*?\n  end/m]
        destroy = text[/test "should destroy post" do.*?\n  end/m]
        expect(create).to include("assert_response :redirect")
        expect(destroy).to include("assert_response :see_other")
        expect(destroy).to include("assert_redirected_to posts_path")
      end
    end

    # In a controller spec, Devise's IntegrationHelpers sign in through a
    # Warden request the spec never makes, so every signed-in example gets a
    # redirect to sign in. A controller spec needs ControllerHelpers.
    it "includes the Devise helpers a controller spec signs in with" do
      Dir.mktmpdir do |root|
        FileUtils.mkdir_p(File.join(root, "spec", "controllers"))
        File.write(File.join(root, "spec", "controllers", "people_controller_spec.rb"),
                   "RSpec.describe PeopleController, type: :controller do\nend\n")
        allow(described_class).to receive(:rails_app).and_return(double(root: Pathname.new(root)))
        allow(described_class).to receive(:cached_context).and_return({
          tests: { framework: "rspec", factories: { count: 2 }, factory_names: { "spec/factories/all.rb" => %w[user note] },
                   test_helper_setup: [ "Devise::Test::ControllerHelpers" ] },
          models: { "Note" => { table_name: "notes" } },
          controllers: { controllers: { "NotesController" => { actions: %w[index] }, "PeopleController" => { actions: %w[index] } } },
          routes: { by_controller: { "notes" => [ { verb: "GET", path: "/notes", action: "index", name: "notes" } ] } }
        })

        text = described_class.call(controller: "NotesController").content.first[:text]

        expect(text).to include("type: :controller")
        expect(text).to include("include Devise::Test::ControllerHelpers")
        expect(text).not_to include("IntegrationHelpers")
      end
    end

    # A route key names the model without its namespace. The model is looked
    # up from the controller's namespace outward, and else is the one model
    # whose own name matches (a line_items route serving Store::LineItem).
    describe "a model whose namespace the route key leaves out" do
      def generated_for(ctrl, key, models)
        allow(described_class).to receive(:cached_context).and_return({
          tests: { framework: "rspec", factories: { count: 1 }, factory_names: { "spec/factories/all.rb" => %w[line_item] } },
          models: models.to_h { |name| [ name, { table_name: name.underscore.tr("/", "_").pluralize } ] },
          controllers: { controllers: { ctrl => { actions: %w[destroy] } } },
          routes: { by_controller: { key => [ { verb: "DELETE", path: "/#{key}/:id", action: "destroy", name: key.tr("/", "_").singularize } ] } }
        })
        described_class.call(controller: ctrl).content.first[:text]
      end

      it "builds the one model whose own name the route key names" do
        text = generated_for("LineItemsController", "line_items", %w[Store::LineItem User])

        expect(text).to include("change(Store::LineItem, :count).by(-1)")
        expect(text).not_to include("requires a persisted")
      end

      it "prefers the model in the controller's own namespace" do
        text = generated_for("Admin::LineItemsController", "admin/line_items", %w[Admin::LineItem Store::LineItem])

        expect(text).to include("change(Admin::LineItem, :count).by(-1)")
      end

      it "leaves a name two namespaces share unresolved" do
        text = generated_for("LineItemsController", "line_items", %w[Store::LineItem Shop::LineItem])

        expect(text).to include("requires a persisted")
      end
    end

    # `let(:post)` shadows the `post` a request spec sends, so every example
    # that posts calls the record instead: ArgumentError.
    it "names a record whose name is a request method something else" do
      allow(described_class).to receive(:cached_context).and_return({
        tests: { framework: "rspec", test_helper_setup: factory_syntax, factories: { count: 1 }, factory_names: { "spec/factories/posts.rb" => %w[post] } },
        models: { "Post" => { table_name: "posts" } },
        controllers: { controllers: { "PostsController" => { actions: %w[show update],
                                                             strong_params: [ { name: "post_params", requires: "post", permits: [ "title" ] } ] } } },
        routes: { by_controller: { "posts" => [
          { verb: "GET", path: "/posts/:id", action: "show", name: "post" },
          { verb: "PATCH", path: "/posts/:id", action: "update", name: "post" }
        ] } }
      })

      text = described_class.call(controller: "PostsController").content.first[:text]

      expect(text).to include("let(:post_record) { create(:post) }")
      expect(text).to include("post_url(post_record)")
      expect(text).not_to include("let(:post)")
    end

    # Through an unnamed route the destroy spells its URL from the record's
    # id, so the record is built before the id is read.
    it "builds the record a destroy deletes before reading its id" do
      allow(described_class).to receive(:cached_context).and_return({
        tests: { framework: "minitest", fixture_names: { "notes" => [ "one" ] } },
        models: { "Note" => { table_name: "notes" } },
        controllers: { controllers: { "NotesController" => { actions: %w[destroy] } } },
        routes: { by_controller: { "notes" => [ { verb: "DELETE", path: "/notes/:id", action: "destroy", name: nil } ] } }
      })

      text = described_class.call(controller: "NotesController").content.first[:text]

      expect(text.index("note = Note.create!")).to be < text.index("id = note.id")
    end

    # An app that keeps most controller tests as request specs can still keep
    # one controller's test in spec/controllers. rails_get_test_info finds it
    # there, so the generator must not write a second one beside the others.
    it "finds an existing test wherever rails_get_test_info would" do
      Dir.mktmpdir do |root|
        { "spec/requests/posts_spec.rb" => "", "spec/requests/notes_spec.rb" => "",
          "spec/controllers/auth/registrations_controller_spec.rb" => "" }.each do |rel, body|
          FileUtils.mkdir_p(File.dirname(File.join(root, rel)))
          File.write(File.join(root, rel), body)
        end
        allow(described_class).to receive(:rails_app).and_return(double(root: Pathname.new(root)))
        allow(described_class).to receive(:cached_context).and_return({
          tests: { framework: "rspec", factories: { count: 0 }, factory_names: {} },
          models: {},
          controllers: { controllers: { "PostsController" => {}, "NotesController" => {}, "Auth::RegistrationsController" => {} } },
          routes: { by_controller: { "auth/registrations" => [ { verb: "GET", path: "/auth/sign_up", action: "new", name: "new_registration" } ] } }
        })

        text = described_class.call(controller: "Auth::RegistrationsController").content.first[:text]

        expect(text).to include("spec/controllers/auth/registrations_controller_spec.rb already exists")
      end
    end

    # A Devise controller reached without the router finds no Devise mapping
    # and raises, so a controller-level test sets the one its routes use.
    describe "a Devise controller tested without the router" do
      def devise_sessions_text(root, framework, sibling, body, ctrl: "Users::SessionsController", scope: "user")
        key = ctrl.delete_suffix("Controller").underscore
        FileUtils.mkdir_p(File.join(root, File.dirname(sibling)))
        File.write(File.join(root, sibling), body)
        FileUtils.mkdir_p(File.join(root, "app/controllers", File.dirname(key)))
        File.write(File.join(root, "app/controllers/#{key}_controller.rb"), "class #{ctrl} < Devise::SessionsController\nend\n")
        allow(described_class).to receive(:rails_app).and_return(double(root: Pathname.new(root)))
        allow(described_class).to receive(:cached_context).and_return({
          tests: { framework: framework, factories: { count: 0 }, factory_names: {}, fixture_names: {},
                   test_helper_setup: [ "Devise::Test::ControllerHelpers" ] },
          models: { "User" => { table_name: "users" } },
          controllers: { controllers: {
            ctrl => { actions: [], file: "app/controllers/#{key}_controller.rb", parent_class: "Devise::SessionsController" },
            "PeopleController" => { actions: %w[index] }
          } },
          routes: { by_controller: { key => [
            { verb: "GET", path: "/login", action: "new", name: "new_#{scope}_session" },
            { verb: "DELETE", path: "/logout", action: "destroy", name: "destroy_#{scope}_session" }
          ] } }
        })
        described_class.call(controller: ctrl).content.first[:text]
      end

      # Devise names routes for its own kind (session), not the controller: a
      # custom LoginsController for devise_for :store_user has new_store_user_session.
      it "reads the mapping from Devise's route names whatever the controller is called" do
        Dir.mktmpdir do |root|
          text = devise_sessions_text(root, "rspec", "spec/controllers/people_controller_spec.rb",
                                      "RSpec.describe PeopleController, type: :controller do\nend\n",
                                      ctrl: "LoginsController", scope: "store_user")

          expect(text).to include('before { @request.env["devise.mapping"] = Devise.mappings[:store_user] }')
        end
      end

      it "sets the mapping in a controller spec" do
        Dir.mktmpdir do |root|
          text = devise_sessions_text(root, "rspec", "spec/controllers/people_controller_spec.rb",
                                      "RSpec.describe PeopleController, type: :controller do\nend\n")

          expect(text).to include('before { @request.env["devise.mapping"] = Devise.mappings[:user] }')
          expect(text).not_to include("\n\n\n")
        end
      end

      it "sets the mapping in an ActionController::TestCase" do
        Dir.mktmpdir do |root|
          text = devise_sessions_text(root, "minitest", "test/controllers/people_controller_test.rb",
                                      "class PeopleControllerTest < ActionController::TestCase\nend\n")

          expect(text).to include('    @request.env["devise.mapping"] = Devise.mappings[:user]')
        end
      end
    end

    it "falls back to the convention when the app keeps no model tests" do
      Dir.mktmpdir do |root|
        allow(described_class).to receive(:rails_app).and_return(double(root: Pathname.new(root)))
        allow(described_class).to receive(:cached_context).and_return({
          tests: { framework: "minitest", fixtures: {}, factory_names: {} },
          models: { "Organisation" => { table_name: "organisations", associations: [], validations: [], scopes: [], enums: {}, callbacks: {} } }
        })

        text = described_class.call(model: "Organisation").content.first[:text]

        expect(text).to include("# test/models/organisation_test.rb")
      end
    end

    # The marker is this gem's word for "a block lives here", not something
    # the user can paste into an example name.
    it "names a block callback as a block rather than by the marker" do
      allow(described_class).to receive(:cached_context).and_return({
        tests: { framework: "rspec", factories: { count: 1 }, factory_names: {} },
        models: {
          "Status" => {
            associations: [], validations: [], scopes: [], enums: {},
            callbacks: {
              "around_create" => %w[Social::Snowflake::Callbacks],
              "after_create" => [ "[inline_block]" ],
              "before_save" => %w[normalize]
            }
          }
        }
      })

      text = described_class.call(model: "Status").content.first[:text]

      expect(text).to include(%(it "around_create calls Social::Snowflake::Callbacks" do))
      expect(text).to include(%(it "after_create runs its inline block" do))
      expect(text).to include(%(it "before_save calls :normalize" do))
      expect(text).not_to include("[inline_block]")
    end

    it "generates minitest-style output when framework is minitest" do
      allow(described_class).to receive(:cached_context).and_return({
        tests: { framework: "minitest" },
        models: {
          "Post" => {
            associations: [ { type: "belongs_to", name: "user" } ],
            validations: [ { kind: "presence", attributes: %w[ title ] } ],
            scopes: [],
            enums: {},
            callbacks: {}
          }
        }
      })

      result = described_class.call(model: "Post")
      text = result.content.first[:text]
      expect(text).to include("class PostTest < ActiveSupport::TestCase")
      expect(text).to include("validates presence of title")
    end

    # A persisted record validates in the :update context, so an on: :create
    # rule never runs on it; an if: rule runs only when its condition holds.
    describe "a validation that runs only in a context or under a condition" do
      def contact_test(framework)
        allow(described_class).to receive(:cached_context).and_return({
          tests: { framework: framework, factories: { count: 0 }, factory_names: {} },
          models: { "Contact" => { validations: [
            { kind: "length", attributes: %w[title], options: { maximum: 10, on: :create } },
            { kind: "presence", attributes: %w[name], options: { if: :published? } }
          ], associations: [], scopes: [], enums: {}, callbacks: {} } }
        })
        described_class.call(model: "Contact").content.first[:text]
      end

      it "validates in that context and skips the conditional one in a minitest" do
        text = contact_test("minitest")

        expect(text).to include("assert_not @contact.valid?(:create)")
        expect(text).to include('skip "TODO: this validation runs only if: :published?"')
      end

      it "validates in that context and skips the conditional one with shoulda" do
        bundling_shoulda
        text = contact_test("rspec")

        expect(text).to include("validate_length_of(:title).is_at_most(10).on(:create)")
        expect(text).to include('skip "TODO: this validation runs only if: :published?"')
        expect(text).not_to include("validate_presence_of(:name)")
      end
    end

    # Rails needs a glob segment to build the URL, as it needs any other one.
    it "does not request a route without its glob segment" do
      Dir.mktmpdir do |root|
        FileUtils.mkdir_p(File.join(root, "spec/controllers"))
        File.write(File.join(root, "spec/controllers/people_controller_spec.rb"), "RSpec.describe PeopleController, type: :controller do\nend\n")
        allow(described_class).to receive(:rails_app).and_return(double(root: Pathname.new(root)))
        allow(described_class).to receive(:cached_context).and_return({
          tests: { framework: "rspec", factories: { count: 0 }, factory_names: {} },
          models: {},
          controllers: { controllers: { "FilesController" => { actions: %w[download] }, "PeopleController" => { actions: %w[index] } } },
          routes: { by_controller: { "files" => [ { verb: "GET", path: "/files/*path(.:format)", action: "download", name: "file" } ] } }
        })

        text = described_class.call(controller: "FilesController").content.first[:text]

        expect(text).to include("pass :path for GET /files/*path")
        expect(text).not_to include("get :download\n")
      end
    end

    it "generates request spec for controller" do
      allow(described_class).to receive(:cached_context).and_return({
        tests: { framework: "rspec", test_helper_setup: [] },
        models: {},
        routes: {
          by_controller: {
            "posts" => [
              { verb: "GET", path: "/posts", action: "index", name: "posts" },
              { verb: "POST", path: "/posts", action: "create", name: "posts" }
            ]
          }
        }
      })

      result = described_class.call(controller: "PostsController")
      text = result.content.first[:text]
      expect(text).to include("type: :request")
      expect(text).to include("GET /posts")
      expect(text).to include("POST /posts")
    end

    it "generates minitest controller test with quoted paths and defined params for nested routes" do
      allow(described_class).to receive(:cached_context).and_return({
        tests: {
          framework: "minitest",
          test_helper_setup: [],
          fixture_names: { "likes" => [ "one" ], "posts" => [ "one" ] }
        },
        models: { "Like" => { table_name: "likes" } },
        routes: {
          by_controller: {
            "likes" => [
              { verb: "DELETE", path: "/posts/:post_id/like", action: "destroy", name: nil }
            ]
          }
        }
      })

      result = described_class.call(controller: "LikesController")
      text = result.content.first[:text]
      # Path must be a quoted string, not a regex literal
      expect(text).to include('delete "/posts/')
      expect(text).not_to match(/delete\s+\/posts/)
      # post_id variable must be defined
      expect(text).to include("post_id = posts(:one).id")
      # Destroy targets a fresh record so fixture foreign keys stay intact
      expect(text).to include('like = Like.create!(@like.attributes.except("id", "created_at", "updated_at"))')
      expect(text).to include('assert_difference("Like.count", -1)')
    end

    it "generates a scaffold-style minitest controller test from routes, fixtures, and strong params" do
      root = Dir.mktmpdir
      FileUtils.mkdir_p(File.join(root, "app", "controllers"))
      File.write(File.join(root, "app", "controllers", "articles_controller.rb"), <<~RUBY)
        class ArticlesController < ApplicationController
          def index
          end

          def show
          end

          def create
            @article = Article.new(article_params)
            respond_to do |format|
              if @article.save
                format.html { redirect_to article_url(@article), notice: "Created." }
                format.json { render :show, status: :created }
              else
                format.html { render :new, status: :unprocessable_entity }
              end
            end
          end

          def update
            respond_to do |format|
              if @article.update(article_params)
                format.html { redirect_to article_url(@article) }
              else
                format.html { render :edit, status: :unprocessable_entity }
              end
            end
          end

          def destroy
            @article.destroy!
            respond_to do |format|
              format.html { redirect_to articles_path, status: :see_other }
            end
          end
        end
      RUBY
      allow(described_class).to receive(:rails_app).and_return(double(root: Pathname.new(root)))
      allow(described_class).to receive(:cached_context).and_return({
        tests: {
          framework: "minitest",
          test_helper_setup: [],
          fixture_names: { "articles" => [ "one", "two" ] }
        },
        models: { "Article" => { table_name: "articles" } },
        controllers: {
          controllers: {
            "ArticlesController" => {
              file: "app/controllers/articles_controller.rb",
              api_controller: false,
              respond_to_formats: [ "html", "json" ],
              strong_params: [ { name: "article_params", requires: "article", permits: [ "title", "body" ] } ]
            }
          }
        },
        routes: {
          by_controller: {
            "articles" => [
              { verb: "GET", path: "/articles", action: "index", name: "articles" },
              { verb: "POST", path: "/articles", action: "create" },
              { verb: "GET", path: "/articles/:id", action: "show", name: "article", params: [ "id" ] },
              { verb: "PATCH", path: "/articles/:id", action: "update", params: [ "id" ] },
              { verb: "PUT", path: "/articles/:id", action: "update", params: [ "id" ] },
              { verb: "DELETE", path: "/articles/:id", action: "destroy", params: [ "id" ] }
            ]
          }
        }
      })

      result = described_class.call(controller: "ArticlesController")
      text = result.content.first[:text]
      expect(text).to include("@article = articles(:one)")
      # Unnamed POST/PATCH/DELETE routes borrow the helper of the named sibling path
      expect(text).to include("post articles_url, params: { article: { body: @article.body, title: @article.title } }")
      expect(text).to include("patch article_url(@article), params: { article: { body: @article.body, title: @article.title } }")
      # Writes assert redirects, not :success, and update is tested once (PATCH wins over PUT)
      expect(text).to include("assert_response :redirect")
      expect(text.scan("should update article").size).to eq(1)
      expect(text).to include('assert_difference("Article.count")')
      expect(text).to include("assert_response :see_other")
    ensure
      FileUtils.rm_rf(root) if root
    end

    it "generates JSON requests with as: :json for API controllers" do
      root = Dir.mktmpdir
      FileUtils.mkdir_p(File.join(root, "app", "controllers"))
      File.write(File.join(root, "app", "controllers", "orders_controller.rb"), <<~RUBY)
        class OrdersController < ApplicationController
          def index
            render json: Order.all
          end

          def create
            @order = Order.new(order_params)
            if @order.save
              render json: @order, status: :created
            else
              render json: @order.errors, status: :unprocessable_entity
            end
          end
        end
      RUBY
      allow(described_class).to receive(:rails_app).and_return(double(root: Pathname.new(root)))
      allow(described_class).to receive(:cached_context).and_return({
        tests: {
          framework: "minitest",
          test_helper_setup: [],
          fixture_names: { "orders" => [ "one" ] }
        },
        models: { "Order" => { table_name: "orders" } },
        controllers: {
          controllers: {
            "OrdersController" => {
              file: "app/controllers/orders_controller.rb",
              api_controller: true,
              strong_params: [ { name: "order_params", requires: "order", permits: [ "number" ] } ]
            }
          }
        },
        routes: {
          by_controller: {
            "orders" => [
              { verb: "GET", path: "/orders", action: "index", name: "orders" },
              { verb: "POST", path: "/orders", action: "create" }
            ]
          }
        }
      })

      result = described_class.call(controller: "OrdersController")
      text = result.content.first[:text]
      expect(text).to include("get orders_url, as: :json")
      expect(text).to include("post orders_url, params: { order: { number: @order.number } }, as: :json")
      # API responses render, not redirect, and a create answers the status it declares
      expect(text).not_to include("assert_response :redirect")
      expect(text).to include("assert_response :success")
      expect(text).to include("assert_response :created")
    ensure
      FileUtils.rm_rf(root) if root
    end

    it "emits explicit skip TODOs when fixtures or permitted attributes are missing" do
      allow(described_class).to receive(:cached_context).and_return({
        tests: { framework: "minitest", test_helper_setup: [], fixture_names: {} },
        models: { "Widget" => { table_name: "widgets" } },
        routes: {
          by_controller: {
            "widgets" => [
              { verb: "GET", path: "/widgets/:id", action: "show", name: "widget", params: [ "id" ] },
              { verb: "POST", path: "/widgets", action: "create" }
            ]
          }
        }
      })

      result = described_class.call(controller: "WidgetsController")
      text = result.content.first[:text]
      expect(text).to include('skip "TODO:')
      expect(text).not_to include("post widgets_url")
    end

    it "falls back to schema content columns when no strong params are detected" do
      allow(described_class).to receive(:cached_context).and_return({
        tests: {
          framework: "minitest",
          test_helper_setup: [],
          fixture_names: { "articles" => [ "one" ] }
        },
        models: { "Article" => { table_name: "articles" } },
        schema: {
          tables: {
            "articles" => {
              columns: [
                { name: "id", type: "integer" },
                { name: "title", type: "string" },
                { name: "created_at", type: "datetime" },
                { name: "updated_at", type: "datetime" }
              ]
            }
          }
        },
        routes: {
          by_controller: {
            "articles" => [
              { verb: "POST", path: "/articles", action: "create", name: "articles" }
            ]
          }
        }
      })

      result = described_class.call(controller: "ArticlesController")
      text = result.content.first[:text]
      expect(text).to include("params: { article: { title: @article.title } }")
    end

    it "builds the placeholder record from the model's columns, not every permitted param" do
      allow(described_class).to receive(:cached_context).and_return({
        tests: { framework: "rspec", factories: nil, factory_names: nil },
        models: { "Account" => { table_name: "accounts" } },
        schema: {
          tables: {
            "accounts" => {
              columns: [
                { name: "id", type: "integer" },
                { name: "username", type: "string" },
                { name: "note", type: "text" }
              ]
            }
          }
        },
        controllers: {
          controllers: {
            "AccountsController" => {
              strong_params: [ { name: "account_params", requires: "account", permits: %w[username email password agreement] } ]
            }
          }
        },
        routes: {
          by_controller: {
            "accounts" => [ { verb: "GET", path: "/accounts/:id", action: "show", name: "account" } ]
          }
        }
      })

      text = described_class.call(controller: "AccountsController").content.first[:text]

      expect(text).to include("Account.create!({ username: \"MyString\" })")
      expect(text).to include("agreement, email, password")
      expect(text).to include("not columns of accounts")
    end

    it "detects file type from path" do
      allow(described_class).to receive(:cached_context).and_return({
        tests: { framework: "rspec" },
        models: {
          "Post" => {
            associations: [],
            validations: [],
            scopes: [],
            enums: {},
            callbacks: {}
          }
        }
      })

      result = described_class.call(file: "app/models/post.rb")
      text = result.content.first[:text]
      expect(text).to include("RSpec.describe Post")
    end
  end

  describe "authentication setup for a Devise app" do
    def devise_context(framework:, tests: {}, controllers: {})
      {
        tests: {
          framework: framework,
          test_helper_setup: [ "Devise::Test::IntegrationHelpers" ]
        }.merge(tests),
        models: {},
        controllers: { controllers: controllers },
        routes: { by_controller: { "posts" => [ { verb: "GET", path: "/posts", action: "index" } ] } }
      }
    end

    def generated(context)
      allow(described_class).to receive(:cached_context).and_return(context)
      described_class.call(controller: "PostsController").content.first[:text]
    end

    it "does not call a user factory the app does not have" do
      text = generated(devise_context(framework: "rspec", tests: { factories: nil, factory_names: nil }))
      expect(text).to include("include Devise::Test::IntegrationHelpers")
      expect(text).not_to include("create(:user)")
      expect(text).not_to include("before { sign_in user }")
      expect(text).to include("# TODO: these examples run unauthenticated")
    end

    it "keeps the sign_in block when a user factory exists" do
      text = generated(devise_context(
        framework: "rspec",
        tests: { test_helper_setup: [ "Devise::Test::IntegrationHelpers", *factory_syntax ], factories: { location: "spec/factories", count: 1 }, factory_names: { "users.rb" => [ :user ] } }
      ))
      expect(text).to include("let(:user) { create(:user) }")
      expect(text).to include("before { sign_in user }")
    end

    it "does not name a users fixture the app does not have" do
      text = generated(devise_context(framework: "minitest", tests: { fixtures: nil, fixture_names: nil }))
      expect(text).to include("include Devise::Test::IntegrationHelpers")
      expect(text).not_to include("users(:one)")
      expect(text).not_to include("setup do")
      expect(text).to include("# TODO: these tests run unauthenticated")
    end

    # The fixtures guide's shared-attribute idiom opens the file with
    # "DEFAULTS: &DEFAULTS", and Rails' own "_fixture:" key can be first too.
    # Neither is a fixture name.
    it "does not read a shared-attribute anchor off the fixture file as a name" do
      Dir.mktmpdir do |dir|
        FileUtils.mkdir_p(File.join(dir, "test", "fixtures"))
        File.write(File.join(dir, "test", "fixtures", "users.yml"), <<~YAML)
          DEFAULTS: &DEFAULTS
            confirmed_at: <%= Time.current %>

          alice:
            <<: *DEFAULTS
            email: alice@example.com
        YAML
        allow(described_class).to receive(:rails_app).and_return(double(root: Pathname.new(dir)))

        text = generated(devise_context(framework: "minitest", tests: { fixture_names: nil }))

        expect(text).not_to include("users(:DEFAULTS)")
        expect(text).to include("users(:alice)")
      end
    end

    it "does not name an anchor a cached context carries as a fixture name" do
      text = generated(devise_context(
        framework: "minitest",
        tests: { fixture_names: { "users" => [ "DEFAULTS", "alice" ] } }
      ))

      expect(text).not_to include("users(:DEFAULTS)")
      expect(text).to include("users(:alice)")
    end

    it "does not name a cached _fixture key as a fixture name" do
      text = generated(devise_context(
        framework: "minitest",
        tests: { fixture_names: { "users" => [ "_fixture", "alice" ] } }
      ))

      expect(text).not_to include("users(:_fixture)")
      expect(text).to include("users(:alice)")
    end

    it "keeps the fixture sign_in when a users fixture exists" do
      text = generated(devise_context(framework: "minitest", tests: { fixture_names: { "users" => [ "alice" ] } }))
      expect(text).to include("@user = users(:alice)")
      expect(text).to include("sign_in @user")
    end

    it "skips sign_in for a controller whose ancestry authorizes with Doorkeeper" do
      Dir.mktmpdir do |dir|
        FileUtils.mkdir_p(File.join(dir, "app", "controllers"))
        File.write(File.join(dir, "app", "controllers", "api_base_controller.rb"), <<~RUBY)
          class ApiBaseController < ActionController::API
            before_action -> { doorkeeper_authorize! :read }
          end
        RUBY
        allow(RailsAiContext).to receive(:default_app).and_return(RailsAiContext::StaticApp.new(dir))

        text = generated(devise_context(
          framework: "rspec",
          tests: { factories: { location: "spec/factories", count: 1 }, factory_names: { "users.rb" => [ :user ] } },
          controllers: {
            "PostsController" => { parent_class: "ApiBaseController", file: "app/controllers/posts_controller.rb" },
            "ApiBaseController" => { file: "app/controllers/api_base_controller.rb" }
          }
        ))

        expect(text).not_to include("sign_in")
        expect(text).to include("Doorkeeper")
      end
    end

    it "skips the fixture sign_in for a Doorkeeper controller in the minitest generator" do
      Dir.mktmpdir do |dir|
        FileUtils.mkdir_p(File.join(dir, "app", "controllers"))
        File.write(File.join(dir, "app", "controllers", "api_base_controller.rb"), <<~RUBY)
          class ApiBaseController < ActionController::API
            before_action -> { doorkeeper_authorize! :read }
          end
        RUBY
        allow(RailsAiContext).to receive(:default_app).and_return(RailsAiContext::StaticApp.new(dir))

        text = generated(devise_context(
          framework: "minitest",
          tests: { fixture_names: { "users" => [ "alice" ] } },
          controllers: {
            "PostsController" => { parent_class: "ApiBaseController", file: "app/controllers/posts_controller.rb" },
            "ApiBaseController" => { file: "app/controllers/api_base_controller.rb" }
          }
        ))

        expect(text).not_to include("sign_in")
        expect(text).not_to include("users(:alice)")
        expect(text).to include("Doorkeeper")
      end
    end
  end

  # The rspec branch matched the macro against Strings while the static walk
  # reported Symbols, so every row was dropped and the block came out empty.
  describe "a model parsed without booting" do
    it "fills the rspec associations and validations blocks" do
      bundling_shoulda
      Dir.mktmpdir do |dir|
        FileUtils.mkdir_p(File.join(dir, "app", "models"))
        File.write(File.join(dir, "app", "models", "account.rb"), <<~RUBY)
          class Account < ApplicationRecord
            belongs_to :owner
            has_many :statuses, dependent: :destroy
            has_one :profile
            validates :username, presence: true
            validates :followers_url, absence: true
          end
        RUBY

        app = RailsAiContext::StaticApp.new(dir)
        models = RailsAiContext::Introspectors::ModelIntrospector.new(app).static_call
        allow(described_class).to receive(:cached_context)
          .and_return({ tests: { framework: "rspec" }, models: models })
        allow(described_class).to receive(:rails_app).and_return(app)

        text = described_class.call(model: "Account").content.first[:text]

        expect(text).to include("it { is_expected.to belong_to(:owner) }")
        expect(text).to include("it { is_expected.to have_many(:statuses).dependent(:destroy) }")
        expect(text).to include("it { is_expected.to have_one(:profile) }")
        expect(text).to include("it { is_expected.to validate_presence_of(:username) }")
        expect(text).to include("validate_absence_of(:followers_url)")
        expect(text).not_to include(%(describe "associations" do\n  end))
      end
    end

    it "renders a habtm row rather than an empty associations block" do
      bundling_shoulda
      Dir.mktmpdir do |dir|
        FileUtils.mkdir_p(File.join(dir, "app", "models"))
        File.write(File.join(dir, "app", "models", "account.rb"), <<~RUBY)
          class Account < ApplicationRecord
            has_and_belongs_to_many :tags
          end
        RUBY

        app = RailsAiContext::StaticApp.new(dir)
        models = RailsAiContext::Introspectors::ModelIntrospector.new(app).static_call
        allow(described_class).to receive(:cached_context)
          .and_return({ tests: { framework: "rspec" }, models: models })
        allow(described_class).to receive(:rails_app).and_return(app)

        text = described_class.call(model: "Account").content.first[:text]

        expect(text).to include("it { is_expected.to have_and_belong_to_many(:tags) }")
        expect(text).not_to include(%(describe "associations" do\n  end))
      end
    end
  end

  # Every generated one-liner is a shoulda-matchers matcher, and without the
  # gem each one fails with NoMethodError the first time the spec runs.
  describe "an app that does not bundle shoulda-matchers" do
    before do
      allow(described_class).to receive(:cached_context).and_return({
        tests: { framework: "rspec", factories: { count: 1 }, factory_names: { "orders" => [ :order ] } },
        models: {
          "Order" => {
            associations: [ { type: "belongs_to", name: "account" } ],
            validations: [ { kind: "presence", attributes: %w[number] } ],
            enums: { "status" => { "draft" => 0, "sent" => 1 } },
            scopes: [], callbacks: {}
          }
        }
      })
    end

    it "writes examples that need no matcher gem" do
      text = described_class.call(model: "Order").content.first[:text]

      expect(text).not_to include("belong_to(")
      expect(text).not_to include("validate_presence_of(")
      expect(text).to include("reflect_on_association(:account).macro).to eq(:belongs_to)")
      expect(text).to include("validators_on(:number)")
      expect(text).to include("defined_enums")
    end
  end

  describe "an inclusion validation" do
    def generated_for(options)
      bundling_shoulda
      allow(described_class).to receive(:cached_context).and_return({
        tests: { framework: "rspec", factory_names: {} },
        models: { "Order" => { validations: [ { kind: "inclusion", attributes: %w[status], options: options } ] } }
      })
      described_class.call(model: "Order").content.first[:text]
    end

    it "passes an Array literal to in_array, not a quoted String" do
      expect(generated_for({ in: %w[draft sent paid] }))
        .to include(%(in_array(["draft", "sent", "paid"])))
    end

    it "passes a constant as code" do
      expect(generated_for({ in: "Orders::Constants::STATUSES" }))
        .to include("in_array(Orders::Constants::STATUSES)")
    end

    it "carries allow_nil through" do
      expect(generated_for({ in: [ 0, 7 ], allow_nil: true })).to include("in_array([0, 7]).allow_nil")
    end
  end

  describe "a namespaced controller" do
    let(:context) do
      {
        tests: { framework: "rspec", test_helper_setup: [], factories: { count: 1 },
                 factory_names: { "orders" => [ :order ] } },
        models: { "Order" => { table_name: "orders" } },
        controllers: { controllers: { "Api::V1::Admin::OrdersController" => { actions: %w[edit] } } },
        routes: {
          by_controller: {
            "api/v1/admin/orders" => [
              { verb: "POST", path: "/api/v1/admin/orders/edit", action: "edit", name: "api_v1_admin_orders_edit" }
            ]
          }
        }
      }
    end

    before { allow(described_class).to receive(:cached_context).and_return(context) }

    it "names the factory after the model, not after the route key" do
      text = described_class.call(controller: "Api::V1::Admin::OrdersController").content.first[:text]

      expect(text).to include("create(:order)")
      expect(text).not_to include("create(:api/v1/admin/order)")
    end

    it "sends the verb the route declares" do
      text = described_class.call(controller: "Api::V1::Admin::OrdersController").content.first[:text]

      expect(text).to include("post api_v1_admin_orders_edit")
      expect(text).not_to include("get api_v1_admin_orders_edit")
    end

    it "says a controller the app does not have is not there" do
      text = described_class.call(controller: "Api::V1::OrdersController").content.first[:text]

      expect(text).to include("not found")
      expect(text).to include("Api::V1::Admin::OrdersController")
    end
  end

  describe "the short name of a namespaced controller" do
    let(:context) do
      {
        tests: { framework: "rspec", test_helper_setup: [], factories: { count: 1 },
                 factory_names: { "gift_cards" => [ :gift_card ] } },
        models: { "GiftCard" => { table_name: "gift_cards" } },
        controllers: { controllers: { "Admin::GiftCardsController" => { actions: %w[index] } } },
        routes: {
          by_controller: {
            "admin/gift_cards" => [
              { verb: "GET", path: "/admin/gift_cards", action: "index", name: "admin_gift_cards" }
            ]
          }
        }
      }
    end

    before { allow(described_class).to receive(:cached_context).and_return(context) }

    it "resolves every form the routes already answer to" do
      %w[gift_cards gift-cards admin::gift_cards admin/gift_cards].each do |name|
        text = described_class.call(controller: name).content.first[:text]

        expect(text).not_to include("not found"), "expected #{name.inspect} to resolve"
        expect(text).to include("spec/requests/admin/gift_cards_spec.rb")
      end
    end

    # Two surfaces, one rule: a name rails_get_controllers resolves is a name
    # this tool generates for.
    it "resolves a short name the way rails_get_controllers does" do
      allow(RailsAiContext::Tools::GetControllers).to receive(:cached_context).and_return(context)

      listed = RailsAiContext::Tools::GetControllers.call(controller: "gift_cards").content.first[:text]
      generated = described_class.call(controller: "gift_cards").content.first[:text]

      expect(listed).to include("Admin::GiftCardsController")
      expect(generated).not_to include("not found")
    end
  end

  # The declaration is the answer for a model too, and the branch handed it a
  # basename, which carries no namespace to match against.
  describe "a namespaced model whose constant an inflection renames" do
    it "names the constant the file declares" do
      Dir.mktmpdir do |dir|
        FileUtils.mkdir_p(File.join(dir, "app", "models", "ai_reports"))
        File.write(File.join(dir, "app", "models", "ai_reports", "build.rb"), <<~RUBY)
          class AIReports::Build < ApplicationRecord
          end
        RUBY
        allow(described_class).to receive(:rails_app).and_return(RailsAiContext::StaticApp.new(dir))
        allow(described_class).to receive(:cached_context).and_return(
          tests: { framework: "rspec" },
          models: { "AIReports::Build" => { table_name: "ai_reports_builds", associations: [], validations: [] } }
        )

        text = described_class.call(file: "app/models/ai_reports/build.rb").content.first[:text]

        expect(text).to include("RSpec.describe AIReports::Build")
        expect(text).not_to include("AiReports::Build")
        expect(text).not_to include("not found")
      end
    end
  end

  describe "an ActiveInteraction service" do
    # The app registers `inflect.acronym "AI"`, so the constant the file
    # declares is AIReports::Build and the path camelizes to AiReports::Build,
    # which is a constant nothing defines. The static tier never loads the
    # app's inflections, so only the declaration answers.
    it "names the constant the file declares, not the one its path camelizes to" do
      Dir.mktmpdir do |dir|
        FileUtils.mkdir_p(File.join(dir, "app", "services", "ai_reports"))
        File.write(File.join(dir, "app", "services", "ai_reports", "build.rb"), <<~RUBY)
          class AIReports::Build < ActiveInteraction::Base
            def execute; end
          end
        RUBY
        allow(described_class).to receive(:rails_app).and_return(RailsAiContext::StaticApp.new(dir))
        allow(described_class).to receive(:cached_context).and_return({ tests: { framework: "rspec" } })

        text = described_class.call(file: "app/services/ai_reports/build.rb").content.first[:text]

        expect(text).to include("RSpec.describe AIReports::Build do")
        expect(text).not_to include("AiReports::Build")
        expect(text).not_to include("not found")
      end
    end

    # A filter declared inside a `hash :x do ... end` block is a key of that
    # hash, not an input of the interaction: `.filters.keys` is [:order_params,
    # :account], and run() drops the other two silently.
    it "passes only the interaction's own filters to run" do
      Dir.mktmpdir do |dir|
        FileUtils.mkdir_p(File.join(dir, "app", "services", "orders"))
        File.write(File.join(dir, "app", "services", "orders", "create_with_params.rb"), <<~RUBY)
          class Orders::CreateWithParams < ActiveInteraction::Base
            hash :order_params do
              string :title, default: nil
              integer :quantity, default: nil
            end

            object :account

            def execute; end
          end
        RUBY
        allow(described_class).to receive(:rails_app).and_return(RailsAiContext::StaticApp.new(dir))
        allow(described_class).to receive(:cached_context).and_return({ tests: { framework: "rspec" } })

        text = described_class.call(file: "app/services/orders/create_with_params.rb").content.first[:text]

        expect(text).to include("described_class.run(order_params: nil, account: nil)")
        expect(text).not_to include("title: nil")
        expect(text).not_to include("quantity: nil")
      end
    end

    # ActiveInteraction::Base defines .run and .run!, never .call, so a
    # subclass of a subclass still runs the same way.
    it "follows the superclass chain through the app's own services" do
      Dir.mktmpdir do |dir|
        FileUtils.mkdir_p(File.join(dir, "app", "services", "billing", "invoices"))
        File.write(File.join(dir, "app", "services", "billing", "invoices", "base_request.rb"), <<~RUBY)
          class Billing::Invoices::BaseRequest < ActiveInteraction::Base
            string :token

            def execute; end
          end
        RUBY
        File.write(File.join(dir, "app", "services", "billing", "invoices", "charge.rb"), <<~RUBY)
          class Billing::Invoices::Charge < Billing::Invoices::BaseRequest
            hash :body do
              integer :amount, default: nil
            end

            def execute; end
          end
        RUBY
        allow(described_class).to receive(:rails_app).and_return(RailsAiContext::StaticApp.new(dir))
        allow(described_class).to receive(:cached_context).and_return({ tests: { framework: "rspec" } })

        text = described_class.call(file: "app/services/billing/invoices/charge.rb").content.first[:text]

        expect(text).to include("describe \".run\"")
        expect(text).to include("described_class.run(token: nil, body: nil)")
        expect(text).not_to include("described_class.call")
      end
    end

    it "runs it the way the base class does" do
      Dir.mktmpdir do |dir|
        FileUtils.mkdir_p(File.join(dir, "app", "services", "orders"))
        File.write(File.join(dir, "app", "services", "orders", "auto_approve.rb"), <<~RUBY)
          class Orders::AutoApprove < ActiveInteraction::Base
            object :order
            string :reason, default: nil

            def execute; end
          end
        RUBY
        allow(described_class).to receive(:rails_app).and_return(RailsAiContext::StaticApp.new(dir))
        allow(described_class).to receive(:cached_context).and_return({ tests: { framework: "rspec" } })

        text = described_class.call(file: "app/services/orders/auto_approve.rb").content.first[:text]

        expect(text).to include("describe \".run\"")
        expect(text).to include("described_class.run(order: nil, reason: nil)")
        expect(text).not_to include("described_class.call")
      end
    end

    # Only an interaction runs with .run: a plain service generated as one
    # would call a method it does not have.
    it "calls a plain service with .call" do
      Dir.mktmpdir do |dir|
        FileUtils.mkdir_p(File.join(dir, "app", "services"))
        File.write(File.join(dir, "app", "services", "plain_thing.rb"), "class PlainThing\n  def call; end\nend\n")
        allow(described_class).to receive(:rails_app).and_return(RailsAiContext::StaticApp.new(dir))
        allow(described_class).to receive(:cached_context).and_return({ tests: { framework: "rspec" } })

        text = described_class.call(file: "app/services/plain_thing.rb").content.first[:text]

        expect(text).to include("describe \"#call\"")
        expect(text).to include("result = described_class.new.call")
        expect(text).to include("be_truthy")
        expect(text).not_to include("be_valid")
      end
    end

    # bazaar's price_calculator_test.rb was written again as a new file, where
    # a model's existing test is addressed instead.
    it "addresses the cases to a service's existing test" do
      Dir.mktmpdir do |dir|
        FileUtils.mkdir_p([ File.join(dir, "app", "services"), File.join(dir, "test", "services") ])
        File.write(File.join(dir, "app", "services", "price_calculator.rb"), "class PriceCalculator\n  def call; end\nend\n")
        File.write(File.join(dir, "test", "services", "price_calculator_test.rb"), "class PriceCalculatorTest < ActiveSupport::TestCase\nend\n")
        allow(described_class).to receive(:rails_app).and_return(RailsAiContext::StaticApp.new(dir))
        allow(described_class).to receive(:cached_context).and_return({ tests: { framework: "minitest" } })

        text = described_class.call(file: "app/services/price_calculator.rb").content.first[:text]

        expect(text).to start_with("test/services/price_calculator_test.rb already exists. Add the cases below that it lacks to it")
      end
    end
  end

  # A job went through the service template: test/services with
  # ActiveSupport::TestCase, where Rails files it under test/jobs as an
  # ActiveJob::TestCase.
  describe "a job file" do
    def job_test(framework, context = {})
      Dir.mktmpdir do |dir|
        FileUtils.mkdir_p(File.join(dir, "app", "jobs"))
        File.write(File.join(dir, "app", "jobs", "process_payment_job.rb"),
                   "class ProcessPaymentJob < ApplicationJob\n  def perform(payment_id); end\nend\n")
        allow(described_class).to receive(:rails_app).and_return(RailsAiContext::StaticApp.new(dir))
        allow(described_class).to receive(:cached_context).and_return({ tests: { framework: framework } }.merge(context))

        described_class.call(file: "app/jobs/process_payment_job.rb").content.first[:text]
      end
    end

    let(:jobs) { { jobs: { jobs: [ { name: "ProcessPaymentJob", perform_signature: "payment_id" } ] } } }

    it "files a minitest job test under test/jobs as an ActiveJob::TestCase" do
      text = job_test("minitest", jobs)

      expect(text).to include("# test/jobs/process_payment_job_test.rb")
      expect(text).to include("class ProcessPaymentJobTest < ActiveJob::TestCase")
      expect(text).to include("ProcessPaymentJob.perform_now(payment_id)")
      expect(text).not_to include("test/services")
    end

    it "writes a job spec for rspec" do
      text = job_test("rspec", jobs)

      expect(text).to include("# spec/jobs/process_payment_job_spec.rb")
      expect(text).to include("RSpec.describe ProcessPaymentJob, type: :job do")
    end

    it "calls perform on a Sidekiq job, which has no perform_now" do
      text = job_test("minitest", jobs: { jobs: [], workers: [ { name: "ProcessPaymentJob", perform_signature: "payment_id" } ] })

      expect(text).to include("class ProcessPaymentJobTest < ActiveSupport::TestCase")
      expect(text).to include("ProcessPaymentJob.new.perform(payment_id)")
    end
  end

  # The generated setup line follows the app's own specs: an app that assigns
  # instance variables gets no let, and the factory call follows whichever of
  # create and build its specs reach for more.
  describe "setup style read from the app's own specs" do
    def generated_for(existing_spec, setup: factory_syntax, model: "Post")
      Dir.mktmpdir do |dir|
        FileUtils.mkdir_p(File.join(dir, "spec", "models"))
        File.write(File.join(dir, "spec", "models", "comment_spec.rb"), existing_spec)
        allow(described_class).to receive(:rails_app).and_return(double(root: Pathname.new(dir)))
        allow(described_class).to receive(:cached_context).and_return({
          tests: { framework: "rspec", test_helper_setup: setup, factory_names: { "spec/factories/#{model.underscore.pluralize}.rb" => [ model.underscore.to_sym ] } },
          models: { model => { associations: [], validations: [], scopes: [], enums: {}, callbacks: {} } }
        })

        described_class.call(model: model).content.first[:text]
      end
    end

    # A bare `create(:post)` is a NoMethodError in a suite that does not
    # include FactoryBot::Syntax::Methods.
    it "calls FactoryBot's methods on FactoryBot where the suite does not include them" do
      text = generated_for("let(:a) { create(:post) }\nlet(:b) { create(:post) }\n", setup: [])

      expect(text).to include("let(:post) { FactoryBot.create(:post) }")
    end

    # `let(:skip)` would replace the skip an example calls.
    it "names the let apart from a method its examples call" do
      text = generated_for("let(:a) { create(:skip) }\nlet(:b) { create(:skip) }\n", model: "Skip")

      expect(text).to include("let(:skip_record) { create(:skip) }")
    end

    it "writes a let when the app's specs use let" do
      text = generated_for("let(:a) { create(:post) }\nlet(:b) { create(:post) }\n")

      expect(text).to include("let(:post) { create(:post) }")
    end

    it "writes no let for an app that assigns instance variables" do
      text = generated_for("@a = create(:post)\n@b = create(:post)\n@c = create(:post)\n")

      expect(text).not_to include("let(:post)")
    end

    it "follows the app to build when its specs build more than they create" do
      text = generated_for("let(:a) { build(:post) }\nlet(:b) { build(:post) }\n")

      expect(text).to include("let(:post) { build(:post) }")
    end

    it "counts a factory call written without parentheses" do
      text = generated_for("let(:a) { build(:post) }\nlet(:b) { build(:post) }\n" \
                           "let(:c) { create :post }\nlet(:d) { create :post }\nlet(:e) { create :post }\n")

      expect(text).to include("let(:post) { create(:post) }")
    end
  end

  # `belong_to(:[INFERRED])` and `belong_to(::"#{x}")` are both specs that do
  # not parse, so an association the walk could not name gets no matcher.
  describe "an association whose name is computed" do
    before do
      described_class.reset_cache!
      allow(described_class).to receive(:cached_context).and_return(
        models: {
          "Topic" => {
            table_name: "topics",
            associations: [ { type: "belongs_to", name: :user },
                            { type: "has_one", name: ':"#{name.underscore}_search_data"', computed_name: true },
                            { type: "belongs_to", name: "owner_name", computed_name: true } ],
            validations: []
          }
        }
      )
    end

    it "writes a matcher only for the associations it can name" do
      text = described_class.call(model: "Topic").content.first[:text]

      expect(text).to include("reflect_on_association(:user)")
      expect(text).not_to include("search_data")
      expect(text).not_to include("owner_name")
      expect(text).not_to include("INFERRED")
    end

    it "writes a minitest file that parses and tests only the associations it can name" do
      allow(described_class).to receive(:cached_context).and_return(
        tests: { framework: "minitest", fixture_names: {}, factory_names: {} },
        models: {
          "User" => {
            table_name: "users",
            associations: [ { type: "has_many", name: "posts" },
                            { type: "has_many", name: ':"#{k}_posts"', computed_name: true } ],
            validations: []
          }
        }
      )

      text = described_class.call(model: "User").content.first[:text]
      source = text[/```ruby\n(.*)```/m, 1]

      expect(Prism.parse(source).success?).to be(true)
      expect(source).to include("test \"has_many posts\"")
      expect(source).not_to include("_posts")
    end
  end

  describe "text with a double quote in a skip" do
    %w[rspec minitest].each do |framework|
      it "writes a #{framework} model file that parses when a rule option holds a quote" do
        bundling_shoulda
        allow(described_class).to receive(:cached_context).and_return(
          tests: { framework: framework, fixture_names: {}, factory_names: {} },
          models: {
            "Voucher" => {
              table_name: "vouchers",
              associations: [],
              validations: [ { kind: "exclusion", attributes: %w[ tags ], options: { in: %w[admin root] } },
                             { kind: "validates_date", attributes: %w[ starts_on ], options: { after: '"today"' } } ]
            }
          }
        )

        text = described_class.call(model: "Voucher").content.first[:text]
        source = text[/```ruby\n(.*?)```/m, 1]

        expect(Prism.parse(source).success?).to be(true), source
      end
    end
  end

  # Each expected line passes shoulda-matchers 7.0.1 and 8.0.1 against the model it is built from.
  describe "shoulda matchers for declarations with options" do
    before do
      bundling_shoulda
      allow(described_class).to receive(:cached_context).and_return(
        tests: { framework: "rspec", factories: { count: 0 }, factory_names: {} },
        schema: { tables: { "tickets" => { columns: [ { name: "status", type: "integer" }, { name: "kind", type: "string" }, { name: "level", type: "integer" } ] } } },
        models: {
          "Post" => {
            table_name: "posts",
            associations: [ { type: "belongs_to", name: "user", options: { optional: true }, optional: true },
                            { type: "belongs_to", name: "author", options: { class_name: "User" }, class_name: "User" },
                            { type: "belongs_to", name: "owner", options: { optional: "-> { draft? }" }, optional: "-> { draft? }" } ]
          },
          "Item" => {
            table_name: "items",
            validations: [ { kind: "uniqueness", attributes: [ "email" ], options: { case_sensitive: false } },
                           { kind: "uniqueness", attributes: [ "slug" ], options: { scope: :account_id } },
                           { kind: "uniqueness", attributes: [ "code" ], options: { scope: %i[account_id kind], case_sensitive: false } },
                           { kind: "uniqueness", attributes: [ "name" ], options: {} },
                           { kind: "uniqueness", attributes: [ "handle" ], options: { scope: "SCOPE_COLUMNS" } },
                           { kind: "uniqueness", attributes: [ "token" ], options: {}, options_source: "**UNIQUE" } ]
          },
          "Ticket" => {
            table_name: "tickets",
            enums: { "status" => { "active" => 1, "archived" => 2 }, "kind" => { "small" => "small", "big" => "big" },
                     "level" => { "low" => 0, "high" => 1 }, "state" => { "queued" => 0, "done" => 1 },
                     "phase" => { "early" => 0, "late" => 1 }, "tier" => { "gold" => "GOLD_TIER" } },
            enum_options: { "state" => { prefix: true }, "phase" => { suffix: :step } }
          }
        }
      )
    end

    def matchers(model) = described_class.call(model: model).content.first[:text].lines.grep(/is_expected|expect\(/).map(&:strip)

    it "qualifies an optional belongs_to, and falls back to reflection for an optional: it cannot read" do
      expect(matchers("Post")).to eq([
        "it { is_expected.to belong_to(:user).optional }",
        "it { is_expected.to belong_to(:author) }",
        "it { expect(described_class.reflect_on_association(:owner).macro).to eq(:belongs_to) }"
      ])
    end

    it "scopes and case-folds a uniqueness matcher the way the validation does" do
      expect(matchers("Item")).to include(
        "it { is_expected.to validate_uniqueness_of(:email).case_insensitive }",
        "it { is_expected.to validate_uniqueness_of(:slug).scoped_to(:account_id) }",
        "it { is_expected.to validate_uniqueness_of(:code).scoped_to(:account_id, :kind).case_insensitive }",
        "it { is_expected.to validate_uniqueness_of(:name) }"
      )
      expect(matchers("Item").grep(/handle|token/).join).not_to include("validate_uniqueness_of")
    end

    it "asserts an enum's value hash, a non-integer column's type and the method prefix or suffix" do
      expect(matchers("Ticket")).to eq([
        "it { is_expected.to define_enum_for(:status).with_values(active: 1, archived: 2) }",
        "it { is_expected.to define_enum_for(:kind).with_values(small: \"small\", big: \"big\").backed_by_column_of_type(:string) }",
        "it { is_expected.to define_enum_for(:level).with_values(low: 0, high: 1) }",
        "it { is_expected.to define_enum_for(:state).with_values(queued: 0, done: 1).with_prefix }",
        "it { is_expected.to define_enum_for(:phase).with_values(early: 0, late: 1).with_suffix(:step) }",
        "it { expect(described_class.defined_enums[\"tier\"].keys).to match_array([\"gold\"]) }"
      ])
    end
  end

  # define_enum_for checks for the scopes and value methods unless told the enum skips them.
  describe "an enum declared without scopes or value methods" do
    it "says so on the matcher, and falls back to the values example when it cannot read the option" do
      bundling_shoulda
      Dir.mktmpdir do |dir|
        FileUtils.mkdir_p(File.join(dir, "app/models"))
        File.write(File.join(dir, "app/models/ticket.rb"), <<~RUBY)
          class Ticket < ApplicationRecord
            enum :status, { open: 0, closed: 1 }, scopes: false
            enum :level, { low: 0, high: 1 }, instance_methods: false, prefix: true
            enum :tier, { gold: 0, silver: 1 }, scopes: Feature.enabled?
          end
        RUBY
        models = RailsAiContext::Introspectors::ModelIntrospector.new(RailsAiContext::StaticApp.new(dir)).static_call
        allow(described_class).to receive(:cached_context).and_return(
          tests: { framework: "rspec", factories: { count: 0 }, factory_names: {} }, models: models.slice("Ticket")
        )

        lines = described_class.call(model: "Ticket").content.first[:text].lines.grep(/is_expected|expect\(/).map(&:strip)

        expect(lines).to eq([
          "it { is_expected.to define_enum_for(:status).with_values(open: 0, closed: 1).without_scopes }",
          "it { is_expected.to define_enum_for(:level).with_values(low: 0, high: 1).with_prefix.without_instance_methods }",
          "it { expect(described_class.defined_enums[\"tier\"].keys).to match_array([\"gold\", \"silver\"]) }"
        ])
      end
    end
  end

  # validate_uniqueness_of(:title) fails on 7.0.1 and 8.0.1 here: the record it saves is
  # unpublished, so the conditions leave it out and the second record is valid.
  describe "a reflected uniqueness validation with a conditions: lambda" do
    it "falls back to the reflection example instead of the plain matcher" do
      bundling_shoulda
      Object.const_set(:ScopedPost, Class.new(Post) { validates :title, uniqueness: { conditions: -> { where(published: true) } } })
      models = RailsAiContext::Introspectors::ModelIntrospector.new(Rails.application).call
      allow(described_class).to receive(:cached_context).and_return(
        tests: { framework: "rspec", factories: { count: 0 }, factory_names: {} }, models: models.slice("ScopedPost")
      )

      text = described_class.call(model: "ScopedPost").content.first[:text]

      expect(text).not_to include("validate_uniqueness_of(:title)")
      expect(text).to include("expect(described_class.validators_on(:title).map(&:kind)).to include(:uniqueness)")
    ensure
      Object.send(:remove_const, :ScopedPost) if Object.const_defined?(:ScopedPost, false)
    end
  end

  # User.bordered.to_sql is `... WHERE "users"."bordered" = 1`, no ORDER BY.
  describe "a minitest scope test" do
    it "expects ORDER BY only from a scope that calls order, reorder or in_order_of" do
      allow(described_class).to receive(:cached_context).and_return(
        tests: { framework: "minitest", fixture_names: {}, factory_names: {} },
        models: {
          "User" => {
            table_name: "users", associations: [], validations: [],
            scopes: [ { name: "buyers", body: "joins(:orders).distinct" },
                      { name: "bordered", body: "where(bordered: true)" },
                      { name: "by_order", body: "where(order: 1)" },
                      { name: "latest", body: "order(created_at: :desc)" },
                      { name: "ranked", body: "in_order_of(:pos, [ 2, 1 ])" } ]
          }
        }
      )

      source = described_class.call(model: "User").content.first[:text]
      tests = source.split(/^  test /).drop(1).to_h { |t| [ t[/\A"scope \.(\w+)/, 1], t ] }

      expect(tests.select { |_, body| body.include?("ORDER BY") }.keys).to contain_exactly("latest", "ranked")
      expect(tests["bordered"]).to include("assert_kind_of ActiveRecord::Relation, results")
    end
  end

  # `validators_on(:date_of_birth).map(&:kind)` never holds `:validates_date`,
  # so an assertion on it fails for a model that does validate the date.
  describe "a validation listed under a gem's macro" do
    before do
      described_class.reset_cache!
      allow(described_class).to receive(:cached_context).and_return(
        models: {
          "Document" => {
            table_name: "documents",
            associations: [],
            validations: [ { kind: "validates_date", attributes: [ "date_of_birth" ], options: {} } ]
          }
        }
      )
    end

    it "writes no kind assertion it cannot back" do
      text = described_class.call(model: "Document").content.first[:text]

      expect(text).not_to include("include(:validates_date)")
      expect(text).to include("validates_date of date_of_birth")
    end
  end

  # `type` was never read: `model: "Product", type: "system"` answered that
  # test/models/product_test.rb already exists.
  describe "a system test" do
    def system_test(framework, root, tests = {})
      allow(described_class).to receive(:rails_app).and_return(double(root: Pathname.new(root)))
      allow(described_class).to receive(:cached_context).and_return({
        tests: { framework: framework, fixture_names: { "products" => %w[radio] }, factory_names: {} }.merge(tests),
        models: { "Product" => { table_name: "products" } },
        controllers: { controllers: { "ProductsController" => { actions: %w[index show create] } } },
        routes: { by_controller: { "products" => [
          { verb: "GET", path: "/products", action: "index", name: "products" },
          { verb: "POST", path: "/products", action: "create" },
          { verb: "GET", path: "/products/:id", action: "show", name: "product" }
        ] } }
      })
      described_class.call(model: "Product", type: "system").content.first[:text]
    end

    it "visits the model's pages in a minitest system test" do
      Dir.mktmpdir do |root|
        FileUtils.mkdir_p(File.join(root, "test", "models"))
        File.write(File.join(root, "test", "models", "product_test.rb"), "class ProductTest < ActiveSupport::TestCase\nend\n")

        text = system_test("minitest", root)

        expect(text).to include("# test/system/products_test.rb")
        expect(text).to include("class ProductsTest < ApplicationSystemTestCase")
        expect(text).to include("    @product = products(:radio)")
        expect(text).to include("    visit products_url\n    assert_current_path products_path")
        expect(text).to include("    visit product_url(@product)\n    assert_current_path product_path(@product)")
        expect(text).not_to include("product_test.rb already exists")
        expect(text).not_to include("post ")
        expect(text).to include("This app has no test/application_system_test_case.rb")
      end
    end

    it "writes a system spec for rspec" do
      Dir.mktmpdir do |root|
        text = system_test("rspec", root, factory_names: { "products.rb" => %w[product] }, factories: { count: 1 })

        expect(text).to include("# spec/system/products_spec.rb")
        expect(text).to include("RSpec.describe \"Products\", type: :system do")
        expect(text).to include("    visit products_path\n    expect(page).to have_current_path(products_path)")
      end
    end

    # One `create(:post)` for the visit and another for the path assertion are two different posts.
    describe "of a nested route" do
      def nested_system_test(factory: true, models: nil)
        Dir.mktmpdir do |root|
          allow(described_class).to receive(:rails_app).and_return(double(root: Pathname.new(root)))
          allow(described_class).to receive(:cached_context).and_return({
            tests: { framework: "rspec", fixture_names: {}, factory_names: factory ? { "posts.rb" => %w[post], "comments.rb" => %w[comment] } : {} },
            models: models || { "Comment" => { table_name: "comments", associations: [ { type: "belongs_to", name: "post", foreign_key: "post_id" } ],
                                                 validations: [ { kind: "presence", attributes: %w[post], implicit: true } ] },
                                "Post" => { table_name: "posts" } },
            schema: { tables: { "posts" => { columns: [ { name: "title", type: "string" } ] },
                                "comments" => { columns: [ { name: "body", type: "text" }, { name: "post_id", type: "integer" } ] } } },
            controllers: { controllers: { "CommentsController" => { actions: %w[index show] } } },
            routes: { by_controller: { "comments" => [
              { verb: "GET", path: "/posts/:post_id/comments", action: "index", name: "post_comments" },
              { verb: "GET", path: "/posts/:post_id/comments/:id", action: "show", name: "post_comment" }
            ] } }
          })
          return described_class.call(model: "Comment", type: "system").content.first[:text]
        end
      end

      it "visits and asserts the one parent a factory builds, and the subject's own record" do
        text = nested_system_test

        expect(text).to include("let(:post_record) { FactoryBot.create(:post) }")
        expect(text).to include("let(:comment) { FactoryBot.create(:comment, post: post_record) }")
        expect(text).to include("visit post_comments_path(post_record)\n    expect(page).to have_current_path(post_comments_path(post_record))")
        expect(text).to include("visit post_comment_path(post_record, comment)")
      end

      it "makes the parent and the record up from placeholders when no factory builds them" do
        text = nested_system_test(factory: false)

        expect(text).to include('let(:post_record) { Post.create!({ title: "MyString" }) }')
        expect(text).to include('let(:comment) { Comment.create!({ body: "MyText", post_id: post_record.id }) }')
        expect(text).to include("visit post_comments_path(post_record)\n    expect(page).to have_current_path(post_comments_path(post_record))")
        expect(text).to include("visit post_comment_path(post_record, comment)")
        expect(text).not_to include("skip")
      end
    end

    it "says so when no controller serves the model's pages" do
      Dir.mktmpdir do |root|
        allow(described_class).to receive(:rails_app).and_return(double(root: Pathname.new(root)))
        allow(described_class).to receive(:cached_context).and_return({
          tests: { framework: "minitest" }, models: { "Setting" => { table_name: "settings" } }, controllers: { controllers: {} }
        })

        text = described_class.call(model: "Setting", type: "system").content.first[:text]

        expect(text).to include("No controller serves Setting's pages")
      end
    end
  end

  # ActionDispatch::Integration::Runner keeps its own @app, @response, @request and @controller.
  it "names a minitest record after a model called app something the integration runner does not keep" do
    Dir.mktmpdir do |root|
      allow(described_class).to receive(:rails_app).and_return(double(root: Pathname.new(root)))
      allow(described_class).to receive(:cached_context).and_return({
        tests: { framework: "minitest", test_helper_setup: [], fixture_names: { "apps" => %w[one] } },
        models: { "App" => { table_name: "apps" } },
        schema: { tables: { "apps" => { columns: [ { name: "id", type: "integer" }, { name: "name", type: "string" } ] } } },
        controllers: { controllers: { "AppsController" => { actions: %w[show update], strong_params: [ { name: "app_params", requires: "app", permits: %w[name] } ] } } },
        routes: { by_controller: { "apps" => [ { verb: "GET", path: "/apps/:id", action: "show", name: "app" },
                                               { verb: "PATCH", path: "/apps/:id", action: "update", name: "app" } ] } }
      })
      text = described_class.call(controller: "AppsController").content.first[:text]

      expect(text).to include("@app_record = apps(:one)")
      expect(text).to include("get app_url(@app_record)")
      expect(text).to include("params: { app: { name: @app_record.name } }")
      expect(text).not_to include("@app ")
    end
  end

  # Every name a let, local or ivar takes must stay clear of the methods and ivars the example group calls.
  describe "a resource named after a method or ivar an example calls" do
    def resource_text(model, framework:, type: nil, factory: false, extra: {})
      key = model.underscore
      Dir.mktmpdir do |root|
        allow(described_class).to receive(:rails_app).and_return(double(root: Pathname.new(root)))
        allow(described_class).to receive(:cached_context).and_return({
          tests: { framework: framework, factories: nil, factory_names: factory ? { "#{key}.rb" => [ key ] } : nil, fixture_names: {} },
          models: { model => { table_name: key.pluralize }.merge(extra) },
          schema: { tables: { key.pluralize => { columns: [ { name: "id", type: "integer" }, { name: "title", type: "string" } ] } } },
          controllers: { controllers: { "#{model.pluralize}Controller" => { actions: %w[index show create update destroy],
                                                                           strong_params: [ { name: "#{key}_params", requires: key, permits: %w[title] } ] } } },
          routes: { by_controller: { key.pluralize => [
            { verb: "GET", path: "/#{key.pluralize}", action: "index", name: key.pluralize },
            { verb: "POST", path: "/#{key.pluralize}", action: "create", name: key.pluralize },
            { verb: "GET", path: "/#{key.pluralize}/:id", action: "show", name: key },
            { verb: "PATCH", path: "/#{key.pluralize}/:id", action: "update", name: key },
            { verb: "DELETE", path: "/#{key.pluralize}/:id", action: "destroy", name: key }
          ] } }
        })
        return described_class.call(controller: "#{model.pluralize}Controller", model: (model if type), type: type || "request").content.first[:text]
      end
    end

    it "renames the let, so rspec's change matcher and the request helpers still run" do
      text = resource_text("Change", framework: "rspec")

      expect(text).to include("let(:change_record) { Change.create!")
      expect(text).to include("change_url(change_record)")
      expect(text).not_to include("let(:change)")
      expect(text).to include("}.to change(Change, :count).by(1)")
    end

    it "renames the let a system spec visits through" do
      text = resource_text("Page", framework: "rspec", type: "system", factory: true)

      expect(text).to include("let(:page_record) { FactoryBot.create(:page) }")
      expect(text).to include("visit page_path(page_record)")
      expect(text).to include("expect(page).to have_current_path(page_path(page_record))")
    end

    it "names the minitest destroy's local apart from the model's own method, and from every method an example calls" do
      text = resource_text("Response", framework: "minitest")

      expect(text).to include("response_copy = Response.create!(response_record.attributes")
      expect(text).to include("delete response_url(response_copy)")
      expect(text).not_to match(/^\s+response(_record)? = /)
      expect(resource_text("Post", framework: "minitest")).to include("post_copy = Post.create!(post_record.attributes")
    end

    it "renames a let named after skip, create, build or sign_in, which the examples and factories call" do
      %w[Skip Create Build SignIn].each do |model|
        key = model.underscore
        expect(resource_text(model, framework: "rspec")).to include("let(:#{key}_record)")
        expect(resource_text(model, framework: "rspec")).not_to include("let(:#{key})")
      end
    end

    it "renames a minitest ivar the test case keeps" do
      %w[Name Store HtmlDocument RootSession].each do |model|
        expect(resource_text(model, framework: "minitest")).to include("@#{model.underscore}_record")
      end
    end

    # The lists name what the example groups break on when a model is named after it. Both ways: every name is still a
    # method the frameworks define, and every method the generated examples call is a name on the list.
    let(:installed_methods) do
      require "minitest"
      (ActionDispatch::Integration::Runner.instance_methods + ActionDispatch::IntegrationTest.instance_methods +
       Minitest::Test.instance_methods + Minitest::Assertions.instance_methods + RSpec::Matchers.instance_methods +
       RSpec::Core::ExampleGroup.instance_methods + ActionController::TestCase::Behavior.instance_methods +
       ActionDispatch::TestProcess.instance_methods).map(&:to_s)
    end

    # rspec-rails, Capybara, FactoryBot and Devise are the app's gems, not this gem's bundle: their names are listed by hand.
    let(:app_gems_methods) do
      %w[record have_http_status redirect_to have_current_path page visit driven_by assert_redirected_to assert_response assertion_delegator
         generate_response_message create_session setup_fixtures queue_adapter_changed_jobs enqueued_jobs performed_jobs before_setup
         method_missing integration_session app params controller create build build_stubbed attributes_for create_list build_list sign_in sign_out
         include send assert_current_path]
    end

    it "keeps its method list to methods the frameworks define" do
      expect(described_class.singleton_class::SPEC_METHOD_NAMES - installed_methods - app_gems_methods).to eq([])
    end

    # Every file the generator writes for a model with associations, validations, a login filter and a Devise app:
    # request specs, system specs, model and unit specs, and the minitest of each.
    def generated_files
      rules = [ { kind: "presence", attributes: %w[title] }, { kind: "absence", attributes: %w[legacy] }, { kind: "length", attributes: %w[title], options: { maximum: 9 } },
                { kind: "uniqueness", attributes: %w[title] }, { kind: "inclusion", attributes: %w[kind], options: { in: %w[a b] } },
                { kind: "acceptance", attributes: %w[terms] }, { kind: "confirmation", attributes: %w[title] }, { kind: "format", attributes: %w[title], options: { with: "/a/" } },
                { kind: "numericality", attributes: %w[score] } ]
      extra = { validations: rules, associations: [ { type: "belongs_to", name: "owner", polymorphic: true }, { type: "has_many", name: "marks" } ],
                scopes: [ { name: "recent" } ], enums: { "kind" => { "a" => 0 } } }
      files = { model: {}, model_plain: {} }
      texts = []
      %w[rspec minitest].each do |framework|
        texts << resource_text("Thing", framework: framework)
        texts << resource_text("Thing", framework: framework, factory: true)
        texts << resource_text("Thing", framework: framework, extra: { custom_validates: [ "check" ] })
        texts << resource_text("Thing", framework: framework, extra: extra)
      end
      texts << resource_text("Thing", framework: "rspec", type: "system", factory: true)
      texts << resource_text("Thing", framework: "rspec", type: "system")
      bundling_shoulda
      files[:model] = [ resource_text("Thing", framework: "rspec", type: "unit", factory: true, extra: extra), resource_text("Thing", framework: "minitest", type: "unit", extra: extra) ]
      allow(RailsAiContext::GemLock).to receive(:for).and_return(RailsAiContext::GemLock::Spec.new({}))
      files[:model_plain] = [ resource_text("Thing", framework: "rspec", type: "unit", extra: extra) ]
      { all: texts + files[:model] + files[:model_plain], model: files[:model] + files[:model_plain] }
    end

    def called_names(texts)
      texts.flat_map do |text|
        text.lines.flat_map do |line|
          code = line.sub(/#.*/, "").gsub(/"(?:[^"\\]|\\.)*"/, '""')
          code.scan(/(?<![\w.:@$])([a-z_][a-z0-9_]*[?!]?)(?=[ (]|$)/).flatten
        end
      end.uniq
    end

    let(:dsl) { %w[describe it let before setup test subject do end require class def context] }

    it "lists every method any generated file calls that a framework defines" do
      known = installed_methods + app_gems_methods
      missing = (called_names(generated_files[:all]) & known) - described_class.singleton_class::SPEC_METHOD_NAMES - dsl -
                described_class.singleton_class::MODEL_SPEC_CALLS

      expect(missing).to eq([])
    end

    it "lists, for a model spec's let, every method the generated model specs call" do
      known = installed_methods + app_gems_methods
      missing = (called_names(generated_files[:model]) & known) - described_class.singleton_class::MODEL_SPEC_CALLS - dsl

      expect(missing).to eq([])
      expect(described_class.singleton_class::MODEL_SPEC_CALLS - known).to eq([])
    end

    it "keeps the names a model spec's let, a request spec's let and a minitest all call on the list" do
      expect(%w[skip pending include send is_expected expect assert_equal assert_not assert_response create build sign_in attributes_for page visit change get post] -
             described_class.singleton_class::SPEC_METHOD_NAMES).to eq([])
      expect(%w[skip pending expect is_expected create build] - described_class.singleton_class::MODEL_SPEC_CALLS).to eq([])
    end

    it "keeps the minitest instance variable list in step with the test cases" do
      seen = []
      [ ActiveSupport::TestCase, ActionDispatch::IntegrationTest ].each do |base|
        klass = Class.new(base) { define_method(:test_x) { assert true; $r4_seen = instance_variables } }
        test = klass.new("test_x")
        test.run
        seen.concat($r4_seen + test.instance_variables)
      end
      live = seen.map { |name| name.to_s.delete_prefix("@") }.uniq.grep(/\A[a-z][a-z0-9_]*\z/)
      app_only = %w[request response controller routes cookie_jar html_document root_session]

      expect(live - described_class.singleton_class::TEST_CASE_IVARS).to eq([])
      expect(described_class.singleton_class::TEST_CASE_IVARS - live - app_only - %w[after_run assertions code connection_subscriber cookies diff encoders
                                                                                     fixture_cache_key fixture_connection_pools mailer mime name object
                                                                                     old_perform_deliveries options parallel_executor parallelize_with passed
                                                                                     request_count run_cleanup_hooks saved_pool_configs simple_stubs store
                                                                                     uses_transaction view_context_class]).to eq([])
    end
  end

  # bazaar's OrdersController inherits require_login from a hand-written
  # Authentication concern, and every request its generated test sent came
  # back a 302 to /session/new with nothing to say why. Its create reads the
  # session cart, yet the test posted every orders column as `order:` params.
  describe "a controller behind a login filter that is not Devise's" do
    def orders_test(root, filter: "require_login", api: false)
      allow(described_class).to receive(:rails_app).and_return(double(root: Pathname.new(root)))
      allow(described_class).to receive(:cached_context).and_return({
        tests: { framework: "minitest", test_helper_setup: [], fixture_names: { "users" => %w[one], "orders" => %w[first] } },
        models: { "Order" => { table_name: "orders" }, "User" => { table_name: "users" } },
        schema: { tables: { "orders" => { columns: [ { name: "id", type: "integer" }, { name: "number", type: "string" } ] } } },
        controllers: { controllers: { "OrdersController" => {
          actions: %w[index create], strong_params: [], api_controller: api,
          filters: [ { kind: "before", name: filter, from_concern: "Authentication" } ]
        } } },
        routes: { by_controller: { "orders" => [ { verb: "GET", path: "/orders", action: "index", name: "orders" },
                                                 { verb: "POST", path: "/orders", action: "create" } ] } }
      })
      described_class.call(controller: "OrdersController").content.first[:text]
    end

    it "says the requests need a signed-in user when the app's tests have no sign-in helper" do
      Dir.mktmpdir do |root|
        text = orders_test(root)

        expect(text).to include("# TODO: OrdersController runs require_login (from Authentication) before index, create, " \
                                "so each request here is redirected or refused until the test signs in")
        expect(text).to include("_OrdersController runs require_login (from Authentication) before index, create; " \
                                "the requests are redirected or refused until the test signs in (see the TODO)._")
      end
    end

    def write_helper(root, helper)
      FileUtils.mkdir_p(File.join(root, "test", "test_helpers"))
      File.write(File.join(root, "test", "test_helpers", "session_test_helper.rb"),
                 "module SessionTestHelper\n  def #{helper}(user)\n  end\nend\n")
    end

    it "says which helper names it looked for when the app signs in through another name" do
      Dir.mktmpdir do |root|
        write_helper(root, "authorize_request_for")

        text = orders_test(root)

        expect(text).to include("# TODO: OrdersController runs require_login")
        expect(text).to include("no `sign_in` or `log_in` helper in this app's test helpers")
        expect(text).not_to include("define no sign-in helper")
      end
    end

    it "signs in with the app's own helper and a users fixture where it answers the filter" do
      Dir.mktmpdir do |root|
        write_helper(root, "sign_in_as")

        text = orders_test(root, filter: "require_authentication")

        expect(text).to include("  setup do\n    sign_in_as users(:one)\n")
        expect(text).not_to include("# TODO: OrdersController runs require_authentication")
        expect(text).to include("the setup signs in with sign_in_as._")
      end
    end

    it "pairs Devise's sign_in with the authenticate_<scope>! of a model the app has" do
      Dir.mktmpdir do |root|
        write_helper(root, "sign_in")

        expect(orders_test(root, filter: "authenticate_user!")).to include("  setup do\n    sign_in users(:one)\n")
        expect(orders_test(root, filter: "authenticate_token!")).not_to include("sign_in users(:one)")
      end
    end

    # The blog's token-checked Api::V1::BaseController got `sign_in_as
    # users(:one)`, and all three generated tests failed with a 401.
    it "names the helper in a TODO, and signs nothing in, where the filter is not its own or the controller is an API one" do
      Dir.mktmpdir do |root|
        write_helper(root, "sign_in_as")

        hand_written = orders_test(root)
        api = orders_test(root, filter: "require_authentication", api: true)

        expect(hand_written).to include("this app's sign_in_as is not known to get a request past require_login, so send what require_login checks.")
        expect(api).to include("this app's sign_in_as is not known to get a request past require_authentication")
        expect([ hand_written, api ]).to all(satisfy { |text| !text.include?("sign_in_as users(:one)") })
      end
    end

    it "takes the helper from a def, not from a def's text inside a heredoc" do
      Dir.mktmpdir do |root|
        FileUtils.mkdir_p(File.join(root, "test", "test_helpers"))
        File.write(File.join(root, "test", "test_helpers", "session_test_helper.rb"),
                   "module SessionTestHelper\n  DOC = <<~TXT\n    def sign_in_as(user)\n  TXT\n\n  def log_in(user)\n  end\nend\n")

        text = orders_test(root)

        expect(text).to include("this app's log_in is not known to get a request past require_login")
        expect(text).not_to include("sign_in_as")
      end
    end

    it "names the login filter in a system test, which signs in through the login page" do
      Dir.mktmpdir do |root|
        orders_test(root)
        text = described_class.call(controller: "OrdersController", type: "system").content.first[:text]

        expect(text).to include("# test/system/orders_test.rb")
        expect(text).to include("  # TODO: OrdersController runs require_login (from Authentication) before index; " \
                                "a browser signs in the way a user does")
      end
    end

    it "takes no action's inline permit as the create params" do
      Dir.mktmpdir do |root|
        FileUtils.mkdir_p(File.join(root, "app/controllers"))
        File.write(File.join(root, "app/controllers/orders_controller.rb"), <<~RUBY)
          class OrdersController < ApplicationController
            def index
              @orders = Order.where(params.permit(:number))
            end

            def create; end
          end
        RUBY
        orders_test(root)
        controllers = RailsAiContext::Introspectors::ControllerIntrospector.new(RailsAiContext::StaticApp.new(root)).send(:static_call)
        context = described_class.cached_context.merge(controllers: controllers)
        allow(described_class).to receive(:cached_context).and_return(context)

        text = described_class.call(controller: "OrdersController").content.first[:text]

        expect(text).to include("OrdersController has no *_params method; send the order params the action permits, if any")
        expect(text).not_to include("params: { order:")
      end
    end

    it "claims no params read where an action permits inline" do
      Dir.mktmpdir do |root|
        FileUtils.mkdir_p(File.join(root, "app/controllers"))
        File.write(File.join(root, "app/controllers/orders_controller.rb"), <<~RUBY)
          class OrdersController < ApplicationController
            def index; end

            def create
              Order.create(params.require(:order).permit(:number))
            end
          end
        RUBY
        orders_test(root)
        controllers = RailsAiContext::Introspectors::ControllerIntrospector.new(RailsAiContext::StaticApp.new(root)).send(:static_call)
        context = described_class.cached_context.merge(controllers: controllers)
        allow(described_class).to receive(:cached_context).and_return(context)

        text = described_class.call(controller: "OrdersController").content.first[:text]

        expect(text).to include("OrdersController has no *_params method; send the order params the action permits, if any")
        expect(text).not_to include("reads no order params")
      end
    end

    it "posts no params a controller with no strong params never reads" do
      Dir.mktmpdir do |root|
        text = orders_test(root)

        expect(text).to include("OrdersController has no *_params method; send the order params the action permits, if any")
        expect(text).not_to include("params: { order:")
      end
    end
  end

  describe "the presence validation a required belongs_to adds" do
    # Rails writes "must exist" for it, so validate_presence_of, which expects
    # "can't be blank", fails; belong_to(:account) already checks it.
    it "writes no validate_presence_of for it" do
      bundling_shoulda
      allow(described_class).to receive(:cached_context).and_return({
        tests: { framework: "rspec", factory_names: {} },
        models: {
          "Order" => {
            associations: [ { type: "belongs_to", name: "account" } ],
            validations: [
              { kind: "presence", attributes: %w[account], implicit: true },
              { kind: "presence", attributes: %w[number] }
            ]
          }
        }
      })

      text = described_class.call(model: "Order").content.first[:text]

      expect(text).to include("belong_to(:account)")
      expect(text).to include("validate_presence_of(:number)")
      expect(text).not_to include("validate_presence_of(:account)")
    end
  end

  describe "the params a request spec creates a record with" do
    # FactoryBot.attributes_for leaves out every association, so a post sent
    # without its required user_id is never saved.
    def create_spec(validations:, permits: %w[title user_id], associations: [ { type: "belongs_to", name: "user", foreign_key: "user_id" } ])
      strong_params = permits ? [ { name: "post_params", requires: "post", permits: permits } ] : []
      Dir.mktmpdir do |root|
        allow(described_class).to receive(:rails_app).and_return(double(root: Pathname.new(root)))
        allow(described_class).to receive(:cached_context).and_return({
          tests: { framework: "rspec", factories: { count: 2 }, factory_names: { "spec/factories/all.rb" => %w[post user] } },
          models: { "Post" => { table_name: "posts", associations: associations, validations: validations } },
          schema: { tables: { "posts" => { columns: [ { name: "title", type: "string" }, { name: "user_id", type: "integer" } ] } } },
          controllers: { controllers: { "PostsController" => { actions: %w[create],
                                                              strong_params: strong_params } } },
          routes: { by_controller: { "posts" => [ { verb: "POST", path: "/posts", action: "create", name: "posts" } ] } }
        })
        return described_class.call(controller: "PostsController").content.first[:text]
      end
    end

    it "sends the id of a required parent the controller permits" do
      text = create_spec(validations: [ { kind: "presence", attributes: %w[user], implicit: true } ])

      expect(text).to include("let(:valid_attributes) { FactoryBot.attributes_for(:post).merge(user_id: FactoryBot.create(:user).id) }")
    end

    # An action that permits inline has no *_params method to read, and an
    # unpermitted key is only logged.
    it "sends it when the action permits inline" do
      text = create_spec(validations: [ { kind: "presence", attributes: %w[user], implicit: true } ], permits: nil)

      expect(text).to include("FactoryBot.attributes_for(:post).merge(user_id: FactoryBot.create(:user).id)")
    end

    it "leaves out a parent that is optional, or required only under a condition" do
      text = create_spec(validations: [ { kind: "presence", attributes: %w[user], implicit: true, implicit_if: "-> { Current.user }" },
                                        { kind: "presence", attributes: %w[title] } ])

      expect(text).to include("let(:valid_attributes) { FactoryBot.attributes_for(:post) }")
    end

    # A polymorphic parent names no one factory, and its id alone saves nothing.
    it "leaves out a polymorphic parent" do
      text = create_spec(validations: [ { kind: "presence", attributes: %w[user], implicit: true } ],
                         associations: [ { type: "belongs_to", name: "user", foreign_key: "user_id", polymorphic: true } ])

      expect(text).to include("let(:valid_attributes) { FactoryBot.attributes_for(:post) }")
    end

    it "leaves out a parent the controller does not permit" do
      text = create_spec(validations: [ { kind: "presence", attributes: %w[user], implicit: true } ], permits: %w[title])

      expect(text).to include("let(:valid_attributes) { FactoryBot.attributes_for(:post) }")
    end
  end

  describe "a record built from placeholders" do
    # With no factory and no fixture, `user_id: 1` names no user, and create! raises "User must exist".
    def placeholder_spec(validations:, permits: %w[title user_id], enums: {}, user: {}, user_columns: [], models: {}, post_columns: [], framework: "rspec",
                         associations: [ { type: "belongs_to", name: "author", class_name: "User", foreign_key: "user_id" } ])
      Dir.mktmpdir do |root|
        allow(described_class).to receive(:rails_app).and_return(double(root: Pathname.new(root)))
        allow(described_class).to receive(:cached_context).and_return({
          tests: { framework: framework, factories: nil, factory_names: nil },
          models: { "Post" => { table_name: "posts", associations: associations, validations: validations, enums: enums },
                    "User" => { table_name: "users", validations: [ { kind: "uniqueness", attributes: %w[email] } ] }.merge(user) }.merge(models),
          schema: { tables: { "posts" => { columns: [ { name: "title", type: "string" }, { name: "user_id", type: "integer" }, { name: "status", type: "string" },
                                                     { name: "rating", type: "integer" }, *post_columns ] },
                              "users" => { columns: [ { name: "id", type: "integer" }, { name: "name", type: "string" }, { name: "email", type: "string" },
                                                     *user_columns ] } } },
          controllers: { controllers: { "PostsController" => { actions: %w[create show],
                                                              strong_params: [ { name: "post_params", requires: "post", permits: permits } ] } } },
          routes: { by_controller: { "posts" => [ { verb: "POST", path: "/posts", action: "create", name: "posts" },
                                                  { verb: "GET", path: "/posts/:id", action: "show", name: "post" } ] } }
        })
        return described_class.call(controller: "PostsController").content.first[:text]
      end
    end

    it "creates a required parent from its own placeholders" do
      text = placeholder_spec(validations: [ { kind: "presence", attributes: %w[author], implicit: true } ])

      parent = 'user_id: User.create!({ email: "email-#{SecureRandom.hex(4)}@example.com", name: "MyString" }).id'
      expect(text).to include("let(:post_record) { Post.create!({ title: \"MyString\", #{parent} }) }")
      expect(text).to include("let(:valid_attributes) { { title: \"MyString\", #{parent} } }")
    end

    it "takes a value the record's inclusion validation lists" do
      text = placeholder_spec(validations: [ { kind: "inclusion", attributes: %w[status], options: { in: %w[draft published] } } ], permits: %w[status title])

      expect(text).to include('let(:valid_attributes) { { status: "draft", title: "MyString" } }')
    end

    # A request sends "1" for an integer enum, and Rails raises "'1' is not a valid status".
    it "takes an enum attribute's first key" do
      text = placeholder_spec(validations: [], permits: %w[status title], enums: { "status" => { "draft" => 0, "published" => 1 } })

      expect(text).to include('let(:valid_attributes) { { status: "draft", title: "MyString" } }')
    end

    it "stops at a parent of the record's own class" do
      text = placeholder_spec(validations: [ { kind: "presence", attributes: %w[original], implicit: true } ],
                              associations: [ { type: "belongs_to", name: "original", class_name: "Post", foreign_key: "user_id" } ])

      expect(text).to include("let(:valid_attributes) { { title: \"MyString\", user_id: 1 } }")
    end

    def inclusion(attr, list) = { kind: "inclusion", attributes: [ attr ], options: { in: list } }

    it "takes a range's first value, and the type's placeholder for a list a lambda computes" do
      expect(placeholder_spec(validations: [ inclusion("rating", "3..5") ], permits: %w[rating])).to include("let(:valid_attributes) { { rating: 3 } }")
      expect(placeholder_spec(validations: [ inclusion("rating", 2..4) ], permits: %w[rating])).to include("let(:valid_attributes) { { rating: 2 } }")
      expect(placeholder_spec(validations: [ inclusion("status", "(proc)") ], permits: %w[status])).to include("with a lambda or proc in the in option")
    end

    it "writes a symbol an inclusion lists as the string a string column holds" do
      text = placeholder_spec(validations: [ inclusion("status", %i[draft sent]) ], permits: %w[status])

      expect(text).to include('let(:valid_attributes) { { status: "draft" } }')
    end

    it "takes the inclusion's value for an enum the walk could not read as a list" do
      text = placeholder_spec(validations: [ inclusion("status", %w[open closed]) ], permits: %w[status], enums: { "status" => "STATUSES" })

      expect(text).to include('let(:valid_attributes) { { status: "open" } }')
    end

    # Rails raises "'1' is not a valid rating" for a value outside the mapping; left out, the column keeps its default.
    it "leaves out an enum whose mapping the walk could not read, on the record, its params and a parent" do
      text = placeholder_spec(validations: [ { kind: "presence", attributes: %w[author], implicit: true } ], permits: %w[rating title user_id],
                              enums: { "rating" => "RATINGS" }, user: { enums: { "name" => "NAMES" } })

      parent = 'user_id: User.create!({ email: "email-#{SecureRandom.hex(4)}@example.com" }).id'
      expect(text).to include("let(:valid_attributes) { { title: \"MyString\", #{parent} } }")
      expect(text).to include("let(:post_record) { Post.create!({ title: \"MyString\", #{parent} }) }")
      expect(text).to include("# TODO: rating is an enum whose values the source computes; set one it maps")
      expect(text).to include("# TODO: User#name is an enum whose values the source computes; set one it maps")
      minitest = placeholder_spec(validations: [], permits: %w[rating title], enums: { "rating" => "RATINGS" }, framework: "minitest")
      expect(minitest).to include("@post_record ||= Post.create!({ title: \"MyString\" })")
      expect(minitest).to include("params: { post: { title: \"MyString\" } }")
      expect(minitest).to include("  # TODO: rating is an enum whose values the source computes; set one it maps")
    end

    # A controller that finds the record through `@post.comments` 404s on any other post.
    describe "a nested route's parent" do
      def nested_spec(permits:, parent: "post", comment_associations: nil, comment_columns: [], models: {}, framework: "rspec",
                      actions: %w[index create destroy])
        model = parent.camelize
        comment_associations ||= [ { type: "belongs_to", name: parent, foreign_key: "#{parent}_id" } ]
        Dir.mktmpdir do |root|
          allow(described_class).to receive(:rails_app).and_return(double(root: Pathname.new(root)))
          allow(described_class).to receive(:cached_context).and_return({
            tests: { framework: framework, factories: nil, factory_names: nil },
            models: { "Comment" => { table_name: "comments", associations: comment_associations,
                                     validations: [ { kind: "presence", attributes: [ comment_associations.first[:name] ], implicit: true } ] },
                      model => { table_name: parent.pluralize, associations: [ { type: "has_many", name: "comments", as: comment_associations.first[:as_role] }.compact ] } }.merge(models),
            schema: { tables: { "comments" => { columns: [ { name: "body", type: "text" }, { name: "#{parent}_id", type: "integer" }, *comment_columns ] },
                                parent.pluralize => { columns: [ { name: "title", type: "string" } ] } } },
            controllers: { controllers: { "CommentsController" => { actions: actions,
                                                                   strong_params: [ { name: "comment_params", requires: "comment", permits: permits } ] } } },
            routes: { by_controller: { "comments" => [
              { verb: "GET", path: "/#{parent.pluralize}/:#{parent}_id/comments", action: "index", name: "#{parent}_comments" },
              { verb: "POST", path: "/#{parent.pluralize}/:#{parent}_id/comments", action: "create", name: "#{parent}_comments" },
              { verb: "GET", path: "/#{parent.pluralize}/:#{parent}_id/comments/:id", action: "show", name: "#{parent}_comment" },
              { verb: "PATCH", path: "/#{parent.pluralize}/:#{parent}_id/comments/:id", action: "update", name: "#{parent}_comment" },
              { verb: "DELETE", path: "/#{parent.pluralize}/:#{parent}_id/comments/:id", action: "destroy", name: "#{parent}_comment" }
            ].select { |route| actions.include?(route[:action]) } } }
          })
          return described_class.call(controller: "CommentsController").content.first[:text]
        end
      end

      # rspec-rails' `app` is the Rails application, and the destroy example's own local is `record`.
      it "names no let after a method the spec or its examples already use" do
        app = nested_spec(permits: %w[body], parent: "app")
        expect(app).to include('let(:app_record) { App.create!({ title: "MyString" }) }')
        expect(app).to include("delete app_comment_url(app_record, record)")
        expect(app).not_to include("let(:app)")

        record = nested_spec(permits: %w[body], parent: "record")
        expect(record).to include('let(:record_record) { Record.create!({ title: "MyString" }) }')
        expect(record).to include("delete record_comment_url(record_record, record)")
      end

      # `let(:post)` would hide the request helper `post`.
      it "is created from placeholders, named in the path, and owns the record" do
        text = nested_spec(permits: %w[body])

        expect(text).to include('let(:post_record) { Post.create!({ title: "MyString" }) }')
        expect(text).to include('let(:comment) { Comment.create!({ body: "MyText", post_id: post_record.id }) }')
        expect(text).to include('let(:valid_attributes) { { body: "MyText" } }')
        expect(text).to include("get post_comments_url(post_record)")
        expect(text).to include("post post_comments_url(post_record), params: { comment: valid_attributes }")
        expect(text).to include("delete post_comment_url(post_record, record)")
        expect(text).not_to include("skip")
      end

      it "is created from placeholders in a minitest too, with the record, so every action runs" do
        text = nested_spec(permits: %w[body post_id], framework: "minitest", actions: %w[index create show update destroy])

        expect(text).to include("  def post_record\n    @post_record ||= Post.create!({ title: \"MyString\" })\n  end\n")
        expect(text).to include("  def comment_record\n    @comment_record ||= Comment.create!({ body: \"MyText\", post_id: post_record.id })\n  end\n")
        expect(text).not_to include("setup do")
        expect(text).to include("get post_comments_url(post_record)")
        expect(text).to include("post post_comments_url(post_record), params: { comment: { body: \"MyText\", post_id: post_record.id } }")
        expect(text).to include("get post_comment_url(post_record, comment_record)")
        expect(text).to include("patch post_comment_url(post_record, comment_record), params: { comment: { body: comment_record.body, post_id: comment_record.post_id } }")
        expect(text).to include("delete post_comment_url(post_record, comment)")
        expect(text).not_to include("skip")
        expect(text).not_to include("deleting a fixture row")

        expect(nested_spec(permits: %w[body], parent: "app", framework: "minitest")).to include("@app_record ||= App.create!")
      end

      # A parent that cannot be made up cannot be named in the path, and neither can what belongs to it.
      describe "that belongs to a role no model fills" do
        let(:post_models) do
          { "Post" => { table_name: "posts", associations: [ { type: "belongs_to", name: "author", polymorphic: true, foreign_key: "author_id" },
                                                            { type: "has_many", name: "comments" } ],
                        validations: [ { kind: "presence", attributes: %w[author], implicit: true } ] } }
        end
        let(:reason) { "Post belongs_to :author, polymorphic: true, and no model declares has_many or has_one ..., as: :author" }

        it "is not made up in either framework; every example that needs it skips, saying why" do
          %w[rspec minitest].each do |framework|
            text = nested_spec(permits: %w[body], models: post_models, framework: framework, actions: %w[index create show update destroy])

            expect(text).not_to include("MyString")
            expect(text).not_to include("Post.create!")
            expect(text).to include("skip \"TODO: #{reason}")
            expect(text).not_to include("no matching fixture")
            expect(text.scan("skip \"TODO: #{reason}").size).to eq(5)
          end
        end

        it "also keeps a record that needs the unbuildable parent from being made up" do
          text = placeholder_spec(validations: [ { kind: "presence", attributes: %w[author], implicit: true } ],
                                  associations: [ { type: "belongs_to", name: "author", class_name: "Owner", foreign_key: "user_id" } ],
                                  models: { "Owner" => { table_name: "users", associations: [ { type: "belongs_to", name: "holder", polymorphic: true, foreign_key: "holder_id" } ],
                                                         validations: [ { kind: "presence", attributes: %w[holder], implicit: true } ] } })

          expect(text).not_to include("Post.create!")
          expect(text).to include("skip \"TODO: Owner belongs_to :holder, polymorphic: true")
        end
      end

      it "says its attributes may need adjusting before the parent it makes up, not after" do
        text = nested_spec(permits: %w[body])

        todo = "# TODO: adjust these attributes if validations reject the placeholder values"
        expect(text.index(todo)).to be < text.index("let(:post_record)")
        expect(text.scan(todo).size).to eq(1)
      end

      it "sends the route parent's id where the controller permits the owning key" do
        expect(nested_spec(permits: %w[body post_id])).to include('let(:valid_attributes) { { body: "MyText", post_id: post_record.id } }')
      end

      it "fills a polymorphic owner's id and type from the route parent, before another model that fills the role" do
        text = nested_spec(permits: %w[body], comment_associations: [ { type: "belongs_to", name: "subject", polymorphic: true, foreign_key: "subject_id", as_role: "subject" } ],
                           comment_columns: [ { name: "subject_id", type: "integer" }, { name: "subject_type", type: "string" } ],
                           models: { "Article" => { table_name: "posts", associations: [ { type: "has_many", name: "comments", as: "subject" } ] } })

        expect(text).to include('let(:comment) { Comment.create!({ body: "MyText", subject_id: post_record.id, subject_type: "Post" }) }')
      end
    end

    # No model of its own, or a model with no fixture: a parent with a fixture is used as the fixture is, one without is made up.
    describe "a minitest route parent" do
      def parent_test(controller: "ReportsController", fixtures: {}, models: nil, permits: nil)
        models ||= { "Record" => { table_name: "records" } }
        key = controller.delete_suffix("Controller").underscore
        Dir.mktmpdir do |root|
          allow(described_class).to receive(:rails_app).and_return(double(root: Pathname.new(root)))
          allow(described_class).to receive(:cached_context).and_return({
            tests: { framework: "minitest", test_helper_setup: [], fixture_names: fixtures },
            models: models,
            schema: { tables: { "records" => { columns: [ { name: "title", type: "string" } ] },
                                "comments" => { columns: [ { name: "body", type: "text" }, { name: "record_id", type: "integer" } ] } } },
            controllers: { controllers: { controller => { actions: %w[index create], strong_params: permits && [ { name: "#{key.singularize}_params", requires: key.singularize, permits: permits } ] }.compact } },
            routes: { by_controller: { key => [ { verb: "GET", path: "/records/:record_id/#{key}", action: "index", name: "record_#{key}" },
                                                { verb: "POST", path: "/records/:record_id/#{key}", action: "create", name: "record_#{key}" } ] } }
          })
          return described_class.call(controller: controller).content.first[:text]
        end
      end

      it "is made up for a controller with no model, and named in its path" do
        text = parent_test

        expect(text).to include("  def record_record\n    @record_record ||= Record.create!({ title: \"MyString\" })\n  end\n")
        expect(text).to include("get record_reports_url(record_record)")
        expect(text).not_to include("no matching fixture")
      end

      it "is the fixture itself when the app has one, for a controller with and without a model" do
        text = parent_test(fixtures: { "records" => %w[one] })

        expect(text).to include("get record_reports_url(records(:one))")
        expect(text).not_to include("create!")

        comments = parent_test(controller: "CommentsController", fixtures: { "records" => %w[one] }, permits: %w[body record_id],
                               models: { "Record" => { table_name: "records" },
                                         "Comment" => { table_name: "comments", associations: [ { type: "belongs_to", name: "record", foreign_key: "record_id" } ],
                                                        validations: [ { kind: "presence", attributes: %w[record], implicit: true } ] } })
        expect(comments).to include("@comment_record ||= Comment.create!({ body: \"MyText\", record_id: records(:one).id })")
        expect(comments).to include("get record_comments_url(records(:one))")
        expect(comments).not_to include("Record.create!")
      end
    end

    describe "a required polymorphic parent" do
      def polymorphic_spec(user: {}, permits: %w[author_id author_type title], models: {}, user_columns: [], framework: "rspec")
        placeholder_spec(validations: [ { kind: "presence", attributes: %w[author], implicit: true } ], permits: permits,
                         associations: [ { type: "belongs_to", name: "author", polymorphic: true, foreign_key: "author_id" } ],
                         post_columns: [ { name: "author_id", type: "integer" }, { name: "author_type", type: "string" } ], user: user,
                         models: models, user_columns: user_columns, framework: framework)
      end

      # Rails raises NameError constantizing a made-up `author_type: "MyString"`.
      it "skips what needs a record or the role's params in a minitest too, saying why, when no model fills the role" do
        text = polymorphic_spec(framework: "minitest")

        reason = "Post belongs_to :author, polymorphic: true, and no model declares has_many or has_one ..., as: :author"
        expect(text).not_to include("author_type: \"MyString\"")
        expect(text).not_to include("Post.create!")
        expect(text.scan("skip \"TODO: #{reason}").size).to eq(2)
        expect(polymorphic_spec(framework: "minitest", permits: %w[title])).to include("params: { post: { title: \"MyString\" } }")
      end

      it "reads each model's roles once a run, however many placeholders ask" do
        allow(described_class).to receive(:scan_required_roles).and_call_original
        polymorphic_spec(user: { associations: [ { type: "has_many", name: "posts", as: "author", class_name: "Post" } ] })

        expect(described_class).to have_received(:scan_required_roles).with("Post").once
      end

      # Rails stores the owner's base_class.polymorphic_name, so `User#posts` finds an Admin's rows only under "User".
      describe "an STI owner" do
        let(:fills) { [ { type: "has_many", name: "posts", as: "author", class_name: "Post" } ] }
        let(:admin) { { table_name: "users", sti: { sti_parent: "User", type_column: "type" }, validations: [ { kind: "uniqueness", attributes: %w[email] } ] } }

        it "is the base class when the subclass inherits its has_many" do
          text = polymorphic_spec(user: { associations: fills, sti: { sti_base: true, sti_children: %w[Admin], type_column: "type" } },
                                  models: { "Admin" => admin.merge(associations: fills) }, user_columns: [ { name: "type", type: "string" } ])

          parent = 'author_id: User.create!({ email: "email-#{SecureRandom.hex(4)}@example.com", name: "MyString" }).id, author_type: "User"'
          expect(text).to include("let(:valid_attributes) { { #{parent}, title: \"MyString\" } }")
        end

        it "writes the base class's name for a subclass that alone declares the has_many" do
          text = polymorphic_spec(user: { sti: { sti_base: true, sti_children: %w[Admin], type_column: "type" } },
                                  models: { "Admin" => admin.merge(associations: fills) }, user_columns: [ { name: "type", type: "string" } ])

          parent = 'author_id: Admin.create!({ email: "email-#{SecureRandom.hex(4)}@example.com", name: "MyString", type: "Admin" }).id, author_type: "User"'
          expect(text).to include("let(:valid_attributes) { { #{parent}, title: \"MyString\" } }")
        end

        it "writes the top of a deeper STI chain" do
          root = { sti: { sti_base: true, sti_children: %w[Admin], type_column: "type" } }
          text = polymorphic_spec(user: root, models: { "Admin" => admin, "Owner" => admin.merge(sti: { sti_parent: "Admin", type_column: "type" }, associations: fills) },
                                  user_columns: [ { name: "type", type: "string" } ])

          expect(text).to include('type: "Owner" }).id, author_type: "User"')
        end
      end

      it "is created as a model whose has_many names the role" do
        text = polymorphic_spec(user: { associations: [ { type: "has_many", name: "posts", as: "author", class_name: "Post" } ] })

        parent = 'author_id: User.create!({ email: "email-#{SecureRandom.hex(4)}@example.com", name: "MyString" }).id, author_type: "User"'
        expect(text).to include("let(:valid_attributes) { { #{parent}, title: \"MyString\" } }")
        expect(text).to include("let(:post_record) { Post.create!({ #{parent}, title: \"MyString\" }) }")
      end

      it "skips what needs a record, saying why, when no model fills the role" do
        text = polymorphic_spec

        reason = "Post belongs_to :author, polymorphic: true, and no model declares has_many or has_one ..., as: :author"
        expect(text).not_to include("let(:post_record)")
        expect(text).to include("skip \"TODO: #{reason}")
        expect(text.scan("skip \"TODO: #{reason}").size).to eq(2)
      end

      # The controller sets the owner itself (`@note.owner = current_user`), so the params it permits still create one.
      it "keeps the create example when the controller permits neither the role's id nor its type" do
        text = polymorphic_spec(permits: %w[title])

        expect(text).not_to include("let(:post_record)")
        expect(text).to include('let(:valid_attributes) { { title: "MyString" } }')
        expect(text).to include("it \"creates a new Post\" do")
      end
    end

    describe "an STI parent" do
      let(:required) { [ { kind: "presence", attributes: %w[author], implicit: true } ] }

      it "names the subclass in its type column" do
        text = placeholder_spec(validations: required, user_columns: [ { name: "type", type: "string" } ],
                                associations: [ { type: "belongs_to", name: "author", class_name: "Admin", foreign_key: "user_id" } ],
                                models: { "Admin" => { table_name: "users", sti: { sti_parent: "User", type_column: "type" },
                                                          validations: [ { kind: "uniqueness", attributes: %w[email] } ] } })

        expect(text).to include('user_id: Admin.create!({ email: "email-#{SecureRandom.hex(4)}@example.com", name: "MyString", type: "Admin" }).id')
      end

      it "leaves the type column out for the base class" do
        text = placeholder_spec(validations: required, user_columns: [ { name: "type", type: "string" } ],
                                user: { sti: { sti_base: true, sti_children: %w[Admin], type_column: "type" } })

        expect(text).to include('user_id: User.create!({ email: "email-#{SecureRandom.hex(4)}@example.com", name: "MyString" }).id')
      end
    end

    describe "a parent that authenticates by password" do
      let(:required) { [ { kind: "presence", attributes: %w[author], implicit: true } ] }
      let(:parent) { 'user_id: User.create!({ email: "email-#{SecureRandom.hex(4)}@example.com", name: "MyString", password: "password123", password_confirmation: "password123" }).id' }

      it "sets has_secure_password's password, not its digest" do
        text = placeholder_spec(validations: required, user_columns: [ { name: "password_digest", type: "string" } ], user: { has_secure_password: true })

        expect(text).to include(parent)
      end

      it "sets Devise's password, not its encrypted column" do
        text = placeholder_spec(validations: required, user_columns: [ { name: "encrypted_password", type: "string" } ],
                                user: { concerns: %w[Devise::Models::Authenticatable Devise::Models::DatabaseAuthenticatable] })

        expect(text).to include(parent)
      end
    end

    # The controller of a model that authenticates by password: the record and the params both carry the password.
    describe "a record that authenticates by password" do
      def accounts_test(framework, fixture: false, model: { has_secure_password: true }, column: "password_digest", permits: %w[email password password_confirmation])
        Dir.mktmpdir do |root|
          allow(described_class).to receive(:rails_app).and_return(double(root: Pathname.new(root)))
          allow(described_class).to receive(:cached_context).and_return({
            tests: { framework: framework, factories: nil, factory_names: nil, test_helper_setup: [], fixture_names: fixture ? { "accounts" => [ "one" ] } : {} },
            models: { "Account" => { table_name: "accounts" }.merge(model) },
            schema: { tables: { "accounts" => { columns: [ { name: "email", type: "string" }, { name: column, type: "string" } ] } } },
            controllers: { controllers: { "AccountsController" => { actions: %w[index show create update],
                                                                    strong_params: [ { name: "account_params", requires: "account", permits: permits } ] } } },
            routes: { by_controller: { "accounts" => [
              { verb: "GET", path: "/accounts/:id", action: "show", name: "account" },
              { verb: "POST", path: "/accounts", action: "create", name: "accounts" },
              { verb: "PATCH", path: "/accounts/:id", action: "update", name: "account" }
            ] } }
          })
          return described_class.call(controller: "AccountsController").content.first[:text]
        end
      end

      let(:password) { 'password: "password123", password_confirmation: "password123"' }

      it "is made up with the password, and sends it, in a request spec" do
        text = accounts_test("rspec")

        expect(text).to include("let(:account) { Account.create!({ email: \"MyString\", #{password} }) }")
        expect(text).to include("let(:valid_attributes) { { email: \"MyString\", #{password} } }")
      end

      it "is made up with the password in a minitest, and its create sends it" do
        text = accounts_test("minitest")

        expect(text).to include("@account_record ||= Account.create!({ email: \"MyString\", #{password} })")
        expect(text).to include("params: { account: { email: \"MyString\", #{password} } }")
      end

      it "sends the password where the subject is a fixture, which holds only the digest" do
        text = accounts_test("minitest", fixture: true)

        expect(text).to include("params: { account: { email: @account.email, #{password} } }")
        expect(text).not_to include("@account.password")
      end

      it "is Devise's password, not its encrypted column" do
        text = accounts_test("rspec", model: { concerns: %w[Devise::Models::DatabaseAuthenticatable] }, column: "encrypted_password")

        expect(text).to include("let(:account) { Account.create!({ email: \"MyString\", #{password} }) }")
      end
    end

    it "leaves an optional parent's key a placeholder" do
      text = placeholder_spec(validations: [])

      expect(text).to include("let(:valid_attributes) { { title: \"MyString\", user_id: 1 } }")
    end
  end

  # A record made up from placeholders must pass the model's own validations where they say how, and every example
  # that needs it must skip, naming the validation and what to supply, where they do not.
  describe "the value made up under a validation" do
    def thing_text(validations, columns: { "title" => "string", "body" => "text" }, framework: "rspec", model: {}, permits: nil, table: "things")
      Dir.mktmpdir do |root|
        allow(described_class).to receive(:rails_app).and_return(double(root: Pathname.new(root)))
        allow(described_class).to receive(:cached_context).and_return({
          tests: { framework: framework, factories: nil, factory_names: nil, fixture_names: {}, test_helper_setup: [] },
          models: { "Thing" => { table_name: table, validations: validations }.merge(model) },
          schema: { tables: { table => { columns: columns.map { |name, type| { name: name, type: type } } } } },
          controllers: { controllers: { "ThingsController" => { actions: %w[index show create update destroy],
                                                                strong_params: [ { name: "thing_params", requires: "thing", permits: permits || columns.keys } ] } } },
          routes: { by_controller: { "things" => [
            { verb: "GET", path: "/things", action: "index", name: "things" },
            { verb: "POST", path: "/things", action: "create", name: "things" },
            { verb: "GET", path: "/things/:id", action: "show", name: "thing" },
            { verb: "PATCH", path: "/things/:id", action: "update", name: "thing" },
            { verb: "DELETE", path: "/things/:id", action: "destroy", name: "thing" }
          ] } }
        })
        return described_class.call(controller: "ThingsController").content.first[:text]
      end
    end

    def rule(kind, attr, options = {}) = { kind: kind, attributes: [ attr ], options: options }

    it "is long enough and short enough for a length rule" do
      text = thing_text([ rule("length", "body", minimum: 10), rule("length", "title", maximum: 3) ])

      expect(text).to include('let(:valid_attributes) { { body: "MyTextxxxx", title: "MyS" } }')
      expect(thing_text([ rule("length", "title", is: 12) ])).to include('title: "MyStringxxxx"')
    end

    it "includes an attribute a rule names though the controller does not permit it" do
      text = thing_text([ rule("length", "title", maximum: 3) ], permits: %w[body])

      expect(text).to include('let(:thing) { Thing.create!({ body: "MyText", title: "MyS" }) }')
      expect(text).to include('let(:valid_attributes) { { body: "MyText" } }')
    end

    it "is inside a numericality rule's bounds" do
      columns = { "price" => "decimal", "qty" => "integer", "score" => "integer" }
      text = thing_text([ rule("numericality", "price", greater_than: 20), rule("numericality", "qty", only_integer: true, greater_than_or_equal_to: 5),
                          rule("numericality", "score", less_than: 0) ], columns: columns)

      expect(text).to include('price: "21"')
      expect(text).to include("qty: 5")
      expect(text).to include("score: -1")
    end

    it "is accepted for an acceptance rule, a virtual attribute too" do
      text = thing_text([ rule("acceptance", "terms"), rule("acceptance", "agreed") ], columns: { "terms" => "boolean", "title" => "string" }, permits: %w[terms agreed title])

      expect(text).to include('agreed: "1"')
      expect(text).to include("terms: true")
    end

    it "repeats the value in a confirmation rule's field" do
      text = thing_text([ rule("confirmation", "title") ], permits: %w[title title_confirmation])

      expect(text).to include('title: "MyString", title_confirmation: "MyString"')
      expect(text).not_to include("nil")
    end

    it "satisfies a format the gem can read, and leaves out an attribute that may be blank" do
      text = thing_text([ rule("format", "title", with: "URI::MailTo::EMAIL_REGEXP"), rule("format", "body", with: "/\\A\\d+\\z/") ])

      expect(text).to include('body: "1"')
      expect(text).to include('title: "a@example.com"')
      expect(thing_text([ rule("format", "title", with: "/\\A[A-Z]{9}\\z/", allow_blank: true) ], permits: %w[title])).to include("let(:valid_attributes) { {  } }")
    end

    it "satisfies a format written as a %r literal" do
      text = thing_text([ rule("format", "body", with: "%r{\\A\\d+\\z}"), rule("format", "title", with: "%r{\\AABC\\z}i") ])

      expect(text).to include('body: "1"')
      expect(text).to include('title: "abc"')
      expect(text).not_to include("validates format of")
    end

    it "is one of the values an acceptance rule accepts" do
      text = thing_text([ rule("acceptance", "agreed", accept: [ "yes", "ok" ]) ], columns: { "agreed" => "string" })

      expect(text).to include('agreed: "yes"')
    end

    # A numeric string must meet the column's length rule too.
    it "is a numeric string of the right length for a numericality rule on a string column" do
      columns = { "digits" => "string", "code" => "string", "grade" => "string" }
      text = thing_text([ rule("numericality", "digits", only_integer: true), rule("length", "digits", is: 4),
                          rule("numericality", "code", greater_than: 5000), rule("length", "code", is: 4),
                          rule("numericality", "grade", in: "1..5"), rule("length", "grade", minimum: 2) ], columns: columns)

      expect(text).to include('digits: "1000"')
      expect(text).to include('code: "5001"')
      expect(text).to include('grade: "01"')
    end

    it "is inside a length rule given as a range" do
      expect(thing_text([ rule("length", "title", in: "3..5") ])).to include('title: "MyStr"')
    end

    describe "that it cannot satisfy" do
      let(:reasons) do
        { "format" => "Thing validates format of title (/\\A[A-Z]{9}\\z/); supply a value it accepts",
          "custom" => "Thing runs the custom validation title_is_real; supply a record that passes it",
          "attachment" => "Thing validates presence of file, which is not a column; supply it (an attachment, for one)",
          "kind" => "Thing validates comparison of title, which the gem cannot evaluate; supply a record that passes it" }
      end

      def stuck_text(validations, framework, **options)
        thing_text(validations, framework: framework, **options)
      end

      it "skips every example that needs the record or its params, in both frameworks, saying why" do
        %w[rspec minitest].each do |framework|
          text = stuck_text([ rule("format", "title", with: "/\\A[A-Z]{9}\\z/") ], framework)

          expect(text).to include("skip #{"TODO: #{reasons["format"]}".inspect}")
          expect(text).not_to include("create!")
          expect(text).not_to include("adjust these attributes")
          expect(text.scan("skip #{"TODO: #{reasons["format"]}".inspect}").size).to eq(4)
        end
      end

      it "skips for a custom validate method" do
        text = stuck_text([], "rspec", model: { custom_validates: [ "title_is_real" ] })

        expect(text).to include("skip \"TODO: #{reasons["custom"]}\"")
        expect(text).not_to include("create!")
      end

      it "skips for a presence rule on an attribute that is no column, an attachment for one" do
        text = stuck_text([ rule("presence", "file") ], "minitest")

        expect(text).to include("skip \"TODO: #{reasons["attachment"]}\"")
      end

      it "skips for a rule it cannot evaluate" do
        text = stuck_text([ rule("comparison", "title", greater_than: "other") ], "rspec")

        expect(text).to include("skip \"TODO: #{reasons["kind"]}\"")
      end

      # The made-up record fails closed: a rule it does not read completely makes the examples that need the record skip.
      it "skips for validates_with, a validator class, validates_each and any kind it does not know" do
        with = { kind: "validates_with", attributes: [], validator: "MemberValidator", options: {} }
        text = stuck_text([ with ], "rspec")

        expect(text).to include('skip "TODO: Thing runs validates_with MemberValidator; supply a record that passes it"')
        expect(text).not_to include("create!")
        expect(stuck_text([ rule("validates_each", "title") ], "minitest")).to include("Thing validates validates_each of title, which the gem cannot evaluate")
        expect(stuck_text([ rule("email", "title") ], "rspec")).to include("Thing validates email of title, which the gem cannot evaluate")
      end

      it "skips for an option of a known rule it does not honor, naming the option" do
        text = stuck_text([ rule("length", "title", minimum: 3, tokenizer: "words") ], "rspec")

        expect(text).to include('skip "TODO: Thing validates length of title with the option tokenizer, which the gem does not honor; supply a value that passes it"')
      end

      it "skips for a lambda or proc anywhere in the rule" do
        [ [ "presence", { if: "(proc)" } ], [ "presence", { unless: "->(r) { r.x }" } ], [ "uniqueness", { conditions: "-> { where(x: 1) }" } ] ].each do |kind, options|
          text = stuck_text([ rule(kind, "title", options) ], "rspec")

          expect(text).to include("skip \"TODO: Thing validates #{kind} of title with a lambda or proc in the #{options.keys.first} option; supply a record that passes it\"")
        end
      end

      it "reads a method name in if or unless, and a rule that runs only on update, completely" do
        text = stuck_text([ rule("presence", "title", if: :paid?), rule("length", "body", minimum: 3, on: :update, comparison: "x") ], "rspec")

        expect(text).not_to include("skip")
      end

      it "reads a string in an inclusion list as a value, whatever it spells" do
        text = stuck_text([ rule("inclusion", "title", in: %w[proc lambda ->]) ], "rspec")

        expect(text).not_to include("lambda or proc")
        expect(text).not_to include("skip")
      end

      it "keeps the create when the controller permits no attribute the rule needs, as when it sets the value itself" do
        text = stuck_text([ rule("format", "title", with: "/\\A[A-Z]{9}\\z/") ], "rspec", permits: %w[body])

        expect(text).to include("it \"creates a new Thing\" do")
      end
    end

    # The static tier cannot read a computed table name, so its columns are unknown and every attribute would be nil.
    it "skips what needs a record when the model's table is computed and its columns cannot be read" do
      %w[rspec minitest].each do |framework|
        text = thing_text([ rule("presence", "memo") ], framework: framework, table: nil, columns: {}, model: { table_name: nil, table_set_by: "Thing.table_name" }, permits: %w[memo])

        expect(text).to include("skip \"TODO: Thing has a table name the source computes, so its columns are unknown here; supply the attributes it needs\"")
        expect(text).not_to include("nil")
      end
    end
  end

  # An example with an empty body passes and proves nothing.
  describe "a model spec's format, acceptance, confirmation and macro validations" do
    def signup_spec(framework, validations)
      bundling_shoulda
      Dir.mktmpdir do |root|
        allow(described_class).to receive(:rails_app).and_return(double(root: Pathname.new(root)))
        allow(described_class).to receive(:cached_context).and_return({
          tests: { framework: framework, factories: nil, factory_names: nil, fixture_names: {} },
          models: { "Signup" => { table_name: "signups", validations: validations } },
          schema: { tables: { "signups" => { columns: [ { name: "email", type: "string" }, { name: "terms", type: "boolean" } ] } } }
        })
        return described_class.call(model: "Signup").content.first[:text]
      end
    end

    let(:rules) do
      [ { kind: "acceptance", attributes: %w[terms], options: {} }, { kind: "confirmation", attributes: %w[email], options: {} },
        { kind: "format", attributes: %w[email], options: { with: "/@/" } }, { kind: "validates_with", attributes: %w[email], options: {} } ]
    end

    it "is a matcher where shoulda has one, and a skip saying what to supply where it has none" do
      text = signup_spec("rspec", rules)

      expect(text).to include("it { is_expected.to validate_acceptance_of(:terms) }")
      expect(text).to include("it { is_expected.to validate_confirmation_of(:email) }")
      expect(text).to include('skip "TODO: set email to a value the format rejects and one it accepts"')
      expect(text).to include('skip "TODO: assert that a record breaking validates_with on email is invalid and one meeting it is valid"')
      expect(text).not_to match(/do\n\s+# TODO: implement/)
    end

    it "is a skip too where the app does not bundle shoulda-matchers" do
      allow(RailsAiContext::GemLock).to receive(:for).and_return(RailsAiContext::GemLock::Spec.new({}))
      text = signup_spec("rspec", [ { kind: "validates_with", attributes: %w[email], options: {} } ])

      expect(text).to include('skip "TODO: assert that a record breaking validates_with on email is invalid and one meeting it is valid"')
    end
  end

  # `resource :profile` has no :id, so nothing in the request names the record the action reads.
  describe "a singular resource" do
    def profile_text(framework, fixtures: {})
      Dir.mktmpdir do |root|
        allow(described_class).to receive(:rails_app).and_return(double(root: Pathname.new(root)))
        allow(described_class).to receive(:cached_context).and_return({
          tests: { framework: framework, factories: nil, factory_names: nil, fixture_names: fixtures, test_helper_setup: [] },
          models: { "Profile" => { table_name: "profiles" } },
          schema: { tables: { "profiles" => { columns: [ { name: "bio", type: "string" } ] } } },
          controllers: { controllers: { "ProfilesController" => { actions: %w[show update destroy],
                                                                 strong_params: [ { name: "profile_params", requires: "profile", permits: %w[bio] } ] } } },
          routes: { by_controller: { "profiles" => [
            { verb: "GET", path: "/profile", action: "show", name: "profile" },
            { verb: "PATCH", path: "/profile", action: "update", name: "profile" },
            { verb: "DELETE", path: "/profile", action: "destroy", name: "profile" }
          ] } }
        })
        return described_class.call(controller: "ProfilesController").content.first[:text]
      end
    end

    it "calls the made-up record before it is shown or updated, in a request spec and a minitest" do
      spec = profile_text("rspec")
      expect(spec).to include("      profile\n      get profile_url")
      expect(spec).to include("      profile\n      patch profile_url")

      test = profile_text("minitest")
      expect(test).to include("    profile_record\n    get profile_url")
      expect(test).to include("    profile_record\n    patch profile_url")
    end

    it "calls the record in a system spec's show page too" do
      Dir.mktmpdir do |root|
        allow(described_class).to receive(:rails_app).and_return(double(root: Pathname.new(root)))
        allow(described_class).to receive(:cached_context).and_return({
          tests: { framework: "rspec", factories: nil, factory_names: nil, fixture_names: {}, test_helper_setup: [] },
          models: { "Profile" => { table_name: "profiles" } },
          schema: { tables: { "profiles" => { columns: [ { name: "bio", type: "string" } ] } } },
          controllers: { controllers: { "ProfilesController" => { actions: %w[show] } } },
          routes: { by_controller: { "profiles" => [ { verb: "GET", path: "/profile", action: "show", name: "profile" } ] } }
        })

        expect(described_class.call(model: "Profile", type: "system").content.first[:text]).to include("    profile\n    visit profile_path")
      end
    end

    it "leaves a fixture's ivar alone, which setup already set" do
      expect(profile_text("minitest", fixtures: { "profiles" => %w[one] })).not_to match(/^\s+@profile\n/)
    end
  end

  # The Dashboard controller has no model: its show needs no record.
  describe "a singular resource with no model" do
    def dashboard_text(framework)
      Dir.mktmpdir do |root|
        allow(described_class).to receive(:rails_app).and_return(double(root: Pathname.new(root)))
        allow(described_class).to receive(:cached_context).and_return({
          tests: { framework: framework, factories: nil, factory_names: nil, fixture_names: {}, test_helper_setup: [] },
          models: {}, controllers: { controllers: { "DashboardsController" => { actions: %w[show] } } },
          routes: { by_controller: { "dashboards" => [ { verb: "GET", path: "/dashboard", action: "show", name: "dashboard" } ] } }
        })
        return described_class.call(controller: "DashboardsController").content.first[:text]
      end
    end

    it "requests the page without a record, in both frameworks" do
      expect(dashboard_text("rspec")).to include("get dashboard_url")
      expect(dashboard_text("rspec")).not_to include("skip")
      expect(dashboard_text("minitest")).to include("get dashboard_url")
      expect(dashboard_text("minitest")).not_to include("skip")
    end
  end

  describe "a model spec's validation without a matcher" do
    def absence_text(framework, rules)
      bundling_shoulda
      Dir.mktmpdir do |root|
        allow(described_class).to receive(:rails_app).and_return(double(root: Pathname.new(root)))
        allow(described_class).to receive(:cached_context).and_return({
          tests: { framework: framework, factories: nil, factory_names: nil, fixture_names: {} },
          models: { "Trace" => { table_name: "traces", validations: rules } },
          schema: { tables: { "traces" => { columns: [ { name: "legacy", type: "string" } ] } } }
        })
        return described_class.call(model: "Trace").content.first[:text]
      end
    end

    it "is a matcher for absence where shoulda has one" do
      expect(absence_text("rspec", [ { kind: "absence", attributes: %w[legacy], options: {} } ])).to include("it { is_expected.to validate_absence_of(:legacy) }")
    end

    it "is a skip that names the rule and what to assert where there is no matcher" do
      text = absence_text("rspec", [ { kind: "comparison", attributes: %w[legacy], options: { less_than: :other } } ])

      expect(text).to include('skip "TODO: assert that a record breaking comparison on legacy (less_than: other) is invalid and one meeting it is valid"')
      expect(text).not_to include("implement comparison validation test")
    end
  end

  describe "a model spec's uniqueness matcher" do
    # The matcher saves a record built from its subject, and described_class.new leaves every attribute nil.
    def users_spec(factory_names: nil, user: {}, framework: "rspec", fixture_names: {})
      bundling_shoulda
      Dir.mktmpdir do |root|
        allow(described_class).to receive(:rails_app).and_return(double(root: Pathname.new(root)))
        allow(described_class).to receive(:cached_context).and_return({
          tests: { framework: framework, factories: factory_names && { count: 1 }, factory_names: factory_names, fixture_names: fixture_names },
          models: { "User" => { table_name: "users", validations: [ { kind: "uniqueness", attributes: %w[email] } ] }.merge(user) },
          schema: { tables: { "users" => { columns: [ { name: "id", type: "integer" }, { name: "name", type: "string" }, { name: "email", type: "string" } ] } } }
        })
        return described_class.call(model: "User").content.first[:text]
      end
    end

    it "says which enum its subject leaves out" do
      text = users_spec(user: { enums: { "name" => "NAMES" } })

      expect(text).to include('subject { described_class.new({ email: "email-#{SecureRandom.hex(4)}@example.com" }) }')
      expect(text).to include("    # TODO: name is an enum whose values the source computes; set one it maps")
    end

    # A saved copy of an unsaved record with every attribute nil is what the matcher compares against.
    it "gets the factory's record as its subject, ahead of it" do
      text = users_spec(factory_names: { "users.rb" => %w[user] })

      expect(text).to include("subject { FactoryBot.build(:user) }")
      expect(text.index("subject { FactoryBot.build(:user) }")).to be < text.index("validate_uniqueness_of(:email)")
    end

    it "is a minitest's duplicate of a saved record made up from placeholders, and says so when none can be" do
      text = users_spec(framework: "minitest")

      expect(text).to include('duplicate = User.create!({ email: "email-#{SecureRandom.hex(4)}@example.com", name: "MyString" }).dup')
      expect(text).to include("# TODO: adjust these attributes if validations reject the placeholder values")
      expect(users_spec(framework: "minitest", fixture_names: { "users" => %w[one] })).to include("duplicate = @user.dup")

      stuck = users_spec(framework: "minitest", user: { associations: [ { type: "belongs_to", name: "owner", polymorphic: true, foreign_key: "owner_id" } ],
                                                        validations: [ { kind: "uniqueness", attributes: %w[email] }, { kind: "presence", attributes: %w[owner], implicit: true } ] })
      expect(stuck).to include("skip \"TODO: User belongs_to :owner, polymorphic: true")
      expect(stuck).not_to include("User.create!")
    end

    it "gets a subject built from placeholders, ahead of it" do
      text = users_spec
      subject = 'subject { described_class.new({ email: "email-#{SecureRandom.hex(4)}@example.com", name: "MyString" }) }'

      expect(text).to include(subject)
      expect(text.index(subject)).to be < text.index("validate_uniqueness_of(:email)")
    end
  end

  describe "the value made up for a unique column" do
    # A fresh prefix keeps the copied value apart from every row and keeps
    # it valid: "email-1a2b" fails an email format, "1a2bone@example.com" does not.
    def users_test(framework)
      Dir.mktmpdir do |root|
        allow(described_class).to receive(:rails_app).and_return(double(root: Pathname.new(root)))
        allow(described_class).to receive(:cached_context).and_return({
          tests: { framework: framework, fixture_names: { "users" => [ "one" ] }, factories: { count: framework == "rspec" ? 1 : 0 },
                   factory_names: framework == "rspec" ? { "spec/factories/users.rb" => %w[user] } : {} },
          models: { "User" => { table_name: "users", validations: [ { kind: "uniqueness", attributes: %w[email] } ] } },
          schema: { tables: { "users" => { columns: [ { name: "email", type: "string" } ] } } },
          controllers: { controllers: { "UsersController" => { actions: %w[create update destroy],
                                                              strong_params: [ { name: "user_params", requires: "user", permits: %w[email] } ] } } },
          routes: { by_controller: { "users" => [
            { verb: "POST", path: "/users", action: "create", name: "users" },
            { verb: "PATCH", path: "/users/:id", action: "update", name: "user" },
            { verb: "DELETE", path: "/users/:id", action: "destroy", name: "user" }
          ] } }
        })
        return described_class.call(controller: "UsersController").content.first[:text]
      end
    end

    it "prefixes the fixture's own value in a minitest" do
      text = users_test("minitest")

      expect(text).to include('email: "#{SecureRandom.hex(4)}#{@user.email}"')
      expect(text).to include('.merge("email" => "#{SecureRandom.hex(4)}#{@user.email}")')
      expect(text).not_to include("email-")
    end

    it "prefixes the subject's own value in a request spec" do
      text = users_test("rspec")

      expect(text).to include('.merge("email" => "#{SecureRandom.hex(4)}#{user.email}")')
      expect(text).not_to include("email-")
    end
  end

  # A copy of the record's own number, date or time is a duplicate; one more than it is not.
  describe "the value made up for a unique column that is not a string" do
    def tickets_test(framework, fixture: true, unique: %w[number code], permits: %w[code number title], types: {})
      Dir.mktmpdir do |root|
        allow(described_class).to receive(:rails_app).and_return(double(root: Pathname.new(root)))
        columns = { "number" => "integer", "code" => "string", "title" => "string" }.merge(types)
        allow(described_class).to receive(:cached_context).and_return({
          tests: { framework: framework, fixture_names: fixture ? { "tickets" => [ "one" ] } : {}, factories: nil, factory_names: nil },
          models: { "Ticket" => { table_name: "tickets", validations: unique.map { |attr| { kind: "uniqueness", attributes: [ attr ] } } } },
          schema: { tables: { "tickets" => { columns: columns.map { |name, type| { name: name, type: type } } } } },
          controllers: { controllers: { "TicketsController" => { actions: %w[create update destroy],
                                                                strong_params: [ { name: "ticket_params", requires: "ticket", permits: permits } ] } } },
          routes: { by_controller: { "tickets" => [
            { verb: "POST", path: "/tickets", action: "create", name: "tickets" },
            { verb: "PATCH", path: "/tickets/:id", action: "update", name: "ticket" },
            { verb: "DELETE", path: "/tickets/:id", action: "destroy", name: "ticket" }
          ] } }
        })
        return described_class.call(controller: "TicketsController").content.first[:text]
      end
    end

    it "is one more than the fixture's value, in the create and the fresh record a destroy deletes" do
      text = tickets_test("minitest")

      expect(text).to include('params: { ticket: { code: "#{SecureRandom.hex(4)}#{@ticket.code}", number: @ticket.number + 1, title: @ticket.title } }')
      expect(text).to include('.merge("number" => @ticket.number + 1, "code" => "#{SecureRandom.hex(4)}#{@ticket.code}")')
      expect(text).not_to include("differ from existing")
      expect(text).not_to include("confirm the fresh record")
    end

    it "does not touch the value of an update, which the record already holds alone" do
      expect(tickets_test("minitest")).to include("patch ticket_url(@ticket), params: { ticket: { code: ")
      expect(tickets_test("minitest")).not_to match(/TODO: ensure/)
    end

    it "is one more than the subject's value in a request spec's destroy, a column the controller does not permit too" do
      text = tickets_test("rspec", permits: %w[title])

      expect(text).to include('.merge("number" => ticket.number + 1, "code" => "#{SecureRandom.hex(4)}#{ticket.code}")')
    end

    it "is the placeholder of a record made up from placeholders, which the create finds no other row beside" do
      text = tickets_test("minitest", fixture: false)

      expect(text).to include("params: { ticket: { code: \"code-\#{SecureRandom.hex(4)}\", number: 1, title: \"MyString\" } }")
      expect(text).to include('.merge("number" => ticket_record.number + 1, "code" => "#{SecureRandom.hex(4)}#{ticket_record.code}")')
    end

    it "skips what needs a fresh value for a type that has none, saying why" do
      text = tickets_test("minitest", unique: %w[active], permits: %w[active title], types: { "active" => "boolean" })

      expect(text).to include("skip \"TODO: active is a unique boolean column; no fresh value can be made up for it")
      expect(text.scan("no fresh value can be made up").size).to eq(2)
    end
  end

  describe "the value a minitest validation test breaks the rule with" do
    def user_test(validations)
      allow(described_class).to receive(:cached_context).and_return({
        tests: { framework: "minitest", fixture_names: { "users" => [ "one" ] } },
        models: { "User" => { table_name: "users", validations: validations, enums: { "role" => { "member" => 0, "owner" => 1 } } } },
        schema: { tables: { "users" => { columns: [ { name: "admin", type: "boolean" }, { name: "role", type: "string" },
                                                    { name: "status", type: "string" }, { name: "name", type: "string" } ] } } }
      })
      described_class.call(model: "User").content.first[:text]
    end

    def test_block(text, title)
      text[/  test "#{title}" do\n.*?\n  end/m]
    end

    # "__invalid_value__" casts to true on a boolean column and raises
    # ArgumentError on an enum, so neither test could fail the record.
    it "skips an inclusion on a boolean column or an enum" do
      text = user_test([ { kind: "inclusion", attributes: %w[admin], options: { in: [ true, false ] } },
                         { kind: "inclusion", attributes: %w[role], options: { in: "roles.keys" } } ])

      expect(test_block(text, "validates inclusion of admin")).to include('skip "TODO: set admin to a value outside the inclusion list"')
      expect(test_block(text, "validates inclusion of role")).to include('skip "TODO: set role to a value outside the inclusion list"')
      expect(text).not_to include("__invalid_value__")
    end

    it "keeps the made-up value for a string column" do
      text = user_test([ { kind: "inclusion", attributes: %w[status], options: { in: %w[draft sent] } } ])

      expect(test_block(text, "validates inclusion of status")).to include('@user.status = "__invalid_value__"')
    end

    it "skips a format whose pattern the made-up value matches" do
      text = user_test([ { kind: "format", attributes: %w[name], options: { with: "/\\A[\\w\\s-]+\\z/" } } ])

      expect(test_block(text, "validates format of name")).to include('skip "TODO: set name to a value the format rejects"')
    end

    it "skips a %r format whose pattern the made-up value matches" do
      text = user_test([ { kind: "format", attributes: %w[name], options: { with: "%r{\\A[a-z-]+\\z}" } },
                         { kind: "format", attributes: %w[status], options: { with: "%r{\\A[A-Z-]+\\z}i" } } ])

      expect(test_block(text, "validates format of name")).to include('skip "TODO: set name to a value the format rejects"')
      expect(test_block(text, "validates format of status")).to include('skip "TODO: set status to a value the format rejects"')
      expect(text).not_to include('= "invalid-format"')
    end

    it "keeps the made-up value for a pattern it breaks, or one it cannot read" do
      text = user_test([ { kind: "format", attributes: %w[name], options: { with: "/\\A\\d+\\z/" } },
                         { kind: "format", attributes: %w[status], options: { with: "URI::MailTo::EMAIL_REGEXP" } } ])

      expect(test_block(text, "validates format of name")).to include('@user.name = "invalid-format"')
      expect(test_block(text, "validates format of status")).to include('@user.status = "invalid-format"')
    end
  end

  describe "an inclusion list given as a method call" do
    # validate_inclusion_of needs in_array or in_range, and raises without one.
    it "skips the example, since the matcher cannot take the source text" do
      bundling_shoulda
      allow(described_class).to receive(:cached_context).and_return({
        tests: { framework: "rspec", factory_names: {} },
        models: { "User" => { validations: [ { kind: "inclusion", attributes: %w[role], options: { in: "roles.keys", allow_nil: true } } ] } }
      })

      text = described_class.call(model: "User").content.first[:text]

      expect(text).to include(%(it "validates inclusion of role" do\n      skip "TODO: set role to a value outside the inclusion list"))
      expect(text).not_to include("validate_inclusion_of(")
    end

    it "skips an inclusion on an enum, which raises on a value outside it" do
      bundling_shoulda
      allow(described_class).to receive(:cached_context).and_return({
        tests: { framework: "rspec", factory_names: {} },
        models: { "User" => { validations: [ { kind: "inclusion", attributes: %w[role], options: { in: %w[member owner] } } ],
                              enums: { "role" => { "member" => 0, "owner" => 1 } } } }
      })

      text = described_class.call(model: "User").content.first[:text]

      expect(text).not_to include("validate_inclusion_of(")
    end
  end

  describe "a plain service's entry point" do
    def service_spec(source)
      Dir.mktmpdir do |dir|
        FileUtils.mkdir_p(File.join(dir, "app", "services"))
        File.write(File.join(dir, "app", "services", "post_publisher.rb"), source)
        allow(described_class).to receive(:rails_app).and_return(RailsAiContext::StaticApp.new(dir))
        allow(described_class).to receive(:cached_context).and_return({ tests: { framework: "rspec" } })
        return described_class.call(file: "app/services/post_publisher.rb").content.first[:text]
      end
    end

    it "calls a class method call on the class" do
      text = service_spec("class PostPublisher\n  def self.call\n    true\n  end\nend\n")

      expect(text).to include("describe \".call\"")
      expect(text).to include("      result = described_class.call\n")
    end

    it "finds a call defined under class << self" do
      text = service_spec("class PostPublisher\n  class << self\n    def call; end\n  end\nend\n")

      expect(text).to include("      result = described_class.call\n")
    end

    # The class has no .call, so described_class.call is a NoMethodError, and
    # nil for the post is a NoMethodError inside it.
    it "skips an instance call whose class takes arguments, naming them" do
      text = service_spec(<<~RUBY)
        class PostPublisher
          def initialize(post, notify: true, by:)
            @post = post
          end

          def call
            @post.update!(status: "published")
          end
        end
      RUBY

      expect(text).to include("describe \"#call\"")
      expect(text).to include('skip "TODO: build what PostPublisher.new takes, then call it"')
      expect(text).to include("# result = described_class.new(post, by: by).call")
      expect(text).not_to include("described_class.call")
    end

    it "skips an instance call that takes arguments" do
      text = service_spec("class PostPublisher\n  def call(post)\n    post.touch\n  end\nend\n")

      expect(text).to include('skip "TODO: build what PostPublisher#call takes, then call it"')
      expect(text).to include("# result = described_class.new.call(post)")
    end

    it "reads the entry point of the service class alone, not a class it nests or one beside it" do
      text = service_spec(<<~RUBY)
        class PostPublisher
          class Step
            def self.call(step); end

            def initialize(post); end
          end

          def call; end
        end

        class PostPublisherError
          def initialize(message); end
        end
      RUBY

      expect(text).to include("describe \"#call\"")
      expect(text).to include("      result = described_class.new.call\n")
    end

    it "skips a service with no call" do
      text = service_spec("class PostPublisher\n  def publish; end\nend\n")

      expect(text).to include('skip "TODO: PostPublisher defines no call; test the method it exposes"')
      expect(text).not_to include("described_class.call")
    end
  end
end
