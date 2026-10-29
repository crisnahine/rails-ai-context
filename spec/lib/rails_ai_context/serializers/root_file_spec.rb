# frozen_string_literal: true

require "spec_helper"

RSpec.describe RailsAiContext::Serializers::RootFile do
  let(:context) { RailsAiContext.introspect }
  # Copilot keeps a copy beside AGENTS.md, since most of its surfaces read no other file.
  let(:roots) { %w[AGENTS.md .github/copilot-instructions.md] }

  def managed_block(path)
    text = File.read(path)
    from = text.index(RailsAiContext::Serializers::SectionMarkerWriter::BEGIN_MARKER)
    to = text.index(RailsAiContext::Serializers::SectionMarkerWriter::END_MARKER)
    text[from..to]
  end

  # Copilot CLI drops a copy only when two instruction files are identical,
  # so one differing title line made it load the same root file twice.
  %i[compact full].each do |mode|
    it "gives every AI tool the same root file bytes in #{mode} mode" do
      Dir.mktmpdir do |dir|
        allow(RailsAiContext.configuration).to receive(:output_dir_for).and_return(dir)
        allow(RailsAiContext.configuration).to receive(:context_mode).and_return(mode)
        RailsAiContext::Serializers::ContextFileSerializer.new(context, format: :all).call

        blocks = roots.map { |name| managed_block(File.join(dir, name)) }
        expect(blocks.uniq.size).to eq(1), roots.zip(blocks.map { |b| b.lines[1] }).inspect
      end
    end
  end

  it "renders the file every root path gets" do
    expect(described_class.new(context).call).to start_with("# #{context[:app_name]} - AI Context")
  end

  describe "compact mode" do
    before { RailsAiContext.configuration.context_mode = :compact }
    after { RailsAiContext.configuration.context_mode = :compact }

    it "generates ≤150 lines for a large app" do
      models = 200.times.each_with_object({}) do |i, h|
        h["Model#{i}"] = {
          associations: 5.times.map { |j| { type: "has_many", name: "rel_#{j}" } },
          validations: 3.times.map { |j| { kind: "presence", attributes: [ "attr_#{j}" ] } },
          table_name: "model_#{i}s"
        }
      end

      context = {
        app_name: "BigApp", rails_version: "8.0", ruby_version: "3.4",
        generated_at: Time.now.iso8601,
        schema: { adapter: "postgresql", tables: {}, total_tables: 180 },
        models: models,
        routes: { total_routes: 1500, by_controller: {} },
        gems: { notable: [ { name: "devise", category: :auth } ] },
        conventions: { architecture: [ "MVC", "Service objects" ], patterns: [], config_files: [] },
        jobs: { jobs: [], mailers: [], channels: [] },
        auth: { authentication: {}, authorization: {} },
        migrations: { total: 500, pending: [] }
      }

      output = described_class.new(context).call
      line_count = output.lines.count

      expect(line_count).to be <= 175
      expect(output).to include("Tools (#{RailsAiContext::Server::TOOLS.size})")
      expect(output).to include("rails_get_schema")
      expect(output).to include("rails_diagnose")
    end

    it "counts pending migrations only when the payload says what is applied" do
      base = {
        app_name: "App", rails_version: "8.0", ruby_version: "3.4",
        generated_at: Time.now.iso8601, schema: {}, models: {},
        routes: {}, gems: {}, conventions: {}
      }

      known = described_class.new(base.merge(migrations: { total: 4, pending: [] })).call
      unknown = described_class.new(base.merge(migrations: { total: 4 })).call

      expect(known).to include("- Migrations: 4 total, 0 pending")
      expect(unknown).to include("- Migrations: 4 total\n")
      expect(unknown).not_to include("4 total,")
    end

    it "includes key models capped at 15" do
      models = 30.times.each_with_object({}) do |i, h|
        h["Model#{i.to_s.rjust(2, '0')}"] = { associations: [], validations: [] }
      end

      context = {
        app_name: "App", rails_version: "8.0", ruby_version: "3.4",
        generated_at: Time.now.iso8601, schema: {}, models: models,
        routes: {}, gems: {}, conventions: {}
      }

      output = described_class.new(context).call
      expect(output).to include("...15 more")
    end

    # The file said "Key models" and listed the alphabetical first 15, while
    # rails_onboard named the most connected ones: two answers to one question.
    it "ranks key models by association count, most connected first" do
      models = {
        "Zebra" => { associations: 4.times.map { |j| { type: "has_many", name: "z#{j}" } } },
        "Alpha" => { associations: [] },
        "Beta"  => { associations: [ { type: "belongs_to", name: "zebra" } ] }
      }

      context = {
        app_name: "App", rails_version: "8.0", ruby_version: "3.4",
        generated_at: Time.now.iso8601, schema: {}, models: models,
        routes: {}, gems: {}, conventions: {}
      }

      output = described_class.new(context).call
      listed = output.lines.grep(/\A- \*\*(Zebra|Beta|Alpha)\*\*/).map { |l| l[/\*\*(\w+)\*\*/, 1] }

      expect(listed).to eq(%w[Zebra Beta Alpha])
      expect(output).to include("Key models (3 total, most connected first)")
    end

    it "includes app name and version" do
      context = {
        app_name: "MyApp", rails_version: "8.0", ruby_version: "3.4",
        generated_at: Time.now.iso8601
      }
      output = described_class.new(context).call
      expect(output).to include("MyApp")
      expect(output).to include("Rails 8.0")
    end
  end

  describe "full mode" do
    before { RailsAiContext.configuration.context_mode = :full }
    after { RailsAiContext.configuration.context_mode = :compact }

    it "renders the whole markdown document" do
      context = {
        app_name: "App", rails_version: "8.0", ruby_version: "3.4",
        generated_at: Time.now.iso8601
      }
      output = described_class.new(context).call
      expect(output).to be_a(String)
      expect(output).to include("## Behavioral Rules")
    end
  end

  describe "scope name rendering" do
    before { RailsAiContext.configuration.context_mode = :compact }
    after  { RailsAiContext.configuration.context_mode = :compact }

    it "renders scope names from hash-style scopes, not garbled hash output" do
      context = {
        app_name: "App", rails_version: "8.0", ruby_version: "3.4",
        generated_at: Time.now.iso8601,
        models: {
          "User" => {
            associations: [],
            validations: [],
            scopes: [ { name: "active", body: "where(active: true)" }, { name: "recent", body: "order(created_at: :desc)" } ],
            constants: []
          }
        }
      }

      output = described_class.new(context).call
      expect(output).to include("scopes: active, recent")
      expect(output).not_to include("{:name=>")
      expect(output).not_to include("body")
    end
  end

  describe "test command" do
    let(:base_context) do
      {
        app_name: "App", rails_version: "8.0", ruby_version: "3.4",
        generated_at: Time.now.iso8601
      }
    end

    context "compact mode" do
      before { RailsAiContext.configuration.context_mode = :compact }
      after  { RailsAiContext.configuration.context_mode = :compact }

      it "uses rails test for minitest projects" do
        output = described_class.new(base_context.merge(tests: { framework: "minitest" })).call
        expect(output).to include("rails test")
        expect(output).not_to include("bundle exec rspec")
      end

      it "uses bundle exec rspec for rspec projects" do
        output = described_class.new(base_context.merge(tests: { framework: "rspec" })).call
        expect(output).to include("bundle exec rspec")
        expect(output).not_to include("rails test")
      end

      it "defaults to rails test when framework is unknown" do
        output = described_class.new(base_context).call
        expect(output).to include("rails test")
      end
    end

    context "full mode" do
      before { RailsAiContext.configuration.context_mode = :full }
      after  { RailsAiContext.configuration.context_mode = :compact }

      it "uses rails test for minitest projects" do
        output = described_class.new(base_context.merge(tests: { framework: "minitest" })).call
        expect(output).to include("rails test")
        expect(output).not_to include("bundle exec rspec")
      end

      it "uses bundle exec rspec for rspec projects" do
        output = described_class.new(base_context.merge(tests: { framework: "rspec" })).call
        expect(output).to include("bundle exec rspec")
      end
    end
  end
  # The generated file and the routes tool answer the same question through
  # different code paths. The serializer counted raw Rails routes while the
  # tool merged each resource's PATCH/PUT pair, so one app produced two
  # numbers - 27 in CLAUDE.md, 24 from rails_get_routes.
  describe "route count parity with rails_get_routes" do
    it "reports the same app route total the routes tool reports" do
      RailsAiContext::Tools::GetRoutes.reset_cache!

      routes_text = RailsAiContext::Tools::GetRoutes.call(detail: "standard").content.first[:text]
      routes_total = routes_text[/# Routes \((\d+) route/, 1].to_i
      expect(routes_total).to be > 0

      output = described_class.new(RailsAiContext.introspect).call
      serializer_total = output[/- Routes: (\d+) app route/, 1].to_i

      expect(serializer_total).to eq(routes_total)
    end
  end

  describe "compact budget" do
    before { RailsAiContext.configuration.context_mode = :compact }

    # An empty entry must survive as a blank line between sections.
    it "leaves a blank line between the title and the first section" do
      output = described_class.new(serializer_context).call

      expect(output).to start_with("# TestApp - AI Context\n\n> Rails")
      expect(output).to include("\n\n## Stack")
    end

    # A private API app measured 152 non-blank lines in the managed block
    # against a budget of 150: the BEGIN/END markers were added after the trim.
    # They are part of what the gem writes, so they come out of the budget.
    it "counts the markers, so the written block never exceeds the budget" do
      whole = described_class.new(serializer_context).call.lines.grep_v(/\A\s*\z/).size
      budget = whole - 2 + RailsAiContext::Serializers::SectionMarkerWriter::MARKER_LINES
      allow(RailsAiContext.configuration).to receive(:claude_max_lines).and_return(budget)

      Dir.mktmpdir do |dir|
        path = File.join(dir, "CLAUDE.md")
        RailsAiContext::Serializers::SectionMarkerWriter.write_with_markers(
          path, described_class.new(serializer_context).call, root: dir
        )

        block = File.read(path).lines
        expect(block.first).to start_with("<!-- BEGIN rails-ai-context -->")
        expect(block.join).to include("_Context trimmed.")
        expect(block.grep_v(/\A\s*\z/).size).to be <= budget
      end
    end

    # A budget smaller than the guide used to cut the guide and the protocol
    # to one line, while the docs said they are kept whole.
    it "cuts the data and keeps the title, the rules and the tools guide whole" do
      allow(RailsAiContext.configuration).to receive(:claude_max_lines).and_return(20)

      output = described_class.new(serializer_context).call

      expect(output).to start_with("# TestApp - AI Context")
      expect(output).not_to include("## Key models")
      expect(output.index("_Context trimmed.")).to be < output.index("## Commands")
      expect(output).to include("## Rules", "Anti-Hallucination Protocol", "### All #{RailsAiContext::Server.exposed_tools.size} tools")
    end
  end

  describe "full mode header" do
    before { RailsAiContext.configuration.context_mode = :full }
    after { RailsAiContext.configuration.context_mode = :compact }

    it "leaves one blank line between the header block and the prose" do
      context = {
        app_name: "App", rails_version: "8.0", ruby_version: "3.4",
        generated_at: Time.now.iso8601
      }
      output = described_class.new(context).call

      expect(output).to include("Ruby 3.4\n\nThis file gives AI assistants")
    end
  end

  # The regenerate line at the foot of the file is read by whoever opens it;
  # a standalone install has no rake task to run.
  describe "the regenerate command in the footer" do
    around do |example|
      RailsAiContext.configuration.context_mode = :full
      example.run
    ensure
      RailsAiContext.configuration.context_mode = :compact
    end

    let(:minimal) do
      { app_name: "App", rails_version: "8.0", ruby_version: "3.4", schema: {}, models: {},
        routes: {}, gems: {}, conventions: {} }
    end

    it "names the binary in a standalone install" do
      allow(RailsAiContext::InstallMode).to receive(:standalone?).and_return(true)
      output = described_class.new(minimal).call

      expect(output).to include("Run `rails-ai-context context` to regenerate it.")
      expect(output).not_to include("rails ai:context")
    end

    # A plain `rails ai:context` regenerated the file in compact mode.
    it "names a rake run that stays in full mode where the app bundles the gem" do
      allow(RailsAiContext::InstallMode).to receive(:standalone?).and_return(false)

      expect(described_class.new(minimal).call).to include("Run `CONTEXT_MODE=full rails ai:context` to regenerate it.")
    end
  end

  describe "static tier" do
    let(:context) do
      {
        app_name: "TestApp", rails_version: "8.0", ruby_version: "3.4",
        generated_at: Time.now.iso8601,
        schema: { adapter: "sqlite3", tables: {}, total_tables: 5 },
        models: {
          "User" => { associations: [ { type: "has_many", name: "posts" } ], validations: [] },
          "Post" => { associations: [ { type: "belongs_to", name: "user" } ], validations: [] }
        },
        routes: { total_routes: 20, by_controller: { "users" => [], "posts" => [] } },
        gems: { notable_gems: [ { name: "devise", category: :auth } ] },
        conventions: { architecture: [ "MVC" ], patterns: [], config_files: [ "config/routes.rb" ] },
        jobs: { jobs: [], mailers: [], channels: [] },
        auth: { authentication: {}, authorization: {} },
        migrations: { total: 10, pending: [] }
      }
    end

    it "renders no routes line when the static tier refused routes" do
      refused = context.merge(routes: { unavailable: "requires a booted Rails app" })

      expect(described_class.new(refused).call).not_to include("- Routes:")
    end
  end
end
