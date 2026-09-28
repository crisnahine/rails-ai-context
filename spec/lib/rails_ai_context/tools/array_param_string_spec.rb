# frozen_string_literal: true

require "spec_helper"

# A schema array param can arrive as a string: an MCP client may send
# "app/models/post.rb" where the schema says an array, and a direct call does
# the same. review_changes answered "undefined method 'any?' for an instance
# of String". A string is a one-element list, and the CLI's documented
# `a.rb,b.rb` form is a list, whichever way the call comes in.
RSpec.describe "a string given for an array parameter" do
  # Every tool whose schema declares an array param, and that param.
  ARRAY_PARAMS = {
    RailsAiContext::Tools::GetContext => :include,
    RailsAiContext::Tools::ReviewChanges => :files,
    RailsAiContext::Tools::SecurityScan => :files,
    RailsAiContext::Tools::Validate => :files
  }.freeze

  it "names every tool whose schema declares an array param" do
    declared = RailsAiContext::Server::TOOLS.flat_map do |tool|
      (tool.input_schema.to_h[:properties] || {}).select { |_, prop| prop[:type] == "array" }.keys.map { |key| [ tool, key.to_sym ] }
    end
    expect(declared).to contain_exactly(*ARRAY_PARAMS.to_a, [ RailsAiContext::Tools::SecurityScan, :checks ])
  end

  # The list reaches the tool body: SafeCall turns the string into it before
  # the tool runs, so a spy on the body's own work sees the array.
  it "reaches each tool's body as a list" do
    seen = []
    allow(RailsAiContext::Tools::ReviewChanges).to receive(:refuse_unsafe_paths).and_wrap_original do |original, files|
      seen << files
      original.call(files)
    end

    RailsAiContext::Tools::ReviewChanges.call(files: "app/models/post.rb")

    expect(seen).to eq([ %w[app/models/post.rb] ])
  end

  {
    [ RailsAiContext::Tools::GetContext, :include ] => { include: "services", model: "Post" },
    [ RailsAiContext::Tools::ReviewChanges, :files ] => { files: "app/models/post.rb" },
    [ RailsAiContext::Tools::SecurityScan, :files ] => { files: "app/models/post.rb" },
    [ RailsAiContext::Tools::SecurityScan, :checks ] => { checks: "CheckSQL,CheckXSS" },
    [ RailsAiContext::Tools::Validate, :files ] => { files: "app/models/post.rb" }
  }.each do |(tool, param), args|
    it "answers #{tool.tool_name} #{param} given as a string without failing" do
      result = tool.call(**args)
      text = result.content.first[:text]

      expect(text).not_to include("undefined method")
      expect(text).not_to match(/Tool #{tool.tool_name} failed/)
    end
  end

  it "answers review_changes instead of failing on the string" do
    text = RailsAiContext::Tools::ReviewChanges.call(files: "app/models/post.rb").content.first[:text]

    expect(text).not_to include("undefined method")
  end

  it "validates both files of a comma list given as one string" do
    text = RailsAiContext::Tools::Validate.call(files: "app/models/post.rb,app/models/comment.rb").content.first[:text]

    expect(text).to include("2/2 files passed")
  end

  # The CLI already split these; it keeps doing so, in both spellings.
  it "reaches the tool as a list through the CLI, as a flag and as key=value" do
    [ %w[--files app/models/post.rb,app/models/comment.rb], %w[files=app/models/post.rb,app/models/comment.rb] ].each do |args|
      out = RailsAiContext::CLI::ToolRunner.new("validate", args).run
      expect(out).to include("2/2 files passed")
    end
  end
end
