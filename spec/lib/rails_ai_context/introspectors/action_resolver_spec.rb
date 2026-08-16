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
end
