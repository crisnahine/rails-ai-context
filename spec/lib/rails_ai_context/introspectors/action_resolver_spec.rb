# frozen_string_literal: true

require "spec_helper"

RSpec.describe RailsAiContext::Introspectors::ActionResolver do
  let(:source) do
    <<~RUBY
      class PostsController < ApplicationController
        def index; end
        def show; end
        def _internal_probe; end

        class Form
          def save; end
          def validate!; end
        end

        private

        def find_post; end
      end
    RUBY
  end

  # A stand-in for a booted class: name, superclass chain, and what
  # reflection's action_methods would answer.
  let(:fake) do
    Struct.new(:name, :superclass, :action_set, keyword_init: true) do
      def action_methods
        action_set || []
      end
    end
  end
  let(:framework_base) { fake.new(name: "ActionController::Base") }
  let(:app_base) do
    fake.new(name: "ApplicationController", superclass: framework_base,
             action_set: %w[set_locale current_user])
  end

  describe ".actions_from_source" do
    it "reports only the class's own public instance methods" do
      expect(described_class.actions_from_source(source, class_name: "PostsController"))
        .to eq(%w[index show])
    end

    it "keeps underscored names when asked" do
      actions = described_class.actions_from_source(source, class_name: "PostsController",
                                                            skip_underscored: false)
      expect(actions).to include("_internal_probe")
    end

    it "matches both nesting spellings of a namespaced class" do
      compact = "class Admin::PostsController < ApplicationController\n  def index; end\nend\n"
      nested  = "module Admin\n  class PostsController < ApplicationController\n    def index; end\n  end\nend\n"

      expect(described_class.actions_from_source(compact, class_name: "Admin::PostsController")).to eq(%w[index])
      expect(described_class.actions_from_source(nested, class_name: "Admin::PostsController")).to eq(%w[index])
    end
  end

  describe ".resolve" do
    it "prefers the class's own source and filters nested owners" do
      klass = fake.new(name: "PostsController", superclass: app_base)

      actions = described_class.resolve(klass, source: source, kind: :controller,
                                        read_source: ->(_k) { nil })

      expect(actions).to eq(%w[index show])
    end

    it "walks to the nearest app-owned ancestor when the class defines nothing" do
      shared = fake.new(name: "SharedBase", superclass: app_base)
      klass = fake.new(name: "ThinController", superclass: shared)
      sources = { "SharedBase" => "class SharedBase < ApplicationController\n  def index; end\nend\n" }

      actions = described_class.resolve(klass, source: "class ThinController < SharedBase\nend\n",
                                        kind: :controller, read_source: ->(k) { sources[k.name] })

      expect(actions).to eq(%w[index])
    end

    it "answers empty when every ancestor was readable and defines nothing" do
      shared = fake.new(name: "SharedBase", superclass: app_base, action_set: %w[helper_leak])
      klass = fake.new(name: "ThinController", superclass: shared, action_set: %w[helper_leak])

      actions = described_class.resolve(klass, source: "class ThinController < SharedBase\nend\n",
                                        kind: :controller,
                                        read_source: ->(_k) { "class SharedBase\nend\n" })

      expect(actions).to eq([])
    end

    it "falls back to reflection minus the app base when there is no source" do
      gem_ctrl = fake.new(name: "Doorkeeper::ApplicationsController", superclass: app_base,
                          action_set: %w[index create set_locale current_user])

      actions = described_class.resolve(gem_ctrl, source: nil, kind: :controller,
                                        read_source: ->(_k) { nil })

      expect(actions).to eq(%w[create index])
    end

    it "falls back to reflection when an ancestor's source cannot be read" do
      gem_base = fake.new(name: "SomeGem::BaseController", superclass: app_base)
      klass = fake.new(name: "ThinController", superclass: gem_base,
                       action_set: %w[index set_locale current_user])

      actions = described_class.resolve(klass, source: "class ThinController < SomeGem::BaseController\nend\n",
                                        kind: :controller, read_source: ->(_k) { nil })

      expect(actions).to eq(%w[index])
    end
  end

  describe ".reflected_actions" do
    it "subtracts the app mailer base under the mailer kind" do
      am_base = fake.new(name: "ActionMailer::Base")
      application_mailer = fake.new(name: "ApplicationMailer", superclass: am_base,
                                    action_set: %w[default_url_options])
      mailer = fake.new(name: "UserMailer", superclass: application_mailer,
                        action_set: %w[welcome default_url_options])

      expect(described_class.reflected_actions(mailer, kind: :mailer)).to eq(%w[welcome])
    end
  end

  describe ".own_methods" do
    it "filters listener output to one owner, whatever the nesting spelling" do
      methods = [
        { name: "index", owner: %w[PostsController] },
        { name: "save", owner: %w[PostsController Form] },
        { name: "show", owner: %w[Admin::PostsController] }
      ]

      expect(described_class.own_methods(methods, "PostsController").map { |m| m[:name] }).to eq(%w[index])
      expect(described_class.own_methods(methods, "Admin::PostsController").map { |m| m[:name] }).to eq(%w[show])
    end
  end

  describe ".public_methods_from_source" do
    let(:source) { "class Widget\n  def full_name(sep = ' ')\n  end\n\n  def self.build(attrs)\n  end\n\n  private\n\n  def secret\n  end\nend\n" }

    it "lists the public instance methods with their signatures" do
      expect(described_class.public_methods_from_source(source)).to eq([ "full_name(sep = ' ')" ])
    end

    it "lists private and class methods separately" do
      expect(described_class.private_methods_from_source(source)).to eq(%w[secret])
      expect(described_class.class_methods_from_source(source)).to eq([ "build(attrs)" ])
    end

    it "reads a module as the owner and keeps a nested class out of it" do
      concern = <<~RUBY
        module Searchable
          extend ActiveSupport::Concern

          class_methods do
            def search(query); end
          end

          class Result
            def score; end
          end

          def search_result_title; end
          def _framework_hook; end

          private def normalize; end
        end
      RUBY

      expect(described_class.public_methods_from_source(concern)).to eq(%w[search_result_title])
      expect(described_class.private_methods_from_source(concern)).to eq(%w[normalize])
      expect(described_class.class_methods_from_source(concern)).to eq([ "search(query)" ])
      expect(described_class.public_methods_from_source(concern, owner: "Searchable::Result")).to eq(%w[score])
    end
  end

  describe ".public_methods_from_source on a concern that defines a method twice" do
    it "lists the signature once" do
      concern = "module Trackable\n  included do\n    def track; end\n  end\n\n  def track; end\nend\n"

      expect(described_class.public_methods_from_source(concern)).to eq(%w[track])
    end
  end

  describe ".signature" do
    it "renders the method as written, without a self prefix" do
      methods = RailsAiContext::Introspectors::SourceIntrospector.walk_source(
        "class Job\n  def self.enqueue(id, wait: 0); end\n  def perform(user_id, options = {}); end\nend\n",
        { methods: RailsAiContext::Introspectors::Listeners::MethodsListener }
      )[:methods]

      expect(methods.map { |m| described_class.signature(m) }).to eq([ "enqueue(id, wait: 0)", "perform(user_id, options = {})" ])
      expect(described_class.parameter_list(methods.last)).to eq("user_id, options = {}")
    end
  end

  describe "what an action assigns and renders" do
    let(:action_source) do
      <<~RUBY
        def update
          @post = Post.find(params[:id])
          @comments, @authors = @post.comments, @post.authors
          if @post.update(post_params)
            render json: @post
          else
            render :edit
            render json: @post.errors
          end
        end
      RUBY
    end

    it "names the instance variables the body assigns" do
      expect(described_class.assigned_ivars(action_source)).to eq(%w[post comments authors])
    end

    it "counts an assignment but never a comparison" do
      body = <<~RUBY
        def show
          return unless @post == current_user
          return if @author != current_user
          @user ||= find
          @count += 1
          @name =~ /x/
        end
      RUBY

      expect(described_class.assigned_ivars(body)).to eq(%w[user count])
    end

    # A doubled angle bracket is a shift-assign; a single one is a comparison.
    it "counts a shift assignment" do
      expect(described_class.assigned_ivars("@buffer <<= x\n")).to eq(%w[buffer])
      expect(described_class.assigned_ivars("@shift >>= x\n")).to eq(%w[shift])
      expect(described_class.assigned_ivars("@a <= b\n")).to eq([])
      expect(described_class.assigned_ivars("@a >= b\n")).to eq([])
    end

    it "names the templates the body renders" do
      expect(described_class.rendered_templates(action_source)).to eq(%w[edit])
    end

    it "names the instance variables a json or xml response consumes" do
      expect(described_class.rendered_ivars(action_source)).to eq(%w[post])
      expect(described_class.rendered_ivars("render xml: @widget")).to eq(%w[widget])
      expect(described_class.rendered_ivars("render json: @order, status: :created")).to eq(%w[order])
      expect(described_class.rendered_ivars('redirect_to @post, notice: "ok"')).to eq([])
    end

    it "answers the body of the named method with the lines it occupies" do
      source = "class C\n  def show\n    @a = 1\n  end\n\n  def edit; end\nend\n"

      expect(described_class.method_body(source, "show"))
        .to eq(code: "  def show\n    @a = 1\n  end", start_line: 2, end_line: 4)
      expect(described_class.method_body(source, "nope")).to be_nil
    end

    it "answers the same body for an action named in another case" do
      source = "class C\n  def show\n    @a = 1\n  end\n\n  def edit; end\nend\n"

      expect(described_class.method_body(source, "Show"))
        .to eq(code: "  def show\n    @a = 1\n  end", start_line: 2, end_line: 4)
    end
  end
end
