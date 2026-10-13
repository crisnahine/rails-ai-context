# frozen_string_literal: true

require "spec_helper"

# An exception nobody planned for is an error on every surface: isError over
# MCP and exit 1 on the CLI, so a crash never reads as a result.
RSpec.describe "a tool that raises unexpectedly" do
  {
    RailsAiContext::Tools::Onboard => [ :cached_context, {} ],
    RailsAiContext::Tools::Diagnose => [ :classify_error, { error: "NoMethodError: undefined method `foo' for nil" } ],
    RailsAiContext::Tools::GenerateTest => [ :cached_context, { model: "User" } ],
    RailsAiContext::Tools::ReviewChanges => [ :rails_app, {} ],
    RailsAiContext::Tools::RuntimeInfo => [ :gather_cache, { section: "cache" } ],
    RailsAiContext::Tools::SessionContext => [ :render_status, { action: "status" } ]
  }.each do |tool, (seam, params)|
    it "#{tool.tool_name} answers with an error result" do
      allow(tool).to receive(seam).and_raise(NoMethodError, "undefined method 'to_sentence' for an instance of Array")

      response = tool.call(**params)

      expect(response.error?).to be(true), response.content.first[:text]
      expect(response.content.first[:text]).to start_with("Tool #{tool.tool_name} failed: NoMethodError: undefined method 'to_sentence'")
    end
  end

  [ SystemStackError, SecurityError, SyntaxError ].each do |error|
    it "answers a #{error} with an error result, and marks the CLI run failed" do
      allow(RailsAiContext::Tools::Onboard).to receive(:cached_context).and_raise(error, "boom")
      runner = RailsAiContext::CLI::ToolRunner.new("onboard", [])

      expect(RailsAiContext::Tools::Onboard.call.error?).to be(true)
      expect(runner.run).to start_with("Tool rails_onboard failed: #{error}: boom")
      expect(runner.error).to be(true)
    end
  end

  it "marks the CLI run failed, which is exit 1" do
    allow(RailsAiContext::Tools::Onboard).to receive(:cached_context).and_raise(NoMethodError, "boom")
    runner = RailsAiContext::CLI::ToolRunner.new("onboard", [])

    expect(runner.run).to include("Tool rails_onboard failed: NoMethodError: boom")
    expect(runner.error).to be(true)
  end

  # The crash is inside a section another tool builds: the answer keeps every
  # section and is still an error on both surfaces.
  describe "inside a composed section" do
    tools = RailsAiContext::Tools
    crash = "undefined method 'to_sentence' for an instance of Array"

    def crash_in(tool, seam = :cached_context)
      allow(tool).to receive(seam).and_raise(NoMethodError, "undefined method 'to_sentence' for an instance of Array")
    end

    {
      "rails_get_context for a controller and an action" => [ tools::GetContext, tools::GetRoutes, { controller: "PostsController", action: "index" }, "PostsController" ],
      "rails_get_context for a controller" => [ tools::GetContext, tools::GetRoutes, { controller: "PostsController" }, "PostsController" ],
      "rails_get_context for a model" => [ tools::GetContext, tools::GetSchema, { model: "Post" }, "# Post" ],
      "rails_get_context for a feature" => [ tools::GetContext, tools::GetSchema, { feature: "post" }, "post" ],
      "rails_get_context for an include" => [ tools::GetContext, tools::GetStimulus, { model: "Post", include: [ "stimulus" ] }, "# Post" ],
      "rails_diagnose" => [ tools::Diagnose, tools::GetControllers, { error: "NoMethodError: undefined method `foo' for nil", action: "posts#show" }, "NoMethodError" ]
    }.each do |title, (outer, inner, params, kept)|
      it "#{title} answers an error result that keeps the other sections" do
        crash_in(inner)

        response = outer.call(**params)
        text = response.content.first[:text]

        expect(response.error?).to be(true), text
        expect(text).to include("Tool #{inner.tool_name} failed: NoMethodError: #{crash}")
        expect(text).to include(kept)
        expect(text).not_to start_with("Tool ")
      end
    end

    it "rails_review_changes answers an error result that keeps its review" do
      allow(tools::ReviewChanges).to receive(:get_changed_files).and_return([ "config/routes.rb" ])
      crash_in(tools::GetRoutes)

      response = tools::ReviewChanges.call
      text = response.content.first[:text]

      expect(response.error?).to be(true), text
      expect(text).to include("**1 file changed** (1 routes)")
      expect(text).to include("Tool rails_get_routes failed: NoMethodError: #{crash}")
    end

    it "says what crashed where the answer shows no text of that section" do
      allow(tools::ReviewChanges).to receive(:get_changed_files).and_return([ "app/models/post.rb" ])
      crash_in(tools::GetModelDetails)

      response = tools::ReviewChanges.call
      text = response.content.first[:text]

      expect(response.error?).to be(true), text
      expect(text).to start_with("# Review: HEAD")
      expect(text.scan("Tool rails_get_model_details failed: NoMethodError: #{crash}").size).to eq(1)
    end

    it "marks the CLI run failed, which is exit 1" do
      crash_in(tools::GetSchema)
      runner = RailsAiContext::CLI::ToolRunner.new("context", [ "--model", "Post" ])

      expect(runner.run).to include("Tool rails_get_schema failed: NoMethodError: #{crash}")
      expect(runner.error).to be(true)
    end

    it "is over with the call, so the next answer is an ordinary one" do
      crash_in(tools::GetSchema)
      tools::GetContext.call(model: "Post")
      allow(tools::GetSchema).to receive(:cached_context).and_call_original

      expect(tools::GetContext.call(model: "Post").error?).to be(false)
    end

    it "leaves the answer ordinary when a section answers an error of its own" do
      allow(tools::GetSchema).to receive(:call).and_return(tools::BaseTool.error_response("**Error:** the schema dump could not be read"))

      response = tools::GetContext.call(model: "Post")
      text = response.content.first[:text]

      expect(response.error?).to be(false), text
      expect(text).to include("# Post")
      expect(text).to include("**Error:** the schema dump could not be read")
    end
  end
end
