# frozen_string_literal: true

require "spec_helper"
require "tmpdir"
require "open3"

# A tool skip_tools turned off is never run, also as a section of another
# tool's answer, and the answer says which sections it left out.
RSpec.describe "Composite tools in an app whose skip_tools turns tools off" do
  around do |example|
    saved = RailsAiContext.configuration.skip_tools
    example.run
  ensure
    RailsAiContext.configuration.skip_tools = saved
  end

  def skip(*names)
    RailsAiContext.configuration.skip_tools = names
  end

  def text(response)
    response.content.first[:text]
  end

  def left_out(*names)
    "_#{names.map { |n| "`#{n}`" }.join(', ')} #{names.size > 1 ? 'are' : 'is'} turned off in this app " \
      "(skip_tools lists #{names.size > 1 ? 'them' : 'it'}), so #{names.size > 1 ? 'their sections are' : 'its section is'} left out._"
  end

  it "rails_get_context leaves out the model section without running rails_get_model_details" do
    skip("rails_get_model_details")
    expect(RailsAiContext::Tools::GetModelDetails).not_to receive(:call)

    answer = text(RailsAiContext::Tools::GetContext.call(model: "Post"))

    expect(answer).to include(left_out("rails_get_model_details"))
    expect(answer.scan("turned off in this app").size).to eq(1)
    expect(answer).to include("posts")
    expect(answer).to start_with("## Table: posts")
  end

  it "rails_get_context opens with the first section it has, for a controller and for a feature too" do
    skip("rails_get_controllers", "rails_analyze_feature")

    expect(text(RailsAiContext::Tools::GetContext.call(controller: "PostsController"))).to start_with("# Routes")
    expect(text(RailsAiContext::Tools::GetContext.call(feature: "post"))).to start_with("## Table: posts")
  end

  it "rails_get_context answers with the line alone when every section is turned off" do
    skip("rails_get_controllers", "rails_get_routes", "rails_get_view")
    [ RailsAiContext::Tools::GetControllers, RailsAiContext::Tools::GetRoutes, RailsAiContext::Tools::GetView ].each do |tool|
      expect(tool).not_to receive(:call)
    end

    answer = text(RailsAiContext::Tools::GetContext.call(controller: "PostsController"))

    expect(answer.strip).to start_with(left_out("rails_get_controllers", "rails_get_routes", "rails_get_view"))
  end

  it "rails_diagnose leaves out the controller section without running rails_get_controllers" do
    skip("rails_get_controllers")
    expect(RailsAiContext::Tools::GetControllers).not_to receive(:call)

    answer = text(RailsAiContext::Tools::Diagnose.call(error: "ActiveRecord::RecordNotFound: Couldn't find Post", action: "posts#show"))

    expect(answer).to include(left_out("rails_get_controllers"))
    expect(answer).not_to include("## Controller Context")
  end

  describe "a built-in a custom tool replaced" do
    let(:custom) { double("MyApp::Tool", call: nil) }

    before { allow(RailsAiContext::Server).to receive(:resolve_custom_tools).and_return([ custom ]) }

    it "is left out as a composed section and as an include, and the custom tool is never run" do
      expect(custom).not_to receive(:call)

      allow(custom).to receive(:tool_name).and_return("rails_get_model_details")
      skip("rails_get_model_details")
      expect(text(RailsAiContext::Tools::GetContext.call(model: "Post"))).to include(left_out("rails_get_model_details"))

      allow(custom).to receive(:tool_name).and_return("rails_security_scan")
      skip("rails_security_scan")
      expect(text(RailsAiContext::Tools::GetContext.call(model: "Post", include: %w[security])))
        .to include(RailsAiContext::Server.skipped_tool_message("rails_security_scan"))
    end

    it "still gets the model's schema and tests from rails_get_context" do
      allow(custom).to receive(:tool_name).and_return("rails_get_model_details")
      skip("rails_get_model_details")

      answer = text(RailsAiContext::Tools::GetContext.call(model: "Post"))

      expect(answer).to start_with("## Table: posts")
      expect(answer).to include(left_out("rails_get_model_details"))
    end

    it "is pointed at by no answer, since the custom tool takes other arguments" do
      allow(custom).to receive(:tool_name).and_return("rails_get_schema")
      expect(RailsAiContext::Tools::BaseTool.pointer("rails_get_schema", 'table:"posts"')).to eq('`rails_get_schema(table:"posts")`')

      skip("rails_get_schema")
      expect(RailsAiContext::Server.served_tool("rails_get_schema")).not_to be_nil
      expect(RailsAiContext::Tools::BaseTool.pointer("rails_get_schema", 'table:"posts"')).to be_nil
    end
  end

  it "a composite another composite calls keeps its own left-out list" do
    base = RailsAiContext::Tools::BaseTool
    inner = Class.new(base) do
      tool_name "rails_nest_inner"
      define_singleton_method(:call) { |server_context: nil| text_response("inner#{response_text(compose(RailsAiContext::Tools::GetRoutes))}") }
    end
    outer = Class.new(base) do
      tool_name "rails_nest_outer"
      define_singleton_method(:call) do |server_context: nil|
        text_response("outer[#{response_text(compose(inner))}]#{response_text(compose(RailsAiContext::Tools::GetSchema))}")
      end
    end
    stub_const("RailsAiContext::Tools::NestInner", inner)
    skip("rails_get_routes", "rails_get_schema")

    expect(text(outer.call)).to eq("outer[inner\n\n#{left_out('rails_get_routes')}]\n\n#{left_out('rails_get_schema')}")
  ensure
    [ inner, outer ].each(&:abstract!)
  end

  describe "rails_review_changes" do
    def git(*args)
      out, status = Open3.capture2e("git", "-c", "user.name=t", "-c", "user.email=t@t.t", "-c", "commit.gpgsign=false",
                                    *args, chdir: @dir)
      raise out unless status.success?

      out
    end

    around do |example|
      Dir.mktmpdir do |dir|
        @dir = dir
        git("init", "-q")
        FileUtils.mkdir_p(File.join(dir, "app/controllers"))
        File.write(File.join(dir, "app/controllers/posts_controller.rb"), "class PostsController < ApplicationController\nend\n")
        git("add", "-A")
        git("commit", "-q", "-m", "init")
        File.write(File.join(dir, "app/controllers/posts_controller.rb"), "class PostsController < ApplicationController\n  def index; end\nend\n")
        example.run
      end
    end

    before do
      RailsAiContext::Tools::ReviewChanges.reset_cache!
      allow(RailsAiContext::Tools::ReviewChanges).to receive(:rails_app).and_return(double(root: Pathname.new(@dir)))
    end

    it "leaves out a controller's routes without running rails_get_routes" do
      skip("rails_get_routes")
      expect(RailsAiContext::Tools::GetRoutes).not_to receive(:call)

      answer = text(RailsAiContext::Tools::ReviewChanges.call(ref: "HEAD"))

      expect(answer).to include("app/controllers/posts_controller.rb")
      expect(answer).to include(left_out("rails_get_routes"))
    end
  end
end
