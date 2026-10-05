# frozen_string_literal: true

require "spec_helper"
require "tmpdir"

RSpec.describe RailsAiContext::Introspectors::ControllerSettings do
  describe ".from_source" do
    it "reads the layout and each class-level setting as written" do
      source = <<~RUBY
        class UsersController < ApplicationController
          layout "admin", only: :index
          wrap_parameters :user, include: [:name,
                                           :email_address]
          allow_browser versions: :modern
          def index
            protect_from_forgery with: :null_session
          end
        end
      RUBY

      expect(described_class.from_source(source)).to eq(
        layout: { name: "admin", only: [ "index" ] },
        settings: [ "wrap_parameters :user, include: [:name, :email_address]", "allow_browser versions: :modern" ]
      )
    end

    it "reads a layout method, a block, false, and leaves nil to the lookup Rails does" do
      expect(described_class.from_source("class A\n  layout :pick\nend\n")).to eq(layout: { method: "pick" })
      expect(described_class.from_source("class A\n  layout ->(c) { 'x' }\nend\n")).to eq(layout: { block: 2 })
      expect(described_class.from_source("class A\n  layout false\nend\n")).to eq(layout: { name: false })
      expect(described_class.from_source("class A\n  layout nil\nend\n")).to eq({})
    end

    it "degrades on source it cannot parse" do
      expect(described_class.from_source("class A\n  layout 'x',\n")).to be_a(Hash)
      expect(described_class.from_source(nil)).to eq({})
    end
  end

  describe ".resolve" do
    around do |example|
      Dir.mktmpdir("controller-settings") do |root|
        @root = root
        FileUtils.mkdir_p(File.join(root, "app/controllers"))
        FileUtils.mkdir_p(File.join(root, "app/views/layouts"))
        File.write(File.join(root, "app/views/layouts/application.html.erb"), "")
        File.write(File.join(root, "app/views/layouts/admin.html.erb"), "")
        File.write(File.join(root, "app/views/layouts/posts.html.erb"), "")
        File.write(File.join(root, "app/controllers/application_controller.rb"), <<~RUBY)
          class ApplicationController < ActionController::Base
            allow_browser versions: :modern
            protect_from_forgery with: :exception
            add_flash_types :warning, :info
          end
        RUBY
        example.run
      end
    end

    def ctx(controllers)
      { controllers: { controllers: controllers } }
    end

    it "names a declared layout and the settings inherited from ApplicationController" do
      context = ctx("UsersController" => { parent_class: "ApplicationController", layout: { name: "admin", only: [ "index" ] },
                                           settings: [ "wrap_parameters :user" ] })

      resolved = described_class.resolve(context, "UsersController", root: @root)

      expect(resolved[:layout]).to eq(name: "admin", only: [ "index" ], from: "UsersController",
                                      otherwise: { name: "application", implied: true })
      expect(resolved[:settings]).to eq([
        { text: "allow_browser versions: :modern", from: "ApplicationController" },
        { text: "protect_from_forgery with: :exception", from: "ApplicationController" },
        { text: "add_flash_types :warning, :info", from: "ApplicationController" },
        { text: "wrap_parameters :user", from: "UsersController" }
      ])
    end

    it "finds the layout Rails looks up by the controller's name, then its ancestors'" do
      context = ctx("PostsController" => { parent_class: "ApplicationController", file: "app/controllers/posts_controller.rb" },
                    "TagsController" => { parent_class: "ApplicationController" })

      expect(described_class.resolve(context, "PostsController", root: @root)[:layout]).to eq(name: "posts", implied: true)
      expect(described_class.resolve(context, "TagsController", root: @root)[:layout]).to eq(name: "application", implied: true)
    end

    it "takes an ancestor's declaration over the name lookup, as the class attribute does" do
      context = ctx("Admin::BaseController" => { parent_class: "ApplicationController", layout: { name: "admin" } },
                    "Admin::PostsController" => { parent_class: "BaseController" })

      expect(described_class.resolve(context, "Admin::PostsController", root: @root)[:layout])
        .to eq(name: "admin", from: "Admin::BaseController")
    end

    it "says which ancestor it could not read instead of guessing" do
      context = ctx("ShopController" => { parent_class: "Spree::StoreController" })

      expect(described_class.resolve(context, "ShopController", root: @root)[:layout]).to eq(unread: "Spree::StoreController")
    end

    it "gives an API controller no layout" do
      context = ctx("Api::ThingsController" => { parent_class: "ActionController::API", api_controller: true })

      expect(described_class.resolve(context, "Api::ThingsController", root: @root)).to eq(settings: [])
    end
  end
end
