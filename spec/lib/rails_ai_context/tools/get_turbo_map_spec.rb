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

  # bazaar's stream:"nope" answered with the whole map and no word that
  # nothing matched: the frames and responses are not streams to filter.
  describe ".call with stream filter" do
    it "says no stream matches a filter that matches none" do
      result = described_class.call(stream: "nonexistent_stream_xyz", detail: "standard")
      text = result.content.first[:text]

      expect(text).to start_with("No broadcast or `turbo_stream_from` matches stream:\"nonexistent_stream_xyz\".")
      expect(text).not_to include("## Turbo Frames")
    end
  end

  describe ".call with controller filter" do
    it "filters results by controller name" do
      result = described_class.call(controller: "nonexistent_controller_xyz")
      text = result.content.first[:text]
      expect(text).to include("Turbo Map")
    end

    # `blog_posts` is its own controller with its own views, and a substring
    # filter reported its frames as `posts`'s Turbo usage.
    it "does not answer a controller with a view whose directory merely contains the name" do
      allow(described_class).to receive(:cached_context).and_return(
        turbo: {
          turbo_frames: [ { tag: "turbo_frame_tag", id: "post", file: "app/views/blog_posts/show.html.erb", line: 1 } ],
          stream_subscriptions: [], model_broadcasts: [], explicit_broadcasts: [],
          turbo_stream_responses: [], turbo_stream_templates: []
        }
      )

      text = described_class.call(controller: "posts", detail: "standard").content.first[:text]

      expect(text).not_to include("blog_posts")
    end

    # An MCP client sends "" for an argument it leaves unset, and the segment
    # matcher raised ArgumentError on a needle of no segments.
    it "reads a blank filter as no filter" do
      expect(described_class.call(controller: "").content.first[:text])
        .to eq(described_class.call.content.first[:text])
      expect(described_class.call(controller: "/").content.first[:text])
        .to eq(described_class.call.content.first[:text])
      expect(described_class.call(stream: " ").content.first[:text])
        .to eq(described_class.call.content.first[:text])
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

        **Warnings:** 2 potential mismatch(es) detected

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

        ## Warnings
        - Broadcast to `post, comments` has no matching `turbo_stream_from` (Comment.broadcasts_to (app/models/comment.rb:7))
        - Subscription to `@post` has no matching broadcast (app/views/posts/index.html.erb:1)

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

        ### Stream: `post, comments`
        - **Broadcasters:** `Comment.broadcasts_to (app/models/comment.rb:7)`
        - _No subscribers found for this stream_

        ## Warnings
        - Broadcast to `post, comments` has no matching `turbo_stream_from` (Comment.broadcasts_to (app/models/comment.rb:7))
        - Subscription to `@post` has no matching broadcast (app/views/posts/index.html.erb:1)
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

        ## Stream Wiring
        ### Stream: `post, comments`
        - **Broadcasters:** `Comment.broadcasts_to (app/models/comment.rb:7)`
        - _No subscribers found for this stream_

        ## Warnings
        - Broadcast to `post, comments` has no matching `turbo_stream_from` (Comment.broadcasts_to (app/models/comment.rb:7))
      TEXT
    end
  end

  # bazaar wires all four of its streams, and the map called every one
  # unwired: array streams read as "(dynamic)" and were never compared.
  describe "stream wiring by the records and names a stream is built from" do
    let(:models) do
      {
        "Product" => { associations: [] },
        "User" => { associations: [] },
        "Review" => { associations: [ { type: "belongs_to", name: "product" } ] },
        "Notification" => { associations: [ { type: "belongs_to", name: "user" } ] }
      }
    end
    let(:turbo) do
      {
        model_broadcasts: [
          { model: "Product", macro: "broadcasts_refreshes", stream: "self (model plural, refreshes)",
            streams: [ [ { literal: "products" } ], [ { expr: "self" } ] ], file: "app/models/product.rb", line: 27 }
        ],
        explicit_broadcasts: [
          { method: "broadcast_prepend_to", stream: "(dynamic)", parts: [ { expr: "user" }, { literal: "notifications" } ],
            owner: "Notification", file: "app/models/notification.rb", line: 24 },
          { method: "broadcast_prepend_to", stream: "(dynamic)", parts: [ { expr: "product" }, { literal: "reviews" } ],
            owner: "Review", file: "app/models/review.rb", line: 10 },
          { method: "broadcast_replace_to", stream: "(dynamic)", parts: [ { expr: "ledger" }, { literal: "rows" } ],
            owner: "Review", file: "app/models/review.rb", line: 12 }
        ],
        stream_subscriptions: [
          { stream: "current_user, notifications", parts: [ { expr: "current_user" }, { literal: "notifications" } ],
            file: "app/views/layouts/application.html.erb", line: 18 },
          { stream: "@product", parts: [ { expr: "@product" } ], file: "app/views/products/show.html.erb", line: 2 },
          { stream: "@product, reviews", parts: [ { expr: "@product" }, { literal: "reviews" } ], file: "app/views/products/show.html.erb", line: 3 },
          { stream: "@report, rows", parts: [ { expr: "@report" }, { literal: "rows" } ], file: "app/views/reports/show.html.erb", line: 1 }
        ]
      }
    end

    before do
      allow(described_class).to receive(:cached_context).and_return(models: models, turbo: turbo)
    end

    def wiring(text, stream)
      text[/### Stream: `#{Regexp.escape(stream)}`\n(.*?)(?=\n\n|\z)/m, 1]
    end

    it "wires a model's record and names to the view's record of the same model" do
      text = described_class.call(detail: "full").content.first[:text]

      expect(wiring(text, "@product, reviews")).to include("**Broadcasters:** `broadcast_prepend_to (app/models/review.rb:10)`")
      expect(wiring(text, "current_user, notifications")).to include("`broadcast_prepend_to (app/models/notification.rb:24)`")
      expect(wiring(text, "@product")).to include("`Product.broadcasts_refreshes (app/models/product.rb:27) on update and destroy`")
      expect(text).not_to include("No broadcasters found for this stream")
    end

    it "reads Current.user, Rails 8's signed-in user, as a User record" do
      turbo[:stream_subscriptions] = [
        { stream: "Current.user, notifications", parts: [ { expr: "Current.user" }, { literal: "notifications" } ],
          file: "app/views/layouts/_notifications.html.erb", line: 2 }
      ]
      text = described_class.call(detail: "full").content.first[:text]

      expect(wiring(text, "Current.user, notifications")).to include("**Broadcasters:** `broadcast_prepend_to (app/models/notification.rb:24)`")
      expect(text).not_to include("Can't tell whether `broadcast_prepend_to (app/models/notification.rb:24)`")
      expect(text).not_to include("Subscription to `Current.user, notifications`")
    end

    # The blog's comments filter kept the model broadcasts but none of the
    # post views that hear them, and called three wired streams unheard.
    it "judges a filtered stream against every subscriber the app has" do
      text = described_class.call(detail: "full", controller: "reports").content.first[:text]

      expect(wiring(text, "@product")).to include("**Subscribers:** `app/views/products/show.html.erb:2`")
      expect(text).not_to include("Broadcast to `self` has no matching")
      expect(text).to include("Broadcast to `products` has no matching `turbo_stream_from`")
    end

    it "says it can't tell where a stream names nothing it resolves, and warns only where it is sure" do
      text = described_class.call(detail: "full").content.first[:text]

      expect(wiring(text, "@report, rows")).to include("_Can't tell whether `broadcast_replace_to (app/models/review.rb:12)` broadcasts here")
      expect(text).not_to include("Subscription to `@report, rows`")
      expect(text).to include("Broadcast to `products` has no matching `turbo_stream_from`")
    end
  end

  describe "more turbo_stream responses than the section prints" do
    before { described_class.reset_cache! }

    before do
      responses = (1..20).map { |n| { controller: "PostsController", action: "act#{n}" } }
      allow(described_class).to receive(:cached_context).and_return(turbo: { turbo_stream_responses: responses })
    end

    it "says how many it showed and how to see the rest" do
      text = described_class.call.content.first[:text]

      expect(text).to include("Showing 15 of 20")
      expect(text).to include("rails_get_turbo_map(detail:\"full\")")
    end

    it "prints them all in full detail" do
      text = described_class.call(detail: "full").content.first[:text]

      expect(text).to include("act20")
      expect(text).not_to include("Showing 15 of 20")
    end
  end
end
