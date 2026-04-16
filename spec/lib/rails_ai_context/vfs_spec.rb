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
        routes: [
          { controller: "posts", action: "index", verb: "GET", path: "/posts" },
          { controller: "posts", action: "show", verb: "GET", path: "/posts/:id" },
          { controller: "users", action: "index", verb: "GET", path: "/users" }
        ]
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
        expect(result.first[:mime_type]).to eq("application/json")

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
        expect(data["filtered_by"]).to eq("posts")
      end

      it "raises for bare routes URI without controller" do
        expect { described_class.resolve("rails-ai-context://routes") }
          .to raise_error(RailsAiContext::Error, /Unknown VFS URI/)
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
        expect(result.first[:mime_type]).to eq("text/html")
      end

      it "blocks path traversal" do
        expect {
          described_class.resolve("rails-ai-context://views/../../etc/passwd")
        }.to raise_error(RailsAiContext::Error, /not allowed/)
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
        # gave two distinct error messages — "View not found" vs "sensitive
        # file" — which a caller could use to probe whether app/views/.env
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
