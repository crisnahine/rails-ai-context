# frozen_string_literal: true

require "spec_helper"
require "tmpdir"

RSpec.describe RailsAiContext::Serializers::CompactSerializerHelper do
  let(:host) do
    Class.new do
      include RailsAiContext::Serializers::CompactSerializerHelper

      def cap(lines, keep: [])
        send(:enforce_max_lines, lines, keep: keep)
      end
    end.new
  end

  def content_lines(output)
    output.lines.grep_v(/\A\s*\z/).size
  end

  describe "the Commands section" do
    let(:commands_host) do
      Class.new do
        include RailsAiContext::Serializers::TestCommandDetection
        include RailsAiContext::Serializers::StackOverviewHelper
        include RailsAiContext::Serializers::CompactSerializerHelper

        def context = { tests: { framework: "rspec" } }

        def commands(root) = send(:render_commands, root)
      end.new
    end

    it "names only the commands the app has" do
      Dir.mktmpdir do |root|
        FileUtils.mkdir_p(File.join(root, "bin"))
        FileUtils.mkdir_p(File.join(root, "db/migrate"))
        File.write(File.join(root, "bin/rails"), "")

        lines = commands_host.commands(root)

        expect(lines).to include("- `bin/rails server` - start the app")
        expect(lines).to include("- `bin/rails db:migrate` - run pending migrations")
        expect(lines.join("\n")).not_to include("bin/dev")
      end
    end

    it "names bin/dev when the app has one" do
      Dir.mktmpdir do |root|
        FileUtils.mkdir_p(File.join(root, "bin"))
        File.write(File.join(root, "bin/dev"), "")
        File.write(File.join(root, "bin/rails"), "")

        lines = commands_host.commands(root)

        expect(lines).to include("- `bin/dev` - start dev server")
        expect(lines.join("\n")).not_to include("bin/rails server")
        expect(lines.join("\n")).not_to include("db:migrate")
      end
    end
  end

  # enforce_max_lines reserves the BEGIN/END markers the writer adds, so a spec
  # about the trim states the budget the method actually has to spend.
  def with_budget(lines)
    allow(RailsAiContext.configuration).to receive(:claude_max_lines)
      .and_return(lines + RailsAiContext::Serializers::SectionMarkerWriter::MARKER_LINES)
  end

  # with_budget adds MARKER_LINES back, so it cannot notice the reservation
  # going missing. These two stub the raw setting and count the real writer.
  describe "the marker reservation" do
    it "reserves exactly the non-blank lines the writer wraps the block in" do
      Dir.mktmpdir do |dir|
        path = File.join(dir, "CLAUDE.md")
        RailsAiContext::Serializers::SectionMarkerWriter.write_with_markers(path, "one\ntwo")

        added = content_lines(File.read(path)) - 2
        expect(RailsAiContext::Serializers::SectionMarkerWriter::MARKER_LINES).to eq(added)
        expect(added).to eq(2)
      end
    end

    it "leaves room for the markers inside claude_max_lines" do
      allow(RailsAiContext.configuration).to receive(:claude_max_lines).and_return(10)
      lines = 40.times.map { |i| "line #{i}" }

      expect(content_lines(host.cap(lines))).to eq(8)
    end
  end

  describe "#enforce_max_lines" do
    # Counting blank separators would cut the tools guide off the end of every file.
    it "counts content lines, not the blank separators, against the budget" do
      with_budget(50)
      lines = 50.times.flat_map { |i| (i % 5 == 4) ? [ "line #{i}", "" ] : [ "line #{i}" ] }

      output = host.cap(lines)

      expect(output).not_to include("_Context trimmed.")
      expect(content_lines(output)).to eq(50)
    end

    # A budget the setter rejects can still arrive through a stub or an assigned ivar.
    it "keeps nothing but the notice when the budget is zero or less" do
      with_budget(0)

      output = host.cap([ "line one", "", "line two" ])

      expect(output).to eq("_Context trimmed. Use MCP tools for full details._")
    end

    # The loop counts a whitespace-only line as blank, so the tail trim has to
    # agree: an exact "" comparison left the trim note sitting under one.
    it "drops a whitespace-only line from the tail before the trim note" do
      with_budget(2)

      output = host.cap([ "line one", "   ", "line two", "line three" ])

      expect(output).to eq("line one\n\n_Context trimmed. Use MCP tools for full details._")
    end

    it "trims to the budget in content lines when the file runs over" do
      with_budget(10)
      lines = 40.times.flat_map { |i| [ "line #{i}", "" ] }

      output = host.cap(lines)

      expect(content_lines(output)).to eq(10)
      expect(output).to end_with("_Context trimmed. Use MCP tools for full details._")
    end
  end

  # The Rules and the tools guide tell the reader how to behave; the data above
  # them is what the MCP tools can answer in full. OFN sat exactly on the
  # budget, so one added Stack line dropped the last rule off four files.
  describe "#enforce_max_lines with a kept tail" do
    let(:rules) { [ "## Rules", "- rule one", "- rule two", "" ] }

    it "cuts a data line and keeps the trailing rules whole" do
      with_budget(6)
      body = [ "# App", "- Models: 3", "- Routes: 9", "- In-repo engines: 4", "" ]

      output = host.cap(body, keep: rules)

      expect(output).to include("- Models: 3")
      expect(output).to include("- rule two")
      expect(output).not_to include("- In-repo engines: 4")
      expect(content_lines(output)).to eq(6)
    end

    it "puts the trim note where the cut is, not at the end of the file" do
      with_budget(6)
      body = [ "# App", "- Models: 3", "- Routes: 9", "- In-repo engines: 4", "" ]

      output = host.cap(body, keep: rules)

      expect(output).to match(/- rule two\s*\z/)
      expect(output.index("_Context trimmed.")).to be < output.index("## Rules")
    end

    it "leaves a file under the budget untouched" do
      with_budget(50)
      body = [ "# App", "- Models: 3", "" ]

      output = host.cap(body, keep: rules)

      expect(output).not_to include("_Context trimmed.")
      expect(output).to include("- Models: 3")
      expect(output).to include("- rule two")
    end

    # "## Commands" with nothing under it but the trim note is worse than no
    # Commands section: the heading claims content the cut removed.
    it "drops a heading whose body the cut removed" do
      with_budget(7)
      body = [ "# App", "- Models: 3", "", "## Key models", "- **Post**", "- **User**", "" ]

      output = host.cap(body, keep: rules)

      expect(output).to include("- Models: 3")
      expect(output).not_to include("## Key models")
      expect(output).to include("- rule two")
    end

    it "drops a heading left bare under another heading" do
      with_budget(7)
      body = [ "# App", "- Rails 8", "", "## Gems", "", "### Payments", "- stripe", "" ]

      output = host.cap(body, keep: rules)

      expect(output).not_to include("## Gems")
      expect(output).not_to include("### Payments")
      expect(output).to include("- Rails 8")
    end

    # A `#` inside a fenced block is a comment, not a heading, and a block cut
    # open would render everything after it - the note and the rules - as code.
    it "cuts a fenced block whole rather than leaving it open" do
      with_budget(8)
      body = [ "# App", "- Models: 3", "", "## Example", "```ruby", "x = 1", "# set up", "y = 2", "```", "" ]

      output = host.cap(body, keep: rules)

      expect(output.lines.count { |l| l.lstrip.start_with?("```") }).to be_even
      expect(output).not_to include("```ruby")
      expect(output).to include("- Models: 3")
      expect(output).to match(/- rule two\s*\z/)
    end

    it "keeps a comment line inside a fenced block that fits" do
      with_budget(12)
      body = [ "# App", "```ruby", "x = 1", "# set up", "```", "- Models: 3", "- Routes: 9", "- Jobs: 2", "" ]

      output = host.cap(body, keep: rules)

      expect(output).to include("```ruby\nx = 1\n# set up\n```")
    end

    # The budget is a hard cap, so a tail that cannot fit is trimmed like any
    # other overflow rather than pushing the file over. A heading left bare by
    # that cut goes too, which can put the output under the cap.
    it "falls back to trimming the tail when the rules alone exceed the budget" do
      with_budget(3)
      body = [ "# App", "- Models: 3" ]

      output = host.cap(body, keep: rules)

      expect(content_lines(output)).to eq(3)
      expect(output).to include("- Models: 3")
      expect(output).to end_with("_Context trimmed. Use MCP tools for full details._")
    end
  end

  # The line was gated on the conventions section having seen app/services, so
  # an app whose services the scan finds under a configured extra path got no
  # line beside a jobs line that had them.
  describe "the services line" do
    let(:arch_host) do
      names = service_list
      Class.new do
        include RailsAiContext::Serializers::CompactSerializerHelper

        define_method(:service_names) { names }

        def context
          { conventions: { architecture: [ "MVC" ], patterns: [], directory_structure: {} } }
        end

        def job_names = []
        def arch_labels_hash = {}
        def pattern_labels_hash = {}
      end.new
    end

    context "when the scan found services" do
      let(:service_list) { %w[PaymentService] }

      it "prints them whatever directory the conventions walk saw" do
        expect(arch_host.send(:render_architecture)).to include("**Services:** PaymentService")
      end
    end

    context "when it found none" do
      let(:service_list) { [] }

      it "prints no line" do
        expect(arch_host.send(:render_architecture).grep(/Services:/)).to eq([])
      end
    end
  end

  # The static tier has no conventions section, and the services and jobs
  # lines, which never needed it, went with it.
  describe "the architecture section without the booted conventions" do
    let(:static_host) do
      Class.new do
        include RailsAiContext::Serializers::CompactSerializerHelper

        def context = { conventions: { unavailable: "requires a booted Rails app" } }
        def service_names = %w[PaymentService]
        def job_names = %w[SyncJob]
      end.new
    end

    it "still names the services and jobs" do
      lines = static_host.send(:render_architecture)

      expect(lines).to include("## Architecture")
      expect(lines).to include("**Services:** PaymentService")
      expect(lines).to include("**Jobs:** SyncJob")
    end

    it "prints no heading when there is nothing under it" do
      host = Class.new do
        include RailsAiContext::Serializers::CompactSerializerHelper

        def context = {}
        def service_names = []
        def job_names = []
      end.new

      expect(host.send(:render_architecture)).to eq([])
    end
  end

  # An app that runs every piece of background work through Sidekiq had its
  # whole async story left out of the line: Whitehall's 31 workers read as
  # "Async: 1 mailer".
  describe "the async line" do
    let(:async_host) do
      Class.new do
        include RailsAiContext::Serializers::CompactSerializerHelper

        def context
          { jobs: { jobs: [ { name: "ImportJob" } ], workers: [ { name: "CleanupWorker" } ],
                    mailers: [ { name: "UserMailer" } ], channels: [] } }
        end

        def full_preset_stack_lines = []
      end.new
    end

    it "counts the Sidekiq workers beside the jobs" do
      line = async_host.send(:render_stack_overview).find { |l| l.start_with?("- Async:") }

      expect(line).to eq("- Async: 1 job, 1 Sidekiq worker, 1 mailer")
    end
  end

  describe "the stimulus registration rule" do
    def rules(auto)
      ctx = { stimulus: { controllers: [ { name: "hello" } ], auto_registers: auto }, conventions: { patterns: [] } }
      RailsAiContext::Serializers::ClaudeSerializer.new(ctx).send(:render_footer).join("\n")
    end

    it "promises auto-registration only when the app loads them that way" do
      expect(rules(true)).to include("auto-register")
    end

    it "promises nothing about registration otherwise" do
      text = rules(false)

      expect(text).not_to include("auto-register")
      expect(text).to include("not auto-loaded from `app/javascript/controllers`")
    end
  end
end
