# frozen_string_literal: true

require "spec_helper"

RSpec.describe RailsAiContext::VFS do
  let(:context) do
    {
      models: {
        "Post" => {
          table_name: "posts",
          associations: [ { name: "comments", type: "has_many" } ],
          validations: [ { kind: "presence", attributes: [ "title" ] } ]
        },
        "User" => {
          table_name: "users",
          associations: [],
          validations: []
        }
      },
      schema: {
        tables: {
          "posts" => {
            columns: [ { name: "id", type: "integer" }, { name: "title", type: "string" } ],
            primary_key: "id"
          }
        }
      },
      controllers: {
        controllers: {
          "ApplicationController" => {
            filters: [
              { kind: "before", name: "authenticate_user!" },
              { kind: "before", name: "set_locale" }
            ]
          },
          "PostsController" => {
            parent_class: "ApplicationController",
            actions: [ "index", "show", "create" ],
            filters: [
              { kind: "before", name: "set_post", only: [ "show" ] },
              { kind: "before", name: "authenticate_user!" }
            ],
            strong_params: [ { name: "post_params", requires: :post, permits: [ :title ] } ]
          },
          "Admin::PostsController" => {
            file: "app/controllers/admin/posts_controller.rb",
            actions: [ "index" ],
            filters: []
          },
          "ActivityPub::InboxesController" => {
            file: "app/controllers/activitypub/inboxes_controller.rb",
            actions: [ "create" ],
            filters: []
          },
          "Api::V1::GiftCardsController" => {
            file: "app/controllers/api/v1/gift_cards_controller.rb",
            actions: [ "redeem", "list" ],
            filters: []
          }
        }
      },
      routes: {
        # Mirrors RouteIntrospector#call output: routes are grouped under
        # :by_controller keyed by controller name (there is no flat :routes list).
        total_routes: 3,
        by_controller: {
          "posts" => [
            { verb: "GET", path: "/posts", action: "index", name: "posts" },
            { verb: "GET", path: "/posts/:id", action: "show", name: "post" }
          ],
          "users" => [
            { verb: "GET", path: "/users", action: "index", name: "users" }
          ]
        },
        api_namespaces: [],
        mounted_engines: [],
        root_route: nil
      }
    }
  end

  before do
    allow(RailsAiContext).to receive(:introspect).and_return(context)
  end

  describe ".resolve" do
    context "models" do
      it "resolves a model URI" do
        result = described_class.resolve("rails-ai-context://models/Post")
        expect(result).to be_an(Array)
        expect(result.first[:uri]).to eq("rails-ai-context://models/Post")
        expect(result.first[:mimeType]).to eq("application/json")

        data = JSON.parse(result.first[:text])
        expect(data["table_name"]).to eq("posts")
      end

      it "resolves case-insensitively" do
        result = described_class.resolve("rails-ai-context://models/post")
        data = JSON.parse(result.first[:text])
        expect(data["table_name"]).to eq("posts")
      end

      it "enriches with schema data" do
        result = described_class.resolve("rails-ai-context://models/Post")
        data = JSON.parse(result.first[:text])
        expect(data["schema"]).to be_a(Hash)
        expect(data["schema"]["columns"]).to be_an(Array)
      end

      it "returns error for unknown model" do
        result = described_class.resolve("rails-ai-context://models/Widget")
        data = JSON.parse(result.first[:text])
        expect(data["error"]).to include("not found")
        expect(data["available"]).to include("Post", "User")
      end

      it "caps an oversized model payload without breaking the JSON contract" do
        allow(RailsAiContext.configuration).to receive(:max_tool_response_chars).and_return(40)

        result = described_class.resolve("rails-ai-context://models/Post")
        text = result.first[:text]
        expect(text).to include("truncated")
        expect(text.length).to be <= 200
        expect { JSON.parse(text) }.not_to raise_error
      end
    end

    context "controllers" do
      it "resolves a controller URI" do
        result = described_class.resolve("rails-ai-context://controllers/PostsController")
        data = JSON.parse(result.first[:text])
        expect(data["actions"]).to include("index", "show", "create")
      end

      it "resolves flexible names" do
        result = described_class.resolve("rails-ai-context://controllers/posts")
        data = JSON.parse(result.first[:text])
        expect(data["actions"]).to include("index")
      end

      it "returns error for unknown controller" do
        result = described_class.resolve("rails-ai-context://controllers/WidgetsController")
        data = JSON.parse(result.first[:text])
        expect(data["error"]).to include("not found")
      end

      it "resolves a namespaced controller by its route key" do
        result = described_class.resolve("rails-ai-context://controllers/admin/posts")
        expect(JSON.parse(result.first[:text])).to include("actions")
      end

      # The routes resource answers this spelling, and answering "not found"
      # to one of two resources for the same name reads as a missing
      # controller.
      it "resolves a namespaced controller by its last path segment" do
        result = described_class.resolve("rails-ai-context://controllers/gift_cards")
        data = JSON.parse(result.first[:text])
        expect(data["actions"]).to include("redeem")
      end

      it "resolves a controller whose declared name does not camelize from its path" do
        result = described_class.resolve("rails-ai-context://controllers/activitypub/inboxes")
        expect(result.first[:text]).not_to include("not found")
      end

      it "caps an oversized controller payload without breaking the JSON contract" do
        allow(RailsAiContext.configuration).to receive(:max_tool_response_chars).and_return(40)

        result = described_class.resolve("rails-ai-context://controllers/PostsController")
        text = result.first[:text]
        expect(text).to include("truncated")
        expect(text.length).to be <= 200
        expect { JSON.parse(text) }.not_to raise_error
      end
    end

    context "controller actions" do
      it "resolves a controller action URI" do
        result = described_class.resolve("rails-ai-context://controllers/posts/show")
        data = JSON.parse(result.first[:text])
        expect(data["controller"]).to eq("PostsController")
        expect(data["action"]).to eq("show")
      end

      it "returns error for unknown action" do
        result = described_class.resolve("rails-ai-context://controllers/posts/destroy")
        data = JSON.parse(result.first[:text])
        expect(data["error"]).to include("not found")
      end

      it "includes applicable filters" do
        result = described_class.resolve("rails-ai-context://controllers/posts/index")
        data = JSON.parse(result.first[:text])
        expect(data["filters"]).to be_an(Array)
      end

      it "carries the inherited filters, ahead of the controller's own" do
        result = described_class.resolve("rails-ai-context://controllers/posts/show")
        data = JSON.parse(result.first[:text])
        expect(data["filters"].map { |f| f["name"] }).to eq(%w[set_locale authenticate_user! set_post])
      end
    end

    context "routes" do
      it "filters routes by controller" do
        result = described_class.resolve("rails-ai-context://routes/posts")
        data = JSON.parse(result.first[:text])
        expect(data["routes"].size).to eq(2)
        expect(data["total_routes"]).to eq(2)
        expect(data["filtered_by"]).to eq("posts")
      end

      it "flattens by_controller entries and restores the controller key" do
        result = described_class.resolve("rails-ai-context://routes/posts")
        data = JSON.parse(result.first[:text])
        expect(data["routes"]).to all(include("controller" => "posts"))
        expect(data["routes"].map { |r| r["path"] }).to contain_exactly("/posts", "/posts/:id")
        expect(data["routes"].first).to include("verb" => "GET", "action" => "index", "name" => "posts")
      end

      it "answers the same routes for the declared name and the route key" do
        by_key = JSON.parse(described_class.resolve("rails-ai-context://routes/posts").first[:text])
        by_name = JSON.parse(described_class.resolve("rails-ai-context://routes/PostsController").first[:text])
        expect(by_name["total_routes"]).to eq(by_key["total_routes"])
      end

      it "answers routes by route key for a controller that carries no file" do
        controllers = context[:controllers][:controllers].merge("ActivityPub::OutboxesController" => { actions: [ "show" ] })
        by_controller = context[:routes][:by_controller].merge(
          "activitypub/outboxes" => [ { verb: "GET", path: "/users/:id/outbox", action: "show", name: "outbox" } ]
        )
        allow(RailsAiContext).to receive(:introspect).and_return(
          context.merge(controllers: { controllers: controllers }, routes: context[:routes].merge(by_controller: by_controller))
        )

        data = JSON.parse(described_class.resolve("rails-ai-context://routes/activitypub/outboxes").first[:text])
        expect(data["total_routes"]).to eq(1)
      end

      it "returns an empty list for a controller that exists and has no routes" do
        result = described_class.resolve("rails-ai-context://routes/Admin::PostsController")
        data = JSON.parse(result.first[:text])
        expect(data["routes"]).to eq([])
        expect(data["total_routes"]).to eq(0)
      end

      # Zero because the controller has none, not zero because the name went
      # nowhere: the document has to say which.
      it "names the controller it resolved when that controller has no routes" do
        data = JSON.parse(described_class.resolve("rails-ai-context://routes/Admin::PostsController").first[:text])

        expect(data["resolved_controller"]).to eq("Admin::PostsController")
        expect(data["note"]).to include("no routes")
      end

      # A zero-route success document for a name that resolved to nothing
      # cannot be told apart from one for a name that does not exist, and the
      # sibling controllers resource already answers that case with an error.
      it "says so when the name resolves to no controller at all" do
        result = described_class.resolve("rails-ai-context://routes/TotallyMadeUpThing")
        data = JSON.parse(result.first[:text])

        expect(data["error"]).to include("TotallyMadeUpThing")
        expect(data["available"]).to include("posts", "users")
        expect(data).not_to have_key("total_routes")
      end

      # The tool answers this exact string with the routes; the resource
      # downcased the input without underscoring it, so "giftcards" never
      # equalled the key's own "gift_cards".
      it "resolves a short CamelCase controller name" do
        by_controller = context[:routes][:by_controller].merge(
          "api/v1/gift_cards" => [
            { verb: "POST", path: "/api/v1/gift-cards/redeem", action: "redeem", name: "api_v1_gift_cards_redeem" },
            { verb: "GET", path: "/api/v1/gift-cards/list", action: "list", name: "api_v1_gift_cards_list" }
          ]
        )
        allow(RailsAiContext).to receive(:introspect).and_return(
          context.merge(routes: context[:routes].merge(by_controller: by_controller))
        )

        data = JSON.parse(described_class.resolve("rails-ai-context://routes/GiftCards").first[:text])

        expect(data["total_routes"]).to eq(2)
        expect(data["routes"].map { |r| r["action"] }).to contain_exactly("redeem", "list")
      end

      # A route to a controller with no file resolves to no controller, so
      # the route keys are matched on the name's own route form.
      it "matches a CamelCase name against route keys when no controller resolves" do
        by_controller = context[:routes][:by_controller].merge(
          "stripe/webhooks" => [ { verb: "POST", path: "/stripe/webhooks", action: "create", name: "stripe_webhooks" } ]
        )
        allow(RailsAiContext).to receive(:introspect).and_return(
          context.merge(routes: context[:routes].merge(by_controller: by_controller))
        )

        data = JSON.parse(described_class.resolve("rails-ai-context://routes/Webhooks").first[:text])

        expect(data["total_routes"]).to eq(1)
        expect(data["routes"].first["controller"]).to eq("stripe/webhooks")
      end

      # A name that is all suffix leaves nothing to match, and an empty
      # needle is a substring of every route key.
      it "answers not found for a name that is only the controller suffix" do
        data = JSON.parse(described_class.resolve("rails-ai-context://routes/_controller").first[:text])

        expect(data["error"]).to include("not found")
        expect(data).not_to have_key("routes")
      end

      it "raises for bare routes URI without controller" do
        expect { described_class.resolve("rails-ai-context://routes") }
          .to raise_error(RailsAiContext::Error, /Unknown VFS URI/)
      end

      it "truncates payloads beyond max_tool_response_chars" do
        allow(RailsAiContext.configuration).to receive(:max_tool_response_chars).and_return(40)

        result = described_class.resolve("rails-ai-context://routes/posts")
        text = result.first[:text]
        expect(text).to include("truncated")
        expect(text.length).to be <= 200
        expect { JSON.parse(text) }.not_to raise_error
      end

      it "caps a large routing table without breaking the JSON contract" do
        many = 300.times.map { |i| { verb: "GET", path: "/posts/#{i}", action: "show", name: "post_#{i}" } }
        allow(RailsAiContext).to receive(:introspect).and_return(
          context.merge(routes: { by_controller: { "posts" => many } })
        )
        allow(RailsAiContext.configuration).to receive(:max_tool_response_chars).and_return(2_000)

        result = described_class.resolve("rails-ai-context://routes/posts")
        text = result.first[:text]
        expect(result.first[:mimeType]).to eq("application/json")
        expect(text.length).to be <= 2_000

        data = JSON.parse(text)
        # The counts stay put and the surviving entries are whole: the budget
        # comes out of the routes list, not off the end of the string.
        expect(data["filtered_by"]).to eq("posts")
        expect(data["total_routes"]).to eq(300)
        expect(data["routes"].size).to be_between(1, 299)
        expect(data["routes"]).to all(include("verb", "path", "action", "name", "controller"))
        expect(data["_truncated"]["clipped"]).to include(hash_including("path" => "routes", "total" => 300))
      end
    end

    context "views" do
      let(:views_dir) { Rails.root.join("app", "views") }
      let(:test_dir_name) { "vfs_test_views_#{Process.pid}" }

      before do
        FileUtils.mkdir_p(views_dir.join(test_dir_name))
        File.write(views_dir.join(test_dir_name, "index.html.erb"), "<h1>VFS Test</h1>")
      end

      after do
        FileUtils.rm_rf(views_dir.join(test_dir_name))
      end

      it "resolves a view URI" do
        result = described_class.resolve("rails-ai-context://views/#{test_dir_name}/index.html.erb")
        expect(result.first[:text]).to include("<h1>VFS Test</h1>")
        expect(result.first[:mimeType]).to eq("text/html")
      end

      it "blocks path traversal" do
        expect {
          described_class.resolve("rails-ai-context://views/../../etc/passwd")
        }.to raise_error(RailsAiContext::Error, /not allowed/)
      end

      it "reads the static tier's app root, not the booted app's" do
        Dir.mktmpdir do |static_root|
          FileUtils.mkdir_p(File.join(static_root, "app", "views", "greetings"))
          File.write(File.join(static_root, "app", "views", "greetings", "show.html.erb"), "<h1>Static</h1>")

          previous_tier = RailsAiContext.tier
          previous_root = RailsAiContext.configuration.app_root
          begin
            RailsAiContext.tier = :static
            RailsAiContext.configuration.app_root = static_root

            result = described_class.resolve("rails-ai-context://views/greetings/show.html.erb")
            expect(result.first[:text]).to include("<h1>Static</h1>")
          ensure
            RailsAiContext.tier = previous_tier
            RailsAiContext.configuration.app_root = previous_root
          end
        end
      end

      it "returns error for missing view" do
        result = described_class.resolve("rails-ai-context://views/vfs_nonexistent_#{Process.pid}/file.erb")
        data = JSON.parse(result.first[:text])
        expect(data["error"]).to include("not found")
      end
    end

    context "unknown URI" do
      it "raises for unrecognized URI" do
        expect {
          described_class.resolve("rails-ai-context://unknown/path")
        }.to raise_error(RailsAiContext::Error, /Unknown VFS URI/)
      end
    end

    it "calls introspect fresh each time" do
      expect(RailsAiContext).to receive(:introspect).twice.and_return(context)
      described_class.resolve("rails-ai-context://models/Post")
      described_class.resolve("rails-ai-context://routes/posts")
    end
  end
end
