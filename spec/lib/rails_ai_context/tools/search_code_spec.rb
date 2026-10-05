# frozen_string_literal: true

require "spec_helper"

RSpec.describe RailsAiContext::Tools::SearchCode do
  # Writes a throwaway app tree and points the memoized configuration at it.
  # app_root must be put back or every later example searches a deleted dir.
  def with_search_app(files)
    previous_root = RailsAiContext.configuration.app_root
    Dir.mktmpdir do |dir|
      files.each do |rel, body|
        FileUtils.mkdir_p(File.join(dir, File.dirname(rel)))
        File.write(File.join(dir, rel), body)
      end
      RailsAiContext.configuration.app_root = dir
      yield dir
    end
  ensure
    RailsAiContext.configuration.app_root = previous_root
  end

  # The fallback searched a list of extensions case-insensitively while
  # ripgrep searched every text file case-sensitively, so one app's answer
  # differed by a factor of seven between the two backends.
  describe "ripgrep and the Ruby fallback" do
    it "match the same lines" do
      skip "requires ripgrep" unless described_class.send(:ripgrep_available?)

      files = {
        "app/models/listing.rb" => "class Listing\n  # a listing\nend\n",
        "lib/tasks/listings.rake" => "task :Listing\n",
        "README.md" => "Listing docs\n",
        "Gemfile" => "# Listing app\n",
        ".hidden/listing.rb" => "Listing\n",
        "app/assets/logo.png" => "\x89PNG\0\0Listing\n"
      }
      with_search_app(files) do |dir|
        lines = ->(rows) { rows.map { |r| "#{r[:file]}:#{r[:line_number]}" }.sort }
        rg = lines.call(described_class.send(:search_with_ripgrep, "Listing", dir, nil, 1000, dir, 0).first)
        ruby = lines.call(described_class.send(:search_with_ruby, "Listing", dir, nil, 1000, dir).first)

        expect(ruby).to eq(rg)
        expect(rg).to eq(%w[Gemfile:1 README.md:1 app/models/listing.rb:1 lib/tasks/listings.rake:1])
      end
    end

    # ripgrep reads .ignore and .rgignore in and out of a git repository, with
    # .rgignore on top; the fallback searched what they hid.
    it "honour the same .ignore and .rgignore files" do
      skip "requires ripgrep" unless described_class.send(:ripgrep_available?)

      files = {
        ".ignore" => "*.gen.rb\n",
        ".rgignore" => "!keep.gen.rb\n",
        "lib/.ignore" => "vendored.rb\n",
        "a.gen.rb" => "Listing\n",
        "keep.gen.rb" => "Listing\n",
        "lib/vendored.rb" => "Listing\n",
        "lib/own.rb" => "Listing\n"
      }
      with_search_app(files) do |dir|
        lines = ->(rows) { rows.map { |r| r[:file] }.sort }
        rg = lines.call(described_class.send(:search_with_ripgrep, "Listing", dir, nil, 1000, dir, 0).first)
        ruby = lines.call(described_class.send(:search_with_ruby, "Listing", dir, nil, 1000, dir).first)

        expect(ruby).to eq(rg)
        expect(rg).to eq(%w[keep.gen.rb lib/own.rb])
      end
    end

    # The `ignore` crate (0.4.31, dir.rs `Ignore::matched_ignore`) ranks by
    # file type across the whole tree: any .rgignore match, deepest first,
    # beats any .ignore match, which beats any .gitignore, then
    # .git/info/exclude, then the global file. Depth decides only within one
    # type. A directory it ignores is never entered.
    {
      "a root .ignore whitelist beats a deeper .gitignore" =>
        [ { ".ignore" => "!keep.log\n", "sub/.gitignore" => "*.log\n" }, %w[sub/keep.log] ],
      "a root .rgignore whitelist beats a deeper .ignore" =>
        [ { ".rgignore" => "!keep.log\n", "sub/.ignore" => "*.log\n" }, %w[sub/keep.log] ],
      "a deeper .gitignore beats a root .gitignore" =>
        [ { ".gitignore" => "!*.log\n", "sub/.gitignore" => "*.log\n" }, %w[] ],
      "a root .ignore beats .git/info/exclude" =>
        [ { ".git/info/exclude" => "*.log\n", ".ignore" => "!keep.log\n" }, %w[sub/keep.log] ],
      "a directory an .ignore hides is never entered, whatever it whitelists" =>
        [ { ".ignore" => "sub/\n", "sub/.rgignore" => "!keep.log\n" }, %w[] ]
    }.each do |layout, (ignore_files, expected)|
      it "agree when #{layout}" do
        skip "requires ripgrep" unless described_class.send(:ripgrep_available?)

        files = ignore_files.merge("sub/keep.log" => "Listing\n", "sub/other.log" => "Listing\n")
        with_search_app(files) do |dir|
          FileUtils.mkdir_p(File.join(dir, ".git", "info"))
          File.write(File.join(dir, ".git", "info", "exclude"), ignore_files[".git/info/exclude"].to_s)
          lines = ->(rows) { rows.map { |r| r[:file] }.sort }
          rg = lines.call(described_class.send(:search_with_ripgrep, "Listing", dir, nil, 1000, dir, 0).first)
          ruby = lines.call(described_class.send(:search_with_ruby, "Listing", dir, nil, 1000, dir).first)

          expect(rg).to eq(expected)
          expect(ruby).to eq(rg)
        end
      end
    end

    # ripgrep walks up from the searched directory to the filesystem root and
    # reads every ancestor's ignore files; the git ones only as far as the
    # nearest `.git`, a file or a directory (dir.rs `add_parents` and the
    # `saw_git` guard in `matched_ignore`, ignore 0.4.31).
    describe "ignore files outside the searched directory" do
      def compare(search_root)
        lines = ->(rows) { rows.map { |r| r[:file] }.sort }
        [ lines.call(described_class.send(:search_with_ripgrep, "Qzv", search_root, nil, 1000, search_root, 0).first),
          lines.call(described_class.send(:search_with_ruby, "Qzv", search_root, nil, 1000, search_root).first) ]
      end

      def write(root, files)
        files.each do |rel, body|
          FileUtils.mkdir_p(File.join(root, File.dirname(rel)))
          File.write(File.join(root, rel), body)
        end
      end

      before { skip "requires ripgrep" unless described_class.send(:ripgrep_available?) }

      it "agree for an app nested in a larger repository" do
        Dir.mktmpdir do |repo|
          system("git", "init", "-q", repo, exception: true)
          write(repo, {
            ".gitignore" => "qzv_generated/\n",
            "apps/.gitignore" => "*.qzvlog\n",
            ".git/info/exclude" => "qzv_scratch/\n",
            "apps/blog/app.rb" => "Qzv\n",
            "apps/blog/qzv_generated/a.rb" => "Qzv\n",
            "apps/blog/x.qzvlog" => "Qzv\n",
            "apps/blog/qzv_scratch/b.rb" => "Qzv\n"
          })
          rg, ruby = compare(File.join(File.realpath(repo), "apps", "blog"))

          expect(rg).to eq(%w[app.rb])
          expect(ruby).to eq(rg)
        end
      end

      # A worktree or a submodule has a `.git` file, and its info/exclude lives
      # in the common git directory the `gitdir:` line leads to.
      it "agree for an app nested in a worktree" do
        Dir.mktmpdir do |dir|
          main = File.join(File.realpath(dir), "main")
          system("git", "init", "-q", main, exception: true)
          system("git", "-C", main, "-c", "user.email=a@b.c", "-c", "user.name=t",
                 "commit", "-q", "--allow-empty", "-m", "init", exception: true)
          tree = File.join(File.realpath(dir), "tree")
          system("git", "-C", main, "worktree", "add", "-q", tree, exception: true)
          write(main, { ".git/info/exclude" => "qzv_scratch/\n" })
          write(tree, {
            ".gitignore" => "*.qzvlog\n",
            "apps/blog/app.rb" => "Qzv\n",
            "apps/blog/x.qzvlog" => "Qzv\n",
            "apps/blog/qzv_scratch/b.rb" => "Qzv\n"
          })
          rg, ruby = compare(File.join(tree, "apps", "blog"))

          expect(rg).to eq(%w[app.rb])
          expect(ruby).to eq(rg)
        end
      end

      # Inside a repository nested in the app, the app's .gitignore stops at
      # the nested `.git`; .ignore does not.
      it "agree for a repository nested inside the app" do
        Dir.mktmpdir do |dir|
          app = File.realpath(dir)
          system("git", "init", "-q", app, exception: true)
          system("git", "init", "-q", File.join(app, "vendor_repo"), exception: true)
          write(app, {
            ".gitignore" => "*.qzvlog\n",
            ".ignore" => "*.qzvtmp\n",
            "a.qzvlog" => "Qzv\n",
            "vendor_repo/b.qzvlog" => "Qzv\n",
            "vendor_repo/c.qzvtmp" => "Qzv\n",
            "vendor_repo/d.rb" => "Qzv\n"
          })
          rg, ruby = compare(app)

          expect(rg).to eq(%w[vendor_repo/b.qzvlog vendor_repo/d.rb])
          expect(ruby).to eq(rg)
        end
      end
    end

    # ripgrep matches ignore patterns case-sensitively unless told otherwise,
    # on a case-insensitive filesystem too; git's core.ignorecase is a git
    # setting, not a ripgrep one.
    it "match ignore patterns with the same case sensitivity" do
      skip "requires ripgrep" unless described_class.send(:ripgrep_available?)

      files = { ".gitignore" => "/lib/foo/\n", "lib/Foo/bar.rb" => "Listing\n" }
      with_search_app(files) do |dir|
        FileUtils.mkdir_p(File.join(dir, ".git"))
        lines = ->(rows) { rows.map { |r| r[:file] }.sort }
        rg = lines.call(described_class.send(:search_with_ripgrep, "Listing", dir, nil, 1000, dir, 0).first)
        ruby = lines.call(described_class.send(:search_with_ruby, "Listing", dir, nil, 1000, dir).first)

        expect(rg).to include("lib/Foo/bar.rb")
        expect(ruby).to eq(rg)
      end
    end

    # ripgrep does not follow a symlink, to a file or to a directory, unless
    # given --follow; the fallback reported a linked file under its target,
    # so the target's lines came back twice.
    it "leave symlinks alone the same way" do
      skip "requires ripgrep" unless described_class.send(:ripgrep_available?)

      files = { "app/real.rb" => "Listing\n", "lib/inner/deep.rb" => "Listing\n" }
      with_search_app(files) do |dir|
        File.symlink(File.join(dir, "app", "real.rb"), File.join(dir, "app", "linked.rb"))
        File.symlink(File.join(dir, "lib", "inner"), File.join(dir, "lib", "linked_dir"))
        lines = ->(rows) { rows.map { |r| "#{r[:file]}:#{r[:line_number]}" }.sort }
        rg = lines.call(described_class.send(:search_with_ripgrep, "Listing", dir, nil, 1000, dir, 0).first)
        ruby = lines.call(described_class.send(:search_with_ruby, "Listing", dir, nil, 1000, dir).first)

        expect(rg).to eq(%w[app/real.rb:1 lib/inner/deep.rb:1])
        expect(ruby).to eq(rg)
      end
    end

    # The fallback returned match lines only while ripgrep returned their
    # context too, so the two answered the default call with other lines.
    [ 0, 2, 5 ].each do |ctx|
      it "emit the same rows with #{ctx} lines of context" do
        skip "requires ripgrep" unless described_class.send(:ripgrep_available?)

        lines = (1..30).map { |i| [ 1, 2, 6, 14, 15, 30 ].include?(i) ? "Qzv #{i}" : "line #{i}" }
        files = { "a.rb" => lines.join("\n") + "\n", "b/c.rb" => "x\nQzv\ny\n" }
        with_search_app(files) do |dir|
          rows = ->(found) { found.map { |r| [ r[:file], r[:line_number], r[:match] != false ] } }
          rg = rows.call(described_class.send(:search_with_ripgrep, "Qzv", dir, nil, 1000, dir, ctx).first)
          ruby = rows.call(described_class.send(:search_with_ruby, "Qzv", dir, nil, 1000, dir, ctx).first)

          expect(ruby).to eq(rg)
        end
      end
    end

    it "cap the same rows" do
      skip "requires ripgrep" unless described_class.send(:ripgrep_available?)

      with_search_app("a.rb" => (1..40).map { |i| i.even? ? "Qzv" : "x" }.join("\n") + "\n") do |dir|
        rows = ->(found) { found.map { |r| [ r[:file], r[:line_number] ] } }
        rg = rows.call(described_class.send(:search_with_ripgrep, "Qzv", dir, nil, 7, dir, 2).first)
        ruby = rows.call(described_class.send(:search_with_ruby, "Qzv", dir, nil, 7, dir, 2).first)

        expect(ruby).to eq(rg)
      end
    end

    # A matching line in a Latin-1 file is not valid UTF-8, and splitting
    # ripgrep's output raised, which came back as a one-row answer reading
    # `error:0: invalid byte sequence in UTF-8`.
    it "keep a match in a file that is not UTF-8" do
      skip "requires ripgrep" unless described_class.send(:ripgrep_available?)

      with_search_app("app/plain.rb" => "Listing\n") do |dir|
        File.binwrite(File.join(dir, "app", "latin.rb"), "# caf\xE9 Listing\n".b)
        rows = described_class.send(:search_with_ripgrep, "Listing", dir, nil, 1000, dir, 0).first

        expect(rows.map { |r| r[:file] }.sort).to eq(%w[app/latin.rb app/plain.rb])
        expect(rows.map { |r| r[:file] }).not_to include("error")
      end
    end

    # ripgrep reads an excluded path the way a .gitignore line reads: `docs`
    # names a directory at any depth, and never `logo/` beside `log`. The
    # fallback matched a prefix of the top-level path, so it searched a nested
    # spec/fixtures/docs and skipped a top-level logo/ directory.
    it "exclude the same paths" do
      skip "requires ripgrep" unless described_class.send(:ripgrep_available?)

      files = {
        "spec/fixtures/docs/a.json" => "Listing\n",
        "logo/b.rb" => "Listing\n",
        "log/c.rb" => "Listing\n",
        "engines/shop/spec/d_spec.rb" => "Listing\n",
        "app/e.rb" => "Listing\n"
      }
      with_search_app(files) do |dir|
        lines = ->(rows) { rows.map { |r| r[:file] }.sort }
        [ false, true ].each do |exclude_tests|
          rg = lines.call(described_class.send(:search_with_ripgrep, "Listing", dir, nil, 1000, dir, 0,
                                               exclude_tests: exclude_tests).first)
          ruby = lines.call(described_class.send(:search_with_ruby, "Listing", dir, nil, 1000, dir,
                                                 exclude_tests: exclude_tests).first)

          expect(ruby).to eq(rg)
        end
      end
    end
  end

  describe ".call" do
    it "rejects invalid file_type with special characters" do
      result = described_class.call(pattern: "test", file_type: "rb;rm -rf /")
      text = result.content.first[:text]
      expect(text).to include("Invalid file_type")
    end

    it "accepts valid alphanumeric file_type" do
      result = described_class.call(pattern: "class", file_type: "rb")
      text = result.content.first[:text]
      expect(text).not_to include("Invalid file_type")
    end

    it "uses smart result limiting and shows the match count" do
      result = described_class.call(pattern: "class")
      text = result.content.first[:text]
      expect(text).to match(/\*\*\d+\+? matches?/)
      expect(result).to be_a(MCP::Tool::Response)
    end

    it "prevents path traversal" do
      result = described_class.call(pattern: "test", path: "../../etc")
      text = result.content.first[:text]
      expect(text).to match(/Path not (found|allowed)/)
    end

    it "blocks sibling-directory escape via File::SEPARATOR-aware containment" do
      # A realpath like /app/myapp_evil would pass start_with?("/app/myapp") without
      # the separator suffix - the fix adds File::SEPARATOR to close this gap.
      Dir.mktmpdir("rac_sibling_") do |sibling_dir|
        result = described_class.call(pattern: "test", path: sibling_dir)
        text = result.content.first[:text]
        expect(text).to match(/Path not (found|allowed)/)
      end
    end

    it "returns results for a valid search" do
      result = described_class.call(pattern: "ActiveRecord::Schema")
      text = result.content.first[:text]
      expect(text).to include("Search:")
    end

    # Turning search_extensions into a positive glob list on the ripgrep path
    # made the two backends agree and cost the reach that makes the tool
    # useful: a Gemfile, a Rakefile and a .md carry no listed extension. The
    # Ruby fallback still globs by extension, so this is ripgrep's property.
    it "finds a match in a file whose name carries no listed extension" do
      skip "requires ripgrep" unless described_class.send(:ripgrep_available?)

      previous_root = RailsAiContext.configuration.app_root
      Dir.mktmpdir do |dir|
        FileUtils.mkdir_p(File.join(dir, "app", "models"))
        File.write(File.join(dir, "Gemfile"), %(source "https://rubygems.org"\ngem "devise"\n))
        File.write(File.join(dir, "app", "models", "post.rb"), "class Post; end\n")
        RailsAiContext.configuration.app_root = dir
        allow(RailsAiContext).to receive(:tier).and_return(:static)

        text = described_class.call(pattern: "devise").content.first[:text]

        expect(text).to include("Gemfile")
      end
    ensure
      # app_root lives on the memoized configuration, so setting it without
      # putting it back sends every later example at a deleted directory.
      RailsAiContext.configuration.app_root = previous_root
    end

    it "returns a not-found message for unmatched patterns" do
      result = described_class.call(pattern: "zzz_impossible_pattern_zzz_42")
      text = result.content.first[:text]
      expect(text).to include("No results found")
    end

    it "rejects empty patterns" do
      result = described_class.call(pattern: "   ")
      text = result.content.first[:text]
      expect(text).to include("Pattern is required")
    end

    it "rejects invalid regex patterns" do
      result = described_class.call(pattern: "[invalid")
      text = result.content.first[:text]
      expect(text).to include("Invalid regex")
    end

    it "rejects unknown match_type" do
      result = described_class.call(pattern: "test", match_type: "bogus")
      text = result.content.first[:text]
      expect(text).to include("Unknown match_type")
    end

    it "marks match lines with '>' and context lines with spaces when context is shown" do
      skip "requires ripgrep for context lines" unless described_class.send(:ripgrep_available?)

      result = described_class.call(pattern: "class Post", path: "app/models", context_lines: 2)
      text = result.content.first[:text]
      expect(text).to include("`>` = match line")
      expect(text).to match(%r{^> app/models/post\.rb:\d+: class Post})
      expect(text).to match(/^  \S+:\d+:/)
    end

    it "keeps the plain format when no context lines are requested" do
      result = described_class.call(pattern: "class Post", path: "app/models", context_lines: 0)
      text = result.content.first[:text]
      expect(text).not_to include("`>` = match line")
      expect(text).to match(%r{^app/models/post\.rb:\d+: class Post})
    end
  end

  # A composer must be able to ask whether the trace found a `def` without
  # reading the sentence this tool renders.
  describe "a trace that found no definition" do
    it "marks the answer rather than only saying so in prose" do
      traced = described_class.call(pattern: "zzz_no_such_method_anywhere", match_type: "trace")

      expect(described_class.send(:definition_missing?, traced)).to be true
    end

    it "does not mark a trace that found one" do
      traced = described_class.call(pattern: "display_url", match_type: "trace")

      expect(described_class.send(:definition_missing?, traced)).to be false
    end
  end

  # `\b` is a word/non-word transition, so a pattern edge that is already
  # non-word can carry neither an escape nor a boundary naively: the pattern
  # has to be literal, and each `\b` added only where the edge is a word char.
  describe "exact_match" do
    let(:status_source) do
      <<~RB
        class Status
          def reblog?
            true
          end

          def reblog
            nil
          end

          def check
            reblog?
          end

          def other
            reblog
          end
        end
      RB
    end

    let(:foo_bar_source) do
      <<~RB
        class FooBar
          def build
            @user = 1
          end
        end
      RB
    end

    [ true, false ].each do |with_ripgrep|
      context(with_ripgrep ? "on the ripgrep backend" : "on the Ruby fallback backend") do
        before do
          allow(RailsAiContext).to receive(:tier).and_return(:static)
          if with_ripgrep
            skip "requires ripgrep" unless described_class.send(:ripgrep_available?)
          else
            allow(described_class).to receive(:ripgrep_available?).and_return(false)
          end
        end

        def text_for(**kwargs)
          described_class.call(context_lines: 0, **kwargs).content.first[:text]
        end

        # Whitehall: `--pattern scheduled_publication --limit 2` answered "No
        # matches at offset 0. Total: 56+ matches." A page size is never an
        # answer of nothing.
        it "shows a match even when the limit is smaller than its context block" do
          buried = <<~RB
            class Buried
              def one; end

              def two; end

              def scheduled_publication; end
            end
          RB

          with_search_app("app/models/buried.rb" => buried) do
            text = described_class.call(pattern: "scheduled_publication", limit: 2, context_lines: 2)
                                  .content.first[:text]

            expect(text).not_to include("No matches at offset")
            expect(text).to match(/buried\.rb:6:.*scheduled_publication/)
          end
        end

        # config/application.yml is figaro's secrets file. One backend read it
        # and the other did not, and the answer that read it carried the
        # values.
        it "never reads a sensitive file" do
          with_search_app("config/application.yml" => "JWT_HMAC_SECRET: aaaaaaaaaaaaaaaa\n",
                          "app/models/user.rb" => "class User\n  JWT_HMAC_SECRET = 1\nend\n") do
            text = text_for(pattern: "JWT_HMAC_SECRET")

            expect(text).to include("user.rb")
            expect(text).not_to include("application.yml")
          end
        end

        # ripgrep applies .gitignore inside a git repository and not outside
        # one, so a Ruby scan that ignores it agrees with ripgrep on nothing.
        it "skips a gitignored file inside a git repository" do
          files = { ".gitignore" => "generated/\n", "generated/dump.rb" => "SECRET_TOKEN = 1\n",
                    "app/models/user.rb" => "SECRET_TOKEN = 2\n" }
          with_search_app(files) do |dir|
            FileUtils.mkdir_p(File.join(dir, ".git"))
            text = text_for(pattern: "SECRET_TOKEN")

            expect(text).to include("user.rb")
            expect(text).not_to include("generated/dump.rb")
          end
        end

        it "skips a file a nested .gitignore hides" do
          files = { "config/.gitignore" => "local_token.rb\n", "config/local_token.rb" => "SECRET_TOKEN = 1\n",
                    "app/models/user.rb" => "SECRET_TOKEN = 2\n" }
          with_search_app(files) do |dir|
            FileUtils.mkdir_p(File.join(dir, ".git"))
            text = text_for(pattern: "SECRET_TOKEN")

            expect(text).to include("user.rb")
            expect(text).not_to include("local_token.rb")
          end
        end

        it "reads the same file outside a git repository, the way ripgrep does" do
          files = { ".gitignore" => "generated/\n", "generated/dump.rb" => "SECRET_TOKEN = 1\n" }
          with_search_app(files) do
            expect(text_for(pattern: "SECRET_TOKEN")).to include("generated/dump.rb")
          end
        end

        # Defence in depth on the same shape: a secret in a file no pattern
        # names still leaves through this tool's own output.
        it "filters a credential-shaped value out of the line it returns" do
          with_search_app("config/custom_secrets.yml" => "jwt_hmac_secret: #{'a1' * 43}\n") do
            text = text_for(pattern: "jwt_hmac_secret")

            expect(text).to include("jwt_hmac_secret")
            expect(text).to include("[FILTERED]")
            expect(text).not_to include("a1a1")
          end
        end

        # Each row was redacted alone, so a PEM key's body lines came back in
        # plaintext; the key is only a key between its markers.
        it "filters every body line of a PEM key it returns" do
          body = %w[MIIEowIBAAKCAQEAu1SU1LfVLPHCozMxH2Mo4lgOEePzNm0tRgeLezV6ffAt0gun
                    VTLw7onLRnrq0/IzW7yWR7QkrmBL7jTKEn5u+qKhbwKfBstIs+bMY2Zkp18gnTxK
                    LxoS2tFczGkPLPgizskuemMghRniWaoLcyehkd3qqGElvW/VDL5AaWTg0nLVkjRo]
          source = [ "KEY = <<~PEM", "  -----BEGIN RSA PRIVATE KEY-----", *body.map { |l| "  #{l}" },
                     "  -----END RSA PRIVATE KEY-----", "PEM" ].join("\n") + "\n"
          with_search_app("lib/keys/signer.rb" => source) do
            [ { pattern: "PRIVATE KEY", context_lines: 3 }, { pattern: "LxoS2tFczGkPLPgizsk" } ].each do |args|
              [ false, true ].each do |group_by_file|
                text = described_class.call(**args, group_by_file: group_by_file).content.first[:text]
                rows = text.lines.drop(1).join # the header echoes the pattern searched for

                # A match inside the filtered body confirms nothing, so no row comes back.
                expect(text).to include("No results found") if args[:pattern].start_with?("LxoS")
                expect(rows).not_to match(/MIIEow|VTLw7on|LxoS2tF/)
              end
            end
          end
        end

        # A file is as good a scope as a directory; "Path not found" for one
        # sent the caller off to search the whole app.
        it "searches a single file named as the path" do
          files = { "app/models/user.rb" => "class User\n  def Qzv; end\nend\n", "app/models/post.rb" => "Qzv\n" }
          with_search_app(files) do
            text = described_class.call(pattern: "Qzv", path: "app/models/user.rb", context_lines: 0).content.first[:text]

            expect(text).to include("app/models/user.rb:2")
            expect(text).not_to include("post.rb")
            expect(text).not_to include("Path not found")
          end
        end

        it "refuses a sensitive file named as the path, or linked to by it" do
          with_search_app("config/master.key" => "Qzv\n") do |dir|
            File.symlink(File.join(dir, "config", "master.key"), File.join(dir, "config", "notes.txt"))

            %w[config/master.key config/notes.txt].each do |path|
              expect(described_class.call(pattern: "Qzv", path: path).content.first[:text]).to include("Path not allowed")
            end
          end
        end

        # The pattern ran on the raw file, so a filtered row answered whether a secret starts `3b`.
        it "returns no row for a match that falls only inside a filtered value" do
          source = "#!/bin/sh\nexport APP_SECRET_TOKEN=#{'3b' * 20}\necho done\n"
          with_search_app("bin/setup" => source) do
            %w[APP_SECRET_TOKEN=3b 3b3b3b].each do |pattern|
              expect(text_for(pattern: pattern, context_lines: 1)).to include("No results found")
            end
            text = text_for(pattern: "APP_SECRET_TOKEN=", context_lines: 0)
            expect(text).to include("1 match", "bin/setup:2: export APP_SECRET_TOKEN=[FILTERED]")
          end
        end

        it "answers a right and a wrong guess at a secret's prefix the same way with context on" do
          source = "class Thing\n  # foo_marker\n  API_TOKEN = \"Zx9Yq7Wk3Lp5Vn8Rt2Mb\"\n  BAR = 2\nend\n"
          with_search_app("app/models/thing.rb" => source) do
            right, wrong = %w[Zx9Y QQQQ].map do |guess|
              text_for(pattern: "foo_marker|#{guess}", context_lines: 1).lines.drop(1).join
            end

            expect(right).to eq(wrong)
            expect(right).to include(%(thing.rb:3: API_TOKEN = "[FILTERED]"))
          end
        end

        it "shows the code after a regex that names a PEM marker" do
          source = %(PATTERNS = [\n  { name: "RSA", regex: /-----BEGIN RSA PRIVATE KEY-----/ }\n].freeze\n\ndef scrub(data)\nend\n)
          with_search_app("app/services/scrubber.rb" => source) do
            expect(text_for(pattern: "def ", context_lines: 0)).to include("scrubber.rb:5: def scrub(data)")
          end
        end

        # Ripgrep matches a line without its terminator, so `\s$` means trailing whitespace.
        it "matches a line without its newline" do
          with_search_app("app/models/a.rb" => "alpha\nbeta \ngamma\r\ndelta\n") do
            text = text_for(pattern: "\\s$", context_lines: 0)

            expect(text).to include("2 matches")
            expect(text).to include("a.rb:2", "a.rb:3")
          end
        end

        it "matches the pattern literally instead of as a regex" do
          with_search_app("app/models/status.rb" => status_source) do
            text = text_for(pattern: "def reblog?", exact_match: true)

            expect(text).to include("status.rb:2")
            expect(text).not_to include("status.rb:6")
          end
        end

        it "finds a predicate definition with match_type definition" do
          with_search_app("app/models/status.rb" => status_source) do
            expect(text_for(pattern: "reblog?", match_type: "definition", exact_match: true))
              .to include("status.rb:2")
          end
        end

        it "matches literally with match_type call" do
          with_search_app("app/models/status.rb" => status_source) do
            text = text_for(pattern: "reblog?", match_type: "call", exact_match: true)

            expect(text).to include("status.rb:11")
            expect(text).not_to include("status.rb:15")
          end
        end

        it "finds a pattern whose first character is not a word character" do
          with_search_app("app/models/foo_bar.rb" => foo_bar_source) do
            expect(text_for(pattern: "@user", exact_match: true)).to include("foo_bar.rb:3")
          end
        end

        # The class branch keeps its leading `\w*` unbounded so a CamelCase
        # prefix still resolves; a leading `\b` would forbid that.
        it "still finds a class whose name carries a word prefix" do
          with_search_app("app/models/foo_bar.rb" => foo_bar_source) do
            expect(text_for(pattern: "Bar", match_type: "class", exact_match: true))
              .to include("foo_bar.rb:1")
          end
        end
      end
    end
  end

  describe "a method name and its ?, ! and = neighbours" do
    let(:pinger_source) do
      <<~RB
        class QaPinger
          def self.qa_ping(x)
            qa_helper(x)
          end

          def qa_ping?
            true
          end

          def qa_ping!
            nil
          end

          def qa_ping=(value)
            @value = value
          end

          def self.qa_helper(x) = x
        end
      RB
    end

    let(:controller_source) do
      <<~RB
        class QaPingsController < ApplicationController
          def show
            QaPinger.qa_ping(1)
            # qa_ping mentioned in a comment
          end
        end
      RB
    end

    let(:script_source) do
      <<~JS
        // qa_ping mentioned in a comment
        /* qa_ping in a block comment */
         * qa_ping in a doc comment
        qa_ping();
      JS
    end

    let(:view_source) do
      <<~ERB
        <%# qa_ping mentioned in a comment %>
        <%= qa_ping %>
        <script>
          // qa_ping in inline script
          /* qa_ping in an inline block comment */
        </script>
      ERB
    end

    let(:style_files) do
      { "app/assets/stylesheets/ping.css" => "#qa_ping { color: red; }\n/* qa_ping in a stylesheet */\n",
        "app/assets/stylesheets/ping.scss" => "// qa_ping in scss\n#qa_ping { color: blue; }\n",
        "app/javascript/ping.coffee" => "# qa_ping in coffee\n" }
    end

    # A splat written with a space reads like a JS doc-comment line, and a
    # call of the predicate is not a call of the plain name.
    let(:user_source) do
      <<~RB
        class UserOfPing
          def run
            [1,
             * qa_ping(3)]
            QaPinger.new.qa_ping?
            QaPinger.new.qa_ping = 2
          end
        end
      RB
    end

    let(:files) do
      { "app/services/qa_pinger.rb" => pinger_source, "app/controllers/qa_pings_controller.rb" => controller_source,
        "app/javascript/ping.js" => script_source, "app/views/pings/show.html.erb" => view_source,
        "app/models/user_of_ping.rb" => user_source }.merge(style_files)
    end

    [ true, false ].each do |with_ripgrep|
      context(with_ripgrep ? "on the ripgrep backend" : "on the Ruby fallback backend") do
        before do
          allow(RailsAiContext).to receive(:tier).and_return(:static)
          if with_ripgrep
            skip "requires ripgrep" unless described_class.send(:ripgrep_available?)
          else
            allow(described_class).to receive(:ripgrep_available?).and_return(false)
          end
        end

        it "traces one definition and leaves the traced method out of its siblings" do
          with_search_app(files) do
            text = described_class.call(pattern: "qa_ping", match_type: "trace").content.first[:text]
            definition = text[/## Definition.*?(?=## Called from)/m]

            expect(definition.scan(/^\*\*app\/services\/qa_pinger\.rb:(\d+)\*\*/).flatten).to eq([ "2" ])
            siblings = definition[/## Sibling methods \(same file\)\n(.*?)\n\n/m, 1].lines.map(&:strip)
            expect(siblings).to eq([ "- `qa_ping?`", "- `qa_ping!`", "- `qa_ping=`", "- `self.qa_helper`" ])
          end
        end

        it "still traces a predicate by its own name" do
          with_search_app(files) do
            text = described_class.call(pattern: "qa_ping?", match_type: "trace").content.first[:text]

            expect(text.scan(/^\*\*app\/services\/qa_pinger\.rb:(\d+)\*\*/).flatten).to eq([ "6" ])
          end
        end

        it "finds only the exact method with match_type definition" do
          with_search_app(files) do
            text = described_class.call(pattern: "qa_ping", match_type: "definition", exact_match: true,
                                        context_lines: 0).content.first[:text]

            expect(text).to include("qa_pinger.rb:2:")
            expect(text).not_to match(/qa_pinger\.rb:(6|10|14):/)
          end
        end

        it "does not count a comment line as a call site" do
          with_search_app(files) do
            text = described_class.call(pattern: "qa_ping", match_type: "call", context_lines: 0).content.first[:text]

            expect(text).to include("qa_pings_controller.rb:3:", "ping.js:4:", "show.html.erb:2:", "user_of_ping.rb:4:")
            expect(text).not_to include("mentioned in a comment", "block comment", "doc comment")
            expect(text).not_to include("inline script", "ping.css", "ping.scss", "ping.coffee")
            expect(text).to include("**6 matches**")
          end
        end

        # A live ERB tag runs on the server whatever comment surrounds it, and
        # `#id` opens an element in haml and slim.
        it "keeps a line holding a live ERB tag, and a haml or slim id element" do
          templates = {
            "app/views/pings/show.js.erb" => "// <%= qa_ping %>\n/* <%= qa_ping %> */\n// qa_ping in a js.erb comment\n",
            "app/views/pings/show.text.erb" => "# <%= qa_ping %>\n# qa_ping in a text.erb comment\n",
            "app/views/pings/show.html.haml" => "-# qa_ping silent\n/ qa_ping html comment\n#qa_ping= qa_ping\n",
            "app/views/pings/show.html.slim" => "/ qa_ping comment\n/! qa_ping html comment\n#qa_ping = qa_ping\n"
          }
          with_search_app(templates) do
            text = described_class.call(pattern: "qa_ping", match_type: "call", context_lines: 0).content.first[:text]

            expect(text).to include("show.js.erb:1:", "show.js.erb:2:", "show.text.erb:1:", "show.html.haml:3:", "show.html.slim:3:")
            expect(text).to include("**5 matches**")
          end
        end

        it "does not count a call of the predicate or the setter as a call of the plain name" do
          with_search_app(files) do
            text = described_class.call(pattern: "qa_ping", match_type: "call", exact_match: true,
                                        context_lines: 0).content.first[:text]

            expect(text).to include("user_of_ping.rb:4:")
            expect(text).not_to include("user_of_ping.rb:5:", "user_of_ping.rb:6:")
          end
        end

        it "leaves a spaced setter call out of the trace callers" do
          with_search_app(files) do
            text = described_class.call(pattern: "qa_ping", match_type: "trace").content.first[:text]

            expect(text[/## Called from.*/m]).not_to include("qa_ping = 2")
          end
        end

        it "lists Ruby splat lines and leaves predicate calls out of the trace callers" do
          with_search_app(files) do
            text = described_class.call(pattern: "qa_ping", match_type: "trace").content.first[:text]
            callers = text[/## Called from.*/m]

            expect(callers).to include("4: * qa_ping(3)")
            expect(callers).not_to include("qa_ping?")
          end
        end
      end
    end
  end

  describe "a regex that times out while rows are confirmed" do
    it "still drops a context row with no match beside it" do
      skip "needs Regexp::TimeoutError" unless defined?(Regexp::TimeoutError)

      backtracking = "#{'a' * 40}!"
      with_search_app("app/a.rb" => "#{backtracking}\ntwo\n# three\n") do |dir|
        regex = Regexp.new("^(a+)+\\1$", timeout: 0.01)
        rows = [ { file: "app/a.rb", line_number: 1, content: backtracking, match: true },
                 { file: "app/a.rb", line_number: 3, content: "# three", match: false } ]

        kept = described_class.send(:confirmed_rows, rows, dir, regex, 0)

        expect(kept.map { |r| r[:line_number] }).to eq([ 1 ])
      end
    end
  end

  describe "trace mode call sites" do
    let(:saver_source) do
      <<~RB
        class Saver
          def save!
            true
          end

          def presave!
            nil
          end

          def run
            presave!
            save!
          end
        end
      RB
    end

    it "does not list a longer method name as a call site of a bang method" do
      allow(RailsAiContext).to receive(:tier).and_return(:static)

      with_search_app("app/models/saver.rb" => saver_source) do
        text = described_class.call(pattern: "save!", match_type: "trace").content.first[:text]

        expect(text).to include("12: save!")
        expect(text).not_to include("11: presave!")
      end
    end

    # The parenthesis the old scan required is optional in Ruby, and a model
    # whose predicates read `requesting_access? && account.present?` reported
    # calling nothing at all.
    it "lists a scheduled enqueue among the calls a body makes" do
      allow(RailsAiContext).to receive(:tier).and_return(:static)

      source = <<~RB
        class Order < ApplicationRecord
          def schedule_sync
            RefreshWorker.perform_in(5.minutes, id)
          end
        end
      RB

      with_search_app("app/models/order.rb" => source) do
        text = described_class.call(pattern: "schedule_sync", match_type: "trace").content.first[:text]

        expect(text).to include("`RefreshWorker.perform_in`")
      end
    end

    it "reads the calls a body makes without parentheses" do
      allow(RailsAiContext).to receive(:tier).and_return(:static)

      source = <<~RB
        class Subscription < ApplicationRecord
          def requires_approval?
            return false if partner_instant_approval?
            requesting_access? && account.present?
          end

          def partner_instant_approval?
            false
          end

          def requesting_access?
            true
          end
        end
      RB

      with_search_app("app/models/subscription.rb" => source) do
        text = described_class.call(pattern: "requires_approval?", match_type: "trace").content.first[:text]

        expect(text).to include("## Calls internally")
        expect(text).to include("`partner_instant_approval?`")
        expect(text).to include("`requesting_access?`")
      end
    end

    it "does not count a comment mentioning the method as a call site" do
      allow(RailsAiContext).to receive(:tier).and_return(:static)

      source = <<~RB
        class Models::Subscriptions::Flag
          def execute
            account = subscription.account
            # Brokered accounts are skipped. brokered? is the check for that.
            errors.add(:subscription, 'is brokered') if account.brokered?
          end
        end
      RB

      with_search_app("app/services/models/subscriptions/flag.rb" => source) do
        text = described_class.call(pattern: "brokered?", match_type: "trace").content.first[:text]

        expect(text).to include("(1 site)")
        expect(text).not_to include("Brokered accounts are skipped")
        expect(text).to include("(Service)")
      end
    end
  end

  # ripgrep exits 1 when it matched nothing and 2 when the run itself failed,
  # which is what an rg too old for --field-match-separator does.
  # ripgrep 13, which Ubuntu 22.04 and Debian 12 ship, rejects `\ ` as an
  # unrecognized escape and exits 2 with no output, so every exact search
  # with a space fell back to Ruby and lost its context lines.
  describe "the pattern an exact search hands ripgrep" do
    let(:patterns) { [] }

    before do
      allow(RailsAiContext).to receive(:tier).and_return(:static)
      allow(described_class).to receive(:ripgrep_available?).and_return(true)
      allow(Open3).to receive(:capture3) do |*cmd, **|
        patterns << cmd.last(2).first
        [ "", "", instance_double(Process::Status, success?: false, exitstatus: 1) ]
      end
    end

    it "escapes no space, for every match type" do
      with_search_app("app/models/status.rb" => "class Status\nend\n") do
        %w[any call definition class].each do |match_type|
          described_class.call(pattern: "def reblog?", match_type: match_type, exact_match: true)
        end
        described_class.call(pattern: "reblog? x", match_type: "trace")
      end

      expect(patterns).not_to be_empty
      expect(patterns.grep(/\\ /)).to eq([])
    end
  end

  describe "when the ripgrep run fails" do
    before do
      allow(RailsAiContext).to receive(:tier).and_return(:static)
      allow(described_class).to receive(:ripgrep_available?).and_return(true)
      allow(Open3).to receive(:capture3)
        .and_return([ "", "rg: unrecognized flag --field-match-separator\n", instance_double(Process::Status, success?: false, exitstatus: 2) ])
    end

    it "answers from the Ruby backend rather than reporting no results" do
      with_search_app("app/models/status.rb" => "class Status\n  def reblog?\n  end\nend\n") do
        text = described_class.call(pattern: "def reblog?", context_lines: 2).content.first[:text]

        expect(text).to include("def reblog?")
        expect(text).not_to include("No results found")
      end
    end
  end

  # rg exits 2 for an error it recovered from too, and still prints every
  # match it found. Rerunning in Ruby there throws a good result set away and
  # loses both the context rows and the files with no listed extension.
  describe "when ripgrep recovered from an error" do
    before do
      allow(RailsAiContext).to receive(:tier).and_return(:static)
      skip "requires ripgrep" unless described_class.send(:ripgrep_available?)
    end

    it "keeps the matches and says the search hit an error" do
      with_search_app(
        "Gemfile" => %(gem "devise"\n),
        "app/models/status.rb" => "class Status\n  # devise lives here\nend\n",
        "app/models/locked.rb" => "# devise\n"
      ) do |dir|
        make_unreadable(File.join(dir, "app", "models", "locked.rb"))

        text = described_class.call(pattern: "devise").content.first[:text]

        expect(text).to include("Gemfile:1")
        expect(text).to include("app/models/status.rb:2")
        expect(text).to include("The search reported an error and may have skipped files")
      ensure
        File.chmod(0o644, File.join(dir, "app", "models", "locked.rb"))
      end
    end

    # The tools never read a sensitive file, so rg failing to open one is not
    # an error in the answer, and saying so would hint the file exists.
    it "ignores an error on a sensitive file it could not open" do
      with_search_app("app/models/status.rb" => "# devise\n", "config/master.key" => "devise\n") do |dir|
        key = File.join(dir, "config", "master.key")
        make_unreadable(key)
        expect(described_class).not_to receive(:search_with_ruby)

        text = described_class.call(pattern: "devise").content.first[:text]
        expect(text).to include("app/models/status.rb:1")
        expect(text).not_to include("reported an error")
        expect(described_class.call(pattern: "nothing_matches_this").content.first[:text])
          .not_to include("reported an error")
      ensure
        File.chmod(0o644, key)
      end
    end
  end

  # The search returns rows - match rows and context rows - so a count taken
  # off the row list moves with context_lines and stops at the line cap.
  describe "result counts" do
    # Three matching lines, each padded so -C 2 pulls four context rows.
    let(:padded_source) { ([ "# pad", "# pad", "  def reblog?", "# pad", "# pad", "# pad" ] * 3).join("\n") + "\n" }

    before do
      allow(RailsAiContext).to receive(:tier).and_return(:static)
      skip "requires ripgrep for context lines" unless described_class.send(:ripgrep_available?)
    end

    def header_count(text)
      text[/\*\*(\d+)/, 1]
    end

    it "counts matches, not the rows emitted around them" do
      with_search_app("app/models/status.rb" => padded_source) do
        with_ctx = described_class.call(pattern: "def reblog?", exact_match: true, context_lines: 2).content.first[:text]
        no_ctx = described_class.call(pattern: "def reblog?", exact_match: true, context_lines: 0).content.first[:text]

        expect(header_count(with_ctx)).to eq("3")
        expect(header_count(no_ctx)).to eq("3")
      end
    end

    it "shows as many match lines as the header says it shows" do
      with_search_app("app/models/status.rb" => padded_source) do
        text = described_class.call(pattern: "def reblog?", exact_match: true, context_lines: 2).content.first[:text]

        expect(text.lines.count { |l| l.start_with?("> ") }).to eq(3)
        expect(text).to include("showing 3")
        expect(text).to include("lines with context")
      end
    end

    # Paging is row-based, so an offset can land wholly inside one match's
    # trailing context. Rows under a "showing 0" header contradict it.
    it "answers a page of pure context rows as an empty page" do
      with_search_app("app/models/zed.rb" => "a\nb\nqqmarker\nd\ne\n") do
        text = described_class.call(pattern: "qqmarker", context_lines: 2, offset: 3).content.first[:text]

        expect(text).to include("No matches at offset 3")
        expect(text).not_to include("showing 0")
        expect(text).not_to include("zed.rb:4")
      end
    end

    # A match line whose own content is tab-separated digits used to parse as
    # a context row, which would take it out of the count entirely.
    it "counts a match whose content looks like a context row" do
      with_search_app("app/models/zed.rb" => "aaa\n\t12\tqqmarker\nbbb\n") do
        text = described_class.call(pattern: "qqmarker", context_lines: 2).content.first[:text]

        expect(header_count(text)).to eq("1")
      end
    end
  end

  # The line cap and its label are printed off the row list either backend
  # produced, so these run without ripgrep.
  describe "the line cap in the header" do
    before { allow(RailsAiContext).to receive(:tier).and_return(:static) }

    it "names the line cap as a cap instead of printing it as the total" do
      previous_cap = RailsAiContext.configuration.max_search_results
      RailsAiContext.configuration.max_search_results = 10

      with_search_app("app/services/thing.rb" => (([ "  def call" ] * 50).join("\n") + "\n")) do
        text = described_class.call(pattern: "def call", context_lines: 0).content.first[:text]

        expect(text).to include("first 10 lines scanned")
      end
    ensure
      RailsAiContext.configuration.max_search_results = previous_cap
    end

    # paginate prints its own cut total as "10+", so the header saying a bare
    # "10 matches" made the two lines of one answer disagree.
    it "marks the header count as a floor when the rows were cut" do
      previous_cap = RailsAiContext.configuration.max_search_results
      RailsAiContext.configuration.max_search_results = 10

      with_search_app("app/services/thing.rb" => (([ "  def call" ] * 50).join("\n") + "\n")) do
        text = described_class.call(pattern: "def call", context_lines: 0).content.first[:text]

        expect(text).to include("**10+ matches - first 10 lines scanned**")
      end
    ensure
      RailsAiContext.configuration.max_search_results = previous_cap
    end

    it "reports a file's whole match count beside what the page shows" do
      with_search_app("app/services/thing.rb" => (([ "  def call" ] * 20).join("\n") + "\n")) do
        text = described_class.call(pattern: "def call", context_lines: 0, limit: 5, group_by_file: true).content.first[:text]

        expect(text).to include("(20 matches, 5 shown)")
      end
    end

    # The heading counts sites and the cap counts lines, so the note goes
    # once, under both sections, rather than into each heading.
    it "notes once that a trace stopped at the line cap" do
      previous_cap = RailsAiContext.configuration.max_search_results
      RailsAiContext.configuration.max_search_results = 10
      source = "class Saver\n  def touch\n    true\n  end\nend\n" + (([ "touch" ] * 50).join("\n") + "\n")

      with_search_app("app/models/saver.rb" => source) do
        text = described_class.call(pattern: "touch", match_type: "trace").content.first[:text]

        expect(text).to match(/## Called from \(\d+ sites\)/)
        expect(text.scan("Only the first 10 matching lines were scanned").size).to eq(1)
      end
    ensure
      RailsAiContext.configuration.max_search_results = previous_cap
    end
  end

  describe ".ripgrep_available?" do
    after { described_class.instance_variable_set(:@rg_available, nil) }

    it "caches the result including false" do
      # Reset to nil so we can observe caching
      described_class.instance_variable_set(:@rg_available, nil)

      # First call: should run system check
      result = described_class.send(:ripgrep_available?)

      # Store the result and call again - should not re-check
      expect(described_class.instance_variable_get(:@rg_available)).not_to be_nil

      # Force false and verify it stays cached
      described_class.instance_variable_set(:@rg_available, false)
      expect(described_class.send(:ripgrep_available?)).to eq(false)
    end
  end

  # Every read of the shared cache is a deep copy of the whole payload, and a
  # trace read it once per controller file that calls the method.
  describe "shared context reads in a trace" do
    def reads_for(count)
      described_class.reset_cache!
      reads = 0
      allow(described_class).to receive(:cached_context) do
        reads += 1
        { routes: { by_controller: {} } }
      end

      files = { "app/models/helper.rb" => "class Helper\n  def helper_x\n    1\n  end\nend\n" }
      (1..count).each do |i|
        files["app/controllers/thing#{i}_controller.rb"] =
          "class Thing#{i}Controller\n  def index\n    helper_x\n  end\nend\n"
      end

      with_search_app(files) do
        described_class.call(pattern: "helper_x", match_type: "trace")
      end
      reads
    end

    it "reads the shared context the same number of times for 3 calling controllers as for 30" do
      allow(RailsAiContext).to receive(:tier).and_return(:static)

      expect(reads_for(30)).to eq(reads_for(3))
    end
  end

  # The route hint is read out of a capture group, and `String#match?` never
  # sets one, so the name it looked the routes up by was always nil and the
  # hint never rendered for any app.
  describe "a trace whose caller is a controller with routes" do
    it "names the routes that reach the call site" do
      described_class.reset_cache!
      allow(RailsAiContext).to receive(:tier).and_return(:static)
      files = {
        "app/models/post.rb" => "class Post\n  def publish_all\n    1\n  end\nend\n",
        "app/controllers/posts_controller.rb" => "class PostsController\n  def index\n    publish_all\n  end\nend\n"
      }

      with_search_app(files) do
        allow(described_class).to receive(:cached_context).and_return({
          routes: { by_controller: { "posts" => [ { verb: "GET", path: "/posts" } ] } }
        })

        text = described_class.call(pattern: "publish_all", match_type: "trace").content.first[:text]

        expect(text).to include("`GET /posts`")
      end
    end
  end
  # Both backends read one exclusion list and read it the same way: a trailing
  # slash is a directory, a slash-free entry is a basename at any depth.
  describe "the generated-file exclusions" do
    let(:fixture) do
      {
        "app/models/status.rb" => "NEEDLE_TOKEN in source\n",
        "CLAUDE.md" => "NEEDLE_TOKEN in a generated file\n",
        ".claude/rules/models.md" => "NEEDLE_TOKEN in a generated rule\n",
        ".mcp.json" => "NEEDLE_TOKEN in mcp config\n",
        ".codex/config.toml" => "NEEDLE_TOKEN in codex config\n",
        "AGENTS.md" => "NEEDLE_TOKEN in agents\n",
        ".ai-context.json" => "NEEDLE_TOKEN in the json export\n",
        ".claude/settings.json" => "NEEDLE_TOKEN in a hand-written setting\n",
        "app/services/AGENTS.md" => "NEEDLE_TOKEN in a nested generated file\n",
        # .md is outside search_extensions, so this is the nested entry the Ruby fallback can reach.
        "app/services/opencode.json" => "NEEDLE_TOKEN in a nested generated config\n"
      }
    end

    before { allow(RailsAiContext).to receive(:tier).and_return(:static) }

    def files_found
      text = described_class.call(pattern: "NEEDLE_TOKEN", context_lines: 0, limit: 50).content.first[:text]
      text.scan(/^>?\s*([^\s:]+):\d+:/).flatten.uniq.sort
    end

    it "hands ripgrep the list the Ruby fallback filters on" do
      allow(described_class).to receive(:ripgrep_available?).and_return(true)
      captured = nil
      allow(Open3).to receive(:capture3) do |*args, **_kwargs|
        captured = args
        [ "", "", instance_double(Process::Status, success?: true, exitstatus: 0) ]
      end

      with_search_app(fixture) { described_class.call(pattern: "NEEDLE_TOKEN") }

      globs = captured.grep(/\A--glob=!/).map { |g| g.sub("--glob=!", "") }
      expect(globs).to include(*described_class.send(:ai_context_paths))
      expect(globs).not_to include("**/AGENTS.md")
    end

    # RIPGREP_CONFIG_PATH can turn on --hidden; the AI tools' own directories must stay out.
    it "excludes the directories an AI tool owns outright" do
      allow(described_class).to receive(:ripgrep_available?).and_return(true)
      captured = nil
      allow(Open3).to receive(:capture3) do |*args, **_kwargs|
        captured = args
        [ "", "", instance_double(Process::Status, success?: true, exitstatus: 0) ]
      end

      with_search_app(fixture) { described_class.call(pattern: "NEEDLE_TOKEN") }

      globs = captured.grep(/\A--glob=!/).map { |g| g.sub("--glob=!", "") }
      expect(globs).to include(".claude/", ".cursor/", ".codex/")
      expect(globs).not_to include(".github/", ".vscode/")
    end

    it "hides the same files on the ripgrep and Ruby paths" do
      skip "requires ripgrep" unless described_class.send(:ripgrep_available?)

      with_ripgrep = with_search_app(fixture) { files_found }
      without_ripgrep = with_search_app(fixture) do
        allow(described_class).to receive(:ripgrep_available?).and_return(false)
        files_found
      end

      expect(with_ripgrep).to eq(without_ripgrep)
      expect(with_ripgrep).to include("app/models/status.rb")
      expect(with_ripgrep).not_to include("CLAUDE.md", ".claude/rules/models.md", ".mcp.json", ".codex/config.toml")
      expect(with_ripgrep).not_to include("app/services/AGENTS.md", "app/services/opencode.json")
    end

    it "searches a placeholder a sensitive glob matches on both paths, and never the secret beside it" do
      skip "requires ripgrep" unless described_class.send(:ripgrep_available?)

      original = RailsAiContext.configuration.sensitive_patterns
      RailsAiContext.configuration.sensitive_patterns = %w[keys.*]
      files = { "secrets/keys.yml" => "NEEDLE_TOKEN: real\n", "secrets/keys.yml.sample" => "NEEDLE_TOKEN: placeholder\n" }
      with_ripgrep = with_search_app(files) { files_found }
      without_ripgrep = with_search_app(files) do
        allow(described_class).to receive(:ripgrep_available?).and_return(false)
        files_found
      end

      expect(with_ripgrep).to eq([ "secrets/keys.yml.sample" ])
      expect(without_ripgrep).to eq(with_ripgrep)
    ensure
      RailsAiContext.configuration.sensitive_patterns = original
    end
  end
  describe "definitions written in every form Ruby allows" do
    let(:files) do
      {
        "app/services/token_issuer.rb" => "class TokenIssuer\n  def call = sign(payload)\n\n  private def sign(data) = data.to_s\nend\n",
        "app/services/stamp_service.rb" => "class StampService\n  def call = stamp_now(1)\n\n  def run\n    stamp_now(2)\n  end\n\n  def stamp_now(n) = n\nend\n",
        "lib/billing/money.rb" => "module Billing\n  Money = Data.define(:amount, :currency)\nend\n\nclass Billing::Ledger\nend\n\nclass ::TopLevelThing\nend\n",
        "app/models/widget.rb" => "class Widget < ApplicationRecord\n  def Widget.legacy_finder(id) = find(id)\n  ruby2_keywords def kw_pass(*args); end\nend\n"
      }
    end

    [ true, false ].each do |rg|
      context(rg ? "with ripgrep" : "with the Ruby fallback") do
        before do
          allow(RailsAiContext).to receive(:tier).and_return(:static)
          skip "requires ripgrep" if rg && !described_class.send(:ripgrep_available?)
          allow(described_class).to receive(:ripgrep_available?).and_return(false) unless rg
        end

        def text(**args)
          described_class.call(**args).content.first[:text]
        end

        it "traces a private endless def and its endless caller" do
          with_search_app(files) do
            traced = text(pattern: "sign", match_type: "trace")

            expect(traced).to include("**app/services/token_issuer.rb:4**")
            expect(traced).to include("## Called from (1 site)")
            expect(traced).to include("  2: def call = sign(payload)")
            expect(traced).not_to include("  4: private def sign")
          end
        end

        it "shows a one-line def's body as its own line" do
          with_search_app(files) do
            traced = text(pattern: "sign", match_type: "trace")

            expect(traced).to include("```ruby\n  private def sign(data) = data.to_s\n```")
            expect(traced).not_to include("- `private`")
          end
        end

        it "counts an endless body as a call site" do
          with_search_app(files) do
            traced = text(pattern: "stamp_now", match_type: "trace")

            expect(traced).to include("## Called from (2 sites)")
            expect(traced).to include("  2: def call = stamp_now(1)", "  5: stamp_now(2)")
          end
        end

        it "finds a def behind a modifier or a constant receiver" do
          with_search_app(files) do
            expect(text(pattern: "sign", match_type: "definition")).to include("app/services/token_issuer.rb:4")
            expect(text(pattern: "legacy_finder", match_type: "definition")).to include("app/models/widget.rb:2")
            expect(text(pattern: "kw_pass", match_type: "definition")).to include("app/models/widget.rb:3")
          end
        end

        it "finds a compact class name, a rooted one and a Data.define constant" do
          with_search_app(files) do
            expect(text(pattern: "Ledger", match_type: "class")).to include("lib/billing/money.rb:5")
            expect(text(pattern: "TopLevelThing", match_type: "class")).to include("lib/billing/money.rb:8")
            expect(text(pattern: "Money", match_type: "class")).to include("lib/billing/money.rb:2")
            expect(text(pattern: "Money", match_type: "class", exact_match: true)).to include("lib/billing/money.rb:2")
          end
        end
      end
    end
  end
end
