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
        FileUtils.mkdir_p(File.join(dir, "app/models"))
        File.write(File.join(dir, "app/models/post.rb"), "class Post < ApplicationRecord\nend\n")
        git("add", "-A")
        git("commit", "-q", "-m", "init")
        File.write(File.join(dir, "app/models/post.rb"), "class Post < ApplicationRecord\n  validates :title, presence: true\nend\n")
        example.run
      end
    end

    before do
      RailsAiContext::Tools::ReviewChanges.reset_cache!
      allow(RailsAiContext::Tools::ReviewChanges).to receive(:rails_app).and_return(double(root: Pathname.new(@dir)))
    end

    it "leaves out the model context without running rails_get_model_details" do
      skip("rails_get_model_details")
      expect(RailsAiContext::Tools::GetModelDetails).not_to receive(:call)

      answer = text(RailsAiContext::Tools::ReviewChanges.call(ref: "HEAD"))

      expect(answer).to include("app/models/post.rb")
      expect(answer).to include(left_out("rails_get_model_details"))
    end
  end
end
