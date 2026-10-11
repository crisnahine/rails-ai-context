# frozen_string_literal: true

require_relative "e2e_helper"

# One stdio MCP session against an app that changes under it, the way an
# agent works: it edits a file and asks about it at once. The server runs in
# development, as a client starts it (no RAILS_ENV of its own), and without
# `listen` in the bundle, as in a new Rails 8 app: each call checks the
# app's files itself and reloads its code when they moved. The same session
# reads resources by URI and runs rails_query.
#
# A copy of the shared in-Gemfile app, since the examples edit its files;
# each puts back what it changed.
RSpec.describe "E2E: an MCP session while the app changes", type: :e2e do
  before(:all) do
    source = E2E.shared_app(install_path: :in_gemfile)
    @app = source.copy_to(parent_dir: File.join(E2E.root, "mcp_live_session"), name: "blog")
    @env = @app.env.merge("RAILS_ENV" => "development")

    # The development database as bin/setup leaves it, holding one post for
    # the query examples to read.
    seed = File.join(@app.app_path, "tmp", "e2e_seed.rb")
    File.write(seed, %(Post.create!(title: "E2E query probe", body: "seeded", published: true)\n))
    [ %w[bin/rails db:prepare], [ "bin/rails", "runner", seed ] ].each do |cmd|
      out, status = Open3.capture2e(@env, *E2E::TestAppBuilder.script_command(cmd), chdir: @app.app_path)
      raise "#{cmd.join(' ')} failed:\n#{out}" unless status.success?
    end

    @mcp = E2E::McpStdioClient.new(nil, timeout: 90, launch: {
      env: @env, command: [ *@app.cli_command, "serve" ], chdir: @app.app_path
    }).start!
    @mcp.initialize!
  end

  after(:all) { @mcp&.stop! }

  def app_file(relative) = File.join(@app.app_path, relative)

  def text(response) = response.dig("result", "content", 0, "text").to_s

  def model_details = text(@mcp.call_tool("rails_get_model_details", { model: "Post" }))

  # Writes `content` to the app file for the block, then puts the file back.
  def editing(relative, content)
    path = app_file(relative)
    original = File.read(path)
    File.write(path, content)
    yield path
  ensure
    File.write(path, original) if original
  end

  describe "an edit made a moment before the call" do
    it "runs where nothing but the call's own check can see an edit: no listen in the bundle" do
      expect(File.read(app_file("Gemfile.lock"))).not_to match(/^ {4}listen \(/)
    end

    it "is in the answer: an association and a scope added to a model" do
      expect(model_details).not_to include("comments")

      editing("app/models/post.rb", <<~RUBY) do
        class Post < ApplicationRecord
          has_many :comments
          scope :published, -> { where(published: true) }
        end
      RUBY
        answer = model_details
        expect(answer).to match(/has_many\W+comments/)
        expect(answer).to include("published").and include("where(published: true)")
      end
    end

    # The server crashed on a file saved mid-edit, or answered from before it.
    it "reports a model saved with a syntax error, then reads the fix the next call" do
      editing("app/models/post.rb", "class Post < ApplicationRecord\n  has_many :comments\n  def summary(\nend\n") do |path|
        broken = @mcp.call_tool("rails_get_model_details", { model: "Post" })
        expect(broken["error"]).to be_nil, broken.inspect
        expect(text(broken)).to include("syntax error").and include("app/models/post.rb")

        File.write(path, <<~RUBY)
          class Post < ApplicationRecord
            has_many :comments
            scope :drafts, -> { where(published: false) }
          end
        RUBY
        fixed = model_details
        expect(fixed).not_to include("syntax error")
        expect(fixed).to include("drafts").and include("where(published: false)")
      end
    end
  end

  describe "resources" do
    # The resource was described as the action's source and never carried it.
    it "reads an action as its file, its lines and its source, with a literal secret filtered" do
      # Built at run time: GitHub's push protection refuses a literal key.
      key = "sk_live_#{'b' * 24}"
      controller = File.read(app_file("app/controllers/posts_controller.rb"))
      edited = controller.sub("  def index\n", "  def index\n    gateway = \"#{key}\"\n")
      expect(edited).not_to eq(controller)

      editing("app/controllers/posts_controller.rb", edited) do |path|
        response = @mcp.request("resources/read", { uri: "rails-ai-context://controllers/PostsController/index" })
        action = JSON.parse(response.dig("result", "contents", 0, "text"))

        expect(action).to include("controller" => "PostsController", "action" => "index",
                                  "file" => "app/controllers/posts_controller.rb")
        first, last = action["lines"].to_s.split("-").map(&:to_i)
        expect(first).to be_positive
        expect(action["source"].lines.size).to eq(last - first + 1)
        expect(File.readlines(path)[first - 1].chomp).to eq("  def index")
        expect(action["source"]).to include("def index").and include(%(gateway = "[FILTERED]"))
        expect(JSON.generate(response)).not_to include(key)
      end
    end

    # A read for a name the app does not have came back as a successful read
    # holding an "error" key.
    it "fails an unknown URI with -32602 and the URIs it serves" do
      response = @mcp.request("resources/read", { uri: "rails-ai-context://nothing/here" }, raise_on_error: false)

      expect(response["result"]).to be_nil
      expect(response.dig("error", "code")).to eq(-32602)
      expect(response.dig("error", "data", "available"))
        .to include("rails-ai-context://controllers/{name}/{action}", "rails://schema")
    end

    it "fails an unknown controller with -32602 and the controllers the app has" do
      response = @mcp.request("resources/read", { uri: "rails-ai-context://controllers/NopeController/index" },
                              raise_on_error: false)

      expect(response.dig("error", "code")).to eq(-32602)
      expect(response.dig("error", "data", "available")).to include("PostsController")
    end
  end

  describe "rails_query" do
    it "answers a SELECT" do
      response = @mcp.call_tool("rails_query", { sql: "SELECT title, published FROM posts" })

      expect(response.dig("result", "isError")).not_to eq(true), text(response)
      expect(text(response)).to include("E2E query probe")
    end

    it "refuses an UPDATE, and the row stays as it was" do
      response = @mcp.call_tool("rails_query", { sql: "UPDATE posts SET title = 'changed by e2e'" })

      expect(response.dig("result", "isError")).to eq(true), text(response)
      expect(text(response)).to include("UPDATE")
      after = text(@mcp.call_tool("rails_query", { sql: "SELECT title FROM posts" }))
      expect(after).to include("E2E query probe")
      expect(after).not_to include("changed by e2e")
    end
  end
end
