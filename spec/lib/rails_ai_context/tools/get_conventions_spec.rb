# frozen_string_literal: true

require "spec_helper"
require "tmpdir"
require "fileutils"
require "pathname"

RSpec.describe RailsAiContext::Tools::GetConventions do
  before { described_class.reset_cache! }

  let(:conventions_data) do
    {
      architecture: %w[hotwire service_objects docker],
      patterns: %w[sti polymorphic soft_delete],
      directory_structure: {
        "app/models" => 12,
        "app/controllers" => 8,
        "app/services" => 5,
        "app/views" => 20,
        "app/jobs" => 3
      },
      custom_directories: {
        "app/services" => "Service objects",
        "app/forms" => "Form objects"
      },
      config_files: %w[
        config/application.rb
        config/puma.rb
        Gemfile
        Procfile
        docker-compose.yml
        .kamal/deploy.yml
      ]
    }
  end

  before do
    allow(described_class).to receive(:cached_context).and_return({
      conventions: conventions_data
    })
  end

  describe ".call" do
    it "returns conventions and architecture heading" do
      result = described_class.call
      text = result.content.first[:text]
      expect(text).to include("App Conventions & Architecture")
    end

    it "shows architecture patterns with human-readable labels" do
      result = described_class.call
      text = result.content.first[:text]
      expect(text).to include("Architecture")
      expect(text).to include("Hotwire (Turbo + Stimulus)")
      expect(text).to include("Service objects pattern")
      expect(text).to include("Dockerized")
    end

    it "shows detected patterns with human-readable labels" do
      result = described_class.call
      text = result.content.first[:text]
      expect(text).to include("Detected patterns")
      expect(text).to include("Single Table Inheritance (STI)")
      expect(text).to include("Polymorphic associations")
      expect(text).to include("Soft deletes")
    end

    it "shows directory structure with file counts" do
      result = described_class.call
      text = result.content.first[:text]
      expect(text).to include("Directory structure")
      expect(text).to include("app/models")
      expect(text).to include("12 files")
    end

    it "shows custom directories" do
      result = described_class.call
      text = result.content.first[:text]
      expect(text).to include("Custom Directories")
      expect(text).to include("app/services")
      expect(text).to include("Service objects")
    end

    it "shows notable config files, filtering obvious ones" do
      result = described_class.call
      text = result.content.first[:text]
      expect(text).to include("Notable config files")
      expect(text).to include("Procfile")
      expect(text).to include("docker-compose.yml")
      # Obvious config files should be filtered
      expect(text).not_to match(/^- `config\/application.rb`/)
      expect(text).not_to match(/^- `Gemfile`/)
    end

    it "generates a convention fingerprint summary" do
      result = described_class.call
      text = result.content.first[:text]
      expect(text).to include("Convention Fingerprint")
      expect(text).to include("This app uses")
    end
  end

  describe "edge cases" do
    it "handles missing conventions data" do
      allow(described_class).to receive(:cached_context).and_return({})
      result = described_class.call
      text = result.content.first[:text]
      expect(text).to include("not available")
    end

    it "handles conventions introspection error" do
      allow(described_class).to receive(:cached_context).and_return({
        conventions: { error: "introspection failed" }
      })
      result = described_class.call
      text = result.content.first[:text]
      expect(text).to include("failed")
      expect(text).to include("introspection failed")
    end

    it "handles empty architecture list" do
      conventions_data[:architecture] = []
      result = described_class.call
      text = result.content.first[:text]
      expect(text).not_to include("## Architecture")
    end

    it "handles empty patterns list" do
      conventions_data[:patterns] = []
      result = described_class.call
      text = result.content.first[:text]
      expect(text).not_to include("Detected patterns")
    end

    it "handles empty directory structure" do
      conventions_data[:directory_structure] = {}
      result = described_class.call
      text = result.content.first[:text]
      expect(text).not_to include("Directory structure")
    end

    it "handles nil config_files gracefully" do
      conventions_data[:config_files] = nil
      result = described_class.call
      text = result.content.first[:text]
      expect(text).to include("App Conventions & Architecture")
    end

    it "handles unknown architecture key with humanized fallback" do
      conventions_data[:architecture] = %w[custom_pattern]
      result = described_class.call
      text = result.content.first[:text]
      expect(text).to include("Custom pattern")
    end

    it "handles unknown pattern key with humanized fallback" do
      conventions_data[:patterns] = %w[custom_strategy]
      result = described_class.call
      text = result.content.first[:text]
      expect(text).to include("Custom strategy")
    end
  end

  describe "App Patterns - controller test pattern detection" do
    let(:tmpdir) { Dir.mktmpdir }
    let(:tests_dir) { File.join(tmpdir, "test", "controllers") }

    before do
      FileUtils.mkdir_p(tests_dir)
      FileUtils.mkdir_p(File.join(tmpdir, "app", "controllers"))
      allow(Rails.application).to receive(:root).and_return(Pathname.new(tmpdir))
      allow(described_class).to receive(:cached_context).and_return({ conventions: {} })
    end

    after { FileUtils.remove_entry(tmpdir) }

    it "builds the skeleton from the signals the existing tests carry" do
      File.write(File.join(tests_dir, "posts_controller_test.rb"), <<~RUBY)
        require "test_helper"

        class PostsControllerTest < ActionDispatch::IntegrationTest
          include Devise::Test::IntegrationHelpers

          test "requires authentication" do
            get posts_path
            assert_response :redirect
          end

          test "index" do
            sign_in users(:one)
            get posts_path
            assert_response :success
            assert_select "h1", "Posts"
          end
        end
      RUBY

      text = described_class.call.content.first[:text]

      expect(text).to include("### Controller Test Pattern (follow this for new tests)")
      expect(text).to include("  include Devise::Test::IntegrationHelpers")
      expect(text).to include("  test \"requires authentication\" do")
      expect(text).to include("    sign_in users(:one)")
      expect(text).to include("    assert_select \"h1\", \"[Expected Title]\"")
      expect(text).to include("Detected from: PostsController")
    end

    it "signs in with the helper the tests call, not Devise's sign_in" do
      File.write(File.join(tests_dir, "sessions_controller_test.rb"), <<~RUBY)
        require "test_helper"

        class SessionsControllerTest < ActionDispatch::IntegrationTest
          setup { @user = User.take }

          test "destroy" do
            sign_in_as(User.take)

            delete session_path

            assert_redirected_to new_session_path
          end

          test "new" do
            get new_session_path
            assert_response :success
          end
        end
      RUBY

      text = described_class.call.content.first[:text]

      expect(text).to include("  test \"[action] renders page\" do\n    sign_in_as(User.take)\n    get [path]")
      expect(text).not_to include("sign_in users(:one)")
    end

    it "signs in a users fixture where the tests sign in a variable the skeleton never sets" do
      FileUtils.mkdir_p(File.join(tmpdir, "test", "fixtures"))
      File.write(File.join(tmpdir, "test", "fixtures", "users.yml"), "admin:\n  email: a@example.com\n")
      File.write(File.join(tests_dir, "posts_controller_test.rb"), <<~RUBY)
        class PostsControllerTest < ActionDispatch::IntegrationTest
          setup do
            @user = users(:admin)
            sign_in @user
          end

          test "index" do
            get posts_path
            assert_response :success
          end
        end
      RUBY

      text = described_class.call.content.first[:text]

      expect(text).to include("  test \"[action] renders page\" do\n    sign_in users(:admin)\n    get [path]")
      expect(text).not_to include("sign_in @user")
    end

    it "reads no users fixture through a fixture file symlinked out of the app" do
      outside = Dir.mktmpdir
      File.write(File.join(outside, "users.yml"), "secret_label:\n  email: a@example.com\n")
      FileUtils.mkdir_p(File.join(tmpdir, "test", "fixtures"))
      File.symlink(File.join(outside, "users.yml"), File.join(tmpdir, "test", "fixtures", "users.yml"))
      File.write(File.join(tests_dir, "posts_controller_test.rb"), <<~RUBY)
        class PostsControllerTest < ActionDispatch::IntegrationTest
          setup do
            @user = users(:admin)
            sign_in @user
          end

          test "index" do
            get posts_path
            assert_response :success
          end
        end
      RUBY

      text = described_class.call.content.first[:text]

      expect(text).not_to include("secret_label")
    ensure
      FileUtils.rm_rf(outside) if outside
    end

    it "keeps the helper the tests call when it signs in a variable" do
      File.write(File.join(tests_dir, "posts_controller_test.rb"), <<~RUBY)
        class PostsControllerTest < ActionDispatch::IntegrationTest
          test "index" do
            user = User.take
            sign_in_as(user)
            get posts_path
            assert_response :success
          end
        end
      RUBY

      text = described_class.call.content.first[:text]

      expect(text).to include("    # TODO: sign_in_as a user built from this app's own test data\n    get [path]")
      expect(text).not_to include("sign_in_as(user)")
    end

    it "reads no sign-in from a test name that mentions one" do
      File.write(File.join(tests_dir, "pages_controller_test.rb"), <<~RUBY)
        class PagesControllerTest < ActionDispatch::IntegrationTest
          test "shows sign_in link" do
            get root_path
            assert_response :success
          end
        end
      RUBY

      text = described_class.call.content.first[:text]

      expect(text).to include("### Controller Test Pattern")
      expect(text).not_to include("    sign_in")
    end

    it "renders no skeleton when no test asserts a response" do
      File.write(File.join(tests_dir, "quiet_controller_test.rb"), <<~RUBY)
        require "test_helper"

        class QuietControllerTest < ActionDispatch::IntegrationTest
          test "nothing" do
            sign_in users(:one)
          end
        end
      RUBY

      text = described_class.call.content.first[:text]

      expect(text).not_to include("### Controller Test Pattern")
    end
  end

  describe "App Patterns - create action flow detection" do
    let(:tmpdir) { Dir.mktmpdir }
    let(:controllers_dir) { File.join(tmpdir, "app", "controllers") }

    before do
      FileUtils.mkdir_p(controllers_dir)
      allow(Rails.application).to receive(:root).and_return(Pathname.new(tmpdir))
      allow(described_class).to receive(:cached_context).and_return({ conventions: {} })
    end

    after { FileUtils.remove_entry(tmpdir) }

    context "with no auth detected" do
      before do
        File.write(File.join(controllers_dir, "posts_controller.rb"), <<~RUBY)
          class PostsController < ApplicationController
            def create
              @post = Post.new(post_params)
              if @post.save
                redirect_to @post, notice: "Created!"
              else
                render :new, status: :unprocessable_entity
              end
            end
          end
        RUBY
      end

      it "shows detected flow lines without a current_user guard" do
        result = described_class.call
        text = result.content.first[:text]
        expect(text).to include("### Create Action Pattern (follow this for new actions)")
        expect(text).to include("PostsController: build → save → redirect/render")
        expect(text).to include("@record = [Model].new([params_method])")
        expect(text).not_to include("current_user")
      end
    end

    context "with auth (permission checks) detected" do
      before do
        File.write(File.join(controllers_dir, "comments_controller.rb"), <<~RUBY)
          class CommentsController < ApplicationController
            def create
              unless can_comment?
                redirect_to root_path, alert: "Not allowed"
                return
              end

              @comment = Comment.new(comment_params)
              if @comment.save
                redirect_to @comment, notice: "Created!"
              else
                render :new, status: :unprocessable_entity
              end
            end
          end
        RUBY
      end

      it "shows the permission-guard skeleton" do
        result = described_class.call
        text = result.content.first[:text]
        expect(text).to include("### Create Action Pattern (follow this for new actions)")
        expect(text).to include("unless current_user.can_[permission]?")
        expect(text).to include("@record = current_user.[association].build([params_method])")
      end

      # A guard or flash string repeated across controllers is one convention.
      it "lists a repeated check and flash string once" do
        File.write(File.join(controllers_dir, "replies_controller.rb"), <<~RUBY)
          class RepliesController < ApplicationController
            def create
              unless can_comment?
                redirect_to root_path, alert: "Not allowed"
                return
              end
              redirect_to @reply, notice: "Created!"
            end
          end
        RUBY

        text = described_class.call.content.first[:text]

        expect(text.scan("- Check: `can_comment?`").size).to eq(1)
        expect(text.scan(%q(- Deny: redirect_to ..., alert: "Not allowed")).size).to eq(1)
        expect(text.scan(%q(- Success: notice: "Created!")).size).to eq(1)
      end
    end

    context "with an API-only controller that only renders json" do
      before do
        File.write(File.join(controllers_dir, "orders_controller.rb"), <<~RUBY)
          class OrdersController < ApplicationController
            def create
              @order = Order.new(order_params)

              if @order.save
                render json: @order, status: :created, location: @order
              else
                render json: @order.errors, status: :unprocessable_content
              end
            end
          end
        RUBY
      end

      it "shows a render-json skeleton, not the HTML redirect/render one" do
        result = described_class.call
        text = result.content.first[:text]
        expect(text).to include("OrdersController: build → save → render json")
        expect(text).to include("render json: @record, status: :created")
        # Skeleton mirrors the failure status the controller actually renders.
        expect(text).to include("render json: @record.errors, status: :unprocessable_content")
        expect(text).not_to include("redirect_to @record")
        expect(text).not_to include("render :new")
      end
    end

    context "with a scaffolded controller that responds to both html and json" do
      before do
        File.write(File.join(controllers_dir, "articles_controller.rb"), <<~RUBY)
          class ArticlesController < ApplicationController
            def create
              @article = Article.new(article_params)

              respond_to do |format|
                if @article.save
                  format.html { redirect_to @article, notice: "Article was successfully created." }
                  format.json { render :show, status: :created, location: @article }
                else
                  format.html { render :new, status: :unprocessable_content }
                  format.json { render json: @article.errors, status: :unprocessable_content }
                end
              end
            end
          end
        RUBY
      end

      it "still shows the HTML redirect/render skeleton (redirect_to means it really has a view layer)" do
        result = described_class.call
        text = result.content.first[:text]
        expect(text).to include("ArticlesController: build → save → redirect/render")
        expect(text).to include('redirect_to @record, notice: "[success message]"')
        # Rails 7.1+ scaffolds render :unprocessable_content; the skeleton
        # follows the detected symbol instead of hardcoding the pre-7.1 one.
        expect(text).to include("render :new, status: :unprocessable_content")
        expect(text).not_to include("render json: @record")
      end
    end
  end

  describe ".detect_frontend_stack" do
    around { |example| Dir.mktmpdir { |dir| @root = dir; example.run } }

    before { allow(RailsAiContext).to receive(:default_app).and_return(double("app", root: Pathname.new(@root))) }

    def stack(package_json)
      File.write(File.join(@root, "package.json"), JSON.generate(package_json))
      described_class.send(:detect_frontend_stack)
    end

    it "names only the packages the app depends on" do
      result = stack(
        "dependencies" => { "vite" => "^5.0.0", "vite-plugin-ruby" => "^5.0.0" },
        "overrides" => { "webpack" => "^5.76.0", "esbuild" => "^0.25.0" }
      )
      expect(result).to eq([ "Vite" ])
    end

    it "names a tool reached only through a scoped plugin package" do
      result = stack("devDependencies" => { "@tailwindcss/vite" => "^4.0.0", "@hotwired/turbo-rails" => "^8.0.0" })
      expect(result).to contain_exactly("Tailwind CSS", "Turbo")
    end
  end

  describe "the not-found handling line" do
    it "credits a rescue only to the set_ method whose body holds it" do
      Dir.mktmpdir do |dir|
        FileUtils.mkdir_p(File.join(dir, "app", "controllers"))
        File.write(File.join(dir, "app", "controllers", "posts_controller.rb"), <<~RB)
          class PostsController < ApplicationController
            def set_post
              @post = Post.find(params[:id])
            end

            def set_post_author
              @author = Author.find(params[:author_id])
            rescue ActiveRecord::RecordNotFound
              redirect_to authors_path
            end
          end
        RB
        allow(described_class).to receive(:rails_app).and_return(double(root: Pathname.new(dir)))
        text = described_class.call.content.first[:text]

        expect(text).to include("- Not found: set_post_author → rescue → redirect_to authors_path")
        expect(text).not_to include("- Not found: set_post →")
      end
    end
  end

  # `validates_timeliness.en.yml` translates en; the name before the locale is the gem's.
  describe "the locales line" do
    def conventions_text(i18n)
      Dir.mktmpdir do |dir|
        FileUtils.mkdir_p(File.join(dir, "config", "locales"))
        File.write(File.join(dir, "config", "locales", "validates_timeliness.en.yml"), "en:\n  a: A\n")
        File.write(File.join(dir, "config", "locales", "fr.yml"), "fr:\n  a: A\n")
        allow(described_class).to receive(:rails_app).and_return(double(root: Pathname.new(dir)))
        context = { conventions: conventions_data }
        context[:i18n] = i18n if i18n
        allow(described_class).to receive(:cached_context).and_return(context)
        return described_class.call.content.first[:text]
      end
    end

    it "names the locales the i18n section reads from the files" do
      i18n = { locale_files: [ { file: "validates_timeliness.en.yml", locales: [ "en" ] }, { file: "fr.yml", locales: [ "fr" ] } ] }
      expect(conventions_text(i18n)).to include("**Locales:** en, fr (2 total)")
    end

    it "reads the locale part of a file name without the i18n section" do
      expect(conventions_text(nil)).to include("**Locales:** en, fr (2 total)")
    end
  end
end
