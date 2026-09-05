# frozen_string_literal: true

require "spec_helper"
require "rake"
require "tmpdir"

# `ai:inspect` and the generated context files describe the same app. A count
# qualified on one surface and bare on the other reads as two different
# numbers for the same question.
RSpec.describe "the ai:inspect route count" do
  let(:context) do
    {
      app_name: "Blog",
      rails_version: "8.1.0",
      ruby_version: "3.4.0",
      routes: {
        total_routes: 31,
        by_controller: {
          "posts" => [
            { verb: "GET", path: "/posts", action: "index" },
            { verb: "GET", path: "/posts/:id", action: "show" }
          ],
          "rails/conductor/inbound_emails" => [
            { verb: "GET", path: "/conductor", action: "index" }
          ]
        }
      }
    }
  end

  before { allow(RailsAiContext).to receive(:introspect).and_return(context) }

  it "qualifies the total the way the generated context files do" do
    expect(invoke_rake_task("ai:inspect"))
      .to include("Routes: 2 app routes across 1 controller (31 total incl. framework)")
  end

  # The summary line states both versions at once. Answering one with a
  # refusal and the other with the interpreter running the task reads as a
  # fact about the app it is not.
  context "when the app declares no Ruby version" do
    around do |example|
      RailsAiContext.tier = :static
      example.run
    ensure
      RailsAiContext.tier = :runtime
    end

    it "prints the refusal rather than the running interpreter" do
      Dir.mktmpdir do |dir|
        static_context = RailsAiContext::Introspector.new(RailsAiContext::StaticApp.new(dir)).call
        allow(RailsAiContext).to receive(:introspect).and_return(static_context)

        output = invoke_rake_inspect

        expect(output).to include("Ruby [UNAVAILABLE: app declares none]")
        expect(output).not_to include("Ruby #{RUBY_VERSION}")
      end
    end
  end
end
