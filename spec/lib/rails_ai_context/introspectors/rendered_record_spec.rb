# frozen_string_literal: true

require "spec_helper"

RSpec.describe RailsAiContext::Introspectors::RenderedRecord do
  around do |example|
    Dir.mktmpdir("rendered-record") do |root|
      @root = root
      FileUtils.mkdir_p(File.join(root, "app/models"))
      File.write(File.join(root, "app/models/comment.rb"), <<~RUBY)
        class Comment < ApplicationRecord
          belongs_to :commentable, polymorphic: true
          belongs_to :author, class_name: "::Blog::User"
        end
      RUBY
      example.run
    end
  end

  it "follows a namespaced class_name to that model's default partial" do
    _, model = described_class.resolve("comment.author", @root)

    expect(model).to eq("blog/user")
    expect(described_class.partial_path(model, @root)).to eq("blog/users/user")
  end

  it "resolves nothing through a polymorphic association or an unknown call on one record" do
    expect(described_class.resolve("comment.commentable", @root)).to be_nil
    expect(described_class.resolve("comment.summary", @root)).to be_nil
    expect(described_class.resolve("comments.recent", @root)).to eq(%w[comments comment])
  end
end
