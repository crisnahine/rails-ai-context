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
    RailsAiContext::Tools::Validate => -> { call(files: [ "../../etc/passwd" ]) }
  }

  refusals.each do |tool, refuse|
    it "#{tool.tool_name} answers a refused path as an error" do
      tool.reset_cache!
      response = tool.instance_exec(&refuse)

      expect(text_of(response)).to match(/not allowed|denied|sensitive/)
      expect(response.error?).to be(true)
    end
  end

  it "keeps a file that is simply not there an ordinary empty answer" do
    RailsAiContext::Tools::GetEditContext.reset_cache!
    response = RailsAiContext::Tools::GetEditContext.call(file: "app/models/nope.rb", near: "x")

    expect(text_of(response)).to include("File not found")
    expect(response.error?).to be(false)
  end
end
