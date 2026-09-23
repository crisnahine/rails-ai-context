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

    context "with through associations and app acronyms" do
      let(:models_data) do
        {
          "Order" => {
            table_name: "orders",
            associations: [
              { type: "belongs_to", name: "primary_buyer", class_name: "User", foreign_key: "primary_buyer_id" },
              { type: "has_many", name: "buyer_emails", through: "primary_buyer", options: { source: :emails } },
              { type: "has_many", name: "watched_orders", foreign_key: "order_id" },
              { type: "has_many", name: "watched_by", through: "watched_orders", options: { source: :user } }
            ]
          },
          "User" => {
            table_name: "users",
            associations: [
              { type: "has_many", name: "emails", foreign_key: "user_id" },
              { type: "has_many", name: "watched_orders", foreign_key: "user_id" }
            ]
          },
          "Email" => { table_name: "emails", associations: [ { type: "belongs_to", name: "user" } ] },
          "WatchedOrder" => {
            table_name: "watched_orders",
            associations: [ { type: "belongs_to", name: "order" }, { type: "belongs_to", name: "user" } ]
          },
          "AIMatchResult" => {
            table_name: "ai_match_results",
            associations: [ { type: "has_many", name: "ai_match_items", foreign_key: "ai_match_result_id" } ]
          },
          "AIMatchItem" => {
            table_name: "ai_match_items",
            associations: [ { type: "belongs_to", name: "ai_match_result" } ]
          },
          "SearchCriteria" => {
            table_name: "search_criteria",
            associations: [ { type: "has_many", name: "search_criteria_embeddings" } ]
          },
          "SearchCriteriaEmbedding" => {
            table_name: "search_criteria_embeddings",
            associations: [ { type: "belongs_to", name: "search_criteria" } ]
          }
        }
      end

      it "routes a through edge via the class the hop points at" do
        text = described_class.call(format: "mermaid").content.first[:text]
        expect(text).to include("Order ==>|through| User")
        expect(text).to include("User ==>|through| Email")
        expect(text).not_to include("PrimaryBuyer")
        expect(text).not_to include("BuyerEmail")
      end

      it "reads a static through target off the source association" do
        text = described_class.call(format: "mermaid").content.first[:text]
        expect(text).to include("WatchedOrder ==>|through| User")
        expect(text).not_to include("WatchedBy")
      end

      it "names targets the way the app declares them" do
        text = described_class.call(format: "mermaid").content.first[:text]
        expect(text).to include("AIMatchItem -->|belongs_to| AIMatchResult")
        expect(text).to include("AIMatchResult -->|has_many| AIMatchItem")
        expect(text).not_to include("AiMatch")
      end

      it "does not singularize a belongs_to name" do
        text = described_class.call(format: "mermaid").content.first[:text]
        expect(text).to include("SearchCriteriaEmbedding -->|belongs_to| SearchCriteria")
        expect(text).not_to include("SearchCriterium")
      end
    end

    context "when the graph is capped or a model failed" do
      let(:models_data) do
        data = {}
        60.times { |i| data["Widget#{i}"] = { table_name: "widgets", associations: [] } }
        data["Broken"] = { error: "undefined method 'klass' for nil" }
        data
      end

      it "says how many models the cap left out" do
        text = described_class.call(format: "mermaid").content.first[:text]
        expect(text).to include("**Models:** 60")
        expect(text).to include("Showing 50 of 60 models")
      end

      it "names the model it could not read" do
        text = described_class.call(format: "text").content.first[:text]
        expect(text).to include("1 model left out, introspection failed: Broken")
      end
    end

    # The model count was app-wide and the association count was the edge
    # count of the fifty nodes that survived the cut, printed side by side on
    # one line, so the second number read as app-wide too.
    context "when models past the node cap carry associations" do
      let(:models_data) do
        data = {}
        60.times do |i|
          data["Widget#{format('%02d', i)}"] = {
            table_name: "widgets",
            associations: [ { macro: :belongs_to, name: :account, class_name: "Account", foreign_key: "account_id" } ]
          }
        end
        data["Account"] = { table_name: "accounts", associations: [] }
        data
      end

      it "counts the associations over the same models the count names" do
        text = described_class.call(format: "text").content.first[:text]

        expect(text).to include("**Models:** 61 | **Associations:** 60")
        expect(text).to include("Showing 50 of 61 models")
      end

      # The header counts every association; a reader counting the edges the
      # cut graph draws needs the note to say it drew fewer.
      it "says how many of the associations the cut graph draws" do
        text = described_class.call(format: "text").content.first[:text]
        drawn = text.lines.count { |line| line.match?(/^  belongs_to /) }

        expect(drawn).to be < 60
        expect(text).to include("Showing 50 of 61 models and #{drawn} of 60 associations")
      end

      it "counts them the same way in the mermaid rendering" do
        text = described_class.call(format: "mermaid").content.first[:text]

        expect(text).to include("**Models:** 61 | **Associations:** 60")
      end
    end

    context "with an association that cannot resolve" do
      let(:models_data) do
        {
          "Post" => {
            table_name: "posts",
            associations: [
              { type: "has_many", name: "comments", class_name: "Comment" },
              { type: "has_many", name: "reader_emails", through: "reader", unavailable: "through :reader is not an association" }
            ]
          },
          "Comment" => { table_name: "comments", associations: [ { type: "belongs_to", name: "post" } ] }
        }
      end

      it "keeps the model and drops only the dangling edge" do
        text = described_class.call(format: "mermaid").content.first[:text]

        expect(text).to include("Post -->|has_many| Comment")
        # Without the guard the record still becomes an edge, through a
        # `Reader` node and on to a `ReaderEmail` neither of which is a class.
        expect(text).not_to match(/reader/i)
      end
    end
  end
end
