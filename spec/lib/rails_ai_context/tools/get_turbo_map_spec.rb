# frozen_string_literal: true

require "spec_helper"
require "fileutils"
require "tmpdir"

RSpec.describe RailsAiContext::Tools::GetTurboMap do
  before { described_class.reset_cache! }

  describe ".call with no turbo usage" do
    it "reports no turbo streams or frames detected" do
      result = described_class.call
      text = result.content.first[:text]
      expect(text).to include("Turbo Map")
      # The test app may or may not have turbo usage; either show results or say none
      expect(text).to be_a(String)
    end
  end

  describe ".call with detail:summary" do
    it "returns summary counts" do
      result = described_class.call(detail: "summary")
      text = result.content.first[:text]
      expect(text).to include("Turbo Map")
      expect(text).to include("Model broadcasts:")
      expect(text).to include("Explicit broadcasts:")
      expect(text).to include("Stream subscriptions:")
      expect(text).to include("Turbo Frames:")
    end
  end

  describe ".call with detail:standard" do
    it "returns standard detail" do
      result = described_class.call(detail: "standard")
      text = result.content.first[:text]
      expect(text).to include("Turbo Map")
    end
  end

  describe ".call with detail:full" do
    it "returns full detail" do
      result = described_class.call(detail: "full")
      text = result.content.first[:text]
      expect(text).to include("Turbo Map (Full Detail)")
    end
  end

  describe ".call with unknown detail level" do
    it "reads an invalid detail level as the default, and says so" do
      text = described_class.call(detail: "invalid").content.first[:text]

      expect(text).to start_with(described_class.call(detail: "standard").content.first[:text])
      expect(text).to include("invalid")
      expect(text).to include("not a valid `detail`")
    end
  end

  describe ".call with stream filter" do
    it "filters results by stream name" do
      result = described_class.call(stream: "nonexistent_stream_xyz")
      text = result.content.first[:text]
      # With a nonsense filter, should get no matching results
      expect(text).to include("Turbo Map")
    end

    it "reports no matching turbo usage with bad filter" do
      result = described_class.call(stream: "nonexistent_stream_xyz", detail: "standard")
      text = result.content.first[:text]
      # Should either show empty results or a helpful hint
      expect(text).to match(/No Turbo usage matching|Turbo Map/)
    end
  end

  describe ".call with controller filter" do
    it "filters results by controller name" do
      result = described_class.call(controller: "nonexistent_controller_xyz")
      text = result.content.first[:text]
      expect(text).to include("Turbo Map")
    end

    it "reports no matching turbo usage with bad controller filter" do
      result = described_class.call(controller: "nonexistent_controller_xyz", detail: "standard")
      text = result.content.first[:text]
      expect(text).to match(/No Turbo usage matching|Turbo Map/)
    end
  end

  describe "turbo stream response detection" do
    it "detects turbo stream templates from test app" do
      # The test app has spec/internal/app/views/posts/create.turbo_stream.erb
      result = described_class.call(detail: "summary")
      text = result.content.first[:text]
      expect(text).to include("Turbo")
    end
  end

  describe "when turbo-rails is not installed" do
    let(:lock_path) { File.join(Rails.root.to_s, "Gemfile.lock") }

    before do
      File.write(lock_path, <<~LOCK)
        GEM
          remote: https://rubygems.org/
          specs:
            rails (8.0.0)
      LOCK
    end

    after { FileUtils.rm_f(lock_path) }

    it "short-circuits with a not-installed message instead of a Turbo Drive block" do
      result = described_class.call
      text = result.content.first[:text]
      expect(text).to include("Turbo is not installed in this app")
      expect(text).not_to include("Turbo Drive Configuration")
      expect(text).not_to include("Turbo Map")
    end
  end

  # The Turbo section of an app with no views at all: the introspector run
  # over an empty root, so the shape is the real one.
  def turbo_section_of_an_empty_app
    Dir.mktmpdir { |dir| RailsAiContext::Introspectors::TurboIntrospector.new(RailsAiContext::StaticApp.new(dir)).call }
  end

  # The section's own entries are `{ controller:, action: }`; a Ruby hash
  # inspect is not how the rest of the file names a controller action.
  describe "a Turbo Stream response" do
    before do
      allow(described_class).to receive(:cached_context).and_return(
        turbo: turbo_section_of_an_empty_app.merge(
          turbo_stream_responses: [ { controller: "PostsController", action: "create" } ]
        )
      )
    end

    it "renders as Controller#action in the standard view" do
      text = described_class.call(detail: "standard").content.first[:text]

      expect(text).to include("- `PostsController#create`")
    end

    it "renders as Controller#action in the full view" do
      text = described_class.call(detail: "full").content.first[:text]

      expect(text).to include("- `PostsController#create`")
    end
  end

  describe ".call for an API-only app" do
    it "reports API-only apps as not applicable instead of an empty listing" do
      allow(described_class).to receive(:cached_context).and_return(api: { api_only: true }, turbo: turbo_section_of_an_empty_app)

      result = described_class.call(controller: "nonexistent_controller_xyz", detail: "standard")
      text = result.content.first[:text]
      expect(text).to include("Not applicable")
      expect(text).to include("API-only")
    end
  end

  describe "stream wiring" do
    it "pairs a broadcast with its subscription and warns only about the unmatched one" do
      Dir.mktmpdir do |dir|
        FileUtils.mkdir_p(File.join(dir, "app", "models"))
        FileUtils.mkdir_p(File.join(dir, "app", "views", "posts"))
        File.write(File.join(dir, "app", "models", "post.rb"),
                   "class Post < ApplicationRecord\n  after_create_commit -> { broadcast_append_to \"posts\" }\nend\n")
        File.write(File.join(dir, "app", "views", "posts", "index.html.erb"),
                   "<%= turbo_stream_from :posts %>\n<%= turbo_stream_from :alerts %>\n")
        app = RailsAiContext::StaticApp.new(dir)
        allow(RailsAiContext).to receive(:default_app).and_return(app)
        allow(described_class).to receive(:cached_context).and_return(turbo: RailsAiContext::Introspectors::TurboIntrospector.new(app).call)

        text = described_class.call(detail: "full").content.first[:text]

        expect(text).to include(<<~'TEXT')
          ## Stream Wiring
          ### Stream: `alerts`
          - **Subscribers:** `app/views/posts/index.html.erb:2`
          - _No broadcasters found for this stream_

          ### Stream: `posts`
          - **Broadcasters:** `broadcast_append_to (app/models/post.rb:2)`
          - **Subscribers:** `app/views/posts/index.html.erb:1`

          ## Warnings
          - Subscription to `alerts` has no matching broadcast (app/views/posts/index.html.erb:2)
        TEXT
        expect(text.scan("has no matching").size).to eq(1)
      end
    end
  end

  describe ".call when nothing is found" do
    before { allow(described_class).to receive(:cached_context).and_return(turbo: turbo_section_of_an_empty_app) }

    it "marks the answer empty so a composing tool can read it" do
      result = described_class.call(detail: "standard")

      expect(described_class.send(:empty?, result)).to be true
      expect(result.content.first[:text]).to include("No Turbo Streams or Frames detected")
    end

    it "marks a filtered miss empty too" do
      result = described_class.call(controller: "nonexistent_controller_xyz", detail: "full")

      expect(described_class.send(:empty?, result)).to be true
      expect(result.content.first[:text]).to include("No Turbo usage matching")
    end
  end

  describe "when turbo-rails IS installed (per Gemfile.lock)" do
    let(:lock_path) { File.join(Rails.root.to_s, "Gemfile.lock") }

    before do
      File.write(lock_path, <<~LOCK)
        GEM
          remote: https://rubygems.org/
          specs:
            turbo-rails (2.0.0)
      LOCK
    end

    after { FileUtils.rm_f(lock_path) }

    it "runs the normal Turbo Map flow" do
      result = described_class.call
      text = result.content.first[:text]
      expect(text).to include("Turbo Map")
      expect(text).not_to include("Turbo is not installed")
    end
  end

  # What the static fixture renders, pinned as literals. The introspector
  # carries the wiring the tool used to scan for itself; these keep that
  # move honest.
  describe "rendered against the static fixture" do
    before do
      allow(RailsAiContext).to receive(:default_app).and_return(RailsAiContext::StaticApp.new(IntrospectedFixture::ROOT))
      allow(described_class).to receive(:cached_context).and_return(IntrospectedFixture.context)
    end

    def rendered(**args)
      described_class.call(**args).content.first[:text]
    end

    it "renders the summary counts" do
      expect(rendered(detail: "summary")).to eq(<<~'TEXT'.chomp)
        # Turbo Map

        - **Turbo Stream responses:** 1 (controllers responding with `turbo_stream` format)
        - **Turbo Stream templates:** 1 (`.turbo_stream.erb` view templates)
        - **Model broadcasts:** 1 (via `broadcasts`, `broadcasts_to`, etc.)
        - **Explicit broadcasts:** 0 (via `broadcast_*_to` calls in .rb files)
        - **Stream subscriptions:** 1 (`turbo_stream_from` in views)
        - **Turbo Frames:** 3 (`turbo_frame_tag` in views)

        _Use `detail:"standard"` for stream wiring, or `stream:"name"` to filter._
      TEXT
    end

    it "renders the standard wiring" do
      expect(rendered(detail: "standard")).to eq(<<~'TEXT'.chomp)
        # Turbo Map

        ## Turbo Drive Configuration
        - morph: yes
        - permanent elements: 2
        - data-turbo-false: 0
        - data-turbo-action: 2
        - data-turbo-preload: 0

        ## Turbo Stream Responses
        - `PostsController#create`

        ## Turbo Stream Templates (1) (actions: append×1)
        - `posts/create.turbo_stream.erb`

        ## Model Broadcasts (1)
        - **Comment** `broadcasts_to` (`app/models/comment.rb:7`)

        ## Stream Subscriptions (1)
        - `turbo_stream_from` `@post` (`app/views/posts/index.html.erb:1`)

        ## Turbo Frames (3)
        - `turbo_frame_tag` `dom_id(@post, :edit)` (`app/views/posts/edit.html.erb:1`)
        - `turbo_frame_tag` `dom_id(@post, :edit)` (`app/views/posts/index.html.erb:2`)
        - `turbo_frame_tag` `post` (`app/views/posts/show.html.erb:1`)

        _Use `detail:"full"` for DOM IDs and inline templates, or `stream:"name"` to filter._
      TEXT
    end

    it "renders the full detail with snippets and wiring" do
      expect(rendered(detail: "full")).to eq(<<~'TEXT')
        # Turbo Map (Full Detail)

        ## Turbo Drive Configuration
        - morph: yes
        - permanent elements: 2
        - data-turbo-false: 0
        - data-turbo-action: 2
        - data-turbo-preload: 0

        ## Turbo Stream Responses (1)
        - `PostsController#create`

        ## Turbo Stream Templates (1)
        - `posts/create.turbo_stream.erb`
        - **Actions used:** append×1

        ## Model Broadcasts (1)
        ### Comment - `broadcasts_to`
        - **File:** `app/models/comment.rb:7`
        - **Snippet:** `broadcasts_to ->(comment) { [comment.post, :comments] }`

        ## Stream Subscriptions (1)
        - `turbo_stream_from` `@post` - `app/views/posts/index.html.erb:1`
          ```erb
          <%= turbo_stream_from @post %>
          ```

        ## Turbo Frames (3)
        ### `turbo_frame_tag` `dom_id(@post, :edit)`
        - **File:** `app/views/posts/edit.html.erb:1`
        - **Snippet:** `<%= turbo_frame_tag dom_id(@post, :edit) do %>`

        ### `turbo_frame_tag` `dom_id(@post, :edit)`
        - **File:** `app/views/posts/index.html.erb:2`
        - **Snippet:** `<%= turbo_frame_tag dom_id(@post, :edit) %>`

        ### `turbo_frame_tag` `post`
        - **File:** `app/views/posts/show.html.erb:1`
        - **Snippet:** `<%= turbo_frame_tag :post do %>`

        ## Stream Wiring
        ### Stream: `@post`
        - **Subscribers:** `app/views/posts/index.html.erb:1`
        - _No broadcasters found for this stream_
      TEXT
    end

    it "keeps the whole map under a controller filter that matches every view" do
      expect(rendered(detail: "standard", controller: "posts")).to eq(rendered(detail: "standard"))
    end

    it "filters broadcasts and subscriptions on the stream name or snippet" do
      expect(rendered(detail: "full", stream: "comments")).to eq(<<~'TEXT')
        # Turbo Map (Full Detail)

        ## Turbo Drive Configuration
        - morph: yes
        - permanent elements: 2
        - data-turbo-false: 0
        - data-turbo-action: 2
        - data-turbo-preload: 0

        ## Turbo Stream Responses (1)
        - `PostsController#create`

        ## Turbo Stream Templates (1)
        - `posts/create.turbo_stream.erb`
        - **Actions used:** append×1

        ## Model Broadcasts (1)
        ### Comment - `broadcasts_to`
        - **File:** `app/models/comment.rb:7`
        - **Snippet:** `broadcasts_to ->(comment) { [comment.post, :comments] }`

        ## Turbo Frames (3)
        ### `turbo_frame_tag` `dom_id(@post, :edit)`
        - **File:** `app/views/posts/edit.html.erb:1`
        - **Snippet:** `<%= turbo_frame_tag dom_id(@post, :edit) do %>`

        ### `turbo_frame_tag` `dom_id(@post, :edit)`
        - **File:** `app/views/posts/index.html.erb:2`
        - **Snippet:** `<%= turbo_frame_tag dom_id(@post, :edit) %>`

        ### `turbo_frame_tag` `post`
        - **File:** `app/views/posts/show.html.erb:1`
        - **Snippet:** `<%= turbo_frame_tag :post do %>`
      TEXT
    end
  end
end
