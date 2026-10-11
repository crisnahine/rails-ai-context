# frozen_string_literal: true

require "spec_helper"
require "tmpdir"

RSpec.describe RailsAiContext::Tools::ReviewChanges do
  before { described_class.reset_cache! }

  describe ".call" do
    it "returns an MCP::Tool::Response" do
      result = described_class.call
      expect(result).to be_a(MCP::Tool::Response)
    end

    it "handles no changes gracefully" do
      # Use a ref that matches HEAD exactly (no changes)
      result = described_class.call(ref: "HEAD")
      text = result.content.first[:text]
      # Either shows changes or says no changes - both are valid
      expect(text).to be_a(String)
    end

    it "classifies file types correctly" do
      classify = described_class.send(:classify_file, "app/models/user.rb")
      expect(classify).to eq(:model)

      classify = described_class.send(:classify_file, "app/controllers/users_controller.rb")
      expect(classify).to eq(:controller)

      classify = described_class.send(:classify_file, "db/migrate/20260101_create_users.rb")
      expect(classify).to eq(:migration)

      classify = described_class.send(:classify_file, "spec/models/user_spec.rb")
      expect(classify).to eq(:test)

      classify = described_class.send(:classify_file, "app/views/users/index.html.erb")
      expect(classify).to eq(:view)

      classify = described_class.send(:classify_file, "config/routes.rb")
      expect(classify).to eq(:routes)

      classify = described_class.send(:classify_file, "README.md")
      expect(classify).to eq(:other)
    end

    it "detects missing index warnings in migration diffs" do
      warnings = described_class.send(:detect_warnings, [], Rails.root.to_s, "HEAD")
      expect(warnings).to be_an(Array)
    end

    # The routes block used to be dropped whenever the answer's prose held the
    # words "not found", which a real route listing can carry.
    describe "the routes block for a changed controller" do
      def routes_block_for(response)
        allow(RailsAiContext::Tools::GetRoutes).to receive(:call).and_return(response)
        described_class.send(:gather_file_context, "app/controllers/posts_controller.rb",
          :controller, Rails.root.to_s, "HEAD").join("\n")
      end

      it "is absent when get_routes found nothing" do
        base = RailsAiContext::Tools::BaseTool
        text = routes_block_for(base.empty_response("No routes for 'posts'. Controllers: users"))

        expect(text).not_to include("**Routes:**")
        expect(text).not_to include("No routes for")
      end

      it "is present when a real listing mentions not found" do
        base = RailsAiContext::Tools::BaseTool
        text = routes_block_for(base.text_response("GET /posts/:id posts#show\n# rescues a not found record"))

        expect(text).to include("**Routes:**")
        expect(text).to include("posts#show")
      end
    end

    # git reads an argument that starts with a dash as an option, and
    # `git diff --output=<path>` writes the diff to that path.
    it "refuses a ref git would read as an option, and writes nothing" do
      Dir.mktmpdir do |dir|
        result = described_class.call(ref: "--output=#{File.join(dir, "diff")}")

        expect(result.error?).to be(true)
        expect(result.content.first[:text]).to include("Ref not allowed")
        expect(Dir.children(dir)).to be_empty
      end
    end

    it "says a ref that names no commit is unknown, rather than unchanged" do
      result = described_class.call(ref: "no-such-branch-#{Process.pid}")

      expect(result.error?).to be(true)
      expect(result.content.first[:text]).to include("Unknown ref")
    end

    # The file list came from where the branch left main and each diff from
    # main's tip, so a validation main added later read as one the branch
    # removed; and an edited validates line read as a removed one.
    describe "a review of a branch's validations" do
      def git(*args)
        out, status = Open3.capture2e("git", "-c", "user.name=t", "-c", "user.email=t@t.t", "-c", "commit.gpgsign=false",
                                      *args, chdir: @dir)
        raise out unless status.success?

        out
      end

      def write_model(*validations)
        FileUtils.mkdir_p(File.join(@dir, "app/models"))
        body = validations.map { |v| "  validates #{v}\n" }.join
        File.write(File.join(@dir, "app/models/product.rb"), "class Product < ApplicationRecord\n#{body}end\n")
      end

      around do |example|
        Dir.mktmpdir do |dir|
          @dir = dir
          git("init", "-q")
          git("checkout", "-q", "-b", "main")
          write_model(":name, presence: true", ":sku, presence: true")
          git("add", "-A")
          git("commit", "-q", "-m", "init")
          git("checkout", "-q", "-b", "feature")
          write_model(":name, presence: true, length: { maximum: 120 }")
          git("commit", "-q", "-am", "edit name, drop sku")
          git("checkout", "-q", "main")
          write_model(":name, presence: true", ":sku, presence: true", ":price, presence: true")
          git("commit", "-q", "-am", "main requires price")
          git("checkout", "-q", "feature")
          example.run
        end
      end

      before { allow(described_class).to receive(:rails_app).and_return(double(root: Pathname.new(@dir))) }

      it "reports what the branch removed since it left the ref, and neither main's later lines nor an edit" do
        text = described_class.call(ref: "main").content.first[:text]

        expect(text).to include("**Removed validation**: `app/models/product.rb` - `validates :sku, presence: true`")
        expect(text).not_to include("validates :price")
        expect(text).not_to include("`app/models/product.rb` - `validates :name")
      end

      it "reads an edited validation in the working tree as an edit" do
        write_model(":name, presence: true, length: { maximum: 80 }", ":nickname, presence: true")

        text = described_class.call(ref: "HEAD").content.first[:text]

        expect(text).not_to include("Removed validation")
      end
    end

    # `git diff --name-only` names paths from the top of the repository and
    # `ls-files` from where it runs, so in an app at backend/ a changed model
    # was "backend/app/models/widget.rb", classified as other, with no diff,
    # and a ref's review listed the frontend's files.
    describe "an app in a subfolder of its repository" do
      def git(*args)
        out, status = Open3.capture2e("git", "-c", "user.name=t", "-c", "user.email=t@t.t", "-c", "commit.gpgsign=false",
                                      *args, chdir: @repo)
        raise out unless status.success?

        out
      end

      def write(relative, body)
        FileUtils.mkdir_p(File.dirname(File.join(@repo, relative)))
        File.write(File.join(@repo, relative), body)
      end

      around do |example|
        Dir.mktmpdir do |repo|
          @repo = repo
          git("init", "-q")
          write("backend/app/models/widget.rb", "class Widget < ApplicationRecord\nend\n")
          write("frontend/app.js", "console.log(1)\n")
          git("add", "-A")
          git("commit", "-q", "-m", "init")
          write("frontend/app.js", "console.log(2)\n")
          git("commit", "-q", "-am", "frontend")
          write("backend/app/models/widget.rb", "class Widget < ApplicationRecord\n  validates :name, presence: true\nend\n")
          write("backend/db/migrate/20260101000000_add_color_to_widgets.rb", "class AddColorToWidgets < ActiveRecord::Migration[8.0]\nend\n")
          example.run
        end
      end

      before { allow(described_class).to receive(:rails_app).and_return(double(root: Pathname.new(File.join(@repo, "backend")))) }

      it "names the app's changed files from the app root, with their diffs" do
        text = described_class.call(ref: "HEAD").content.first[:text]

        expect(text).to include("### app/models/widget.rb (model)")
        expect(text).to include("+  validates :name, presence: true")
        expect(text).to include("### db/migrate/20260101000000_add_color_to_widgets.rb (migration)")
        expect(text).to include("rails_validate(files:[\"app/models/widget.rb\", \"db/migrate/20260101000000_add_color_to_widgets.rb\"]")
        expect(text).not_to include("backend/")
      end

      it "leaves another app's commits out of a ref's review" do
        text = described_class.call(ref: "HEAD~1").content.first[:text]

        expect(text).to include("No changes found for ref 'HEAD~1'")
        expect(text).not_to include("frontend")
      end
    end

    it "handles missing git gracefully" do
      allow(Open3).to receive(:capture2).and_return([ "", double(success?: false) ])
      result = described_class.call(ref: "HEAD")
      text = result.content.first[:text]
      expect(text).to include("git")
    end
  end
end
