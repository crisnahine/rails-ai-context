# frozen_string_literal: true

require "spec_helper"
require "prism"

RSpec.describe RailsAiContext::Introspectors::Listeners::ModelReferenceListener do
  def detect_models(source)
    result = Prism.parse(source)
    dispatcher = Prism::Dispatcher.new
    listener = described_class.new
    dispatcher.register(listener, :on_call_node_enter, :on_instance_variable_write_node_enter)
    dispatcher.dispatch(result.value)
    listener.results
  end

  describe "constant receiver detection" do
    it "detects Model.find" do
      models = detect_models("Post.find(1)")
      expect(models).to include("Post")
    end

    it "detects Model.where" do
      models = detect_models("Post.where(published: true)")
      expect(models).to include("Post")
    end

    it "detects Model.new" do
      models = detect_models("Post.new(title: 'Hello')")
      expect(models).to include("Post")
    end

    it "detects Model.create" do
      models = detect_models("Comment.create(body: 'Nice')")
      expect(models).to include("Comment")
    end

    it "detects namespaced models" do
      models = detect_models("Admin::User.find(1)")
      expect(models).to include("Admin::User")
    end

    it "detects multiple models" do
      source = <<~RUBY
        @post = Post.find(params[:id])
        @comments = Comment.where(post_id: @post.id)
      RUBY
      models = detect_models(source)
      expect(models).to include("Post", "Comment")
    end
  end

  describe "params.require detection" do
    it "detects params.require(:post)" do
      models = detect_models("params.require(:post).permit(:title)")
      expect(models).to include("Post")
    end

    it "detects params.require with string key" do
      models = detect_models('params.require("comment").permit(:body)')
      expect(models).to include("Comment")
    end

    it "classifies underscore keys" do
      models = detect_models("params.require(:order_item).permit(:quantity)")
      expect(models).to include("OrderItem")
    end
  end

  describe "instance variable write detection" do
    it "detects @post = Post.new" do
      models = detect_models("@post = Post.new")
      expect(models).to include("Post")
    end

    it "detects @user = User.find(params[:id])" do
      models = detect_models("@user = User.find(params[:id])")
      expect(models).to include("User")
    end
  end

  describe "framework constant filtering" do
    it "excludes Rails framework constants" do
      source = <<~RUBY
        class PostsController < ApplicationController
          def index
            @posts = Post.all
          end
        end
      RUBY
      models = detect_models(source)
      expect(models).to include("Post")
      expect(models).not_to include("ApplicationController")
    end

    it "excludes ActiveRecord references" do
      models = detect_models("ActiveRecord::Base.connection")
      expect(models).to be_empty
    end
  end

  describe "deduplication" do
    it "returns unique model names" do
      source = <<~RUBY
        @post = Post.find(1)
        @posts = Post.all
        Post.where(published: true)
      RUBY
      models = detect_models(source)
      expect(models.count("Post")).to eq(1)
    end
  end
end
