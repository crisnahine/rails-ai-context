# frozen_string_literal: true

require "spec_helper"
require "tmpdir"
require "fileutils"

RSpec.describe RailsAiContext::Tools::GetCallbacks do
  before { described_class.reset_cache! }

  let(:models) do
    {
      "Post" => {
        callbacks: {
          "before_save" => %w[generate_slug],
          "after_create" => %w[notify_subscribers]
        },
        concerns: %w[HtmlSanitizable]
      },
      "User" => {
        callbacks: {
          "before_validation" => %w[normalize_email]
        },
        concerns: []
      }
    }
  end

  before do
    allow(described_class).to receive(:cached_context).and_return({ models: models })
  end

  describe "detail levels for all models" do
    it "returns model names with callback counts for detail:summary" do
      result = described_class.call(detail: "summary")
      text = result.content.first[:text]
      expect(text).to include("**Post**")
      expect(text).to include("**User**")
      expect(text).to include("2 callbacks")
    end

    it "returns callbacks in execution order for detail:standard" do
      result = described_class.call(detail: "standard")
      text = result.content.first[:text]
      expect(text).to include("**before_save**")
      expect(text).to include("`:generate_slug`")
    end
  end

  describe "specific model with detail:standard" do
    it "shows callbacks in execution order" do
      result = described_class.call(model: "Post", detail: "standard")
      text = result.content.first[:text]
      expect(text).to include("# Post")
      expect(text).to include("**before_save**")
      expect(text).to include("`:generate_slug`")
      expect(text).to include("**after_create**")
      expect(text).to include("`:notify_subscribers`")
    end
  end

  describe "concern callbacks with detail:full" do
    let(:tmpdir) { Dir.mktmpdir }
    let(:concern_dir) { File.join(tmpdir, "app", "models", "concerns") }
    let(:model_dir) { File.join(tmpdir, "app", "models") }

    before do
      FileUtils.mkdir_p(concern_dir)
      FileUtils.mkdir_p(model_dir)

      # Create concern file with a callback and its method source
      File.write(File.join(concern_dir, "html_sanitizable.rb"), <<~RUBY)
        module HtmlSanitizable
          extend ActiveSupport::Concern

          included do
            before_save :sanitize_body
          end

          private

          def sanitize_body
            self.body = ActionController::Base.helpers.sanitize(body, tags: ALLOWED_TAGS)
          end
        end
      RUBY

      # Create model file with callbacks
      File.write(File.join(model_dir, "post.rb"), <<~RUBY)
        class Post < ApplicationRecord
          include HtmlSanitizable

          before_save :generate_slug
          after_create :notify_subscribers

          private

          def generate_slug
            self.slug = title.parameterize
          end

          def notify_subscribers
            subscribers.each(&:notify!)
          end
        end
      RUBY

      allow(Rails.application).to receive(:root).and_return(Pathname.new(tmpdir))
      allow(RailsAiContext.configuration).to receive(:concern_paths).and_return(%w[app/models/concerns])
      allow(RailsAiContext.configuration).to receive(:max_file_size).and_return(1_000_000)
    end

    after { FileUtils.remove_entry(tmpdir) }

    it "shows concern callback method source at detail:full" do
      result = described_class.call(model: "Post", detail: "full")
      text = result.content.first[:text]

      # Should have the From Concerns section with the concern name as heading
      expect(text).to include("## From Concerns")
      expect(text).to include("### HtmlSanitizable")
      expect(text).to include("before_save :sanitize_body")

      # Should include the method source code from the concern
      expect(text).to include("def sanitize_body")
      expect(text).to include("ActionController::Base.helpers.sanitize")
    end

    it "shows model callback method source at detail:full" do
      result = described_class.call(model: "Post", detail: "full")
      text = result.content.first[:text]

      # Should include model callback source
      expect(text).to include("def generate_slug")
      expect(text).to include("title.parameterize")
    end

    it "shows concern callbacks as one-liner at detail:standard" do
      result = described_class.call(model: "Post", detail: "standard")
      text = result.content.first[:text]

      expect(text).to include("## From Concerns")
      expect(text).to include("**HtmlSanitizable:**")
      expect(text).to include("before_save :sanitize_body")
      # Should NOT include method source at standard detail
      expect(text).not_to include("def sanitize_body")
    end
  end

  describe "concern callback without method source" do
    let(:tmpdir) { Dir.mktmpdir }
    let(:concern_dir) { File.join(tmpdir, "app", "models", "concerns") }
    let(:model_dir) { File.join(tmpdir, "app", "models") }

    before do
      FileUtils.mkdir_p(concern_dir)
      FileUtils.mkdir_p(model_dir)

      # Concern with callback but method defined dynamically (no def)
      File.write(File.join(concern_dir, "html_sanitizable.rb"), <<~RUBY)
        module HtmlSanitizable
          extend ActiveSupport::Concern

          included do
            before_save :sanitize_body
          end
        end
      RUBY

      File.write(File.join(model_dir, "post.rb"), <<~RUBY)
        class Post < ApplicationRecord
          include HtmlSanitizable
        end
      RUBY

      allow(Rails.application).to receive(:root).and_return(Pathname.new(tmpdir))
      allow(RailsAiContext.configuration).to receive(:concern_paths).and_return(%w[app/models/concerns])
      allow(RailsAiContext.configuration).to receive(:max_file_size).and_return(1_000_000)
    end

    after { FileUtils.remove_entry(tmpdir) }

    it "shows the callback declaration without source when method is not found" do
      result = described_class.call(model: "Post", detail: "full")
      text = result.content.first[:text]

      expect(text).to include("### HtmlSanitizable")
      expect(text).to include("before_save :sanitize_body")
      # No source block since method def is missing
      expect(text).not_to include("```ruby")
    end
  end

  describe "edge cases" do
    it "handles models with no callbacks" do
      allow(described_class).to receive(:cached_context).and_return({
        models: { "Empty" => { callbacks: {}, concerns: [] } }
      })
      result = described_class.call(model: "Empty")
      text = result.content.first[:text]
      expect(text).to include("No callbacks defined")
    end

    it "handles missing model introspection" do
      allow(described_class).to receive(:cached_context).and_return({})
      result = described_class.call(model: "Post")
      text = result.content.first[:text]
      expect(text).to include("not available")
    end

    it "supports case-insensitive model lookup" do
      result = described_class.call(model: "post")
      text = result.content.first[:text]
      expect(text).to include("# Post")
    end
  end
end
