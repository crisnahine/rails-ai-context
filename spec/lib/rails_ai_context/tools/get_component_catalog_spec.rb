# frozen_string_literal: true

require "spec_helper"

RSpec.describe RailsAiContext::Tools::GetComponentCatalog do
  describe ".call" do
    let(:component_data) do
      {
        components: [
          {
            name: "AlertComponent", type: :view_component,
            file: "app/components/alert_component.rb",
            props: [ { name: "type", default: ":info" }, { name: "dismissible", default: "false" } ],
            slots: [ { name: "icon", type: :one }, { name: "actions", type: :many } ],
            sidecar_assets: [ "alert_component.html.erb" ]
          },
          {
            name: "CardComponent", type: :view_component,
            file: "app/components/card_component.rb",
            props: [ { name: "variant", default: ":default" } ],
            slots: [ { name: "header", type: :one }, { name: "footer", type: :one }, { name: "badges", type: :many } ],
            sidecar_assets: [ "card_component.html.erb" ]
          }
        ],
        summary: { total: 2, view_component: 2, phlex: 0, with_slots: 2, with_previews: 0 }
      }
    end

    before do
      allow(described_class).to receive(:cached_context).and_return({ components: component_data })
    end

    it "returns summary detail level" do
      response = described_class.call(detail: "summary")
      text = response.content.first[:text]
      expect(text).to include("AlertComponent")
      expect(text).to include("CardComponent")
      expect(text).to include("2 slots")
    end

    # "559 components (403 ViewComponent, 0 Phlex)" leaves 156 in no bucket
    # and reads as an arithmetic error.
    it "names the components it could not place, so the header adds up" do
      component_data[:summary] = { total: 3, view_component: 2, phlex: 0, unclassified: 1,
                                   with_slots: 2, with_previews: 0 }

      text = described_class.call(detail: "summary").content.first[:text]

      expect(text).to include("**Total:** 3 components (2 ViewComponent, 0 Phlex, 1 of no known base class)")
    end

    it "leaves the remainder out of the header when every component is placed" do
      text = described_class.call(detail: "summary").content.first[:text]

      expect(text).to include("**Total:** 2 components (2 ViewComponent, 0 Phlex)")
    end

    # One short name under three namespaces is a question, not a resolution:
    # answering with the first in sorted order gave one component's props for
    # another's.
    context "when a short name names more than one component" do
      before do
        component_data[:components] = [
          { name: "Activities::ItemComponent", type: :view_component,
            file: "app/components/activities/item_component.rb", props: [], slots: [] },
          { name: "Admin::Enumerations::ItemComponent", type: :view_component,
            file: "app/components/admin/enumerations/item_component.rb", props: [], slots: [] }
        ]
      end

      it "lists them and asks for the full name" do
        text = described_class.call(component: "ItemComponent").content.first[:text]

        expect(text).to include("Component 'ItemComponent' names 2 components:")
        expect(text).to include("**Activities::ItemComponent** (`app/components/activities/item_component.rb`)")
        expect(text).to include("**Admin::Enumerations::ItemComponent**")
        expect(text).to include("Activities::ItemComponent`")
      end

      it "answers the one asked for by its full name" do
        text = described_class.call(component: "Admin::Enumerations::ItemComponent").content.first[:text]

        expect(text).to include("# Admin::Enumerations::ItemComponent")
        expect(text).not_to include("names 2 components")
      end
    end

    it "finds a namespaced component by the name without its namespace" do
      component_data[:components][0][:name] = "Admin::Flash::AlertComponent"

      text = described_class.call(component: "alert").content.first[:text]

      expect(text).to include("# Admin::Flash::AlertComponent")
    end

    it "names the base components apart from the catalog" do
      component_data[:bases] = [ { name: "Wizard::BaseComponent", type: :view_component,
                                   file: "app/components/wizard/base_component.rb", props: [], slots: [] } ]

      text = described_class.call(detail: "summary").content.first[:text]
      expect(text).to include("_Base classes not counted as components: Wizard::BaseComponent.")

      base = described_class.call(component: "Wizard::BaseComponent").content.first[:text]
      expect(base).to include("# Wizard::BaseComponent")
    end

    it "returns standard detail with props and slots" do
      response = described_class.call(detail: "standard")
      text = response.content.first[:text]
      expect(text).to include("Props")
      expect(text).to include("type")
      expect(text).to include("Slots")
      expect(text).to include("icon")
    end

    context "with enum values on props" do
      let(:component_data) do
        {
          components: [
            {
              name: "ButtonComponent", type: :phlex,
              file: "app/components/button_component.rb",
              props: [
                { name: "variant", default: ":primary", values: %w[primary secondary ghost destructive] },
                { name: "size", default: ":md", values: %w[sm md lg] },
                { name: "icon", default: "false" }
              ],
              slots: []
            }
          ],
          summary: { total: 1, view_component: 0, phlex: 1, with_slots: 0, with_previews: 0 }
        }
      end

      it "renders valid values for props with enums" do
        response = described_class.call(component: "button", detail: "standard")
        text = response.content.first[:text]
        expect(text).to include("values: primary, secondary, ghost, destructive")
        expect(text).to include("values: sm, md, lg")
      end

      it "does not render values for props without enums" do
        response = described_class.call(component: "button", detail: "standard")
        text = response.content.first[:text]
        icon_line = text.lines.find { |l| l.include?("`icon`") }
        expect(icon_line).not_to include("values:")
      end
    end

    it "filters by component name" do
      response = described_class.call(component: "alert")
      text = response.content.first[:text]
      expect(text).to include("AlertComponent")
      expect(text).not_to include("CardComponent")
    end

    it "returns not-found for unknown component" do
      response = described_class.call(component: "nonexistent")
      text = response.content.first[:text]
      expect(text).to include("not found")
    end

    it "generates usage examples in full mode" do
      response = described_class.call(component: "alert", detail: "full")
      text = response.content.first[:text]
      expect(text).to include("Usage")
      expect(text).to include("render")
    end

    context "no-props no-slots component" do
      before do
        data = {
          components: [
            {
              name: "DividerComponent", type: :view_component,
              file: "app/components/divider_component.rb",
              props: [], slots: [],
              sidecar_assets: [ "divider_component.html.erb" ]
            }
          ],
          summary: { total: 1, view_component: 1, phlex: 0, with_slots: 0, with_previews: 0 }
        }
        allow(described_class).to receive(:cached_context).and_return({ components: data })
      end

      it "generates inline render without block" do
        response = described_class.call(component: "divider", detail: "full")
        text = response.content.first[:text]
        expect(text).to include("<%= render DividerComponent.new %>")
        expect(text).not_to include("do %>")
      end
    end

    context "props-only component (no slots)" do
      before do
        data = {
          components: [
            {
              name: "BadgeComponent", type: :view_component,
              file: "app/components/badge_component.rb",
              props: [ { name: "label", default: nil }, { name: "color", default: ":gray" } ],
              slots: [],
              sidecar_assets: [ "badge_component.html.erb" ]
            }
          ],
          summary: { total: 1, view_component: 1, phlex: 0, with_slots: 0, with_previews: 0 }
        }
        allow(described_class).to receive(:cached_context).and_return({ components: data })
      end

      it "generates render with args and block for optional content" do
        response = described_class.call(component: "badge", detail: "full")
        text = response.content.first[:text]
        expect(text).to include("render BadgeComponent.new(label: value, color: :gray)")
        expect(text).to include("do %>")
      end
    end

    context "when the app is API-only" do
      around do |example|
        Dir.mktmpdir("api-no-components") do |dir|
          @root = dir
          example.run
        end
      end

      before do
        allow(RailsAiContext).to receive(:default_app).and_return(RailsAiContext::StaticApp.new(@root))
        allow(described_class).to receive(:cached_context).and_return(
          api: { api_only: true },
          components: { components: [] }
        )
      end

      it "reports API-only apps as not applicable instead of an empty listing" do
        response = described_class.call
        text = response.content.first[:text]
        expect(text).to include("Not applicable")
        expect(text).to include("API-only")
      end
    end
  end
end
