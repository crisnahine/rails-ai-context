# frozen_string_literal: true

require "spec_helper"

RSpec.describe RailsAiContext::Tools::Validate do
  before { described_class.reset_cache! }

  describe ".call" do
    it "validates a valid Ruby file" do
      result = described_class.call(files: [ "app/models/post.rb" ])
      text = result.content.first[:text]
      expect(text).to include("syntax OK")
      expect(text).to include("1/1 files passed")
      expect(result.error?).to be false
    end

    it "detects bad Ruby syntax" do
      tmp_dir = File.join(Rails.root, "tmp")
      FileUtils.mkdir_p(tmp_dir)
      bad_file = File.join(tmp_dir, "bad_syntax_test.rb")
      File.write(bad_file, "def foo\n  puts(\"hello\"\nend")
      begin
        result = described_class.call(files: [ "tmp/bad_syntax_test.rb" ])
        text = result.content.first[:text]
        expect(text).to include("0/1 files passed")
        expect(result.error?).to be true
      ensure
        File.delete(bad_file) if File.exist?(bad_file)
      end
    end

    # Keyword arguments in index assignment became a syntax error in Ruby 3.4.
    context "with Ruby the app's own version accepts and the newest rejects" do
      let(:grid) { File.join(Rails.root, "tmp", "grid_index_kwargs.rb") }

      before do
        FileUtils.mkdir_p(File.dirname(grid))
        File.write(grid, "class Grid\n  def put(cells, v)\n    cells[0, strict: true] = v\n  end\nend\n")
      end

      after { FileUtils.rm_f(grid) }

      def validate_as(ruby, static:)
        allow(RailsAiContext).to receive(:static_tier?).and_return(static)
        allow(described_class).to receive(:rails_app).and_return(Rails.application)
        stub_const("RUBY_VERSION", ruby) unless static
        lock = instance_double(RailsAiContext::GemLock::Spec, ruby_version: ruby)
        allow(RailsAiContext::GemLock).to receive(:for).and_call_original
        allow(RailsAiContext::GemLock).to receive(:for).with(Rails.root.to_s).and_return(lock)
        described_class.call(files: [ "tmp/grid_index_kwargs.rb" ]).content.first[:text]
      end

      it "passes it statically for an app that declares Ruby 3.1 or 3.3" do
        expect(validate_as("3.1.6", static: true)).to include("1/1 files passed")
        expect(validate_as("3.3.9", static: true)).to include("1/1 files passed")
      end

      it "passes it booted on Ruby 3.3, and fails it for an app on Ruby 3.4" do
        expect(validate_as("3.3.9", static: false)).to include("1/1 files passed")
        expect(validate_as("3.4.9", static: true)).to include("0/1 files passed")
      end
    end

    # Five SQL-injection warnings for listing.rb printed under public.rb's
    # heading, at the indent that says "this file", because they were appended
    # after the loop.
    context "with Brakeman findings for one of several files" do
      before do
        allow(RailsAiContext::Tools::ValidateSemantics).to receive(:check_brakeman_security)
          .and_return("app/models/post.rb" => [ "[Medium] SQL Injection - app/models/post.rb:12: Post.where(params)" ])
      end

      it "prints the finding under the file it belongs to" do
        text = described_class.call(files: [ "app/models/post.rb", "app/models/comment.rb" ], level: "rails")
                              .content.first[:text]
        lines = text.split("\n")
        post_at = lines.index { |l| l.include?("app/models/post.rb - syntax OK") }
        comment_at = lines.index { |l| l.include?("app/models/comment.rb - syntax OK") }

        expect(lines[(post_at + 1)...comment_at].grep(/SQL Injection/).size).to eq(1)
      end

      it "leaves nothing under a file with no finding of its own" do
        text = described_class.call(files: [ "app/models/comment.rb", "app/models/post.rb" ], level: "rails")
                              .content.first[:text]
        lines = text.split("\n")
        comment_at = lines.index { |l| l.include?("app/models/comment.rb - syntax OK") }
        post_at = lines.index { |l| l.include?("app/models/post.rb - syntax OK") }

        expect(lines[(comment_at + 1)...post_at].grep(/SQL Injection/)).to eq([])
      end

      # A file the loop never reaches still has a finding to report, and the
      # message names the file, so it goes out unindented rather than silently.
      it "reports a finding for a file the loop skipped, naming the file" do
        allow(RailsAiContext::Tools::ValidateSemantics).to receive(:check_brakeman_security)
          .and_return("config/database.yml" => [ "[High] SQL Injection - config/database.yml:3: something" ])

        text = described_class.call(files: [ "config/database.yml" ], level: "rails").content.first[:text]

        expect(text).to include("\u26A0 [High] SQL Injection - config/database.yml:3")
        expect(text).not_to include("  \u26A0 [High]")
      end
    end

    it "returns error for non-existent files" do
      result = described_class.call(files: [ "nonexistent/file.rb" ])
      text = result.content.first[:text]
      expect(text).to include("file not found")
    end

    it "rejects path traversal attempts" do
      result = described_class.call(files: [ "../../etc/passwd" ])
      text = result.content.first[:text]
      expect(text).to match(/not found|not allowed/)
    end

    it "enforces MAX_FILES limit" do
      files = 55.times.map { |i| "app/models/fake#{i}.rb" }
      result = described_class.call(files: files)
      text = result.content.first[:text]
      expect(text).to include("Too many files")
    end

    it "skips unsupported file types" do
      # package.json is neither sensitive nor a validatable language - it
      # should be skipped, not denied. (Previously this test used
      # config/database.yml which is now blocked by the v5.8.1 expanded
      # sensitive_patterns list.)
      result = described_class.call(files: [ "package.json" ])
      text = result.content.first[:text]
      expect(text).to include("skipped")
    end

    it "denies access to sensitive files (v5.8.1)" do
      # config/database.yml, .env, config/master.key - all blocked by the
      # v5.8.1 sensitive_patterns expansion. validate.rb previously had no
      # sensitive_file? check at all, so these would be read + probed via
      # error messages.
      result = described_class.call(files: [ "config/database.yml" ])
      text = result.content.first[:text]
      expect(text).to include("access denied")
      expect(text).to include("sensitive file")
    end

    it "returns empty message for no files" do
      result = described_class.call(files: [])
      text = result.content.first[:text]
      expect(text).to include("No files provided")
    end

    it "validates multiple files at once" do
      result = described_class.call(files: [ "app/models/post.rb", "app/models/user.rb" ])
      text = result.content.first[:text]
      expect(text).to include("2/2 files passed")
    end
  end

  describe "strong params vs schema check", skip: (!defined?(Prism) && "requires Prism (Ruby 3.3+)") do
    let(:controllers_dir) { File.join(Rails.root, "app", "controllers") }

    after do
      path = File.join(controllers_dir, "posts_bad_params_controller.rb")
      File.delete(path) if File.exist?(path)
    end

    it "flags permitted params that are not columns in the table" do
      File.write(File.join(controllers_dir, "posts_bad_params_controller.rb"), <<~RUBY)
        class PostsBadParamsController < ApplicationController
          def create
            @post = Post.new(post_params)
          end

          private

          def post_params
            params.require(:post).permit(:title, :nonexistent_field, :totally_fake)
          end
        end
      RUBY

      result = described_class.call(
        files: [ "app/controllers/posts_bad_params_controller.rb" ],
        level: "rails"
      )
      text = result.content.first[:text]
      expect(text).to include("permits :nonexistent_field")
      expect(text).to include("permits :totally_fake")
      expect(text).not_to include("permits :title") # title is a valid column
    end
  end

  describe "route helper validation", skip: (!defined?(Prism) && "requires Prism (Ruby 3.3+)") do
    let(:tmp_dir) { File.join(Rails.root, "tmp") }
    let(:file_path) { File.join(tmp_dir, "local_route_helper_test.rb") }

    before { FileUtils.mkdir_p(tmp_dir) }

    after do
      File.delete(file_path) if File.exist?(file_path)
    end

    it "does not report locally defined _url methods as missing route helpers" do
      File.write(file_path, <<~RUBY)
        class LocalRouteHelperTest
          def call
            provider_metadata_url
          end

          private

          def provider_metadata_url
            "https://example.test/.well-known/openid-configuration"
          end
        end
      RUBY

      result = described_class.call(files: [ "tmp/local_route_helper_test.rb" ], level: "rails")
      text = result.content.first[:text]

      expect(text).not_to include("provider_metadata_url - route helper not found")
      expect(text).to include("1/1 files passed")
    end

    # An attribute reader has no `def` to find, so a column named like a
    # helper read as a broken route until the column list was consulted.
    it "does not report a model's own *_url column as a missing route helper" do
      result = described_class.call(files: [ "app/models/post.rb" ], level: "rails")
      text = result.content.first[:text]

      expect(text).not_to include("canonical_url - route helper not found")
      expect(text).to include("1/1 files passed")
    end

    it "still reports route-like calls when the local method is defined in another class" do
      File.write(file_path, <<~RUBY)
        class LocalRouteDefinition
          def provider_metadata_url
            "https://example.test/.well-known/openid-configuration"
          end
        end

        class OtherRouteCaller
          def call
            provider_metadata_url
          end
        end
      RUBY

      result = described_class.call(files: [ "tmp/local_route_helper_test.rb" ], level: "rails")
      text = result.content.first[:text]

      expect(text).to include("provider_metadata_url - route helper not found")
    end

    it "does not report private inline _url method definitions in regex fallback mode" do
      allow(RailsAiContext::Tools::ValidateSemantics).to receive(:parse_and_visit).and_return(nil)

      File.write(file_path, <<~RUBY)
        class LocalRouteHelperTest
          def call
            provider_metadata_url
          end

          private def provider_metadata_url
            "https://example.test/.well-known/openid-configuration"
          end
        end
      RUBY

      result = described_class.call(files: [ "tmp/local_route_helper_test.rb" ], level: "rails")
      text = result.content.first[:text]

      expect(text).not_to include("provider_metadata_url - route helper not found")
      expect(text).to include("1/1 files passed")
    end
  end

  describe "JavaScript fallback validator" do
    let(:tmp_dir) { File.join(Rails.root, "tmp") }

    before { FileUtils.mkdir_p(tmp_dir) }

    def validate_js(content)
      path = File.join(tmp_dir, "js_fallback_test.js")
      File.write(path, content)
      described_class.send(:validate_javascript_fallback, Pathname.new(path))
    ensure
      File.delete(path) if File.exist?(path)
    end

    # ── Bracket matching ──────────────────────────────────────────

    it "passes valid JavaScript with matched brackets" do
      ok, = validate_js('function foo() { return [1, 2]; }')
      expect(ok).to be true
    end

    it "detects unmatched opening brace" do
      ok, msg = validate_js('function foo() {')
      expect(ok).to be false
      expect(msg).to include("unmatched")
    end

    it "detects unmatched closing brace" do
      ok, msg = validate_js('var x = 1; }')
      expect(ok).to be false
      expect(msg).to include("unmatched '}'")
    end

    it "detects mismatched bracket types" do
      ok, msg = validate_js('function foo() { return [1, 2); }')
      expect(ok).to be false
      expect(msg).to include("unmatched")
    end

    it "passes nested brackets" do
      ok, = validate_js('var x = { a: [1, (2 + 3)], b: { c: 4 } };')
      expect(ok).to be true
    end

    # ── String handling ───────────────────────────────────────────

    it "ignores brackets inside double-quoted strings" do
      ok, = validate_js('var x = "{ [ ( } ] )";')
      expect(ok).to be true
    end

    it "ignores brackets inside single-quoted strings" do
      ok, = validate_js("var x = '{ [ ( } ] )';")
      expect(ok).to be true
    end

    it "ignores brackets inside template literals" do
      ok, = validate_js('var x = `{ [ ( } ] )`;')
      expect(ok).to be true
    end

    it "handles escaped quotes inside strings" do
      ok, = validate_js('var x = "hello \\"world\\"";')
      expect(ok).to be true
    end

    it "handles escaped backslash before closing quote (the \\\\\" bug)" do
      # In JavaScript: "hello\\" means string contains hello\ and the " closes it.
      # The \\ is an escaped backslash, NOT an escape for the closing quote.
      ok, = validate_js('var x = "hello\\\\"; var y = 1;')
      expect(ok).to be true
    end

    it "handles escaped backslash before closing quote with brackets after" do
      # This is the key regression test: "path\\" followed by { should not
      # treat the { as being inside the string
      ok, = validate_js('var x = "path\\\\"; if (true) { console.log(x); }')
      expect(ok).to be true
    end

    it "handles multiple escaped backslashes before closing quote" do
      # "\\\\" is four backslashes = two escaped backslashes, quote closes
      ok, = validate_js('var x = "test\\\\\\\\"; var y = [];')
      expect(ok).to be true
    end

    it "handles odd backslashes before quote (quote IS escaped)" do
      # "hello\\\"world" = escaped backslash + escaped quote + world + closing quote
      ok, = validate_js('var x = "hello\\\\\\"world";')
      expect(ok).to be true
    end

    it "does not false-positive when bracket char follows escaped-backslash string" do
      # This is the definitive regression test for the escaped backslash bug.
      # JS: var x = "test\\"; var y = ")";
      # "test\\" closes after the escaped backslash. ")" is a separate string.
      # Old code (prev_char check) keeps the first string open, then when it
      # hits the " before ), the string closes, exposing ) as a bare bracket
      # → false positive "unmatched ')'"
      ok, = validate_js('var x = "test\\\\"; var y = ")";')
      expect(ok).to be true
    end

    # ── Comment handling ──────────────────────────────────────────

    it "ignores brackets inside line comments" do
      ok, = validate_js("var x = 1; // { [ (\n")
      expect(ok).to be true
    end

    it "ignores brackets inside block comments" do
      ok, = validate_js("var x = 1; /* { [ ( */ var y = 2;")
      expect(ok).to be true
    end

    it "does not treat // inside a string as a comment" do
      ok, = validate_js('var x = "http://example.com"; var y = {};')
      expect(ok).to be true
    end

    it "does not treat /* inside a string as a block comment" do
      ok, = validate_js('var x = "/* not a comment */"; var y = {};')
      expect(ok).to be true
    end

    # ── Empty / whitespace ────────────────────────────────────────

    it "passes an empty file" do
      ok, = validate_js("")
      expect(ok).to be true
    end

    it "passes a file with only comments" do
      ok, = validate_js("// just a comment\n/* block */\n")
      expect(ok).to be true
    end
  end
  # A model file that maps to no model must not collect the whole app's missing indexes.
  describe "missing foreign-key indexes" do
    before do
      findings = [ { table: "orders", column: "customer_id", suggestion: "add_index :orders, :customer_id" } ]
      allow(RailsAiContext::Payload).to receive(:section).and_wrap_original do |original, context, name|
        name == :performance ? { missing_fk_indexes: findings } : original.call(context, name)
      end
    end

    it "does not report another table's missing index against an unmapped model file" do
      result = described_class.call(files: [ "app/models/application_record.rb" ], level: "rails")
      text = result.content.first[:text]

      expect(text).not_to include("customer_id")
    end
  end

  # CHECK 8, which reports the validated model's own table. It is what carries
  # missing-FK reporting now, and it passed before the CHECK 14 deletion too.
  describe "a mapped model's own missing foreign-key index" do
    it "reports the belongs_to column its table has no index on" do
      result = described_class.call(files: [ "app/models/post.rb" ], level: "rails")
      text = result.content.first[:text]

      expect(text).to include("user_id in posts - foreign key without index (slow queries)")
    end
  end
  # Mastodon declares 40-odd associations inside one `with_options
  # dependent: :destroy` block, and every one of them was reported.
  describe "has_many inside a with_options block" do
    it "warns only about the association the block does not cover" do
      previous_root = RailsAiContext.configuration.app_root
      allow(RailsAiContext).to receive(:tier).and_return(:static)

      Dir.mktmpdir do |dir|
        FileUtils.mkdir_p(File.join(dir, "app", "models"))
        File.write(File.join(dir, "app", "models", "account.rb"), <<~RUBY)
          class Account < ApplicationRecord
            with_options dependent: :destroy do
              has_many :statuses
              has_many :favourites
            end

            has_many :mentions
          end
        RUBY
        RailsAiContext.configuration.app_root = dir

        text = described_class.call(files: [ "app/models/account.rb" ], level: "rails").content.first[:text]

        expect(text).to include("has_many :mentions - missing :dependent option")
        expect(text).not_to include("has_many :statuses - missing :dependent option")
        expect(text).not_to include("has_many :favourites - missing :dependent option")
      end
    ensure
      RailsAiContext.configuration.app_root = previous_root
    end
  end

  describe "has_many inside a block the model may not run" do
    it "leaves the association out of the :dependent check" do
      previous_root = RailsAiContext.configuration.app_root
      allow(RailsAiContext).to receive(:tier).and_return(:static)

      Dir.mktmpdir do |dir|
        FileUtils.mkdir_p(File.join(dir, "app", "models"))
        File.write(File.join(dir, "app", "models", "group.rb"), <<~RUBY)
          class Group < ApplicationRecord
            has_details_table do
              has_many :members
            end

            has_many :invites
          end
        RUBY
        RailsAiContext.configuration.app_root = dir

        text = described_class.call(files: [ "app/models/group.rb" ], level: "rails").content.first[:text]

        expect(text).to include("has_many :invites - missing :dependent option")
        expect(text).not_to include("has_many :members - missing :dependent option")
      end
    ensure
      RailsAiContext.configuration.app_root = previous_root
    end
  end

  # paper_trail adds `has_many :versions` through `has_paper_trail`; reflection
  # lists it, and the fix the warning asked for belongs in no line the app wrote.
  describe "a has_many a gem adds to the model" do
    it "judges only the associations the model's source declares" do
      previous_root = RailsAiContext.configuration.app_root
      allow(RailsAiContext).to receive(:tier).and_return(:static)

      Dir.mktmpdir do |dir|
        FileUtils.mkdir_p(File.join(dir, "app", "models"))
        File.write(File.join(dir, "app", "models", "document.rb"), <<~RUBY)
          class Document < ApplicationRecord
            has_paper_trail
            has_many :pages
          end
        RUBY
        RailsAiContext.configuration.app_root = dir
        allow(RailsAiContext::Tools::ValidateSemantics).to receive(:cached_context).and_return(
          models: {
            "Document" => {
              table_name: "documents", file: "app/models/document.rb",
              associations: [ { type: "has_many", name: "versions" }, { type: "has_many", name: "pages" } ]
            }
          }
        )

        text = described_class.call(files: [ "app/models/document.rb" ], level: "rails").content.first[:text]

        expect(text).to include("has_many :pages - missing :dependent option")
        expect(text).not_to include("has_many :versions")
      end
    ensure
      RailsAiContext.configuration.app_root = previous_root
    end
  end
end
