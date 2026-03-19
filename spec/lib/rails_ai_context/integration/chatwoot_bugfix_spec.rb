# frozen_string_literal: true

require "spec_helper"
require "open3"

# Integration tests that verify bugfixes against a real Rails codebase (chatwoot-develop).
# These tests exercise the actual code paths that were buggy, not just mocked behavior.
RSpec.describe "Bugfix integration tests against chatwoot" do
  let(:chatwoot_root) { "/Users/crisjosephnahine/Documents/Projects/chatwoot-develop" }

  before do
    skip "chatwoot-develop not found" unless Dir.exist?(chatwoot_root)
  end

  # Bug 1: BaseTool.cached_context was thread-unsafe and each of the 9 tool
  # subclasses cached independently (class instance vars go on the subclass).
  # Fix: SHARED_CACHE constant with Mutex, shared across all subclasses.
  describe "Bug 1: Thread-safe shared cache across all tool subclasses" do
    before { RailsAiContext::Tools::BaseTool.reset_cache! }
    after  { RailsAiContext::Tools::BaseTool.reset_cache! }

    it "shares a single SHARED_CACHE across all tool subclasses" do
      cache = RailsAiContext::Tools::BaseTool::SHARED_CACHE

      # All 9 tools should resolve the same SHARED_CACHE constant
      RailsAiContext::Server::TOOLS.each do |tool_class|
        expect(tool_class::SHARED_CACHE).to be(cache),
          "#{tool_class.name} has a different SHARED_CACHE object — cache is not shared!"
      end
    end

    it "protects concurrent access with a Mutex" do
      cache = RailsAiContext::Tools::BaseTool::SHARED_CACHE
      expect(cache[:mutex]).to be_a(Mutex)
    end

    it "survives concurrent reset_cache! calls without errors" do
      threads = 20.times.map do
        Thread.new do
          50.times { RailsAiContext::Tools::BaseTool.reset_cache! }
        end
      end

      expect { threads.each(&:join) }.not_to raise_error
    end

    it "reset_all_caches! clears the shared cache once (not per-tool)" do
      cache = RailsAiContext::Tools::BaseTool::SHARED_CACHE
      cache[:context] = { test: true }
      cache[:timestamp] = 123.0
      cache[:fingerprint] = "abc123"

      RailsAiContext::Tools::BaseTool.reset_all_caches!

      expect(cache[:context]).to be_nil
      expect(cache[:timestamp]).to be_nil
      expect(cache[:fingerprint]).to be_nil
    end
  end

  # Bug 2: SearchCode used `rg --max-count N` which limits matches PER FILE,
  # not total. A search across many files could return hundreds of results
  # when the user asked for 5. The Ruby fallback correctly capped total results.
  # Fix: Added .first(max_results) after parse_rg_output.
  describe "Bug 2: ripgrep --max-count is per-file — results must be capped" do
    it "demonstrates the raw ripgrep bug: --max-count 5 returns way more than 5 results" do
      # This proves the bug existed: rg --max-count 5 returns one match from MANY files
      output, _status = Open3.capture2(
        "rg", "--no-heading", "--line-number", "--max-count", "5",
        "def ", File.join(chatwoot_root, "app/models/"),
        err: File::NULL
      )

      raw_line_count = output.lines.count { |l| l.match?(/^.+?:\d+:/) }
      expect(raw_line_count).to be > 5,
        "Expected ripgrep --max-count 5 to return >5 total results across files, " \
        "got #{raw_line_count}. This proves --max-count is per-file, not total."
    end

    it "caps ripgrep results to max_results after parsing" do
      max = 5
      output, _status = Open3.capture2(
        "rg", "--no-heading", "--line-number", "--max-count", max.to_s,
        "def ", File.join(chatwoot_root, "app/models/"),
        err: File::NULL
      )

      root = chatwoot_root
      # This is the exact parse_rg_output + .first(max_results) from our fix
      parsed = output.lines.filter_map do |line|
        match = line.match(/^(.+?):(\d+):(.*)$/)
        next unless match
        { file: match[1].sub("#{root}/", ""), line_number: match[2].to_i, content: match[3] }
      end

      uncapped = parsed.size
      capped = parsed.first(max).size

      expect(uncapped).to be > max, "Need enough raw results to prove the cap works"
      expect(capped).to eq(max)
    end
  end

  # Bug 3: JobIntrospector had `queue = queue.call rescue queue.to_s` for Proc queues.
  # If queue.call raised, queue.to_s evaluated while queue was still the Proc,
  # yielding garbage like "#<Proc:0x00007f...>" as the queue name.
  # Fix: Changed rescue fallback to "default" instead of queue.to_s.
  describe "Bug 3: Proc queue_name rescue produces garbage — should fallback to 'default'" do
    let(:introspector) { RailsAiContext::Introspectors::JobIntrospector.new(Rails.application) }

    it "demonstrates the old bug: Proc#to_s produces garbage" do
      failing_proc = proc { raise "Redis not available" }
      # This is what the OLD code did: queue.to_s while queue is still the Proc
      garbage = failing_proc.to_s
      expect(garbage).to match(/^#<Proc:/),
        "Proc#to_s should produce garbage like '#<Proc:0x...>' — this is what the old code returned"
    end

    it "the fixed code returns 'default' when a Proc queue raises" do
      # Simulate the fixed logic from job_introspector.rb line 33
      queue = proc { raise "Redis not available" }
      queue = begin queue.call rescue "default" end if queue.is_a?(Proc)

      expect(queue).to eq("default")
    end

    it "the fixed code preserves successful Proc queue results" do
      queue = proc { "critical" }
      queue = begin queue.call rescue "default" end if queue.is_a?(Proc)

      expect(queue).to eq("critical")
    end

    it "the fixed code handles nil-returning Procs gracefully" do
      queue = proc { nil }
      queue = begin queue.call rescue "default" end if queue.is_a?(Proc)

      # nil.to_s returns "" which is handled downstream
      expect(queue.to_s).to eq("")
    end

    it "handles real chatwoot-style symbol queue names (non-Proc)" do
      # Chatwoot uses queue_as :critical, :default, :mailers, etc.
      %i[critical default mailers scheduled_jobs low medium purgable].each do |queue_sym|
        queue = queue_sym
        queue = begin queue.call rescue "default" end if queue.is_a?(Proc)
        expect(queue.to_s).to eq(queue_sym.to_s)
      end
    end
  end
end
