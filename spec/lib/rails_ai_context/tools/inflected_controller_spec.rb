# frozen_string_literal: true

require "spec_helper"
require "tmpdir"

# Every tool that answers a question about a controller by looking somewhere
# on disk has to turn its name back into a path. Underscoring the name is that
# derivation, and it is wrong for any controller the app names through an
# inflection: Mastodon declares ActivityPub::InboxesController, whose file,
# route and spec all sit under activitypub/, not activity_pub/.
#
# Each example asserts the tool finds the thing. The failure this pins is a
# confident negative - "no routes", "no test file found" - which is the answer
# an agent acts on without checking.
RSpec.describe "controllers named through an inflection" do
  let(:root) { @root }

  let(:context) do
    {
      controllers: {
        controllers: {
          "ActivityPub::InboxesController" => {
            file: "app/controllers/activitypub/inboxes_controller.rb",
            actions: [ "create" ]
          }
        }
      },
      routes: {
        by_controller: { "activitypub/inboxes" => [ { verb: "POST", path: "/inbox", action: "create", name: "inbox" } ] }
      },
      views: {
        templates: { "activitypub/inboxes/show.html.erb" => { lines: 3 } },
        partials: {}
      },
      tests: { framework: "rspec" }
    }
  end

  around do |example|
    Dir.mktmpdir do |dir|
      @root = dir
      FileUtils.mkdir_p(File.join(dir, "spec", "requests", "activitypub"))
      File.write(File.join(dir, "spec", "requests", "activitypub", "inboxes_spec.rb"), "it 'posts' do\nend\n")
      FileUtils.mkdir_p(File.join(dir, "app", "controllers", "activitypub"))
      FileUtils.mkdir_p(File.join(dir, "app", "views", "activitypub", "inboxes"))
      File.write(File.join(dir, "app", "views", "activitypub", "inboxes", "show.html.erb"), "<p>x</p>\n")
      example.run
    end
  end

  before do
    [ RailsAiContext::Tools::GetRoutes, RailsAiContext::Tools::GetView,
      RailsAiContext::Tools::GetTestInfo, RailsAiContext::Tools::GenerateTest,
      RailsAiContext::Tools::AnalyzeFeature ].each do |tool|
      tool.reset_cache! if tool.respond_to?(:reset_cache!)
      allow(tool).to receive(:cached_context).and_return(context)
    end
    allow(RailsAiContext).to receive(:default_app).and_return(RailsAiContext::StaticApp.new(root))
  end

  def text(result) = result.content.first[:text]

  it "finds the routes it has" do
    expect(text(RailsAiContext::Tools::GetRoutes.call(controller: "ActivityPub::InboxesController")))
      .to include("POST").and(satisfy { |t| !t.include?("No routes") })
  end

  it "finds the views it has" do
    expect(text(RailsAiContext::Tools::GetView.call(controller: "ActivityPub::InboxesController")))
      .to include("activitypub/inboxes/show.html.erb")
  end

  it "finds the spec file it has" do
    expect(text(RailsAiContext::Tools::GetTestInfo.call(controller: "ActivityPub::InboxesController")))
      .to include("spec/requests/activitypub/inboxes_spec.rb")
  end

  # A generated test that skips itself because it found no routes is worse
  # than no generated test: it reads as a covered case.
  it "generates a test against the routes it has" do
    body = text(RailsAiContext::Tools::GenerateTest.call(controller: "ActivityPub::InboxesController"))
    expect(body).to include("spec/requests/activitypub/inboxes_spec.rb")
    expect(body).not_to include("no routes found")
  end

  # The view directory is the route key, so camelizing it back gives a name
  # the app never declares and the undefined-ivar check silently stops running
  # for every view under it.
  it "still checks the views under an inflected directory" do
    RailsAiContext::Tools::ValidateSemantics.reset_cache!
    allow(RailsAiContext::Tools::ValidateSemantics).to receive(:cached_context)
      .and_return(context.merge(schema: { tables: {} }, models: {}))
    File.write(File.join(root, "app", "controllers", "activitypub", "inboxes_controller.rb"),
               "class ActivityPub::InboxesController < ApplicationController\n  def create\n    @inbox = 1\n  end\nend\n")
    view = "app/views/activitypub/inboxes/show.html.erb"
    File.write(File.join(root, view), "<%= @nope %>\n")

    warnings = RailsAiContext::Tools::ValidateSemantics.check_rails_semantics(view, File.join(root, view))

    expect(warnings.join).to include("@nope")
  end

  it "does not report a controller with a spec as untested" do
    expect(text(RailsAiContext::Tools::AnalyzeFeature.call(feature: "inbox")))
      .not_to include("no test file found")
  end
end
