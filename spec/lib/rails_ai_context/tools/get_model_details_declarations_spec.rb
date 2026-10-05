# frozen_string_literal: true

require "spec_helper"
require "tmpdir"
require "fileutils"

# What a model's own declarations say, read off the source the way both tiers
# read it, then printed by the tool.
RSpec.describe RailsAiContext::Tools::GetModelDetails do
  before { described_class.reset_cache! }

  def details_for(model, files)
    Dir.mktmpdir do |dir|
      files.each do |name, source|
        path = File.join(dir, "app", "models", name)
        FileUtils.mkdir_p(File.dirname(path))
        File.write(path, source)
      end
      models = RailsAiContext::Introspectors::ModelIntrospector.new(RailsAiContext::StaticApp.new(dir)).static_call
      allow(described_class).to receive(:cached_context).and_return({ models: models })
      described_class.call(model: model).content.first[:text]
    end
  end

  it "prints attribute, alias_attribute and has_rich_text declarations" do
    text = details_for("User", "user.rb" => <<~RUBY)
      class User < ApplicationRecord
        attribute :nickname, :string, default: "anon"
        attribute :score, :integer
        alias_attribute :login, :email
        has_one_attached :avatar
        has_rich_text :bio
      end
    RUBY

    expect(text).to include("- `attribute` :nickname (string, default: \"anon\"), :score (integer)")
    expect(text).to include("- `alias_attribute` :login → :email")
    expect(text).to include("- `has_rich_text` :bio")
  end
end
