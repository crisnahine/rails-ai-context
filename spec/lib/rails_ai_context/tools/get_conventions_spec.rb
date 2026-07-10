# frozen_string_literal: true

require "spec_helper"
require "tmpdir"
require "fileutils"

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

  describe "App Patterns - create action flow detection" do
    let(:tmpdir) { Dir.mktmpdir }
    let(:controllers_dir) { File.join(tmpdir, "app", "controllers") }

    before do
      FileUtils.mkdir_p(controllers_dir)
      allow(Rails).to receive(:root).and_return(Pathname.new(tmpdir))
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
end
