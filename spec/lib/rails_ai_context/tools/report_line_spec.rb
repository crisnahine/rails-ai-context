# frozen_string_literal: true

require "spec_helper"

# Every answer a tool gives ends by asking the agent to offer the user a GitHub
# issue when the answer itself is wrong, missing or failing, once per answer.
RSpec.describe "The report line on every tool answer" do
  let(:line) { RailsAiContext::Tools::BaseTool::REPORT_NOTE }

  before { RailsAiContext.configuration.report_issue_line = true }

  def text(response)
    response.content.first[:text]
  end

  it "ends a plain answer" do
    output = text(RailsAiContext::Tools::GetSchema.call(detail: "summary"))

    expect(output).to end_with("_#{line}_")
    expect(output.scan(line).size).to eq(1)
  end

  # A composite answer is built from other tools' answers, each of which would end with it.
  it "ends a composite answer once" do
    output = text(RailsAiContext::Tools::GetContext.call(model: "Post"))

    expect(output.scan(line).size).to eq(1)
  end

  it "ends an error answer" do
    output = text(RailsAiContext::Tools::GetSchema.call(table: "no_such_table_anywhere"))

    expect(output).to include(line)
  end

  # A JSON answer has to parse, so it carries the line under a reserved key.
  it "rides in a JSON answer under its own key" do
    data = JSON.parse(text(RailsAiContext::Tools::GetSchema.call(detail: "summary", format: "json")))

    expect(data["_report"]).to eq(line)
  end

  it "is left out when the app turns it off" do
    RailsAiContext.configuration.report_issue_line = false

    expect(text(RailsAiContext::Tools::GetSchema.call(detail: "summary"))).not_to include(line)
    expect(JSON.parse(text(RailsAiContext::Tools::GetSchema.call(detail: "summary", format: "json")))).not_to have_key("_report")
  end

  it "names where to file and says to ask the user first" do
    expect(line).to include("https://github.com/crisnahine/rails-ai-context/issues").and match(/ask the user/i)
  end
end
