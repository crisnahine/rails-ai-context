# frozen_string_literal: true

require "spec_helper"

RSpec.describe RailsAiContext::Tools::GenerateTest do
  # Every `is_expected.to belong_to(...)` line is a shoulda-matchers matcher,
  # so the generator only writes them for an app that bundles it.
  def bundling_shoulda
    allow(RailsAiContext::GemLock).to receive(:for)
      .and_return(RailsAiContext::GemLock::Spec.new({ "shoulda-matchers" => "6.4.0" }))
  end

  before { described_class.reset_cache! }

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

    # Whitehall keeps model tests in test/unit/app/models and controller tests
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

      it "says a model's test already exists rather than writing a second one" do
        Dir.mktmpdir do |root|
          app_with_tests(root, %w[spec/models/invoice_model_spec.rb spec/models/order_model_spec.rb])
          allow(described_class).to receive(:cached_context).and_return({
            tests: { framework: "rspec", factories: { count: 0 }, factory_names: {} },
            models: { "Invoice" => model, "Order" => model }
          })

          text = described_class.call(model: "Invoice").content.first[:text]

          expect(text).to include("spec/models/invoice_model_spec.rb already exists")
          expect(text).not_to include("RSpec.describe")
        end
      end

      # Consul names its system specs after controllers (spec/system/admin/
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

    # Whitehall: 106 of 107 functional tests are ActionController::TestCase
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
          tests: { framework: "minitest", factories: { location: "test/factories", count: 3 },
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

    # Plots2: Node's table is `node`, its fixtures are nodes.yml. Looking the
    # fixture up by table name found none and wrote a TODO and Node.new.
    describe "a fixture set not named after the table" do
      def plots2_shaped(root, helper: nil)
        FileUtils.mkdir_p(File.join(root, "test", "fixtures"))
        File.write(File.join(root, "test", "test_helper.rb"), helper.to_s)
        allow(described_class).to receive(:rails_app).and_return(double(root: Pathname.new(root)))
      end

      it "finds the fixtures under the pluralized class name" do
        Dir.mktmpdir do |root|
          plots2_shaped(root)
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
          plots2_shaped(root, helper: "class ActiveSupport::TestCase\n  set_fixture_class drupal_users: User\nend\n")
          File.write(File.join(root, "test", "fixtures", "drupal_users.yml"), "bob:\n  name: Bob\n")
          allow(described_class).to receive(:cached_context).and_return({
            tests: { framework: "minitest", fixture_names: { "drupal_users" => [ "bob" ] }, factory_names: {} },
            models: { "User" => { table_name: "rusers", associations: [], validations: [], scopes: [], enums: {}, callbacks: {} } }
          })

          text = described_class.call(model: "User").content.first[:text]

          expect(text).to include("@user = drupal_users(:bob)")
        end
      end
    end

    # A TestCase request names the action, so every dynamic path segment is
    # a param: Whitehall's contacts sit under organisations, Plots2 routes
    # `graph/file/:uid/:id`. Passing only :id raises UrlGenerationError.
    describe "a TestCase for a controller with more path segments than :id" do
      def testcase_app(root, routes, fixture_names: {}, factories: true)
        FileUtils.mkdir_p(File.join(root, "test", "functional", "admin"))
        File.write(File.join(root, "test", "functional", "admin", "people_controller_test.rb"),
                   "class Admin::PeopleControllerTest < ActionController::TestCase\n" \
                   "  setup { #{factories ? "@p = create(:person)" : "@p = people(:one)"} }\nend\n")
        allow(described_class).to receive(:rails_app).and_return(double(root: Pathname.new(root)))
        allow(described_class).to receive(:cached_context).and_return({
          tests: { framework: "minitest", factories: { location: "test/factories", count: 3 },
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

      # Whitehall finds the contact through its own contactable, and its
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

      # Plots2 routes `/openid/:username(/:provider)`: :provider is optional,
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
        tests: { framework: "rspec", factories: { count: 2 }, factory_names: { "spec/factories/all.rb" => %w[contact organisation] } },
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
          tests: { framework: "minitest", factories: { location: "test/factories", count: 3 },
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
          tests: { framework: "rspec", factories: { count: 1 }, factory_names: { "spec/factories/admin.rb" => %w[admin_user] } },
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

    # Whitehall routes `resources :contacts`, but ContactsController has no
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

      # Whitehall's ContactsController gets reorder_for_home_page from a class
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

    # Plots2 routes `graph/file/:uid/:id` to csvfiles#delete, and csvfiles has
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
        controllers: { controllers: { "Spree::Admin::OrdersController" => { actions: %w[index] } } },
        routes: { by_controller: {}, engine_routes: [ { engine: "Spree::Core::Engine", mount: "/", routes: [
          { verb: "GET", path: "/admin/orders", controller: "spree/admin/orders", action: "index", name: "spree.admin_orders" }
        ] } ] }
      })

      text = described_class.call(controller: "Spree::Admin::OrdersController").content.first[:text]

      expect(text).to include("get spree.admin_orders_url")
    end

    # Plots2's shortlink redirects when the user exists and raises when not;
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
    # whose own name matches (a line_items route serving Spree::LineItem).
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
        text = generated_for("LineItemsController", "line_items", %w[Spree::LineItem User])

        expect(text).to include("change(Spree::LineItem, :count).by(-1)")
        expect(text).not_to include("requires a persisted")
      end

      it "prefers the model in the controller's own namespace" do
        text = generated_for("Admin::LineItemsController", "admin/line_items", %w[Admin::LineItem Spree::LineItem])

        expect(text).to include("change(Admin::LineItem, :count).by(-1)")
      end

      it "leaves a name two namespaces share unresolved" do
        text = generated_for("LineItemsController", "line_items", %w[Spree::LineItem Shop::LineItem])

        expect(text).to include("requires a persisted")
      end
    end

    # `let(:post)` shadows the `post` a request spec sends, so every example
    # that posts calls the record instead: ArgumentError.
    it "names a record whose name is a request method something else" do
      allow(described_class).to receive(:cached_context).and_return({
        tests: { framework: "rspec", factories: { count: 1 }, factory_names: { "spec/factories/posts.rb" => %w[post] } },
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
      # custom LoginsController for devise_for :spree_user has new_spree_user_session.
      it "reads the mapping from Devise's route names whatever the controller is called" do
        Dir.mktmpdir do |root|
          text = devise_sessions_text(root, "rspec", "spec/controllers/people_controller_spec.rb",
                                      "RSpec.describe PeopleController, type: :controller do\nend\n",
                                      ctrl: "LoginsController", scope: "spree_user")

          expect(text).to include('before { @request.env["devise.mapping"] = Devise.mappings[:spree_user] }')
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
              "around_create" => %w[Mastodon::Snowflake::Callbacks],
              "after_create" => [ "[inline_block]" ],
              "before_save" => %w[normalize]
            }
          }
        }
      })

      text = described_class.call(model: "Status").content.first[:text]

      expect(text).to include(%(it "around_create calls Mastodon::Snowflake::Callbacks" do))
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
        tests: { factories: { location: "spec/factories", count: 1 }, factory_names: { "users.rb" => [ :user ] } }
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
        expect(text).to include("validates absence of followers_url")
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

        expect(text).to include("describe \".call\"")
        expect(text).to include("be_truthy")
        expect(text).not_to include("be_valid")
      end
    end
  end

  # The generated setup line follows the app's own specs: an app that assigns
  # instance variables gets no let, and the factory call follows whichever of
  # create and build its specs reach for more.
  describe "setup style read from the app's own specs" do
    def generated_for(existing_spec)
      Dir.mktmpdir do |dir|
        FileUtils.mkdir_p(File.join(dir, "spec", "models"))
        File.write(File.join(dir, "spec", "models", "comment_spec.rb"), existing_spec)
        allow(described_class).to receive(:rails_app).and_return(double(root: Pathname.new(dir)))
        allow(described_class).to receive(:cached_context).and_return({
          tests: { framework: "rspec", factory_names: { "spec/factories/posts.rb" => [ :post ] } },
          models: { "Post" => { associations: [], validations: [], scopes: [], enums: {}, callbacks: {} } }
        })

        described_class.call(model: "Post").content.first[:text]
      end
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
end
