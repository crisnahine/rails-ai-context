# frozen_string_literal: true

require "spec_helper"

RSpec.describe RailsAiContext::Introspectors::PerformanceIntrospector do
  let(:introspector) { described_class.new(Rails.application) }

  describe "#call" do
    subject(:result) { introspector.call }

    it "does not return an error" do
      expect(result).not_to have_key(:error)
    end

    it "returns n_plus_one_risks as array" do
      expect(result[:n_plus_one_risks]).to be_an(Array)
    end

    it "returns missing_counter_cache as array" do
      expect(result[:missing_counter_cache]).to be_an(Array)
    end

    it "returns missing_fk_indexes as array" do
      expect(result[:missing_fk_indexes]).to be_an(Array)
    end

    it "detects Model.all in controllers" do
      expect(result[:model_all_in_controllers]).to be_an(Array)
      models = result[:model_all_in_controllers].map { |f| f[:model] }
      expect(models).to include("Post")
    end

    it "provides suggestions for Model.all findings" do
      finding = result[:model_all_in_controllers].find { |f| f[:model] == "Post" }
      expect(finding[:suggestion]).to include("pagination")
    end

    it "detects eager load candidates" do
      expect(result[:eager_load_candidates]).to be_an(Array)
    end

    it "builds a summary with counts" do
      expect(result[:summary]).to be_a(Hash)
      expect(result[:summary][:total_issues]).to be_an(Integer)
      expect(result[:summary][:model_all_in_controllers]).to be >= 1
    end
  end

  describe "N+1 risk level detection" do
    let(:controllers_dir) { File.join(Rails.root, "app/controllers") }
    let(:views_dir) { File.join(Rails.root, "app/views/n1_test") }
    let(:fixture_ctrl) { File.join(controllers_dir, "n1_test_controller.rb") }
    let(:fixture_view) { File.join(views_dir, "index.html.erb") }

    before do
      FileUtils.mkdir_p(views_dir)
    end

    after do
      FileUtils.rm_f(fixture_ctrl)
      FileUtils.rm_rf(views_dir)
    end

    def n1_risks
      introspector.call[:n_plus_one_risks].select { |r| r[:controller]&.include?("n1_test") }
    end

    context "high risk: collection query + view association access, no preloading" do
      before do
        File.write(fixture_ctrl, <<~RUBY)
          class N1TestController < ApplicationController
            def index
              @posts = Post.all
            end
          end
        RUBY
        File.write(fixture_view, <<~ERB)
          <% @posts.each do |post| %>
            <p><%= post.comments.count %></p>
          <% end %>
        ERB
      end

      it "detects high risk" do
        risks = n1_risks
        expect(risks).not_to be_empty
        risk = risks.find { |r| r[:association] == "comments" }
        expect(risk).not_to be_nil
        expect(risk[:risk]).to eq("high")
      end

      it "includes action name" do
        risk = n1_risks.find { |r| r[:association] == "comments" }
        expect(risk[:action]).to eq("index")
      end

      it "provides preloading suggestion" do
        risk = n1_risks.find { |r| r[:association] == "comments" }
        expect(risk[:suggestion]).to include("includes(:comments)")
        expect(risk[:suggestion]).to include("Post")
      end
    end

    context "medium risk: has preloading but not for target association" do
      before do
        File.write(fixture_ctrl, <<~RUBY)
          class N1TestController < ApplicationController
            def index
              @users = User.where(active: true).includes(:posts)
            end
          end
        RUBY
        File.write(fixture_view, <<~ERB)
          <% @users.each do |user| %>
            <p><%= user.comments.count %></p>
          <% end %>
        ERB
      end

      it "detects medium risk when wrong association is preloaded" do
        risks = n1_risks
        risk = risks.find { |r| r[:model] == "User" && r[:association] == "comments" }
        expect(risk).not_to be_nil
        expect(risk[:risk]).to eq("medium")
      end

      it "suggests adding to includes list" do
        risk = n1_risks.find { |r| r[:association] == "comments" }
        expect(risk[:suggestion]).to include("missing :comments")
      end
    end

    context "low risk: association is already preloaded" do
      before do
        File.write(fixture_ctrl, <<~RUBY)
          class N1TestController < ApplicationController
            def index
              @posts = Post.all.includes(:comments)
            end
          end
        RUBY
        File.write(fixture_view, <<~ERB)
          <% @posts.each do |post| %>
            <p><%= post.comments.count %></p>
          <% end %>
        ERB
      end

      it "detects low risk when association is preloaded" do
        risks = n1_risks
        risk = risks.find { |r| r[:association] == "comments" }
        expect(risk).not_to be_nil
        expect(risk[:risk]).to eq("low")
      end

      it "says no action needed" do
        risk = n1_risks.find { |r| r[:association] == "comments" }
        expect(risk[:suggestion]).to include("no action needed")
      end
    end

    context "with multi-line query chain" do
      before do
        File.write(fixture_ctrl, <<~RUBY)
          class N1TestController < ApplicationController
            def index
              @posts = Post.where(published: true)
                          .order(created_at: :desc)
                          .includes(:comments)
            end
          end
        RUBY
        File.write(fixture_view, <<~ERB)
          <% @posts.each do |post| %>
            <p><%= post.comments.size %></p>
          <% end %>
        ERB
      end

      it "detects preloading in multi-line chain as low risk" do
        risk = n1_risks.find { |r| r[:association] == "comments" }
        expect(risk).not_to be_nil
        expect(risk[:risk]).to eq("low")
      end
    end

    context "with eager_load instead of includes" do
      before do
        File.write(fixture_ctrl, <<~RUBY)
          class N1TestController < ApplicationController
            def index
              @posts = Post.all.eager_load(:comments)
            end
          end
        RUBY
        File.write(fixture_view, <<~ERB)
          <% @posts.each do |post| %>
            <p><%= post.comments.size %></p>
          <% end %>
        ERB
      end

      it "recognizes eager_load as preloading" do
        risk = n1_risks.find { |r| r[:association] == "comments" }
        expect(risk).not_to be_nil
        expect(risk[:risk]).to eq("low")
      end
    end

    context "with loop in controller body (no view access)" do
      before do
        File.write(fixture_ctrl, <<~RUBY)
          class N1TestController < ApplicationController
            def index
              @posts = Post.all
              @posts.each do |post|
                post.comments.each { |c| logger.info(c.body) }
              end
            end
          end
        RUBY
      end

      it "detects N+1 from controller loop pattern" do
        risk = n1_risks.find { |r| r[:association] == "comments" }
        expect(risk).not_to be_nil
        expect(risk[:risk]).to eq("high")
      end
    end

    context "with no collection query" do
      before do
        File.write(fixture_ctrl, <<~RUBY)
          class N1TestController < ApplicationController
            def show
              @post = Post.find(1)
            end
          end
        RUBY
      end

      it "does not flag single-record loads" do
        expect(n1_risks).to be_empty
      end
    end

    context "with private method (not an action)" do
      before do
        File.write(fixture_ctrl, <<~RUBY)
          class N1TestController < ApplicationController
            def index
              render plain: "ok"
            end

            private

            def load_posts
              @posts = Post.all
            end
          end
        RUBY
        File.write(fixture_view, <<~ERB)
          <% @posts.each do |post| %>
            <p><%= post.comments.count %></p>
          <% end %>
        ERB
      end

      it "does not flag queries in private methods" do
        expect(n1_risks).to be_empty
      end
    end
  end

  describe "extract_controller_actions" do
    it "extracts public actions only" do
      source = <<~RUBY
        class FooController < ApplicationController
          def index
            @items = []
          end

          def show
            @item = nil
          end

          private

          def set_item
            @item = nil
          end
        end
      RUBY
      actions = introspector.send(:extract_controller_actions, source)
      expect(actions.keys).to contain_exactly("index", "show")
      expect(actions).not_to have_key("set_item")
    end

    it "captures full action body" do
      source = <<~RUBY
        class FooController < ApplicationController
          def index
            @posts = Post.all
            respond_to do |format|
              format.html
            end
          end
        end
      RUBY
      actions = introspector.send(:extract_controller_actions, source)
      expect(actions["index"]).to include("Post.all")
      expect(actions["index"]).to include("respond_to")
    end
  end
end
