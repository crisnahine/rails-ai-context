# frozen_string_literal: true

require "spec_helper"

# Every surface that prints a route count, in one place. The static tier
# recorded what it could not expand and nothing read it, so `CLAUDE.md`, the
# rule files, `rails_onboard` and the rake summary all quoted 94 routes on a
# 723-route app as if that were all of them.
#
# The examples below name the surfaces known today; the drift guard at the
# bottom is what catches the next one.
RSpec.describe "route counts across every surface" do
  let(:routes) do
    {
      total_routes: 94,
      dynamic_routes: 23,
      by_controller: { "posts" => [ { verb: "GET", path: "/posts", action: "index", name: "posts" } ] },
      api_namespaces: [],
      confidence: RailsAiContext::Confidence::STATIC
    }
  end

  let(:context) do
    {
      app_name: "TestApp", rails_version: "8.0", ruby_version: "3.4",
      schema: { adapter: "postgresql", total_tables: 1, tables: { "posts" => { columns: [ { name: "id" } ] } } },
      models: { "Post" => { table_name: "posts", associations: [], validations: [] } },
      routes: routes,
      gems: {}, conventions: {}
    }
  end

  # Serializers that return their whole document from #call.
  {
    "MarkdownSerializer" => RailsAiContext::Serializers::MarkdownSerializer,
    "CopilotSerializer" => RailsAiContext::Serializers::CopilotSerializer,
    "ClaudeSerializer" => RailsAiContext::Serializers::ClaudeSerializer
  }.each do |name, klass|
    it "#{name} says how much of the table is missing" do
      expect(klass.new(context).call).to include("23 dynamic constructs not expanded")
    end
  end

  # Serializers that write a directory of files. OpencodeRulesSerializer is not
  # here: it writes per-directory AGENTS.md files and prints no route count.
  {
    "ClaudeRulesSerializer" => RailsAiContext::Serializers::ClaudeRulesSerializer,
    "CursorRulesSerializer" => RailsAiContext::Serializers::CursorRulesSerializer,
    "CopilotInstructionsSerializer" => RailsAiContext::Serializers::CopilotInstructionsSerializer
  }.each do |name, klass|
    it "#{name} says how much of the table is missing" do
      Dir.mktmpdir do |dir|
        # Read back the paths the serializer reports rather than globbing:
        # these write into .claude/, .cursor/ and .github/, and a plain glob
        # skips a hidden directory.
        written = klass.new(context).call(dir)[:written]
        expect(written).not_to be_empty
        expect(written.map { |f| File.read(f) }.join("\n"))
          .to include("23 dynamic constructs not expanded")
      end
    end
  end

  it "rails_get_routes says how much of the table is missing" do
    allow(RailsAiContext::Tools::GetRoutes).to receive(:cached_context).and_return(context)
    expect(RailsAiContext::Tools::GetRoutes.call.content.first[:text])
      .to include("23 dynamic constructs not expanded")
  end

  it "rails_onboard says how much of the table is missing" do
    allow(RailsAiContext::Tools::Onboard).to receive(:cached_context).and_return(context)
    expect(RailsAiContext::Tools::Onboard.call.content.first[:text])
      .to include("23 dynamic constructs not expanded")
  end

  # A count that is the whole table must not grow a caveat.
  it "stays quiet when nothing was left unexpanded" do
    whole = context.merge(routes: routes.except(:dynamic_routes))
    expect(RailsAiContext::Serializers::MarkdownSerializer.new(whole).call)
      .not_to include("not expanded")
  end

  # The examples above are a list, and a list does not grow on its own. This is
  # what catches the tenth surface: onboard.rb computed its total from
  # by_controller rather than :total_routes, so grepping for the obvious key
  # missed it, and it shipped a whole-table claim with no caveat.
  describe "drift guard" do
    # Both filter to a subset the caller asked for, so a whole-table caveat
    # would not be true of the number beside it - the same reason get_routes
    # gates on `controller.nil?`.
    FILTERED_ANSWERS = %w[
      lib/rails_ai_context/vfs.rb
      lib/rails_ai_context/tools/analyze_feature.rb
    ].freeze

    it "every file that renders a route count goes through the seam" do
      renders_a_count = Dir.glob("lib/**/*.{rb,rake}").select do |path|
        File.read(path).match?(/\[:total_routes\]|count_phrase\([^)]*["']app route["']/)
      end
      expect(renders_a_count).not_to be_empty, "the guard's own pattern matched nothing"

      missing = (renders_a_count - FILTERED_ANSWERS).reject do |path|
        File.read(path).include?("RouteCoverage")
      end

      expect(missing).to be_empty,
        "these print a route count without saying when it is partial: #{missing.join(', ')}. " \
        "Add RailsAiContext::RouteCoverage.suffix(routes), or list the file in FILTERED_ANSWERS " \
        "if the count is deliberately a subset."
    end
  end
end
