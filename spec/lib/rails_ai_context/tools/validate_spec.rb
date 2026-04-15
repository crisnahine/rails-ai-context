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
      ensure
        File.delete(bad_file) if File.exist?(bad_file)
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
      # package.json is neither sensitive nor a validatable language — it
      # should be skipped, not denied. (Previously this test used
      # config/database.yml which is now blocked by the v5.8.1 expanded
      # sensitive_patterns list.)
      result = described_class.call(files: [ "package.json" ])
      text = result.content.first[:text]
      expect(text).to include("skipped")
    end

    it "denies access to sensitive files (v5.8.1)" do
      # config/database.yml, .env, config/master.key — all blocked by the
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
end
