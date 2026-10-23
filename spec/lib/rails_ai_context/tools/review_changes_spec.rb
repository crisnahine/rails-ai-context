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

    it "counts the context files the install writes beside the code as other files, not code" do
      %w[app/models/AGENTS.md app/controllers/CLAUDE.md app/services/AGENTS.md app/jobs/AGENTS.md db/migrate/README.md].each do |path|
        expect(described_class.send(:classify_file, path)).to eq(:other), path
      end
      expect(described_class.send(:classify_file, "app/models/concerns/taggable.rb")).to eq(:model)
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
    describe "the files filter" do
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
          %w[Gemfile Gemfile.lock app/models/user.rb app/models/user.rb.orig app/models/post.rb app/controllers/users_controller.rb].each { |path| write(path, "a\n") }
          git("add", "-A")
          git("commit", "-q", "-m", "init")
          %w[Gemfile Gemfile.lock app/models/user.rb app/models/user.rb.orig app/models/post.rb app/controllers/users_controller.rb].each { |path| write(path, "b\n") }
          example.run
        end
      end

      before { allow(described_class).to receive(:rails_app).and_return(double(root: Pathname.new(@dir))) }

      def reviewed(*files)
        described_class.call(ref: "HEAD", files: files).content.first[:text].scan(/^### (\S+)/).flatten
      end

      it "matches a whole path, not a file whose name contains it" do
        expect(reviewed("Gemfile")).to eq(%w[Gemfile])
        expect(reviewed("app/models/user.rb")).to eq(%w[app/models/user.rb])
      end

      it "matches the files under a directory, with or without its trailing slash" do
        expect(reviewed("app/models")).to contain_exactly("app/models/post.rb", "app/models/user.rb", "app/models/user.rb.orig")
        expect(reviewed("app/models/")).to eq(reviewed("app/models"))
      end

      it "takes several paths" do
        expect(reviewed("Gemfile", "app/controllers")).to contain_exactly("Gemfile", "app/controllers/users_controller.rb")
      end
    end

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

      # A hunk can open below a key's BEGIN line, where a body line read alone is any other line.
      it "filters a key's body in a hunk that opens inside the key, its header line too" do
        body = Array.new(12) { |i| "MIIEowIBAAKCAQEAu1SU1LfVLPHCozMxH2Mo4lgOEePzNm0tRgeLezV6ffAt0g#{i}" }
        key = [ "PRIVATE_KEY = <<~PEM", "-----BEGIN RSA PRIVATE KEY-----", *body, "-----END RSA PRIVATE KEY-----", "PEM", "" ].join("\n")
        write("config/initializers/jwt.rb", key)
        git("add", "-A")
        git("commit", "-q", "-m", "key")
        write("config/initializers/jwt.rb", key.sub("ffAt0g8", "ffAt0gX8"))

        text = described_class.call(ref: "HEAD").content.first[:text]
        expect(text).to include("+[FILTERED]", "-[FILTERED]")
        expect(text).not_to include("MIIEow")

        git("commit", "-q", "-am", "rotate")
        expect(described_class.call(ref: "HEAD~1").content.first[:text]).not_to include("MIIEow")
      end

      # git trims a hunk header's line and cuts it at 80 bytes, and the repository's own config shapes the diff.
      it "keeps a key's body hidden whatever git's config and its header trimming do to the diff" do
        body = Array.new(10) { |i| "MIIEowIBAAKCAQEAu1SU1LfVLPHCozMxH2Mo4lgOEePzNm0tRgeLezV6ffAt0gun#{'Q' * 50}#{i}   " }
        key = [ "-----BEGIN RSA PRIVATE KEY-----", *body, "-----END RSA PRIVATE KEY-----", *Array.new(8) { |i| "line #{i}" }, "" ].join("\n")
        write("config/fixtures/key.txt", key)
        git("add", "-A")
        git("commit", "-q", "-m", "key")
        write("config/fixtures/key.txt", key.sub("ffAt0gun#{'Q' * 50}8", "ffAt0gunX#{'Q' * 50}8"))
        git("config", "color.ui", "always")
        git("config", "diff.suppressBlankEmpty", "true")

        text = described_class.call(ref: "HEAD").content.first[:text]
        expect(text).to include("+[FILTERED]", "-[FILTERED]")
        expect(text).not_to include("MIIEow", "\e[")
      end

      it "shows no line of a hunk it cannot read, such as a merge conflict's" do
        write("config/fixtures/notes.txt", "a\n#{%(API_TOKEN = "#{token}")}\nb\n")
        git("add", "-A")
        git("commit", "-q", "-m", "notes")
        git("checkout", "-q", "-b", "other")
        write("config/fixtures/notes.txt", "a\n#{%(API_TOKEN = "#{token}x")}\nb\n")
        git("commit", "-q", "-am", "other")
        git("checkout", "-q", "-")
        write("config/fixtures/notes.txt", "a\n#{%(API_TOKEN = "#{token}y")}\nb\n")
        git("commit", "-q", "-am", "main")
        Open3.capture2e("git", "merge", "other", chdir: @dir)

        expect(described_class.call(ref: "HEAD").content.first[:text]).not_to include(token, "<<<<<<<")
      end

      # A removed `-- comment` reads `--- comment` in the diff, the shape of the file header.
      it "keeps a body line that reads like a file header in its place" do
        write("db/structure.sql", "line1\n-- Name: users\nline3 alpha\nline4 beta\nline5 gamma\n")
        git("add", "-A")
        git("commit", "-q", "-m", "sql")
        write("db/structure.sql", "line1\n++ x\nline3 alpha\nadded beta\nline4 beta\nline5 gamma\n")

        text = described_class.call(ref: "HEAD").content.first[:text]
        expect(text).to include("\n line1\n--- Name: users\n+++ x\n line3 alpha\n+added beta\n line4 beta\n line5 gamma\n")
      end

      # The builtin ruby driver picks the text after a line's indentation.
      it "shows a method's name in a hunk header that diff=ruby writes" do
        write(".gitattributes", "*.rb diff=ruby\n")
        write("app/models/total.rb", "class Total\n  def total_amount\n#{"    x = 1\n" * 10}  end\n  def token\n    \"#{token}\"\n#{"    y = 1\n" * 10}  end\nend\n")
        git("add", "-A")
        git("commit", "-q", "-m", "total")
        write("app/models/total.rb", File.read(File.join(@dir, "app/models/total.rb")).sub("    x = 1\n" * 10, "#{"    x = 1\n" * 7}    x = 2\n#{"    x = 1\n" * 2}"))

        text = described_class.call(ref: "HEAD").content.first[:text]
        expect(text).to include("@@ def total_amount")
        expect(text).not_to include(token)
      end

      it "reads a file that is not UTF-8, and keeps what says a binary file or a mode changed" do
        File.binwrite(File.join(@dir, "lib/latin.rb").tap { |path| FileUtils.mkdir_p(File.dirname(path)) }, "caf\xE9 = 1\n" * 5)
        File.binwrite(File.join(@dir, "lib/bin.dat"), "x\0y")
        write("lib/run.sh", "echo hi\n")
        git("add", "-A")
        git("commit", "-q", "-m", "files")
        File.binwrite(File.join(@dir, "lib/latin.rb"), "caf\xE9 = 1\n" * 4 + "caf\xE9 = 2\n")
        File.binwrite(File.join(@dir, "lib/bin.dat"), "x\0z")
        File.chmod(0o755, File.join(@dir, "lib/run.sh"))
        git("add", "-A")
        # Git for Windows ignores the file's mode, so the index is told.
        git("update-index", "--chmod=+x", "lib/run.sh")
        git("commit", "-q", "-m", "change")

        text = described_class.call(ref: "HEAD~1").content.first[:text]
        expect(text).to include("+caf\uFFFD = 2", "Binary files a/lib/bin.dat and b/lib/bin.dat differ", "old mode 100644", "new mode 100755")
        expect(text).not_to include("index ", "diff --git")
      end

      # git can print a submodule's own diff in place of its pointer, its files under the submodule's path.
      it "shows a submodule's change as its commits, never its files' lines" do
        Dir.mktmpdir do |sub|
          Open3.capture2e("git", "init", "-q", chdir: sub)
          File.write(File.join(sub, "a.key"), "oldkeyline\n")
          Open3.capture2e("git", "-c", "user.name=t", "-c", "user.email=t@t.t", "-c", "commit.gpgsign=false", "add", "-A", chdir: sub)
          Open3.capture2e("git", "-c", "user.name=t", "-c", "user.email=t@t.t", "-c", "commit.gpgsign=false", "commit", "-q", "-m", "a", chdir: sub)
          git("-c", "protocol.file.allow=always", "submodule", "add", "-q", sub, "lib/shared")
          git("commit", "-q", "-m", "sub")
          inner = File.join(@dir, "lib/shared")
          File.write(File.join(inner, "a.key"), "KEYSECRETBODY9f8e7d6c5b4a\n")
          Open3.capture2e("git", "-c", "user.name=t", "-c", "user.email=t@t.t", "-c", "commit.gpgsign=false", "commit", "-q", "-am", "b", chdir: inner)
          git("commit", "-q", "-am", "bump")
          git("config", "diff.submodule", "diff")

          text = described_class.call(ref: "HEAD~1").content.first[:text]
          expect(text).to include("Subproject commit")
          expect(text).not_to include("KEYSECRETBODY", "oldkeyline")
        end
      end

      it "shows no line of a file whose two sides together pass max_file_size" do
        write("config/fixtures/big.txt", "#{"x\n" * 400}API_TOKEN = \"#{token}\"\n")
        git("add", "-A")
        git("commit", "-q", "-m", "big")
        write("config/fixtures/big.txt", "#{"x\n" * 400}API_TOKEN = \"#{token}z\"\n")
        allow(RailsAiContext.configuration).to receive(:max_file_size).and_return(500)

        text = described_class.call(ref: "HEAD").content.first[:text]
        expect(text).to include("### config/fixtures/big.txt", "+1 / -1 lines")
        expect(text).not_to include(token, "```diff")
      end

      it "places each line where blank context lines sit as git prints them with suppressBlankEmpty" do
        write("app/models/x.rb", "a = 1\n" + "\n" * 7 + "b = 2\nx = 1\ny = 2\nz = 3\nc = 3\npassword = \"hunter2secretvalue\"\nd = 4\n")
        git("add", "-A")
        git("commit", "-q", "-m", "x")
        write("app/models/x.rb", File.read(File.join(@dir, "app/models/x.rb")).sub("c = 3", "c = 33"))
        git("config", "diff.suppressBlankEmpty", "true")

        text = described_class.call(ref: "HEAD").content.first[:text]
        expect(text).to include("-c = 3", "+c = 33", %( password = "[FILTERED]"), " d = 4")
      end

      it "filters a tracked log's short Bearer and Basic credentials as rails_read_logs does" do
        write("log/development.log", "Started GET /\n")
        git("add", "-A")
        git("commit", "-q", "-m", "log")
        write("log/development.log", "Started GET /\n  Authorization: Bearer abc123def456ghi\n  Authorization: Basic dXNlcjpwYXNz\n  HTTP_AUTHORIZATION=Basic dXNlcjpw\n")

        text = described_class.call(ref: "HEAD").content.first[:text]

        expect(text).not_to include("abc123def456ghi")
        expect(text).not_to include("dXNlcjpw")
        expect(text).to include("+  Authorization: [FILTERED]", "+  HTTP_AUTHORIZATION=[FILTERED]")
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
