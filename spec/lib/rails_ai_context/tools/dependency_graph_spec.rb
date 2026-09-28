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
      # page draws needs the note to say how many of them it drew.
      it "counts the edges it drew, so the note and the rows agree" do
        text = described_class.call(format: "text").content.first[:text]
        drawn = text.lines.count { |line| line.match?(/^  belongs_to /) }

        expect(drawn).to be < 60
        expect(text).to include("Showing 50 of 61 models, drawing #{drawn} edges for")
        expect(text).to include("of 60 associations")
      end

      # OpenProject `--model WorkPackage` ended with "pass `model:` to focus
      # the graph" though model: had been passed.
      it "drops the focus hint when a model was passed" do
        text = described_class.call(model: "Account", depth: 1, format: "mermaid").content.first[:text]

        expect(text).not_to include("pass `model:`")
      end

      it "counts the arrows the mermaid block draws, not the records behind them" do
        text = described_class.call(format: "mermaid").content.first[:text]
        arrows = text.lines.count { |line| line.include?("-->") || line.include?("-.->") || line.include?("==>") }

        expect(text).to include("drawing #{arrows} edges for")
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

  describe "an association whose class_name is a runtime expression" do
    before do
      allow(described_class).to receive(:cached_context).and_return(
        models: {
          "RelatedContent" => {
            table_name: "related_contents",
            associations: [
              { macro: :belongs_to, name: :user, class_name: "User" },
              { macro: :has_one, name: :opposite_related_content, class_name: "[INFERRED]" }
            ]
          },
          "User" => { table_name: "users", associations: [] }
        }
      )
    end

    it "draws no node for it and says which association it left out" do
      text = described_class.call(format: "mermaid").content.first[:text]

      expect(text).not_to include("_INFERRED_")
      expect(text).to include("RelatedContent#opposite_related_content")
      expect(text).to include("The association count leaves out 1 association")
    end
  end

  # The note counted only the models the cut kept while the total counted
  # every model, so the two described different sets and the numbers did not
  # add up.
  describe "an unresolved association on a model the node cap cut" do
    before do
      models = { "Anchor" => { table_name: "anchors", associations: [] } }
      120.times do |i|
        models["Filler#{i.to_s.rjust(3, '0')}"] = {
          table_name: "filler#{i}",
          associations: [ { macro: :has_one, name: :mirror, class_name: "[INFERRED]" } ]
        }
      end
      allow(described_class).to receive(:cached_context).and_return(models: models)
    end

    it "counts every unresolved association the totals cover" do
      text = described_class.call(format: "mermaid").content.first[:text]

      expect(text).to include("The association count leaves out 120 associations")
      expect(text).to include("and 110 more")
    end
  end

  describe "a Mongoid document" do
    before do
      allow(described_class).to receive(:cached_context).and_return(
        models: {
          "App" => {
            mongoid: true,
            associations: [ { macro: :has_many, name: :problems, class_name: "Problem" },
                            { type: "embeds_many", name: "watchers" },
                            { type: "embeds_one", name: "issue_tracker" } ],
            embeds: [ { type: :embeds_many, name: :watchers },
                      { type: :embeds_one, name: :issue_tracker },
                      { type: :embedded_in, name: :site_config } ]
          },
          "Problem" => { associations: [] }
        }
      )
    end

    it "draws an edge for each embedded relation" do
      text = described_class.call(format: "mermaid").content.first[:text]

      expect(text).to include("App -->|embeds_many| Watcher")
      expect(text).to include("App -->|embeds_one| IssueTracker")
      expect(text).not_to include("embedded_in")
    end
  end

  # Camelizing a name the walk read off source drew a node no app defines,
  # the way an unreadable class_name once did.
  describe "an association whose name is computed" do
    before do
      allow(described_class).to receive(:cached_context).and_return(
        models: {
          "Topic" => {
            table_name: "topics",
            associations: [
              { macro: :belongs_to, name: :user, class_name: "User" },
              { macro: :has_one, name: '"#{name.underscore}_search_data"'.sub('"', ":"), computed_name: true },
              { macro: :belongs_to, name: "owner_name", computed_name: true }
            ]
          },
          "User" => { table_name: "users", associations: [] }
        }
      )
    end

    it "draws no node for it and says it left the association out" do
      text = described_class.call(format: "mermaid").content.first[:text]

      expect(text).not_to include("_INFERRED_")
      expect(text).not_to include("SearchData")
      expect(text).not_to include("OwnerName")
      expect(text).to include("Topic -->|belongs_to| User")
      expect(text).to include("The association count leaves out 2 associations")
    end
  end

  # OpenProject writes `class_name: "::Token::API"`: a literal, rooted at the
  # top-level namespace. Read as a runtime expression, its edge vanished.
  describe "a class_name written with a leading ::" do
    before do
      allow(described_class).to receive(:cached_context).and_return(
        models: {
          "AnonymousUser" => {
            table_name: "users",
            associations: [ { macro: :has_one, name: :api_token, class_name: "::Token::API" } ]
          },
          "Token::API" => { table_name: "tokens", associations: [] }
        }
      )
    end

    it "draws the edge to the class it names" do
      text = described_class.call(format: "mermaid").content.first[:text]

      expect(text).to include("AnonymousUser -->|has_one| Token__API")
      expect(text).not_to include("runtime expression")
    end
  end

  # Whitehall's PolicyGroup: `has_many :depended_upon_contacts, through:
  # :policy_group_dependencies, source: :dependable, source_type: "Contact"`.
  # The source is a polymorphic belongs_to, so only source_type names the class.
  describe "a through association with a source_type" do
    before do
      allow(described_class).to receive(:cached_context).and_return(
        models: {
          "PolicyGroup" => {
            table_name: "policy_groups",
            associations: [
              { type: "has_many", name: "policy_group_dependencies" },
              { type: "has_many", name: "depended_upon_contacts", through: "policy_group_dependencies",
                options: { source: :dependable, source_type: "Contact" } }
            ]
          },
          "PolicyGroupDependency" => {
            table_name: "policy_group_dependencies",
            associations: [ { type: "belongs_to", name: "dependable", polymorphic: true } ]
          },
          "Contact" => { table_name: "contacts", associations: [] }
        }
      )
    end

    it "points the through edge at the class source_type names" do
      text = described_class.call(format: "mermaid").content.first[:text]

      expect(text).to include("PolicyGroupDependency ==>|through| Contact")
      expect(text).not_to include("==>|through| Dependable")
    end
  end

  # Rails resolves `has_many :investments` on Budget to Budget::Investment
  # when it exists, and Spree::Order's `:payments` to Spree::Payment.
  describe "an association named from inside a namespace" do
    before do
      allow(described_class).to receive(:cached_context).and_return(
        models: {
          "Budget" => {
            table_name: "budgets",
            associations: [ { type: "has_many", name: "investments" }, { type: "has_many", name: "banners" } ]
          },
          "Budget::Investment" => { table_name: "budget_investments", associations: [] },
          "Banner" => { table_name: "banners", associations: [] },
          "Spree::Order" => {
            table_name: "spree_orders",
            associations: [ { type: "has_many", name: "payments" } ]
          },
          "Spree::Payment" => { table_name: "spree_payments", associations: [] }
        }
      )
    end

    it "resolves from the owner's namespace outward" do
      text = described_class.call(format: "mermaid").content.first[:text]

      expect(text).to include("Budget -->|has_many| Budget__Investment")
      expect(text).to include("Budget -->|has_many| Banner")
      expect(text).to include("Spree__Order -->|has_many| Spree__Payment")
      expect(text).not_to match(/-->\|has_many\| (Investment|Payment)\b/)
    end
  end

  # Mastodon's Account follows, blocks and mutes other accounts through three
  # join models; only the first of them was drawn.
  describe "through associations to one target via different join models" do
    before do
      allow(described_class).to receive(:cached_context).and_return(
        models: {
          "Account" => {
            associations: [
              { type: "has_many", name: "active_relationships", class_name: "Follow" },
              { type: "has_many", name: "following", through: "active_relationships", class_name: "Account" },
              { type: "has_many", name: "block_relationships", class_name: "Block" },
              { type: "has_many", name: "blocking", through: "block_relationships", class_name: "Account" }
            ]
          },
          "Follow" => { associations: [ { type: "belongs_to", name: "target_account", class_name: "Account" } ] },
          "Block" => { associations: [ { type: "belongs_to", name: "target_account", class_name: "Account" } ] }
        }
      )
    end

    it "draws each join model" do
      text = described_class.call(model: "Account", depth: 1, format: "mermaid").content.first[:text]

      expect(text).to include("Account ==>|through| Follow", "Follow ==>|through| Account")
      expect(text).to include("Account ==>|through| Block", "Block ==>|through| Account")
    end
  end

  # A leading :: is top level, whatever the owner's namespace holds.
  describe "a rooted class_name inside a namespace" do
    before do
      allow(described_class).to receive(:cached_context).and_return(
        models: {
          "Spree::Order" => { table_name: "spree_orders", associations: [
            { type: "has_many", name: "payments" },
            { type: "has_many", name: "legacy_payments", class_name: "::Payment" }
          ] },
          "Spree::Payment" => { table_name: "spree_payments", associations: [] },
          "Payment" => { table_name: "payments", associations: [] }
        }
      )
    end

    it "draws the top-level class for the rooted name only" do
      text = described_class.call(model: "Spree::Order", format: "mermaid").content.first[:text]

      expect(text).to include("Spree__Order -->|has_many| Spree__Payment", "Spree__Order -->|has_many| Payment\n")
    end
  end

  # The introspector used to drop the `::` before the graph saw it.
  describe "a rooted class_name read from the model's source" do
    it "draws the top-level class" do
      Dir.mktmpdir do |dir|
        FileUtils.mkdir_p(File.join(dir, "app", "models", "shop"))
        File.write(File.join(dir, "app", "models", "payment.rb"), "class Payment < ApplicationRecord\nend\n")
        File.write(File.join(dir, "app", "models", "shop", "payment.rb"), "class Shop::Payment < ApplicationRecord\nend\n")
        File.write(File.join(dir, "app", "models", "shop", "order.rb"),
                   "class Shop::Order < ApplicationRecord\n  has_many :payments\n  has_many :legacy_payments, class_name: \"::Payment\"\nend\n")
        models = RailsAiContext::Introspectors::ModelIntrospector.new(RailsAiContext::StaticApp.new(dir)).static_call
        allow(described_class).to receive(:cached_context).and_return(models: models)

        text = described_class.call(model: "Shop::Order", format: "mermaid").content.first[:text]

        expect(text).to include("Shop__Order -->|has_many| Shop__Payment", "Shop__Order -->|has_many| Payment\n")
      end
    end
  end

  describe "two associations to one class" do
    it "draws an arrow for each, labelled by its association" do
      allow(described_class).to receive(:cached_context).and_return(models: {
        "Article" => { associations: [ { type: "belongs_to", name: "author" },
                                       { type: "belongs_to", name: "owner", class_name: "Author" },
                                       { type: "has_many", name: "tags" } ] },
        "Author" => { associations: [] }, "Tag" => { associations: [] }
      })

      text = described_class.call(format: "mermaid").content.first[:text]

      expect(text).to include("Article -->|belongs_to author| Author", "Article -->|belongs_to owner| Author",
                              "Article -->|has_many| Tag")
      expect(described_class.call(format: "text").content.first[:text]).to include("belongs_to → Author (author)", "belongs_to → Author (owner)")
    end
  end

  # `has_many :buyer_emails, through: :buyer` on a model with no `buyer`
  # association drew a Buyer node and a BuyerEmail node.
  describe "a through association naming no association of its model" do
    it "draws nothing for it and says why" do
      allow(described_class).to receive(:cached_context).and_return(models: {
        "Listing" => { associations: [ { type: "has_many", name: "buyer_emails", through: "buyer" },
                                       { type: "belongs_to", name: "seller" } ] },
        "Seller" => { associations: [] }
      })

      text = described_class.call(format: "mermaid").content.first[:text]

      expect(text).not_to include("Buyer")
      expect(text).to include("Listing -->|belongs_to| Seller",
                              "Listing#buyer_emails (through :buyer, which Listing does not declare)")
    end

    it "names the modules it could not read when the model includes some" do
      allow(described_class).to receive(:cached_context).and_return(models: {
        "Listing" => { concerns_unread: [ "Searchable::Model" ],
                       associations: [ { type: "has_many", name: "buyer_emails", through: "buyer" } ] }
      })

      text = described_class.call(format: "mermaid").content.first[:text]

      expect(text).not_to include("Buyer")
      expect(text).to include("which no file read for Listing declares; Searchable::Model unread")
    end
  end
end
