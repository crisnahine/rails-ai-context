# frozen_string_literal: true

require "spec_helper"
require "tmpdir"
require "fileutils"

# A folder name is a path, not a glob: "work [old] {x}" holds the same app as "work".
RSpec.describe "a static app whose folder name has glob syntax" do
  let(:files) do
    {
      "config/environments/development.rb" => "Rails.application.configure do\n  config.action_mailer.deliver_later_queue_name = :mail\nend\n",
      "config/environments/production.rb" => "Rails.application.configure do\nend\n",
      "config/locales/fr.yml" => "fr:\n  hello: Bonjour\n",
      "config/credentials/production.yml.enc" => "x",
      "rakelib/extra.rake" => "desc \"Extra\"\ntask :extra do\nend\n",
      "db/seeds/users.rb" => "User.create!\n",
      "app/api/v1/things.rb" => "module V1\n  class Things\n  end\nend\n",
      "app/graphql/resolvers/post_resolver.rb" => "class PostResolver\nend\n",
      "test/models/post_test.rb" => "require \"test_helper\"\nclass PostTest < ActiveSupport::TestCase\n  test \"x\" do\n  end\nend\n",
      "test/test_helper.rb" => "require \"rails/test_help\"\n",
      "test/fixtures/posts.yml" => "one:\n  title: A\n",
      "test/mailers/previews/user_mailer_preview.rb" => "class UserMailerPreview < ActionMailer::Preview\nend\n",
      "log/development.log" => "Started GET \"/\"\n"
    }
  end

  let(:tools) do
    {
      RailsAiContext::Tools::GetModelDetails => {},
      RailsAiContext::Tools::GetJobPattern => {},
      RailsAiContext::Tools::GetHelperMethods => { detail: "full" },
      RailsAiContext::Tools::GetComponentCatalog => {},
      RailsAiContext::Tools::GetMailers => {},
      RailsAiContext::Tools::GetTestInfo => { detail: "full" },
      RailsAiContext::Tools::GetConfig => {},
      RailsAiContext::Tools::GetRoutes => {},
      RailsAiContext::Tools::GetView => {},
      RailsAiContext::Tools::Onboard => { detail: "full" }
    }
  end

  def answers(root)
    FileUtils.mkdir_p(File.dirname(root))
    FileUtils.cp_r(File.expand_path("../../fixtures/static_app", __dir__), root)
    files.each do |relative, content|
      FileUtils.mkdir_p(File.dirname(File.join(root, relative)))
      File.write(File.join(root, relative), content)
    end
    RailsAiContext.tier = :static
    RailsAiContext.configuration.app_root = root
    RailsAiContext::Tools::BaseTool.reset_all_caches!
    texts = tools.to_h { |tool, args| [ tool.tool_name, tool.call(**args).content.first[:text] ] }
    # The stamp says when the context was built, and two builds can straddle a second.
    texts["context"] = RailsAiContext::Tools::BaseTool.cached_context.except(:generated_at).inspect
    texts.transform_values { |text| text.gsub("'#{root}'", "ROOT").gsub(root, "ROOT") }
  end

  around do |example|
    Dir.mktmpdir do |dir|
      @dir = dir
      example.run
    ensure
      RailsAiContext.tier = nil
      RailsAiContext.configuration.app_root = nil
      RailsAiContext::Tools::BaseTool.reset_all_caches!
    end
  end

  it "gets the same answers as the app under a plain folder", :aggregate_failures do
    plain = answers(File.join(@dir, "work", "shop"))
    bracketed = answers(File.join(@dir, "work [old] {x}", "shop"))

    expect(plain["rails_get_model_details"]).to include("Invoice")
    plain.each { |tool, text| expect(bracketed[tool]).to eq(text), tool }
  end
end
