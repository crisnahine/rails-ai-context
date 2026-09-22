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
  describe "when the ripgrep run fails" do
    before do
      allow(RailsAiContext).to receive(:tier).and_return(:static)
      allow(described_class).to receive(:ripgrep_available?).and_return(true)
      allow(Open3).to receive(:capture2).and_return([ "", instance_double(Process::Status, success?: false, exitstatus: 2) ])
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
end
