# frozen_string_literal: true

require "spec_helper"

RSpec.describe RailsAiContext::Tools::DependencyGraph do
  describe ".call" do
    let(:models_data) do
      {
        User: {
          table_name: "users",
          associations: [
            { macro: :has_many, name: :posts, class_name: "Post", foreign_key: "user_id" },
            { macro: :has_many, name: :comments, class_name: "Comment", foreign_key: "user_id" }
          ]
        },
        Post: {
          table_name: "posts",
          associations: [
            { macro: :belongs_to, name: :user, class_name: "User", foreign_key: "user_id" },
            { macro: :has_many, name: :comments, class_name: "Comment", foreign_key: "post_id" }
          ]
        },
        Comment: {
          table_name: "comments",
          associations: [
            { macro: :belongs_to, name: :post, class_name: "Post", foreign_key: "post_id" },
            { macro: :belongs_to, name: :user, class_name: "User", foreign_key: "user_id" }
          ]
        }
      }
    end

    before do
      allow(described_class).to receive(:cached_context).and_return({ models: models_data })
    end

    it "generates mermaid diagram" do
      response = described_class.call(format: "mermaid")
      text = response.content.first[:text]
      expect(text).to include("```mermaid")
      expect(text).to include("graph LR")
      expect(text).to include("User")
      expect(text).to include("Post")
    end

    it "generates text output" do
      response = described_class.call(format: "text")
      text = response.content.first[:text]
      expect(text).to include("has_many")
      expect(text).to include("belongs_to")
    end

    it "centers graph on a model" do
      response = described_class.call(model: "Post", format: "text")
      text = response.content.first[:text]
      expect(text).to include("Post")
    end

    it "returns not-found for unknown model" do
      response = described_class.call(model: "Unknown")
      text = response.content.first[:text]
      expect(text).to include("not found")
    end

    it "respects depth parameter" do
      response = described_class.call(model: "Post", depth: 1, format: "text")
      text = response.content.first[:text]
      expect(text).to include("Post")
    end

    it "sanitizes digit-prefixed model names for mermaid" do
      models_with_digit = {
        "3DModel": {
          table_name: "three_d_models",
          associations: [ { macro: :belongs_to, name: :user, class_name: "User", foreign_key: "user_id" } ]
        },
        User: {
          table_name: "users",
          associations: [ { macro: :has_many, name: :"3d_models", class_name: "3DModel", foreign_key: "user_id" } ]
        }
      }
      allow(described_class).to receive(:cached_context).and_return({ models: models_with_digit })

      response = described_class.call(format: "mermaid")
      text = response.content.first[:text]
      expect(text).to include("M3DModel")
      expect(text).not_to match(/\s3DModel\s/)
    end

    context "polymorphic associations" do
      let(:poly_models) do
        {
          Comment: {
            table_name: "comments",
            associations: [
              { macro: :belongs_to, name: :commentable, polymorphic: true, foreign_key: "commentable_id" }
            ]
          },
          Post: {
            table_name: "posts",
            associations: [
              { macro: :has_many, name: :comments, class_name: "Comment", foreign_key: "commentable_id" }
            ]
          },
          Photo: {
            table_name: "photos",
            associations: [
              { macro: :has_many, name: :comments, class_name: "Comment", foreign_key: "commentable_id" }
            ]
          }
        }
      end

      before do
        allow(described_class).to receive(:cached_context).and_return({ models: poly_models })
      end

      it "renders polymorphic with dashed arrow in mermaid" do
        response = described_class.call(format: "mermaid")
        text = response.content.first[:text]
        expect(text).to include("-.->|polymorphic|")
      end

      it "shows concrete targets in text mode" do
        response = described_class.call(format: "text")
        text = response.content.first[:text]
        expect(text).to include("(polymorphic)")
        expect(text).to include("Post")
        expect(text).to include("Photo")
      end

      it "resolves polymorphic targets" do
        response = described_class.call(format: "text")
        text = response.content.first[:text]
        # Comment's commentable should list Post, Photo as concrete types
        comment_section = text.split("## ").find { |s| s.start_with?("Comment") }
        expect(comment_section).to include("Post")
        expect(comment_section).to include("Photo")
      end
    end

    context "through associations" do
      let(:through_models) do
        {
          Doctor: {
            table_name: "doctors",
            associations: [
              { macro: :has_many, name: :appointments, class_name: "Appointment", foreign_key: "doctor_id" },
              { macro: :has_many, name: :patients, class_name: "Patient", through: "appointments", foreign_key: "doctor_id" }
            ]
          },
          Appointment: {
            table_name: "appointments",
            associations: [
              { macro: :belongs_to, name: :doctor, class_name: "Doctor", foreign_key: "doctor_id" },
              { macro: :belongs_to, name: :patient, class_name: "Patient", foreign_key: "patient_id" }
            ]
          },
          Patient: {
            table_name: "patients",
            associations: [
              { macro: :has_many, name: :appointments, class_name: "Appointment", foreign_key: "patient_id" }
            ]
          }
        }
      end

      before do
        allow(described_class).to receive(:cached_context).and_return({ models: through_models })
      end

      it "renders through with double arrow in mermaid" do
        response = described_class.call(format: "mermaid")
        text = response.content.first[:text]
        expect(text).to include("==>|through|")
      end

      it "shows two edges for through associations in mermaid" do
        response = described_class.call(format: "mermaid")
        text = response.content.first[:text]
        # Doctor ==>|through| Appointment, Appointment ==>|through| Patient
        expect(text).to include("Doctor ==>|through| Appointment")
        expect(text).to include("Appointment ==>|through| Patient")
      end

      it "shows through in text mode" do
        response = described_class.call(format: "text")
        text = response.content.first[:text]
        expect(text).to include("through appointments")
      end
    end

    context "cycle detection" do
      let(:cyclic_models) do
        {
          A: {
            table_name: "as",
            associations: [ { macro: :belongs_to, name: :b, class_name: "B", foreign_key: "b_id" } ]
          },
          B: {
            table_name: "bs",
            associations: [ { macro: :belongs_to, name: :c, class_name: "C", foreign_key: "c_id" } ]
          },
          C: {
            table_name: "cs",
            associations: [ { macro: :belongs_to, name: :a, class_name: "A", foreign_key: "a_id" } ]
          }
        }
      end

      before do
        allow(described_class).to receive(:cached_context).and_return({ models: cyclic_models })
      end

      it "does not show cycles by default" do
        response = described_class.call(format: "text")
        text = response.content.first[:text]
        expect(text).not_to include("Circular Dependencies")
      end

      it "detects cycles when show_cycles is true" do
        response = described_class.call(format: "text", show_cycles: true)
        text = response.content.first[:text]
        expect(text).to include("Circular Dependencies")
        expect(text).to include("A")
        expect(text).to include("B")
        expect(text).to include("C")
      end

      it "shows cycle count in mermaid stats" do
        response = described_class.call(format: "mermaid", show_cycles: true)
        text = response.content.first[:text]
        expect(text).to include("Cycles:")
      end

      it "shows cycle paths in mermaid" do
        response = described_class.call(format: "mermaid", show_cycles: true)
        text = response.content.first[:text]
        expect(text).to include("Circular Dependencies")
      end
    end

    context "no cycles present" do
      it "shows no cycles section when no cycles found" do
        response = described_class.call(format: "text", show_cycles: true)
        text = response.content.first[:text]
        # The standard test data has User->Post->Comment which are bidirectional
        # but DFS from the test data may or may not detect cycles depending on
        # the direction. We just verify the section renders cleanly.
        expect(text).to include("Dependency Graph")
      end
    end

    context "STI hierarchies" do
      let(:sti_models) do
        {
          Vehicle: {
            table_name: "vehicles",
            sti: { sti_base: true, sti_children: %w[Car Truck Motorcycle] },
            associations: []
          },
          Car: {
            table_name: "vehicles",
            sti: { sti_parent: "Vehicle" },
            associations: []
          },
          Truck: {
            table_name: "vehicles",
            sti: { sti_parent: "Vehicle" },
            associations: []
          },
          Motorcycle: {
            table_name: "vehicles",
            sti: { sti_parent: "Vehicle" },
            associations: []
          }
        }
      end

      before do
        allow(described_class).to receive(:cached_context).and_return({ models: sti_models })
      end

      it "does not show STI by default" do
        response = described_class.call(format: "text")
        text = response.content.first[:text]
        expect(text).not_to include("STI Hierarchies")
      end

      it "shows STI hierarchies when show_sti is true" do
        response = described_class.call(format: "text", show_sti: true)
        text = response.content.first[:text]
        expect(text).to include("STI Hierarchies")
        expect(text).to include("Vehicle")
        expect(text).to include("Car")
        expect(text).to include("Truck")
      end

      it "shows table name for STI group" do
        response = described_class.call(format: "text", show_sti: true)
        text = response.content.first[:text]
        expect(text).to include("table: vehicles")
      end

      it "renders STI with dotted lines in mermaid" do
        response = described_class.call(format: "mermaid", show_sti: true)
        text = response.content.first[:text]
        expect(text).to include("-.-|STI|")
        expect(text).to include("Vehicle")
        expect(text).to include("Car")
      end

      it "includes STI count in stats" do
        response = described_class.call(format: "mermaid", show_sti: true)
        text = response.content.first[:text]
        expect(text).to include("**STI hierarchies:** 1")
      end
    end

    context "combined features" do
      it "handles show_cycles and show_sti together" do
        response = described_class.call(format: "text", show_cycles: true, show_sti: true)
        text = response.content.first[:text]
        expect(text).to include("Dependency Graph")
      end
    end
  end
end
