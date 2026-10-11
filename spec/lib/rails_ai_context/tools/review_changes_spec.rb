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

    # Longer than one argument to git may be (128 KB on Linux, some 32,000
    # characters for a whole Windows command line): starting git raised,
    # and the answer was the error with the whole ref in it.
    it "says a ref too long to hand git is unknown, and repeats it shortened" do
      result = described_class.call(ref: "r" * 200_000)

      expect(result.error?).to be(true)
      expect(result.content.first[:text]).to start_with("Unknown ref: #{'r' * 80}... (200000 characters)")
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

    # The diff was printed as git gave it, so a secret a change adds or takes
    # out reached the caller whole, as every other tool's source does not, and
    # a file on sensitive_patterns had its lines shown too.
    describe "a diff that holds secrets" do
      let(:token) { "Xk2mQ9pLw7Rt#{'Z4ab'}" }
      let(:live_key) { "sk_live_#{'b' * 24}" }

      def git(*args)
        out, status = Open3.capture2e("git", "-c", "user.name=t", "-c", "user.email=t@t.t", "-c", "commit.gpgsign=false",
                                      *args, chdir: @dir)
        raise out unless status.success?

        out
      end

      def write(relative, body)
        FileUtils.mkdir_p(File.dirname(File.join(@dir, relative)))
        File.write(File.join(@dir, relative), body)
      end

      around do |example|
        Dir.mktmpdir do |dir|
          @dir = dir
          git("init", "-q")
          write("config/initializers/billing.rb", %(API_TOKEN = "#{token}"\n) + "  a = 1\n" * 8)
          git("add", "-A")
          git("commit", "-q", "-m", "init")
          example.run
        end
      end

      before { allow(described_class).to receive(:rails_app).and_return(double(root: Pathname.new(@dir))) }

      def add_secrets
        write("config/initializers/billing.rb", %(API_TOKEN = "#{token}"\n) + "  a = 1\n" * 7 + "  a = 2\n" +
                                               %(STRIPE_KEY = "#{live_key}"\nSEED = { password: "hunter2xy" }.freeze\n))
        write("config/settings.yml", "production:\n  api_token: #{token}\n")
        write("Procfile.dev", "redis: redis-server --requirepass #{token}\n")
        write("config/database.yml", "production:\n  password: #{token}\n")
        write(".env", "PLAIN_SETTING=#{token}\n")
      end

      it "filters the secrets a committed change adds, a hunk header's line among them, and shows no line of a sensitive file" do
        add_secrets
        git("add", "-A")
        git("commit", "-q", "-m", "secrets")

        text = described_class.call(ref: "HEAD~1").content.first[:text]

        expect(text).not_to include(token)
        expect(text).not_to include(live_key)
        expect(text).not_to include("hunter2xy")
        expect(text).to include(%(+STRIPE_KEY = "[FILTERED]"), %(+SEED = { password: "[FILTERED]" }.freeze))
        expect(text).to include(%(@@ API_TOKEN = "[FILTERED]"), "+  api_token: [FILTERED]", "+redis: redis-server --requirepass [FILTERED]")
        expect(text).to include("### config/database.yml (config)", "### .env (other)")
        expect(text.scan("_diff not shown: the file is on `sensitive_patterns`_").size).to eq(2)
      end

      it "filters them in uncommitted changes as well" do
        add_secrets
        git("add", "config/settings.yml")

        text = described_class.call(ref: "HEAD").content.first[:text]

        expect(text).not_to include(token)
        expect(text).not_to include(live_key)
        expect(text).to include("+  api_token: [FILTERED]", %(+STRIPE_KEY = "[FILTERED]"))
      end

      it "filters a secret a change takes out, and leaves the line that replaced it as git gave it" do
        write("config/initializers/billing.rb", %(API_TOKEN = ENV.fetch("API_TOKEN")\n) + "  a = 1\n" * 8)

        text = described_class.call(ref: "HEAD").content.first[:text]

        expect(text).to include(%(-API_TOKEN = "[FILTERED]"), %(+API_TOKEN = ENV.fetch("API_TOKEN")))
        expect(text).not_to include(token)
      end
    end

    # Only `create_table :sym` and `add_column :sym, ...` were read, so a
    # migration naming its table as a string or in parentheses said nothing.
    it "reads a migration's table however the call is written" do
      Dir.mktmpdir do |dir|
        system("git", "init", "-q", dir, exception: true)
        system("git", "-C", dir, "-c", "user.name=t", "-c", "user.email=t@t.t", "-c", "commit.gpgsign=false",
               "commit", "-q", "--allow-empty", "-m", "init", exception: true)
        FileUtils.mkdir_p(File.join(dir, "db/migrate"))
        File.write(File.join(dir, "db/migrate/20260101000000_change_orders.rb"), <<~RUBY)
          class ChangeOrders < ActiveRecord::Migration[8.0]
            def change
              change_table "orders" do |t|
                t.string :status
              end
              add_column("orders", :coupon_id, :integer)
            end
          end
        RUBY
        allow(described_class).to receive(:rails_app).and_return(double(root: Pathname.new(dir)))

        text = described_class.call(ref: "HEAD").content.first[:text]

        expect(text).to include("**Affects tables:** orders")
        expect(text).to include("**Missing index**: `db/migrate/20260101000000_change_orders.rb` adds `coupon_id` without an index")
      end
    end

    # remove_columns, rename_index and the join table methods were not on
    # the list, so `remove_columns :users, :name` named no table. A join
    # table is named from its two tables as Rails names it, unless
    # `table_name:` names it; drop_table drops each table it is given.
    it "reads every table a migration's schema methods name" do
      Dir.mktmpdir do |dir|
        system("git", "init", "-q", dir, exception: true)
        system("git", "-C", dir, "-c", "user.name=t", "-c", "user.email=t@t.t", "-c", "commit.gpgsign=false",
               "commit", "-q", "--allow-empty", "-m", "init", exception: true)
        FileUtils.mkdir_p(File.join(dir, "db/migrate"))
        File.write(File.join(dir, "db/migrate/20260101000000_reshape_accounts.rb"), <<~RUBY)
          class ReshapeAccounts < ActiveRecord::Migration[8.0]
            def change
              remove_columns :users, :name, :email, type: :string
              create_join_table :users, :roles
              drop_join_table :admin_users, :admin_roles
              create_join_table "posts", "tags", table_name: :taggings
              rename_index :accounts, "index_accounts_on_name", "index_accounts_on_title"
              rename_table(:orders, :purchases)
              drop_table :legacy_events, :legacy_logs, if_exists: true
              change_table :invoices do |t|
                t.remove_index :number
              end
              # remove_column :ghosts, :name
            end
          end
        RUBY
        allow(described_class).to receive(:rails_app).and_return(double(root: Pathname.new(dir)))

        text = described_class.call(ref: "HEAD").content.first[:text]

        expect(text).to include("**Affects tables:** users, roles_users, roles, admin_roles_users, admin_users, admin_roles, " \
                                "taggings, posts, tags, accounts, orders, purchases, legacy_events, legacy_logs, invoices\n")
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
