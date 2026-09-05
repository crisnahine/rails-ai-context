# frozen_string_literal: true

require "spec_helper"

# One contract for every tool that takes a path from the caller: a path the
# tool refuses on policy - outside the app, a traversal, a sensitive file - is
# an error result, so a script reading the exit status can tell a refusal from
# an answer. `validate` said so already and the rest exited 0 on the same
# mistake. A path that is simply not there stays an ordinary empty answer.
RSpec.describe "path refusal contract" do
  def text_of(response)
    response.content.first[:text]
  end

  refusals = {
    RailsAiContext::Tools::GetView => -> { call(path: "../../config/master.key") },
    RailsAiContext::Tools::GetEditContext => -> { call(file: "../../etc/passwd", near: "root") },
    RailsAiContext::Tools::GetConcern => -> { call(name: "../../etc/passwd") },
    RailsAiContext::Tools::GetPartialInterface => -> { call(partial: "../../etc/passwd") },
    RailsAiContext::Tools::SearchCode => -> { call(pattern: "root", path: "../..") },
    RailsAiContext::Tools::ReadLogs => -> { call(file: "../../etc/passwd") },
    RailsAiContext::Tools::Validate => -> { call(files: [ "../../etc/passwd" ]) },
    RailsAiContext::Tools::GetTestInfo => -> { call(model: "../../etc/passwd") },
    RailsAiContext::Tools::SecurityScan => -> { call(files: [ "../../etc/passwd" ]) },
    RailsAiContext::Tools::ReviewChanges => -> { call(files: [ "../../etc/passwd" ]) },
    RailsAiContext::Tools::GenerateTest => -> { call(file: "../../etc/passwd") },
    RailsAiContext::Tools::Diagnose => -> { call(error: "NoMethodError", file: "../../etc/passwd") }
  }

  refusals.each do |tool, refuse|
    it "#{tool.tool_name} answers a refused path as an error" do
      tool.reset_cache!
      response = tool.instance_exec(&refuse)

      expect(text_of(response)).to match(/not allowed|denied|sensitive/)
      expect(response.error?).to be(true)
    end
  end

  # An absolute path is the same refusal as a traversal, and every tool that
  # resolves a file says so. search_code resolves a directory by joining the
  # argument onto the root, which turns an absolute path into a subpath that
  # is merely absent - so it answered "not found" and listed the app's own
  # directories, as though the caller had mistyped a relative one.
  absolute_refusals = {
    RailsAiContext::Tools::GetView => -> { call(path: "/etc/passwd") },
    RailsAiContext::Tools::GetEditContext => -> { call(file: "/etc/passwd", near: "root") },
    RailsAiContext::Tools::GetPartialInterface => -> { call(partial: "/etc/passwd") },
    RailsAiContext::Tools::SearchCode => -> { call(pattern: "root", path: "/etc") },
    RailsAiContext::Tools::GenerateTest => -> { call(file: "/etc/passwd") },
    RailsAiContext::Tools::Diagnose => -> { call(error: "NoMethodError", file: "/etc/passwd") },
    RailsAiContext::Tools::ReviewChanges => -> { call(files: [ "/etc/passwd" ]) },
    RailsAiContext::Tools::SecurityScan => -> { call(files: [ "/etc/passwd" ]) }
  }

  absolute_refusals.each do |tool, refuse|
    it "#{tool.tool_name} answers an absolute path as a refusal, not a miss" do
      tool.reset_cache!
      response = tool.instance_exec(&refuse)

      expect(text_of(response)).to match(/not allowed|denied|sensitive/)
      expect(response.error?).to be(true)
    end
  end

  # The list above is what someone remembered to type. This is what the
  # registry says the list has to hold, so a new tool taking a path from the
  # caller cannot quietly skip the contract.
  it "covers every tool that takes a path-shaped parameter" do
    path_params = %w[path file files partial]
    takers = RailsAiContext::Server.builtin_tools.select do |tool|
      properties = (tool.input_schema_value&.to_h || {})[:properties] || {}
      properties.keys.map(&:to_s).any? { |name| path_params.include?(name) }
    end

    expect(takers - (refusals.keys + absolute_refusals.keys)).to be_empty
  end

  it "keeps a directory that is simply not there an ordinary empty answer" do
    RailsAiContext::Tools::SearchCode.reset_cache!
    response = RailsAiContext::Tools::SearchCode.call(pattern: "root", path: "nope")

    expect(text_of(response)).to include("Path not found")
    expect(response.error?).to be(false)
  end

  it "keeps a file that is simply not there an ordinary empty answer" do
    RailsAiContext::Tools::GetEditContext.reset_cache!
    response = RailsAiContext::Tools::GetEditContext.call(file: "app/models/nope.rb", near: "x")

    expect(text_of(response)).to include("File not found")
    expect(response.error?).to be(false)
  end
end
