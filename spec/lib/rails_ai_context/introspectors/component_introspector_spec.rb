# frozen_string_literal: true

require "spec_helper"
require "tmpdir"
require "fileutils"

RSpec.describe RailsAiContext::Introspectors::ComponentIntrospector do
  let(:introspector) { described_class.new(Rails.application) }

  describe "#call" do
    subject(:result) { introspector.call }

    it "does not return an error" do
      expect(result).not_to have_key(:error)
    end

    it "discovers ViewComponent components" do
      names = result[:components].map { |c| c[:name] }
      expect(names).to include("AlertComponent", "CardComponent")
    end

    it "detects component type as view_component" do
      alert = result[:components].find { |c| c[:name] == "AlertComponent" }
      expect(alert[:type]).to eq(:view_component)
    end

    it "extracts renders_one slots" do
      alert = result[:components].find { |c| c[:name] == "AlertComponent" }
      slot_names = alert[:slots].select { |s| s[:type] == :one }.map { |s| s[:name] }
      expect(slot_names).to include("icon")
    end

    it "extracts renders_many slots" do
      alert = result[:components].find { |c| c[:name] == "AlertComponent" }
      slot_names = alert[:slots].select { |s| s[:type] == :many }.map { |s| s[:name] }
      expect(slot_names).to include("actions")
    end

    it "extracts initialize props" do
      alert = result[:components].find { |c| c[:name] == "AlertComponent" }
      prop_names = alert[:props].map { |p| p[:name] }
      expect(prop_names).to include("type", "dismissible")
    end

    it "extracts prop defaults" do
      alert = result[:components].find { |c| c[:name] == "AlertComponent" }
      type_prop = alert[:props].find { |p| p[:name] == "type" }
      expect(type_prop[:default]).to eq(":info")
    end

    it "detects sidecar template assets" do
      alert = result[:components].find { |c| c[:name] == "AlertComponent" }
      expect(alert[:sidecar_assets]).to include("alert_component.html.erb")
    end

    it "extracts card component slots" do
      card = result[:components].find { |c| c[:name] == "CardComponent" }
      slot_names = card[:slots].map { |s| s[:name] }
      expect(slot_names).to include("header", "footer", "badges")
    end

    it "detects Phlex components inheriting from a custom base class" do
      greeting = result[:components].find { |c| c[:name] == "GreetingComponent" }
      expect(greeting).not_to be_nil
      expect(greeting[:type]).to eq(:phlex)
    end

    it "builds a summary" do
      expect(result[:summary]).to be_a(Hash)
      expect(result[:summary][:total]).to be >= 2
      expect(result[:summary][:view_component]).to be >= 2
      expect(result[:summary][:with_slots]).to be >= 2
    end

    it "extracts enum values from hash constants" do
      badge = result[:components].find { |c| c[:name] == "BadgeComponent" }
      variant_prop = badge[:props].find { |p| p[:name] == "variant" }
      expect(variant_prop[:values]).to contain_exactly("primary", "secondary", "success")
    end

    it "extracts enum values from array constants" do
      badge = result[:components].find { |c| c[:name] == "BadgeComponent" }
      size_prop = badge[:props].find { |p| p[:name] == "size" }
      expect(size_prop[:values]).to contain_exactly("sm", "md", "lg")
    end

    it "extracts enum values from case statements" do
      alert = result[:components].find { |c| c[:name] == "AlertComponent" }
      type_prop = alert[:props].find { |p| p[:name] == "type" }
      expect(type_prop[:values]).to include("success", "error", "warning")
    end

    it "does not add values to props without enumerables" do
      greeting = result[:components].find { |c| c[:name] == "GreetingComponent" }
      name_prop = greeting[:props].find { |p| p[:name] == "name" }
      expect(name_prop).not_to have_key(:values)
    end
  end

  # Every app of any size puts a class or two of its own between a component
  # and ViewComponent::Base, and one level of name compare typed all of them
  # "unknown" - on one app 156 of 559.
  # Every other kind of code is read under an in-repo engine; components were
  # read from the root tree only, so 398 of one app's 559 were invisible and
  # asking for one by name answered not found.
  # OpenProject keeps 93 previews under lookbook/previews, set in an
  # initializer; reading only the default directories answered "With
  # previews: 0".
  describe "an app that keeps its previews where its config says" do
    it "links a component to its preview in a configured directory and in the default one" do
      Dir.mktmpdir do |dir|
        FileUtils.mkdir_p(File.join(dir, "app", "components", "common"))
        FileUtils.mkdir_p(File.join(dir, "config", "initializers"))
        FileUtils.mkdir_p(File.join(dir, "lookbook", "previews", "common"))
        FileUtils.mkdir_p(File.join(dir, "spec", "components", "previews"))
        File.write(File.join(dir, "app", "components", "common", "list_component.rb"), "module Common\n  class ListComponent < ViewComponent::Base\n  end\nend\n")
        File.write(File.join(dir, "app", "components", "badge_component.rb"), "class BadgeComponent < ViewComponent::Base\nend\n")
        File.write(File.join(dir, "app", "components", "plain_component.rb"), "class PlainComponent < ViewComponent::Base\nend\n")
        File.write(File.join(dir, "config", "initializers", "lookbook.rb"), <<~RUBY)
          Rails.application.configure do
            config.view_component.previews.paths += [
              Rails.root.join("lookbook/previews").to_s
            ]
          end
        RUBY
        File.write(File.join(dir, "lookbook", "previews", "common", "list_component_preview.rb"),
                   "module Common\n  class ListComponentPreview < ViewComponent::Preview\n  end\nend\n")
        File.write(File.join(dir, "spec", "components", "previews", "badge_component_preview.rb"),
                   "class BadgeComponentPreview < ViewComponent::Preview\nend\n")
        FileUtils.mkdir_p(File.join(dir, "app", "components", "users"))
        File.write(File.join(dir, "app", "components", "users", "avatar_component.rb"),
                   "module Users\n  class AvatarComponent < ViewComponent::Base\n  end\nend\n")
        FileUtils.mkdir_p(File.join(dir, "lookbook", "previews", "open_project", "users"))
        File.write(File.join(dir, "lookbook", "previews", "open_project", "users", "avatar_component_preview.rb"), <<~RUBY)
          module OpenProject::Users
            class AvatarComponentPreview < Lookbook::Preview
              def default
                render(Users::AvatarComponent.new(user: nil))
              end
            end
          end
        RUBY

        result = described_class.new(RailsAiContext::StaticApp.new(dir)).call
        previews = result[:components].to_h { |c| [ c[:name], c[:preview] ] }

        expect(previews).to eq(
          "BadgeComponent" => "spec/components/previews/badge_component_preview.rb",
          "Common::ListComponent" => "lookbook/previews/common/list_component_preview.rb",
          "PlainComponent" => nil,
          "Users::AvatarComponent" => "lookbook/previews/open_project/users/avatar_component_preview.rb"
        )
        expect(result[:summary][:with_previews]).to eq(3)
      end
    end
  end

  # Consul's Admin::BudgetsWizard::BaseComponent is a base four components
  # inherit from, not one a view renders: it is named apart, as service and
  # job bases are.
  describe "an app with an abstract base component" do
    it "names the base apart and leaves it out of the count" do
      Dir.mktmpdir do |dir|
        wizard = File.join(dir, "app", "components", "wizard")
        FileUtils.mkdir_p(wizard)
        File.write(File.join(wizard, "base_component.rb"), "class Wizard::BaseComponent < ViewComponent::Base\nend\n")
        File.write(File.join(wizard, "step_component.rb"), "class Wizard::StepComponent < Wizard::BaseComponent\nend\n")
        File.write(File.join(dir, "app", "components", "base_card_component.rb"), "class BaseCardComponent < ViewComponent::Base\nend\n")
        File.write(File.join(dir, "app", "components", "application_row_component.rb"), "class ApplicationRowComponent < ViewComponent::Base\nend\n")

        result = described_class.new(RailsAiContext::StaticApp.new(dir)).call

        expect(result[:bases].map { |c| c[:name] }).to eq([ "Wizard::BaseComponent" ])
        expect(result[:components].map { |c| c[:name] }).to eq(%w[ApplicationRowComponent BaseCardComponent Wizard::StepComponent])
        expect(result[:summary][:total]).to eq(3)
      end
    end
  end

  describe "an app whose engines hold components" do
    it "reads components from every app tree, typed the same way" do
      Dir.mktmpdir do |dir|
        FileUtils.mkdir_p(File.join(dir, "app", "components"))
        FileUtils.mkdir_p(File.join(dir, "modules", "meetings", "app", "components", "meetings"))
        FileUtils.mkdir_p(File.join(dir, "modules", "meetings", "lib", "open_project", "meetings"))
        File.write(File.join(dir, "modules", "meetings", "lib", "open_project", "meetings", "engine.rb"), "module OpenProject\nend\n")
        File.write(File.join(dir, "app", "components", "application_component.rb"), <<~RUBY)
          class ApplicationComponent < ViewComponent::Base
          end
        RUBY
        File.write(File.join(dir, "app", "components", "alert_component.rb"), <<~RUBY)
          class AlertComponent < ApplicationComponent
          end
        RUBY
        File.write(File.join(dir, "modules", "meetings", "app", "components", "meetings", "blank_slate_component.rb"), <<~RUBY)
          module Meetings
            class BlankSlateComponent < ApplicationComponent
            end
          end
        RUBY

        result = described_class.new(RailsAiContext::StaticApp.new(dir)).call
        entry = result[:components].find { |c| c[:name] == "Meetings::BlankSlateComponent" }

        expect(entry).not_to be_nil
        expect(entry[:type]).to eq(:view_component)
        expect(entry[:file]).to eq("modules/meetings/app/components/meetings/blank_slate_component.rb")
        expect(result[:summary][:total]).to eq(2)
      end
    end
  end

  describe "an app whose components descend through its own base classes" do
    def components(&build)
      Dir.mktmpdir do |dir|
        FileUtils.mkdir_p(File.join(dir, "app", "components"))
        build.call(File.join(dir, "app", "components"))
        return described_class.new(RailsAiContext::StaticApp.new(dir)).call
      end
    end

    it "follows the chain through the app's own bases" do
      result = components do |dir|
        FileUtils.mkdir_p(File.join(dir, "admin"))
        File.write(File.join(dir, "application_component.rb"), <<~RUBY)
          class ApplicationComponent < ViewComponent::Base
          end
        RUBY
        File.write(File.join(dir, "admin", "image_component.rb"), <<~RUBY)
          class Admin::ImageComponent < ApplicationComponent
          end
        RUBY
        File.write(File.join(dir, "admin", "image_card_component.rb"), <<~RUBY)
          class Admin::ImageCardComponent < Admin::ImageComponent
          end
        RUBY
      end

      types = result[:components].to_h { |c| [ c[:name], c[:type] ] }
      expect(types).to eq("Admin::ImageComponent" => :view_component,
                          "Admin::ImageCardComponent" => :view_component)
    end

    # A sidecar file reopens the parent namespace class to nest the component
    # in it, so the first class the file opens names no superclass and is not
    # what the file is named for.
    it "reads the class the file is named for, not the namespace it reopens" do
      result = components do |dir|
        FileUtils.mkdir_p(File.join(dir, "common", "list_component"))
        File.write(File.join(dir, "common", "list_component.rb"), <<~RUBY)
          module Common
            class ListComponent < ViewComponent::Base
            end
          end
        RUBY
        File.write(File.join(dir, "common", "list_component", "item.rb"), <<~RUBY)
          module Common
            class ListComponent
              class Item < ViewComponent::Base
              end
            end
          end
        RUBY
      end

      item = result[:components].find { |c| c[:file].end_with?("list_component/item.rb") }
      expect(item[:name]).to eq("Common::ListComponent::Item")
      expect(item[:type]).to eq(:view_component)
    end

    it "counts what it could not place, so the buckets add up to the total" do
      result = components do |dir|
        File.write(File.join(dir, "table_builder.rb"), <<~RUBY)
          class TableBuilder
          end
        RUBY
        File.write(File.join(dir, "alert_component.rb"), <<~RUBY)
          class AlertComponent < ViewComponent::Base
          end
        RUBY
      end

      summary = result[:summary]
      expect(summary[:unclassified]).to eq(1)
      expect(summary[:view_component] + summary[:phlex] + summary[:unclassified]).to eq(summary[:total])
    end
  end
end
