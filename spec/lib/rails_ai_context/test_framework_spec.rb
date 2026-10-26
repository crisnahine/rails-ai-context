# frozen_string_literal: true

require "spec_helper"
require "tmpdir"

RSpec.describe RailsAiContext::TestFramework do
  around { |example| Dir.mktmpdir { |dir| @root = dir; example.run } }

  def write(rel, body = "")
    path = File.join(@root, rel)
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, body)
  end

  def lockfile(deps: [], specs: [])
    write("Gemfile.lock", <<~LOCK)
      GEM
        remote: https://rubygems.org/
        specs:
      #{specs.map { |s| "    #{s}" }.join("\n")}

      DEPENDENCIES
      #{deps.map { |d| "  #{d}" }.join("\n")}
    LOCK
  end

  it "reads a spec directory of Jasmine JavaScript as minitest when test/ holds the suite" do
    write("spec/javascripts/admin_spec.js")
    write("spec/support/jasmine-browser.json", "{}")
    write("test/unit/user_test.rb")
    lockfile(deps: %w[minitest rubocop-rspec], specs: [ "rspec-core (3.13.6)", "minitest (5.25.4)" ])

    expect(described_class.for(@root)).to eq("minitest")
  end

  # A Gemfile can carry `gem "minitest"` with no test/ directory at all.
  # A gem in the bundle is not a suite.
  it "does not read a bundled minitest with no test tree as a suite" do
    write("spec/models/user_spec.rb")
    lockfile(deps: %w[rspec-rails minitest], specs: [ "rspec-rails (7.1.0)", "minitest (5.25.4)" ])

    expect(described_class.for(@root)).to eq("rspec")
  end

  it "does not read a bundled rspec with no spec tree as a suite" do
    write("test/unit/user_test.rb")
    lockfile(deps: %w[rspec rubocop-rspec], specs: [ "rspec (3.13.2)", "rspec-core (3.13.6)" ])

    expect(described_class.for(@root)).to eq("minitest")
  end

  it "names both when each framework has its own suite" do
    write("spec/models/user_spec.rb")
    write("test/unit/user_test.rb")
    lockfile

    expect(described_class.for(@root)).to eq("rspec, minitest")
  end

  it "reads an app with only spec files as rspec" do
    write("spec/models/user_spec.rb")
    lockfile

    expect(described_class.for(@root)).to eq("rspec")
  end

  it "reads spec/factories without spec files as rspec" do
    write("spec/factories/users.rb")
    lockfile

    expect(described_class.for(@root)).to eq("rspec")
  end

  # Every Rails app bundles minitest through activesupport, so a bundle with
  # it in says nothing about a suite; with no test anywhere the app runs none.
  it "says there are no tests, and which framework the bundle holds, when the app has none" do
    lockfile(specs: [ "minitest (5.25.4)" ])

    expect(described_class.for(@root)).to eq("no tests yet (minitest in the bundle)")
  end

  it "falls back to the lockfile with no test directory at all, GIT section included" do
    write("Gemfile.lock", <<~LOCK)
      GIT
        remote: https://github.com/rspec/rspec-rails.git
        revision: 0123456789abcdef0123456789abcdef01234567
        specs:
          rspec-rails (7.1.0)
    LOCK

    expect(described_class.for(@root)).to eq("no tests yet (rspec-rails in the bundle)")
  end

  it "says the suite is not read for a dummy whose bundle is outside the repository" do
    FileUtils.mkdir_p(File.join(@root, "config"))
    File.write(File.join(@root, "config", "boot.rb"), %(ENV["BUNDLE_GEMFILE"] ||= File.expand_path("../../../Gemfile", __dir__)\n))

    expect(described_class.for(@root)).to eq("not read")
  end

  it "says there are no tests with nothing to read" do
    expect(described_class.for(@root)).to eq("no tests yet")
  end

  it "still scaffolds and runs the framework the bundle holds" do
    expect(described_class.command("no tests yet (rspec-rails in the bundle)")).to eq("bundle exec rspec")
    expect(described_class.command("no tests yet (minitest in the bundle)")).to eq("rails test")
  end
  describe ".candidates" do
    # An app can keep spec/requests/payments_controller_spec.rb.
    it "tries every controller suffix in both controller spec directories" do
      list = described_class.candidates("/nonexistent", :controller, "payments", {})

      expect(list).to include("spec/requests/payments_controller_spec.rb", "spec/controllers/payments_spec.rb")
    end

    # UserController owns spec/requests/user_spec.rb; UsersController has no test yet.
    it "keeps a controller's plural name in the app's learned layout" do
      write("spec/requests/user_spec.rb", "RSpec.describe \"User\", type: :request do\nend\n")
      context = { controllers: { controllers: { "UsersController" => {}, "UserController" => {} } } }

      list = described_class.candidates(@root, :controller, "users", context)

      expect(list).to include("spec/requests/users_spec.rb")
      expect(list).not_to include("spec/requests/user_spec.rb")
    end
  end

  describe ".controller_test?" do
    # The paths rspec-rails 8 and Rails 8 generators write for a controller (rspec-rails 4 wrote
    # posts_request_spec), and the near names that belong to another subject.
    {
      [ "spec/controllers/posts_controller_spec.rb", "posts" ] => true,
      [ "spec/requests/posts_spec.rb", "posts" ] => true,
      [ "spec/requests/posts_request_spec.rb", "posts" ] => true,
      [ "spec/routing/posts_routing_spec.rb", "posts" ] => true,
      [ "spec/system/posts_spec.rb", "posts" ] => true,
      [ "spec/requests/posts_controller_spec.rb", "posts" ] => true,
      [ "test/controllers/posts_controller_test.rb", "posts" ] => true,
      [ "test/system/posts_test.rb", "posts" ] => true,
      [ "test/integration/posts_test.rb", "posts" ] => true,
      [ "test/functional/posts_controller_test.rb", "posts" ] => true,
      [ "spec/controllers/admin/posts_controller_spec.rb", "admin/posts" ] => true,
      [ "spec/requests/admin/badges_controller_spec.rb", "admin/badges" ] => true,
      [ "engines/billing/spec/controllers/invoices_controller_spec.rb", "invoices" ] => true,
      [ "engines/billing/spec/requests/invoices_spec.rb", "invoices" ] => true,
      [ "engines/billing/spec/models/invoice_spec.rb", "invoices" ] => false,
      [ "spec/models/post_spec.rb", "posts" ] => false,
      [ "spec/models/posts_spec.rb", "posts" ] => false,
      [ "test/models/post_test.rb", "posts" ] => false,
      [ "spec/post_spec.rb", "posts" ] => false,
      [ "spec/requests/reposts_spec.rb", "posts" ] => false,
      [ "spec/requests/user_spec.rb", "users" ] => false,
      [ "spec/controllers/user_controller_spec.rb", "users" ] => false,
      [ "spec/requests/tags_spec.rb", "admin/tags" ] => false,
      [ "spec/controllers/admin/posts_controller_spec.rb", "posts" ] => false,
      [ "spec/requests/api/v1/posts_spec.rb", "posts" ] => false
    }.each do |(path, key), owned|
      it "#{owned ? "counts" : "does not count"} #{path} as the #{key} controller's test" do
        expect(described_class.controller_test?(path, key)).to be(owned)
      end
    end
  end

  describe ".suite_folders" do
    {
      "spec/models/widget_spec.rb" => [ "", "models" ],
      "engines/billing/test/controllers/admin/invoices_controller_test.rb" => [ "engines/billing/", "controllers" ],
      "spec/widget_spec.rb" => [ "", nil ],
      "app/models/widget.rb" => [ "", nil ],
      nil => [ "", nil ]
    }.each do |path, folders|
      it "reads #{folders.inspect} from #{path.inspect}" do
        expect(described_class.suite_folders(path)).to eq(folders)
      end
    end
  end

  describe ".named_test?" do
    {
      [ "spec/models/widget_spec.rb", :model, "widget" ] => true,
      [ "spec/models/widget_model_spec.rb", :model, "widget" ] => true,
      [ "test/models/widget_model_test.rb", :model, "widget" ] => true,
      [ "packs/shop/spec/models/widget_spec.rb", :model, "widget" ] => true,
      [ "spec/models/widget_model_spec.rb", :service, "widget" ] => false,
      [ "spec/models/user_mailer_spec.rb", :model, "user" ] => false,
      [ "spec/models/postmark_event_spec.rb", :model, "post" ] => false,
      [ "spec/jobs/admin/badge_job_spec.rb", :job, "badge_job" ] => false,
      [ "spec/jobs/admin/badge_job_spec.rb", :job, "admin/badge_job" ] => true
    }.each do |(path, kind, key), owned|
      it "#{owned ? "counts" : "does not count"} #{path} as the #{kind} #{key}'s test" do
        expect(described_class.named_test?(path, kind, key)).to be(owned)
      end
    end
  end

  describe ".test_subjects" do
    {
      "require \"rails_helper\"\n\nRSpec.describe Shop::Order, type: :model do\nend\n" => [ [ "Shop::Order", [] ] ],
      "describe ::Widget do\nend\n" => [ [ "::Widget", [] ] ],
      "RSpec.describe \"Widgets\", type: :request do\nend\n" => [],
      "module Shop\n  class OrderTest < ActiveSupport::TestCase\n  end\nend\n" => [ [ "::Shop::Order", [] ] ],
      "RSpec.describe Widget do\n  context Gadget do\n  end\nend\n" => [ [ "Widget", [] ], [ "Gadget", [] ] ],
      "RSpec.describe \"flows\" do\n  fdescribe Shop::Order do\n    xfeature Shop::Cart do\n    end\n  end\nend\n" => [ [ "Shop::Order", [] ], [ "Shop::Cart", [] ] ],
      "module Shop\n  module Admin\n    RSpec.describe OrdersController do\n    end\n  end\nend\n" =>
        [ [ "OrdersController", %w[Shop::Admin Shop] ] ],
      "module Shop\n  describe ::OrdersController do\n  end\nend\n" => [ [ "::OrdersController", %w[Shop] ] ],
      "module Jobs::Inner\n  RSpec.describe Sweep do\n  end\nend\n" => [ [ "Sweep", %w[Jobs::Inner] ] ],
      "module Shop\n  module Admin::Tools\n    describe Export do\n    end\n  end\nend\n" =>
        [ [ "Export", %w[Shop::Admin::Tools Shop] ] ],
      "RSpec.shared_examples Widget do\nend\n" => [],
      "module Shop\n  class Admin::Test < ActiveSupport::TestCase\n  end\nend\n" => [],
      "module Shop\n  class Shop::DraftTest < ActiveSupport::TestCase\n  end\nend\n" => [ [ "::Shop::Draft", [] ] ],
      "module Shop\n  module Shop; end\n  class Shop::DraftTest < ActiveSupport::TestCase\n  end\nend\n" => [ [ "::Shop::Shop::Draft", [] ] ],
      "module A\n  Shop = Module.new\n  module B\n    class Shop::DraftTest < ActiveSupport::TestCase\n    end\n  end\nend\n" => [ [ "::A::Shop::Draft", [] ] ],
      "module A\n  Shop ||= Module.new\n  module B\n    class Shop::DraftTest < ActiveSupport::TestCase\n    end\n  end\nend\n" => [ [ "::A::Shop::Draft", [] ] ],
      "module A\n  Shop, Mall = Module.new, Module.new\n  module B\n    class Shop::DraftTest < ActiveSupport::TestCase\n    end\n  end\nend\n" => [ [ "::A::Shop::Draft", [] ] ],
      "module Shop\n  Shop ||= Module.new\n  class Shop::DraftTest < ActiveSupport::TestCase\n  end\nend\n" => [ [ "::Shop::Draft", [] ] ],
      "class Bar\n  M = Module.new\nend\nclass Foo < Bar\n  M ||= Module.new\n  class M::DraftTest < ActiveSupport::TestCase\n  end\nend\n" => [ [ "::Bar::M::Draft", [] ] ],
      "module Shop\n  class Shop::Draft\n    RSpec.describe Item do\n    end\n  end\nend\n" => [ [ "Item", %w[Shop::Draft Shop] ] ]
    }.each do |source, constants|
      it "reads #{constants.inspect} from #{source.lines.grep(/describe|class|shared/).first.strip}" do
        expect(described_class.test_subjects(source).described).to match_array(constants)
      end
    end

    it "reads only the groups and test classes no other one holds, when asked for the top level" do
      source = "module Shop\n  RSpec.describe \"Order\" do\n    describe Presenter do\n    end\n  end\n  " \
               "RSpec.describe Cart do\n    context Item do\n    end\n  end\n  class CartTest < ActiveSupport::TestCase\n    describe Item do\n    end\n  end\nend\n"

      expect(described_class.test_subjects(source).top_level).to contain_exactly([ "Cart", %w[Shop] ], [ "::Shop::Cart", [] ])
    end

    it "reads a top-level group inside a block or a condition whatever comes before or after it" do
      wrapped = "[1].each do\n  RSpec.describe OrderPresenter do\n  end\nend\n"
      conditional = "if true\n  RSpec.describe OrderPresenter do\n  end\nend\n"

      expect(described_class.test_subjects("#{wrapped}RSpec.describe Order do\nend\n").top_level).to contain_exactly([ "OrderPresenter", [] ], [ "Order", [] ])
      expect(described_class.test_subjects("RSpec.describe Order do\nend\n#{wrapped}").top_level).to contain_exactly([ "OrderPresenter", [] ], [ "Order", [] ])
      expect(described_class.test_subjects("#{conditional}RSpec.describe \"x\" do\nend\n").top_level).to contain_exactly([ "OrderPresenter", [] ])
    end

    it "leaves the shared parse cache as it found it" do
      source = "module Shop\n  class OrderTest < ActiveSupport::TestCase\n  end\nend\n# #{SecureRandom.hex}\n"

      expect { described_class.test_subjects(source).described }.not_to change(RailsAiContext::AstCache, :size)
    end

    it "reads each class as ClassDefinitionListener does" do
      source = "module Admin\n  class OrdersControllerTest < BaseTest\n    class Helper < ::Struct\n    end\n  end\n  class Shop::CartTest < Struct.new(:a)\n  end\nend\n" \
               "class TopTest < ActionDispatch::IntegrationTest\nend\n"
      listener = RailsAiContext::Introspectors::SourceIntrospector.walk_source(
        source, { classes: -> { RailsAiContext::Introspectors::Listeners::ClassDefinitionListener.new } }
      )[:classes]

      expect(described_class.test_subjects(source).classes).to eq(listener)
    end

    it "parses the file once for its groups and its classes" do
      source = "module Admin\n  class OrdersControllerTest < BaseTest\n  end\nend\nRSpec.describe Order do\nend\n"
      allow(Prism).to receive(:parse).and_call_original

      found = described_class.test_subjects(source)

      expect(found.classes.map { |klass| klass.values_at(:name, :superclass, :nesting) }).to eq([ [ "OrdersControllerTest", "BaseTest", [ "Admin" ] ] ])
      expect(found.top_level).to contain_exactly([ "::Admin::OrdersController", [] ], [ "Order", [] ])
      expect(Prism).to have_received(:parse).once
    end
  end

  describe "Suite#tested?" do
    it "reads an integration test filed under test/controllers without touching the shared parse cache" do
      Dir.mktmpdir do |root|
        test = "test/controllers/admin/orders_controller_test.rb"
        FileUtils.mkdir_p(File.join(root, "test/controllers/admin"))
        File.write(File.join(root, test), "class OrdersControllerTest < ActionDispatch::IntegrationTest\nend\n# #{SecureRandom.hex}\n")
        suite = described_class::Suite.new(root, [ test ])

        expect { expect(suite.tested?(:controller, "admin/orders", "Admin::OrdersController")).to be(true) }
          .not_to change(RailsAiContext::AstCache, :size)
      end
    end

    # Inside `module Shop`, `describe Order` is Shop::Order, which the app files, so it tests no top-level Order.
    it "reads a group's subject from the module it is written in" do
      Dir.mktmpdir do |root|
        test = "spec/models/order_spec.rb"
        { test => "module Shop\n  RSpec.describe Order do\n  end\nend\n",
          "app/models/shop/order.rb" => "module Shop\n  class Order < ApplicationRecord\n  end\nend\n",
          "app/models/legacy/order_record.rb" => "class Order < ApplicationRecord\nend\n" }.each do |relative, body|
          FileUtils.mkdir_p(File.dirname(File.join(root, relative)))
          File.write(File.join(root, relative), body)
        end
        RailsAiContext::PathResolver.clear_code_roots
        suite = described_class::Suite.new(root, [ test ])

        expect(suite.tested?(:model, "order", "Order")).to be(false)
        expect(suite.tested?(:model, "shop/order", "Shop::Order")).to be(true)
      end
    end
  end

  describe ".test_style" do
    def tests(files)
      files.each { |rel, body| write(rel, body) }
      described_class.test_style(@root, "test/controllers")
    end

    it "reads a superclass written from the root scope" do
      style = tests(
        "test/controllers/users_controller_test.rb" => "class UsersControllerTest < ::ActionController::TestCase\nend\n",
        "test/controllers/posts_controller_test.rb" => "class PostsControllerTest < ::ActionController::TestCase\nend\n"
      )

      expect(style[:test_case]).to be(true)
    end

    it "follows an app base class to the framework class it inherits" do
      style = tests(
        "test/application_controller_test_case.rb" =>
          "class ApplicationControllerTestCase < ActionController::TestCase\nend\n",
        "test/controllers/admin/users_controller_test.rb" =>
          "class Admin::UsersControllerTest < ApplicationControllerTestCase\nend\n",
        "test/controllers/admin/posts_controller_test.rb" =>
          "class Admin::PostsControllerTest < ApplicationControllerTestCase\nend\n",
        "test/controllers/home_controller_test.rb" => "class HomeControllerTest < ActionDispatch::IntegrationTest\nend\n"
      )

      expect(style[:test_case]).to be(true)
    end

    it "reads a compact test class's bare superclass from the top level, and a nested one's from its module" do
      bases = {
        "test/base_test_case.rb" => "class BaseTestCase < ActionController::TestCase\nend\n",
        "test/admin/base_test_case.rb" => "module Admin\n  class BaseTestCase < ActionDispatch::IntegrationTest\n  end\nend\n"
      }
      compact = tests(bases.merge(
        "test/controllers/admin/users_controller_test.rb" => "class Admin::UsersControllerTest < BaseTestCase\nend\n",
        "test/controllers/admin/posts_controller_test.rb" => "class Admin::PostsControllerTest < BaseTestCase\nend\n"
      ))
      expect(compact[:test_case]).to be(true)

      FileUtils.rm_rf(File.join(@root, "test"))
      nested = tests(bases.merge(
        "test/controllers/admin/users_controller_test.rb" => "module Admin\n  class UsersControllerTest < BaseTestCase\n  end\nend\n",
        "test/controllers/admin/posts_controller_test.rb" => "module Admin\n  class PostsControllerTest < BaseTestCase\n  end\nend\n"
      ))
      expect(nested[:test_case]).to be(false)
    end

    it "counts FactoryBot.create as building with factories" do
      style = tests(
        "test/controllers/users_controller_test.rb" =>
          "class UsersControllerTest < ActionDispatch::IntegrationTest\n  setup { @user = FactoryBot.create(:user) }\nend\n"
      )

      expect(style).to eq(test_case: false, factories: true)
    end

    it "does not take an ActiveRecord create for a factory" do
      style = tests(
        "test/controllers/users_controller_test.rb" =>
          "class UsersControllerTest < ActionDispatch::IntegrationTest\n  setup { @user = User.create(name: \"a\") }\nend\n"
      )

      expect(style[:factories]).to be(false)
    end
  end
end
