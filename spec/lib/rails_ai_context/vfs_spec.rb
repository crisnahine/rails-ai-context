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
          "PostsController" => {
            actions: [ "index", "show", "create" ],
            filters: [ { kind: "before", name: "authenticate_user!" } ],
            strong_params: [ { name: "post_params", requires: :post, permits: [ :title ] } ]
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

      it "returns an empty list for a controller with no routes" do
        result = described_class.resolve("rails-ai-context://routes/widgets")
        data = JSON.parse(result.first[:text])
        expect(data["routes"]).to eq([])
        expect(data["total_routes"]).to eq(0)
        expect(data["filtered_by"]).to eq("widgets")
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

      it "blocks sibling-directory traversal via symlink (v5.8.1 C1)" do
        # Reproduces the v5.8.1 security review finding: String#start_with?
        # without a File::SEPARATOR check matches `/a/views_spec` against
        # `/a/views` prefix, letting a symlink in app/views/ escape to a
        # sibling directory.
        sibling_dir = Rails.root.join("app", "views_spec_#{Process.pid}")
        FileUtils.mkdir_p(sibling_dir)
        secret_file = sibling_dir.join("secret.html.erb")
        File.write(secret_file, "<h1>SIBLING SECRET</h1>")

        symlink = views_dir.join("leak_#{Process.pid}.html.erb")
        File.symlink(secret_file, symlink)

        expect {
          described_class.resolve("rails-ai-context://views/leak_#{Process.pid}.html.erb")
        }.to raise_error(RailsAiContext::Error, /not allowed/)
      ensure
        FileUtils.rm_f(symlink) if defined?(symlink)
        FileUtils.rm_rf(sibling_dir) if defined?(sibling_dir)
      end

      it "blocks caller-supplied sensitive names BEFORE filesystem stat (existence oracle)" do
        # The pre-fix `resolve_view` would call File.exist? on the requested
        # path first, then only run sensitive_file? after realpath. That
        # gave two distinct error messages - "View not found" vs "sensitive
        # file" - which a caller could use to probe whether app/views/.env
        # exists. The fix adds an early sensitive_file? check before any
        # filesystem stat, so the rejection reason is identical regardless
        # of whether the file is present.
        expect {
          described_class.resolve("rails-ai-context://views/.env")
        }.to raise_error(RailsAiContext::Error, /sensitive|not allowed/)

        expect {
          described_class.resolve("rails-ai-context://views/master.key")
        }.to raise_error(RailsAiContext::Error, /sensitive|not allowed/)
      end

      it "blocks sensitive files resolved via symlink (v5.8.1 C1 defense-in-depth)" do
        # If a .key or .env file is symlinked into app/views/, the realpath
        # would be under views_dir but the file is sensitive. sensitive_file?
        # on the realpath catches this.
        secret = Rails.root.join("config", "_vfs_test_master_#{Process.pid}.key")
        File.write(secret, "should-never-leak")
        symlink = views_dir.join("leak_secret_#{Process.pid}.key")
        File.symlink(secret, symlink)

        expect {
          described_class.resolve("rails-ai-context://views/leak_secret_#{Process.pid}.key")
        }.to raise_error(RailsAiContext::Error, /sensitive|not allowed/)
      ensure
        FileUtils.rm_f(symlink) if defined?(symlink)
        FileUtils.rm_f(secret) if defined?(secret)
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
