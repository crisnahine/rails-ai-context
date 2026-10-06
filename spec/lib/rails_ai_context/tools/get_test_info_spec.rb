# frozen_string_literal: true

require "spec_helper"
require "timeout"

RSpec.describe RailsAiContext::Tools::GetTestInfo do
  before { described_class.reset_cache! }

  let(:test_data) do
    {
      framework: "RSpec",
      factories: { location: "spec/factories", count: 5 },
      factory_names: { "users.rb" => %w[user admin_user], "posts.rb" => %w[post published_post] },
      factory_traits: { "users.rb" => %w[admin with_posts], "posts.rb" => %w[published] },
      fixtures: nil,
      fixture_names: nil,
      system_tests: { location: "spec/system" },
      test_helpers: %w[spec/support/auth_helpers.rb spec/support/api_helpers.rb],
      test_helper_setup: %w[FactoryBot::Syntax::Methods],
      test_files: {
        "models" => { location: "spec/models", count: 8 },
        "controllers" => { location: "spec/controllers", count: 4 },
        "requests" => { location: "spec/requests", count: 6 }
      },
      test_count_by_category: { "models" => 8, "requests" => 6, "controllers" => 4 },
      ci_config: %w[github_actions],
      coverage: "simplecov"
    }
  end

  before do
    allow(described_class).to receive(:cached_context).and_return({ tests: test_data })
  end

  describe "factory traits" do
    it "renders the file and its trait names, not a Ruby array" do
      text = described_class.call(detail: "standard").content.first[:text]

      expect(text).to include("- **users.rb:** admin, with_posts")
      expect(text).not_to include('["users.rb"')
    end
  end

  describe "a fixtures directory with other files in it" do
    it "says what it counted" do
      test_data[:fixtures] = { location: "spec/fixtures", count: 1, other_files: 485 }

      text = described_class.call(detail: "standard").content.first[:text]

      expect(text).to include("- **Fixtures:** spec/fixtures (1 YAML fixture set, 485 other files)")
    end
  end

  describe ".call with no params" do
    it "defaults to standard detail level" do
      result = described_class.call
      text = result.content.first[:text]
      expect(text).to include("Test Infrastructure")
      expect(text).to include("RSpec")
      expect(text).to include("spec/factories")
    end

    it "shows test file categories" do
      result = described_class.call
      text = result.content.first[:text]
      expect(text).to include("models: 8 files")
      expect(text).to include("requests: 6 files")
    end

    # The counts and the locations are one walk, so one section states both.
    it "lists each category once, with its count and location" do
      text = described_class.call.content.first[:text]

      expect(text).to include("- models: 8 files (spec/models)")
      expect(text).not_to include("Test Counts by Category")
      expect(text.scan(/^- models:/).size).to eq(1)
    end

    it "shows CI config" do
      result = described_class.call
      text = result.content.first[:text]
      expect(text).to include("github_actions")
    end

    it "shows coverage tool" do
      result = described_class.call
      text = result.content.first[:text]
      expect(text).to include("simplecov")
    end
  end

  describe "the test template" do
    it "shows a factory call when the app has factories" do
      text = described_class.call.content.first[:text]
      expect(text).to include("record = create(:model_name)")
    end

    it "does not show a factory call when the app has no factories" do
      allow(described_class).to receive(:cached_context)
        .and_return({ tests: test_data.merge(factories: nil, factory_names: nil) })
      text = described_class.call.content.first[:text]
      expect(text).not_to include("create(:model_name)")
      expect(text).to include("record = ModelName.new")
    end
  end

  # The minitest half of the template reads the app's own test directory, so
  # each example builds one.
  describe "the minitest test template" do
    around do |example|
      Dir.mktmpdir do |dir|
        FileUtils.mkdir_p(File.join(dir, "test", "controllers"))
        File.write(
          File.join(dir, "test", "controllers", "posts_controller_test.rb"),
          "class PostsControllerTest < ActionDispatch::IntegrationTest\n" \
          "  include Devise::Test::IntegrationHelpers\n" \
          "  test \"x\" do\n    sign_in users(:admin)\n  end\nend\n"
        )
        @root = dir
        example.run
      end
    end

    def call_with(tests)
      allow(described_class).to receive(:rails_app).and_return(double(root: Pathname.new(@root)))
      allow(described_class).to receive(:cached_context).and_return({ tests: tests })
      described_class.call.content.first[:text]
    end

    let(:minitest_data) do
      {
        framework: "minitest",
        factories: nil,
        fixtures: { location: "test/fixtures", count: 2 },
        fixture_names: { "users" => %w[admin member], "posts" => %w[first_post] },
        test_files: { "models" => { location: "test/models", count: 1 } }
      }
    end

    it "signs in the app's own users fixture" do
      text = call_with(minitest_data)

      expect(text).to include("sign_in users(:admin)")
      expect(text).not_to include("users(:one)")
    end

    it "leaves the tests unauthenticated when the app owns no users fixture" do
      text = call_with(minitest_data.merge(fixture_names: { "posts" => %w[first_post] }))

      expect(text).not_to include("sign_in users(")
      expect(text).to include("# TODO: sign in a user built from this app's own test data")
    end

    it "does not read the app's own sign_in_as as Devise's sign_in" do
      File.write(File.join(@root, "test", "controllers", "posts_controller_test.rb"),
                 "class PostsControllerTest < ActionDispatch::IntegrationTest\n" \
                 "  include Devise::Test::IntegrationHelpers\n" \
                 "  test \"x\" do\n    sign_in_as users(:admin)\n  end\nend\n")

      expect(call_with(minitest_data)).not_to include("sign_in users(")
    end

    it "does not hand fixture syntax to an app with no fixtures" do
      text = call_with(minitest_data.merge(fixtures: nil, fixture_names: nil))

      expect(text).not_to include("model_names(:fixture_name)")
      expect(text).to include("record = ModelName.new")
    end
  end

  describe ".call with detail:summary" do
    it "returns compact summary with counts" do
      result = described_class.call(detail: "summary")
      text = result.content.first[:text]
      expect(text).to include("Test Infrastructure")
      expect(text).to include("RSpec")
      expect(text).to include("5 files")
    end

    it "shows total test file count" do
      result = described_class.call(detail: "summary")
      text = result.content.first[:text]
      expect(text).to include("18 across 3 categories")
    end
  end

  describe ".call with detail:full" do
    it "shows factory names when available" do
      result = described_class.call(detail: "full")
      text = result.content.first[:text]
      expect(text).to include("Factories")
    end

    it "shows test helper setup" do
      result = described_class.call(detail: "full")
      text = result.content.first[:text]
      expect(text).to include("Test Helper Setup")
      expect(text).to include("FactoryBot::Syntax::Methods")
    end

    it "lists each category once, with its count and location" do
      text = described_class.call(detail: "full").content.first[:text]

      expect(text).to include("- models: 8 files (spec/models)")
      expect(text.scan(/^- models:/).size).to eq(1)
    end

    it "shows test helper files" do
      result = described_class.call(detail: "full")
      text = result.content.first[:text]
      expect(text).to include("spec/support/auth_helpers.rb")
    end
  end

  describe "the steps bin/ci runs" do
    before do
      test_data[:ci_config] = %w[rails_ci]
      test_data[:ci_steps] = [ { name: "Setup", command: "bin/setup --skip-server" }, { name: "Tests: Rails", command: "bin/rails test" } ]
    end

    it "lists them under config/ci.rb at standard and full detail" do
      %w[standard full].each do |detail|
        text = described_class.call(detail: detail).content.first[:text]

        expect(text).to include("- **CI:** rails_ci")
        expect(text).to include("## CI Steps (`config/ci.rb`, run by `bin/ci`)\n- Setup: `bin/setup --skip-server`\n- Tests: Rails: `bin/rails test`")
      end
    end

    it "names the dummy's config/ci.rb under the engine's suite root" do
      test_data[:ci_steps_dir] = "test/dummy/"

      expect(described_class.call.content.first[:text]).to include("## CI Steps (`test/dummy/config/ci.rb`, run by `test/dummy/bin/ci`)")
    end

    it "keeps them out of the summary" do
      expect(described_class.call(detail: "summary").content.first[:text]).not_to include("CI Steps")
    end
  end

  describe "fixtures at full detail" do
    around { |example| Dir.mktmpdir { |dir| @root = dir; example.run } }

    def write(rel, body)
      path = File.join(@root, rel)
      FileUtils.mkdir_p(File.dirname(path))
      File.write(path, body)
    end

    def full_text
      tests = RailsAiContext::Introspectors::TestIntrospector.new(double("app", root: @root)).call
      allow(described_class).to receive(:rails_app).and_return(double(root: Pathname.new(@root)))
      allow(described_class).to receive(:cached_context).and_return({ tests: tests })
      described_class.call(detail: "full").content.first[:text]
    end

    it "reads a set whose first line is an ERB tag beside one that is plain YAML" do
      write("test/fixtures/users.yml", <<~YAML)
        <% password_digest = BCrypt::Password.create("password") %>

        one:
          email_address: one@example.com
          password_digest: <%= password_digest %>
      YAML
      write("test/fixtures/posts.yml", "one: { title: A, user: one }\n")

      text = full_text

      expect(text).to include("- **users:**\n  - `one`: email_address: one@example.com, password_digest: erb_value")
      expect(text).to include("- **posts:**\n  - `one`: title: A, user: one")
    end

    it "follows DEFAULTS, keeps subfolder sets apart and leaves out _fixture and ignored labels" do
      write("test/fixtures/users.yml", "DEFAULTS: &DEFAULTS\n  name: Default\nalice:\n  <<: *DEFAULTS\n  email: alice@example.com\n")
      write("test/fixtures/admin/posts.yml", "pinned:\n  title: Admin pinned\n")
      write("test/fixtures/posts.yml", "_fixture:\n  model_class: Post\n  ignore: base\nbase:\n  title: Base\nfirst:\n  title: Hello\n")

      text = full_text

      expect(text).to include("- **admin/posts:**\n  - `pinned`: title: Admin pinned")
      expect(text).to include("- **posts:**\n  - `first`: title: Hello")
      expect(text).to include("- **users:**\n  - `alice`: name: Default, email: alice@example.com")
      expect(text).not_to include("_fixture")
      expect(text).not_to include("`base`")
    end

    it "picks no label _fixture ignores when it reads the file itself" do
      write("test/fixtures/posts.yml", "_fixture:\n  ignore: base\nbase:\n  title: Base\nfirst:\n  title: Hello\n")
      allow(described_class).to receive(:rails_app).and_return(double(root: Pathname.new(@root)))

      expect(described_class.send(:fixture_key_for, "posts", {})).to eq("first")
    end

    it "never offers a label ERB computes as a fixture key, and shows it as ERB in the listing" do
      write("test/fixtures/users.yml", "<% 2.times do |i| %>\nuser_<%= i %>:\n  n: <%= i %>\n<% end %>\n")
      text = full_text

      expect(described_class.send(:fixture_key_for, "users", { fixture_names: { "users" => [ "user_erb_value" ] } })).to be_nil
      expect(text).to include("- **users:**\n  - `user_<%= ... %>` _(label set by ERB)_")
      expect(text).not_to include("users(:user_erb_value)")
    end

    it "lists a label that starts with an underscore as written, with no ERB note" do
      write("test/fixtures/unders.yml", "_draft:\n  n: 1\nplain:\n  n: 2\n")

      expect(full_text).to include("- **unders:**\n  - `_draft`: n: 1\n  - `plain`: n: 2")
    end

    it "lists the labels of a set it cannot parse and says so" do
      write("test/fixtures/users.yml", "bob:\n  name: B\n")
      write("test/fixtures/broken.yml", "one:\n  title: [unclosed\n")

      text = full_text

      expect(text).to include("- **users:**\n  - `bob`: name: B")
      expect(text).to include("- **broken:** one _(not parsed as YAML; labels only)_")
    end

    it "says a set past the read limit was too large, not that it does not parse" do
      write("test/fixtures/users.yml", "bob:\n  name: #{"B" * 50}\n")
      allow(RailsAiContext.configuration).to receive(:max_test_file_size).and_return(20)

      expect(full_text).to include("- **users:** bob _(over the 20 byte read limit; labels only)_")
    end

    it "prints no label from a fixture file that links out of the app" do
      Dir.mktmpdir do |outside|
        File.write(File.join(outside, "leak.yml"), "secret_label:\n  key: x\n")
        write("test/fixtures/users.yml", "bob:\n  name: B\n")
        File.symlink(File.join(outside, "leak.yml"), File.join(@root, "test", "fixtures", "leak.yml"))

        text = full_text

        expect(text).to include("- **users:**\n  - `bob`: name: B")
        expect(text).not_to include("secret_label")
        expect(text).not_to include("not parsed as YAML")
      end
    end

    it "shows an attribute an alias nests deeply without expanding it" do
      laughs = +"a: &a [x, x, x, x, x, x, x, x, x]\n"
      levels = ("a".."j").to_a
      levels.each_cons(2) { |prev, cur| laughs << "#{cur}: &#{cur} [*#{prev}, *#{prev}, *#{prev}, *#{prev}, *#{prev}, *#{prev}, *#{prev}, *#{prev}, *#{prev}]\n" }
      body = "bomb:\n  title: Short\n" + laughs.lines.map { |line| "  #{line}" }.join + "  tags: [one, two]\n"
      write("test/fixtures/posts.yml", body)

      text = nil
      expect { Timeout.timeout(5) { text = full_text } }.not_to raise_error
      expect(text).to include("- **posts:**\n  - `bomb`: title: Short")
      expect(text).to include("tags: [\"one\", \"two\"]")
      expect(text).not_to include("j: ")
    end
  end

  describe "fabricators and a Cucumber tree" do
    before do
      test_data[:fabricators] = { location: "spec/fabricators", count: 1 }
      test_data[:fabricator_names] = { "spec/fabricators/product_fabricator.rb" => %w[product] }
      test_data[:cucumber] = { location: "features", count: 3, step_definitions: 1 }
    end

    it "counts them in the summary" do
      text = described_class.call(detail: "summary").content.first[:text]

      expect(text).to include("- **Fabricators:** 1 file")
      expect(text).to include("- **Cucumber:** 3 feature files")
    end

    it "names where they live at standard detail" do
      text = described_class.call(detail: "standard").content.first[:text]

      expect(text).to include("- **Fabricators:** spec/fabricators (1 file)")
      expect(text).to include("- **Cucumber:** features (3 feature files, 1 step definition file)")
    end

    it "lists the fabricators by name at full detail" do
      text = described_class.call(detail: "full").content.first[:text]

      expect(text).to include("## Fabricators\n- **spec/fabricators/product_fabricator.rb:** product")
      expect(text).to include("- **Cucumber:** features (3 feature files, 1 step definition file)")
    end
  end

  describe ".call with unknown detail level" do
    it "reads an invalid detail level as the default, and says so" do
      text = described_class.call(detail: "invalid").content.first[:text]

      expect(text).to start_with(described_class.call(detail: "standard").content.first[:text])
      expect(text).to include("invalid")
      expect(text).to include("not a valid `detail`")
    end
  end

  describe ".call with model filter" do
    it "searches for model test file" do
      result = described_class.call(model: "User")
      text = result.content.first[:text]
      # Should either find a test file or report not found with searched paths
      expect(text).to match(/user_spec\.rb|user_test\.rb|No test file found/)
    end

    it "handles model filter with controller-style name" do
      result = described_class.call(model: "Nonexistent")
      text = result.content.first[:text]
      expect(text).to include("No test file found")
      expect(text).to include("Searched:")
    end

    # Whitehall files controller tests under test/functional and model tests
    # under test/unit/app/models, and the no-arg answer already lists both
    # directories. Searching only the conventional two answered "no test file"
    # for a file the same tool had just counted.
    it "finds a controller test the app files outside test/controllers" do
      Dir.mktmpdir do |root|
        FileUtils.mkdir_p(File.join(root, "test", "functional", "admin"))
        File.write(File.join(root, "test", "functional", "admin", "editions_controller_test.rb"),
                   "class Admin::EditionsControllerTest < ActionController::TestCase\n  test \"index\" do\n  end\nend\n")
        allow(described_class).to receive(:rails_app).and_return(double(root: Pathname.new(root)))
        allow(described_class).to receive(:cached_context).and_return({
          tests: test_data, controllers: { controllers: { "Admin::EditionsController" => {} } }
        })

        text = described_class.call(controller: "admin/editions", detail: "full").content.first[:text]

        expect(text).to include("test/functional/admin/editions_controller_test.rb")
        expect(text).not_to include("No test file found")
      end
    end

    it "finds a model test the app files outside test/models" do
      Dir.mktmpdir do |root|
        FileUtils.mkdir_p(File.join(root, "test", "unit", "app", "models"))
        File.write(File.join(root, "test", "unit", "app", "models", "organisation_test.rb"),
                   "class OrganisationTest < ActiveSupport::TestCase\nend\n")
        allow(described_class).to receive(:rails_app).and_return(double(root: Pathname.new(root)))
        allow(described_class).to receive(:cached_context).and_return({ tests: test_data, models: { "Organisation" => {} } })

        text = described_class.call(model: "Organisation", detail: "full").content.first[:text]

        expect(text).to include("test/unit/app/models/organisation_test.rb")
        expect(text).not_to include("No test file found")
      end
    end

    it "names a test file over max_test_file_size instead of calling it missing" do
      Dir.mktmpdir do |root|
        FileUtils.mkdir_p(File.join(root, "test", "models"))
        File.write(File.join(root, "test", "models", "comment_test.rb"),
                   "class CommentTest < ActiveSupport::TestCase\n  test \"x\" do\n  end\nend\n")
        allow(described_class).to receive(:rails_app).and_return(double(root: Pathname.new(root)))
        allow(described_class).to receive(:cached_context).and_return({ tests: test_data, models: { "Comment" => {} } })
        allow(RailsAiContext.configuration).to receive(:max_test_file_size).and_return(20)

        text = described_class.call(model: "Comment").content.first[:text]

        expect(text).not_to include("No test file found")
        expect(text).to include("test/models/comment_test.rb")
        expect(text).to include("max_test_file_size")
      end
    end

    # An app that keeps model specs in spec/models, half of them named
    # user_model_spec.rb, and has a serializer spec at
    # spec/services/serializers/.../user_spec.rb. A basename match anywhere
    # answered the serializer spec for the User model.
    it "looks for a model's test only where the app keeps model tests, in its own naming" do
      Dir.mktmpdir do |root|
        { "spec/models/user_model_spec.rb" => "describe User do\n  it \"is a model\" do\n  end\nend\n",
          "spec/models/invoice_spec.rb" => "describe Invoice do\nend\n",
          "spec/models/order_model_spec.rb" => "describe Order do\nend\n",
          "spec/services/serializers/api/v1/admin/user_spec.rb" => "describe UserSerializer do\n  it \"serializes\" do\n  end\nend\n" }.each do |rel, body|
          FileUtils.mkdir_p(File.dirname(File.join(root, rel)))
          File.write(File.join(root, rel), body)
        end
        allow(described_class).to receive(:rails_app).and_return(double(root: Pathname.new(root)))
        allow(described_class).to receive(:cached_context).and_return({
          tests: test_data, models: { "User" => {}, "Invoice" => {}, "Order" => {} }
        })

        text = described_class.call(model: "User", detail: "full").content.first[:text]

        expect(text).to include("spec/models/user_model_spec.rb")
        expect(text).not_to include("serializers")
      end
    end

    # Mastodon tests AboutController only through spec/system/about_spec.rb,
    # which visits about_path. "No test file found" there is a confident
    # negative about a controller the app does test.
    describe "specs that exercise a controller from outside its controller spec" do
      def app_with(root, files)
        files.each do |rel, body|
          FileUtils.mkdir_p(File.dirname(File.join(root, rel)))
          File.write(File.join(root, rel), body)
        end
        allow(described_class).to receive(:rails_app).and_return(double(root: Pathname.new(root)))
        allow(described_class).to receive(:cached_context).and_return({
          tests: test_data,
          controllers: { controllers: { "AboutController" => {}, "Admin::Settings::AboutController" => {} } },
          routes: { by_controller: {
            "about" => [ { verb: "GET", path: "/about", action: "show", name: "about" } ],
            "admin/settings/about" => [ { verb: "PUT", path: "/admin/settings/about", action: "update", name: "admin_settings_about" } ]
          } }
        })
      end

      it "lists the system spec named for the controller, labelled by its type" do
        Dir.mktmpdir do |root|
          app_with(root, "spec/system/about_spec.rb" => "RSpec.describe 'About page' do\n  it 'visits' do\n    visit about_path\n  end\nend\n",
                         "spec/requests/admin/settings/about_spec.rb" =>
                           "RSpec.describe 'Admin about' do\n  it 'saves' do\n    put admin_settings_about_path\n  end\nend\n")

          text = described_class.call(controller: "AboutController", detail: "summary").content.first[:text]

          expect(text).to include("spec/system/about_spec.rb")
          expect(text).to include("(system")
          expect(text).not_to include("No test file found")
          expect(text).not_to include("admin/settings/about_spec.rb")
        end
      end

      it "finds a spec by the route it visits, whatever it is named" do
        Dir.mktmpdir do |root|
          app_with(root, "spec/features/landing_spec.rb" => "RSpec.feature 'Landing' do\n  scenario 'x' do\n    visit '/about'\n  end\nend\n",
                         "spec/requests/pages_spec.rb" => "RSpec.describe 'Pages' do\n  it 'x' do\n    get about_url\n  end\nend\n")

          text = described_class.call(controller: "AboutController", detail: "summary").content.first[:text]

          expect(text).to include("`spec/features/landing_spec.rb` (feature")
          expect(text).to include("`spec/requests/pages_spec.rb` (request")
        end
      end

      it "lists them beside the controller spec when there is one" do
        Dir.mktmpdir do |root|
          app_with(root, "spec/controllers/about_controller_spec.rb" => "RSpec.describe AboutController do\n  it 'shows' do\n  end\nend\n",
                         "spec/system/about_spec.rb" => "RSpec.describe 'About page' do\n  it 'visits' do\n    visit about_path\n  end\nend\n")

          text = described_class.call(controller: "AboutController", detail: "summary").content.first[:text]

          expect(text).to include("# spec/controllers/about_controller_spec.rb")
          expect(text).to include("`spec/system/about_spec.rb` (system")
        end
      end
    end

    # A model spec's examples sit inside describe and context blocks, and
    # counting every line that opens a block counted the groups as tests.
    it "counts the examples a spec runs, not the groups around them" do
      Dir.mktmpdir do |root|
        FileUtils.mkdir_p(File.join(root, "spec", "models"))
        File.write(File.join(root, "spec", "models", "user_spec.rb"), <<~RUBY)
          RSpec.describe User do
            describe "#name" do
              context "when set" do
                it "returns it" do
                end
                it { is_expected.to be_valid }
              end
              specify { expect(1).to eq(1) }
              xit "is pending" do
              end
            end
            its(:email) { is_expected.to be_nil }
          end
        RUBY
        allow(described_class).to receive(:rails_app).and_return(double(root: Pathname.new(root)))
        allow(described_class).to receive(:cached_context).and_return({ tests: test_data, models: { "User" => {} } })

        text = described_class.call(model: "User", detail: "summary").content.first[:text]

        expect(text).to include("# spec/models/user_spec.rb (5 tests)")
      end
    end

    # The lines listed under the count are the examples it counted, so the
    # two cannot disagree: no group lines, every example form.
    it "lists the examples it counted, and nothing else" do
      Dir.mktmpdir do |root|
        FileUtils.mkdir_p(File.join(root, "spec", "models"))
        File.write(File.join(root, "spec", "models", "user_spec.rb"), <<~RUBY)
          RSpec.describe User do
            context "when set" do
              it "returns it" do
              end
              example "an example" do
              end
              fit "focused" do
              end
            end
            its(:email) { is_expected.to be_nil }
          end
        RUBY
        allow(described_class).to receive(:rails_app).and_return(double(root: Pathname.new(root)))
        allow(described_class).to receive(:cached_context).and_return({ tests: test_data, models: { "User" => {} } })

        text = described_class.call(model: "User", detail: "summary").content.first[:text]

        expect(text.lines.map(&:strip).grep(/\A- /)).to eq([
          '- it "returns it" do', '- example "an example" do', '- fit "focused" do', "- its(:email) { is_expected.to be_nil }"
        ])
      end
    end

    it "counts minitest's test blocks and test_ methods" do
      Dir.mktmpdir do |root|
        FileUtils.mkdir_p(File.join(root, "test", "models"))
        File.write(File.join(root, "test", "models", "user_test.rb"), <<~RUBY)
          class UserTest < ActiveSupport::TestCase
            test "valid" do
            end
            def test_name
            end
            def helper_not_a_test
            end
          end
        RUBY
        allow(described_class).to receive(:rails_app).and_return(double(root: Pathname.new(root)))
        allow(described_class).to receive(:cached_context).and_return({ tests: test_data, models: { "User" => {} } })

        text = described_class.call(model: "User", detail: "summary").content.first[:text]

        expect(text).to include("# test/models/user_test.rb (2 tests)")
      end
    end

    it "does not name a directory outside the app root when it finds nothing" do
      Dir.mktmpdir do |parent|
        root = File.join(parent, "app")
        FileUtils.mkdir_p(File.join(root, "spec", "models"))
        File.write(File.join(parent, "outside_marker.txt"), "x\n")
        allow(described_class).to receive(:rails_app).and_return(double(root: Pathname.new(root)))

        response = described_class.call(model: "../../outside", detail: "full")
        text = response.content.first[:text]

        expect(response.error?).to be(true)
        expect(text).to include("Path not allowed")
        expect(text).not_to include("outside_marker.txt")
        expect(text).not_to include("Files in test directory")
      end
    end

    # Listing paths that were refused reads as if they were searched, and a
    # refusal is an error result, so a script can tell it from an answer.
    it "refuses the name rather than listing paths it never read" do
      Dir.mktmpdir do |parent|
        root = File.join(parent, "app")
        FileUtils.mkdir_p(File.join(root, "spec", "models"))
        allow(described_class).to receive(:rails_app).and_return(double(root: Pathname.new(root)))

        response = described_class.call(model: "../../etc", detail: "full")
        text = response.content.first[:text]

        expect(response.error?).to be(true)
        expect(text).to include("Path not allowed")
        expect(text).not_to include("Searched:")
        expect(text).not_to include("../../etc_spec.rb")
      end
    end

    # The set also holds :sensitive, which a configured pattern reaches for a
    # name that never left the root.
    it "does not blame the app root for a name refused as sensitive" do
      Dir.mktmpdir do |parent|
        root = File.join(parent, "app")
        FileUtils.mkdir_p(File.join(root, "spec", "models"))
        File.write(File.join(root, "spec", "models", "secret_spec.rb"), "# tests\n")
        allow(described_class).to receive(:rails_app).and_return(double(root: Pathname.new(root)))
        original = RailsAiContext.configuration.sensitive_patterns
        RailsAiContext.configuration.sensitive_patterns = original + [ "spec/models/*_spec.rb", "test/models/*_test.rb" ]

        begin
          text = described_class.call(model: "Secret", detail: "full").content.first[:text]
        ensure
          RailsAiContext.configuration.sensitive_patterns = original
        end

        expect(text).to include("refused")
        expect(text).not_to include("Searched:")
        expect(text).to include("or names a sensitive file")
        expect(text).not_to end_with("it leaves the app root.")
      end
    end

    it "does not read a test file that resolves outside the app root or to a sensitive file" do
      Dir.mktmpdir do |parent|
        root = File.join(parent, "app")
        backup = File.join(parent, "app_backup")
        FileUtils.mkdir_p(File.join(root, "spec", "models"))
        FileUtils.mkdir_p(File.join(root, "config"))
        FileUtils.mkdir_p(backup)
        File.write(File.join(root, "spec", "models", "post_spec.rb"), "describe Post do; end\n")
        File.write(File.join(backup, "secret_spec.rb"), "secret\n")
        File.write(File.join(root, "config", "master.key"), "0123456789abcdef\n")
        File.symlink(File.join(backup, "secret_spec.rb"), File.join(root, "spec", "models", "escape_spec.rb"))
        File.symlink(File.join(root, "config", "master.key"), File.join(root, "spec", "models", "leak_spec.rb"))
        allow(described_class).to receive(:rails_app).and_return(double(root: Pathname.new(root)))

        escape = described_class.call(model: "escape", detail: "full").content.first[:text]
        leak = described_class.call(model: "leak", detail: "full").content.first[:text]
        post = described_class.call(model: "post", detail: "full").content.first[:text]

        expect(escape).not_to include("secret")
        expect(leak).not_to include("0123456789abcdef")
        expect(post).to include("describe Post do")
      end
    end
  end

  describe ".call with controller filter" do
    it "searches for controller test file" do
      result = described_class.call(controller: "Posts")
      text = result.content.first[:text]
      expect(text).to match(/posts_controller_spec\.rb|posts_spec\.rb|posts_controller_test\.rb|No test file found/)
    end

    # `spec/requests/posts_spec.rb` is the top-level PostsController's spec.
    # Offering it for Api::V1::PostsController answered a namespaced
    # controller with another controller's tests.
    it "does not answer a namespaced controller with the flat spec of another" do
      Dir.mktmpdir do |root|
        FileUtils.mkdir_p(File.join(root, "spec", "requests"))
        File.write(File.join(root, "spec", "requests", "posts_spec.rb"),
                   "RSpec.describe PostsController do\n  it \"indexes\" do\n  end\nend\n")
        allow(described_class).to receive(:rails_app).and_return(RailsAiContext::StaticApp.new(root))

        text = described_class.call(controller: "Api::V1::PostsController").content.first[:text]

        expect(text).to include("No test file found")
        expect(text).not_to include("indexes")
      end
    end

    it "returns not found with nearby files hint for missing controller test" do
      result = described_class.call(controller: "Nonexistent")
      text = result.content.first[:text]
      expect(text).to include("No test file found")
    end
  end

  describe ".call when introspection data is missing" do
    it "returns not-available when tests key is nil" do
      allow(described_class).to receive(:cached_context).and_return({})
      result = described_class.call
      text = result.content.first[:text]
      expect(text).to include("not available")
    end

    it "returns error message when test data has an error" do
      allow(described_class).to receive(:cached_context).and_return({
        tests: { error: "test dir not found" }
      })
      result = described_class.call
      text = result.content.first[:text]
      expect(text).to include("test dir not found")
    end
  end

  describe ".call with minitest framework data" do
    before do
      minitest_data = test_data.merge(
        framework: "Minitest",
        factories: nil,
        factory_names: nil,
        fixtures: { location: "test/fixtures", count: 3 },
        fixture_names: { "users" => %w[one two], "posts" => %w[first_post] }
      )
      allow(described_class).to receive(:cached_context).and_return({ tests: minitest_data })
    end

    it "shows fixture info for minitest apps" do
      result = described_class.call(detail: "standard")
      text = result.content.first[:text]
      expect(text).to include("test/fixtures")
      expect(text).to include("3 files")
    end
  end

  describe "full detail with minitest fixtures and helpers" do
    before do
      minitest_full_data = {
        framework: "minitest",
        factories: nil,
        factory_names: nil,
        fixtures: { location: "test/fixtures", count: 3 },
        fixture_names: { "users" => %w[one two], "posts" => %w[first_post] },
        system_tests: nil,
        test_helpers: %w[test/helpers/auth_helper.rb],
        test_helper_setup: %w[Devise::Test::IntegrationHelpers],
        test_files: { "models" => { location: "test/models", count: 5 }, "controllers" => { location: "test/controllers", count: 3 } },
        vcr_cassettes: nil,
        ci_config: %w[github_actions],
        coverage: "simplecov"
      }
      allow(described_class).to receive(:cached_context).and_return({ tests: minitest_full_data })
    end

    it "returns full info with fixture names and helper setup" do
      result = described_class.call(detail: "full")
      text = result.content.first[:text]
      expect(text).to include("**users:** one, two")
      expect(text).to include("**posts:** first_post")
      expect(text).to include("Devise::Test::IntegrationHelpers")
      expect(text).to include("simplecov")
    end
  end

  describe "an engine's test/dummy read without booting" do
    it "reads the engine's suite when its bundle is inside the repository, and says it is not read otherwise" do
      Dir.mktmpdir do |engine|
        dummy = File.join(engine, "test", "dummy")
        FileUtils.mkdir_p([ File.join(dummy, "config"), File.join(engine, "test", "models"), File.join(engine, ".git") ])
        File.write(File.join(dummy, "config", "boot.rb"), %(ENV["BUNDLE_GEMFILE"] ||= File.expand_path("../../../Gemfile", __dir__)\n))
        File.write(File.join(engine, "shop.gemspec"), "")
        File.write(File.join(engine, "Gemfile"), "gemspec\n")
        File.write(File.join(engine, "Gemfile.lock"), "GEM\n  specs:\n    minitest (5.25.0)\n")
        File.write(File.join(engine, "test", "test_helper.rb"), "")
        File.write(File.join(engine, "test", "models", "widget_test.rb"), "")
        allow(RailsAiContext::PathResolver).to receive(:enclosing_engine_roots).and_return([])
        app = RailsAiContext::StaticApp.new(dummy)
        allow(described_class).to receive(:rails_app).and_return(app)
        tests = -> { RailsAiContext::Introspectors::TestIntrospector.new(app).call }

        allow(described_class).to receive(:cached_context).and_return({ tests: tests.call })
        text = described_class.call.content.first[:text]
        expect(text).to include("**Framework:** minitest", "**Suite:** the engine's, at `../..`")

        FileUtils.rm_rf(File.join(engine, ".git"))
        described_class.reset_cache!
        allow(described_class).to receive(:cached_context).and_return({ tests: tests.call })
        text = described_class.call.content.first[:text]
        expect(text).to include("**Suite:** not read: config/boot.rb points Bundler at ../../Gemfile, outside the app's git repository")
      end
    end
  end
end
