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

  # The payload key the introspector fills, built the way it builds it, so
  # these render what a real run would hand the tool.
  def payload_concern_callbacks(root, concern_name)
    collected, = RailsAiContext::ConcernMacros.collect(
      root, [ { name: concern_name, ancestor: true } ], keys: %i[callbacks], prefer: "model"
    )
    collected[:callbacks] || []
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
      models["Post"][:concern_callbacks] = payload_concern_callbacks(tmpdir, "HtmlSanitizable")
      # The introspector merges the concern's callbacks into the model's own
      # list, so the execution-order list really holds this method.
      models["Post"][:callbacks]["before_save"] = %w[generate_slug sanitize_body]
    end

    after { FileUtils.remove_entry(tmpdir) }

    # The section attributes the callback; the body belongs to the
    # execution-order list, once, read from the concern that declared it.
    it "shows a concern-declared callback body once, in the execution-order list" do
      result = described_class.call(model: "Post", detail: "full")
      text = result.content.first[:text]

      expect(text).to include("## From Concerns")
      expect(text).to include("- **HtmlSanitizable:** before_save :sanitize_body")
      expect(text).not_to include("### HtmlSanitizable")
      expect(text.scan("ActionController::Base.helpers.sanitize").size).to eq(1)
      expect(text).to include("### :sanitize_body (HtmlSanitizable lines 10-12)")
      expect(text.index("def sanitize_body")).to be < text.index("## From Concerns")
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
      models["Post"][:concern_callbacks] = payload_concern_callbacks(tmpdir, "HtmlSanitizable")
    end

    after { FileUtils.remove_entry(tmpdir) }

    it "shows the callback declaration when the method has no def" do
      result = described_class.call(model: "Post", detail: "full")
      text = result.content.first[:text]

      expect(text).to include("- **HtmlSanitizable:** before_save :sanitize_body")
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

  # `after_create do` was matched by a line regex whose colon was optional,
  # so the block keyword was printed as the method name.
  describe "concern callbacks the line regex mangled" do
    let(:tmpdir) { Dir.mktmpdir }

    before do
      FileUtils.mkdir_p(File.join(tmpdir, "app", "models", "concerns"))
      File.write(File.join(tmpdir, "app", "models", "concerns", "rate_limitable.rb"), <<~RUBY)
        module RateLimitable
          extend ActiveSupport::Concern

          included do
            after_create do
              rate_limiter.record!
            end

            around_create Some::CallbackObject
            after_commit :announce, on: :create
            after_commit :sync, on: [ :create, :update ]
            before_validation :relax_policy, if: -> { quote_policy? }
            after_rollback do
              rate_limiter.rollback!
            end
          end

          def rate_limiter(by = nil)
            @rate_limiter ||= RateLimiter.new(by)
          end
        end
      RUBY

      allow(Rails.application).to receive(:root).and_return(Pathname.new(tmpdir))
      allow(RailsAiContext.configuration).to receive(:concern_paths).and_return(%w[app/models/concerns])
      allow(RailsAiContext.configuration).to receive(:max_file_size).and_return(1_000_000)
      allow(described_class).to receive(:cached_context).and_return(
        models: {
          "Status" => {
            callbacks: { "before_save" => %w[touch_thread] },
            concerns: %w[RateLimitable],
            concern_callbacks: payload_concern_callbacks(tmpdir, "RateLimitable")
          }
        }
      )
    end

    after { FileUtils.remove_entry(tmpdir) }

    it "names the block and the class object instead of inventing a method" do
      text = described_class.call(model: "Status", detail: "standard").content.first[:text]

      expect(text).to include("after_create do")
      expect(text).to include("around_create Some::CallbackObject")
      expect(text).to include("after_rollback do")
      expect(text).not_to include(":do")
      expect(text).not_to include(":Some")
    end

    # `after_commit_on_create` is the resolved type, not a Ruby method - the
    # concern line prints what the file declares.
    it "keeps the declared macro name for an after_commit with on:" do
      text = described_class.call(model: "Status", detail: "standard").content.first[:text]

      expect(text).to include("after_commit :announce")
      expect(text).not_to include("after_commit_on_create")
    end

    # Four after_commit lines that differ only in `on:` read as one
    # declaration without the tail.
    it "keeps the options tail the declaration was written with" do
      text = described_class.call(model: "Status", detail: "standard").content.first[:text]

      expect(text).to include("after_commit :announce, on: :create")
    end

    # One declaration resolves to one record per `on:` event, and the section
    # prints declarations, not resolved types.
    it "prints a multi-event after_commit once" do
      text = described_class.call(model: "Status", detail: "standard").content.first[:text]

      expect(text.scan("after_commit :sync, on: [:create, :update]").size).to eq(1)
    end

    # A quoted marker reads as a string the app wrote.
    it "leaves an unresolved option value unquoted" do
      text = described_class.call(model: "Status", detail: "standard").content.first[:text]

      expect(text).to include("before_validation :relax_policy, if: [INFERRED]")
      expect(text).not_to include(%(if: "[INFERRED]"))
    end

    it "attaches no method source to a block callback at detail:full" do
      text = described_class.call(model: "Status", detail: "full").content.first[:text]

      expect(text).to include("after_create do")
      expect(text).not_to include("def rate_limiter")
    end
  end

  # The section used to walk the concern files itself, so it disagreed with
  # the callbacks the payload already carries and it resolved a namespaced
  # concern differently.
  describe "the concern section reads the payload" do
    it "groups the payload's concern-tagged callbacks by the concern that declared them" do
      allow(described_class).to receive(:cached_context).and_return(
        models: {
          "Status" => {
            callbacks: { "before_validation" => %w[set_visibility] },
            concerns: %w[Status::Visibility],
            concern_callbacks: [
              { name: "before_validation", type: "before_validation", method: "set_visibility",
                from_concern: "Status::Visibility" }
            ]
          }
        }
      )

      text = described_class.call(model: "Status", detail: "standard").content.first[:text]

      expect(text).to include("## From Concerns")
      expect(text).to include("**Status::Visibility:** before_validation :set_visibility")
    end

    it "renders no concern section when the payload tags nothing" do
      allow(described_class).to receive(:cached_context).and_return(
        models: { "Status" => { callbacks: { "before_save" => %w[touch] }, concerns: %w[Discard::Model] } }
      )

      text = described_class.call(model: "Status", detail: "standard").content.first[:text]

      expect(text).not_to include("## From Concerns")
    end
  end
end
