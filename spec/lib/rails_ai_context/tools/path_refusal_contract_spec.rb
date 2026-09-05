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
    RailsAiContext::Tools::GenerateTest => -> { call(file: "../../etc/passwd") }
  }

  # One tool takes a path that is not the question. `rails_diagnose` answers
  # `error:`, and `file:` only points at code to quote, so a refused path costs
  # that section and not the diagnosis. The refusal is still said out loud.
  composed = {
    RailsAiContext::Tools::Diagnose => lambda {
      call(error: "NoMethodError: undefined method `x` for nil", file: "../../etc/passwd", line: 1)
    }
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
    RailsAiContext::Tools::GetTestInfo => -> { call(model: "/etc/passwd") },
    RailsAiContext::Tools::GetConcern => -> { call(name: "/etc/passwd") },
    RailsAiContext::Tools::ReviewChanges => -> { call(files: [ "/etc/passwd" ]) }
  }

  # `rails_security_scan` is not in the list above on purpose: a leading slash
  # has always meant "from the Rails root" there, and the filter strips it, so
  # `/etc/passwd` is the app's own `etc/passwd` and simply is not there. A
  # traversal out of the root is still refused, in the list above this one.

  absolute_refusals.each do |tool, refuse|
    it "#{tool.tool_name} answers an absolute path as a refusal, not a miss" do
      tool.reset_cache!
      response = tool.instance_exec(&refuse)

      expect(text_of(response)).to match(/not allowed|denied|sensitive/)
      expect(response.error?).to be(true)
    end
  end

  composed.each do |tool, refuse|
    it "#{tool.tool_name} says the path was refused and still answers" do
      tool.reset_cache!
      response = tool.instance_exec(&refuse)

      expect(text_of(response)).to match(/not allowed|denied|sensitive/)
      expect(text_of(response)).to include("Error Diagnosis")
      expect(response.error?).to be(false)
    end
  end

  # The lists above are what someone remembered to type. These two are what the
  # code says they have to hold, and they catch different halves: the schema
  # names the parameters that are paths, and the guard call sites name the
  # tools that already know they take one - including the two whose parameter
  # is a name the tool turns into a path, which no parameter name reveals.
  it "covers every tool that takes a path-shaped parameter" do
    path_params = %w[path file files partial]
    takers = RailsAiContext::Server.builtin_tools.select do |tool|
      properties = (tool.input_schema_value&.to_h || {})[:properties] || {}
      properties.keys.map(&:to_s).any? { |name| path_params.include?(name) }
    end

    expect(takers - (refusals.keys + absolute_refusals.keys + composed.keys)).to be_empty
  end

  it "covers every tool that guards a caller path" do
    tools_dir = File.expand_path("../../../../lib/rails_ai_context/tools", __dir__)
    guarding = RailsAiContext::Server.builtin_tools.select do |tool|
      file = File.join(tools_dir, "#{tool.tool_name.sub(/\Arails_/, '')}.rb")
      File.exist?(file) && File.read(file).include?("refuse_unsafe_paths")
    end

    expect(guarding).not_to be_empty
    expect(guarding - (refusals.keys + absolute_refusals.keys + composed.keys)).to be_empty
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
