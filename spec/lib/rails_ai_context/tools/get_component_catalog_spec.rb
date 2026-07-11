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
      before do
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
