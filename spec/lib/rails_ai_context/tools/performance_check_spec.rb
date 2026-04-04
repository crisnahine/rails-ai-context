# frozen_string_literal: true

require "spec_helper"

RSpec.describe RailsAiContext::Tools::PerformanceCheck do
  describe ".call" do
    let(:performance_data) do
      {
        n_plus_one_risks: [
          { model: "Post", association: "comments", controller: "app/controllers/posts_controller.rb",
            action: "index", risk: "high",
            suggestion: "Add .includes(:comments) to the Post query to avoid N+1 queries" },
          { model: "User", association: "comments", controller: "app/controllers/users_controller.rb",
            action: "index", risk: "medium",
            suggestion: "User query has preloading but missing :comments — add it to the includes list" },
          { model: "Post", association: "tags", controller: "app/controllers/posts_controller.rb",
            action: "show", risk: "low",
            suggestion: "tags is preloaded — no action needed" }
        ],
        missing_counter_cache: [],
        missing_fk_indexes: [
          { table: "comments", column: "user_id", suggestion: "add_index :comments, :user_id" },
          { table: "comments", column: "post_id", suggestion: "add_index :comments, :post_id" }
        ],
        model_all_in_controllers: [
          { controller: "app/controllers/posts_controller.rb", model: "Post",
            suggestion: "Post.all loads all records into memory. Consider pagination or scoping." }
        ],
        eager_load_candidates: [
          { model: "Post", associations: %w[comments tags],
            suggestion: "Consider eager loading when rendering Post with associations: comments, tags" }
        ],
        summary: {
          total_issues: 7, n_plus_one_risks: 3, missing_counter_cache: 0,
          missing_fk_indexes: 2, model_all_in_controllers: 1, eager_load_candidates: 1
        }
      }
    end

    before do
      allow(described_class).to receive(:cached_context).and_return({
        performance: performance_data,
        models: { "Post" => {}, "User" => {}, "Comment" => {} }
      })
    end

    it "returns summary counts with risk breakdown" do
      response = described_class.call(detail: "summary")
      text = response.content.first[:text]
      expect(text).to include("N+1 risks: 3")
      expect(text).to include("1 high")
      expect(text).to include("1 medium")
      expect(text).to include("1 low")
    end

    it "returns standard detail with suggestions" do
      response = described_class.call(detail: "standard")
      text = response.content.first[:text]
      expect(text).to include("includes(:comments)")
      expect(text).to include("pagination")
    end

    it "renders risk badges" do
      response = described_class.call(category: "n_plus_one")
      text = response.content.first[:text]
      expect(text).to include("[HIGH]")
      expect(text).to include("[MEDIUM]")
      expect(text).to include("[low]")
    end

    it "sorts N+1 risks high-first" do
      response = described_class.call(category: "n_plus_one")
      text = response.content.first[:text]
      high_pos = text.index("[HIGH]")
      medium_pos = text.index("[MEDIUM]")
      low_pos = text.index("[low]")
      expect(high_pos).to be < medium_pos
      expect(medium_pos).to be < low_pos
    end

    it "shows association name with model in N+1 section" do
      response = described_class.call(category: "n_plus_one")
      text = response.content.first[:text]
      expect(text).to include("**Post**.comments")
      expect(text).to include("**User**.comments")
    end

    it "filters by model name for model-keyed items" do
      response = described_class.call(model: "Post")
      text = response.content.first[:text]
      expect(text).to include("Post")
      expect(text).not_to include("**User**")
    end

    it "filters by model name and matches table-keyed items" do
      response = described_class.call(model: "Comment", detail: "standard")
      text = response.content.first[:text]
      expect(text).to include("comments")
    end

    it "filters by category" do
      response = described_class.call(category: "indexes")
      text = response.content.first[:text]
      expect(text).to include("FK Indexes")
      expect(text).not_to include("N+1")
    end

    it "shows full detail with action context" do
      response = described_class.call(detail: "full", category: "n_plus_one")
      text = response.content.first[:text]
      expect(text).to include("posts_controller.rb")
      expect(text).to include("Action: index")
    end

    it "includes risk counts in N+1 section header" do
      response = described_class.call(category: "n_plus_one")
      text = response.content.first[:text]
      expect(text).to include("N+1 Query Risks (3)")
      expect(text).to include("1 high")
    end

    it "handles N+1 items without risk field gracefully" do
      # Backward compatibility: old-format data without risk field
      performance_data[:n_plus_one_risks] = [
        { model: "Post", association: "comments", controller: "app/controllers/posts_controller.rb",
          suggestion: "Add .includes(:comments)" }
      ]
      response = described_class.call(category: "n_plus_one")
      text = response.content.first[:text]
      expect(text).to include("**Post**.comments")
    end
  end
end
