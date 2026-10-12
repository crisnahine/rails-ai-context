# frozen_string_literal: true

require "spec_helper"

# skip_tools takes a tool out of tools/list, so no answer may send the reader to it.
RSpec.describe "Answers in an app whose skip_tools turns tools off" do
  SKIPPED = %w[rails_search_code rails_get_schema rails_get_model_details rails_get_routes rails_read_logs rails_get_view].freeze

  around do |example|
    saved = RailsAiContext.configuration.skip_tools
    RailsAiContext.configuration.skip_tools = SKIPPED
    example.run
  ensure
    RailsAiContext.configuration.skip_tools = saved
  end

  def text(response)
    response.content.first[:text]
  end

  def calls_to_skipped(answer)
    answer.scan(/\b(rails_\w+)\(/).flatten & SKIPPED
  end

  it "numbers diagnose's fix steps without the ones pointing at a skipped tool" do
    answer = text(RailsAiContext::Tools::Diagnose.call(error: "NameError: uninitialized constant Widget"))

    expect(calls_to_skipped(answer)).to be_empty
    expect(answer).to include("1. Check for typo in class/module name, missing require, or autoload issue\n" \
                              "2. Verify the file is in the correct autoload path (e.g. app/models, app/services)\n\n")
  end

  it "leaves out the recovery hint and the next steps naming a skipped tool" do
    expect(calls_to_skipped(text(RailsAiContext::Tools::GenerateTest.call(model: "NoSuchModel")))).to be_empty
    expect(calls_to_skipped(text(RailsAiContext::Tools::GetCallbacks.call(model: "Post")))).to be_empty
    expect(calls_to_skipped(text(RailsAiContext::Tools::GetControllers.call(controller: "PostsController")))).to be_empty
  end

  it "keeps the pointers to tools still served" do
    RailsAiContext.configuration.skip_tools = []

    expect(text(RailsAiContext::Tools::Diagnose.call(error: "NameError: uninitialized constant Widget")))
      .to include("3. Run `rails_search_code(pattern:\"ClassName\", match_type:\"trace\")` to find where the constant is defined")
  end
end
