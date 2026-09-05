# frozen_string_literal: true

require "spec_helper"
require "rake"

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
end
