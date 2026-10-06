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

  it "reads a receiver that is no model by the records the next name holds" do
    expect(described_class.resolve("current_user.comments.recent", @root)).to eq(%w[comments comment])
    expect(described_class.resolve("current_account.widgets", @root)).to be_nil
  end

  it "credits nothing for a through association that names its source" do
    File.write(File.join(@root, "app/models/user.rb"),
               "class User < ApplicationRecord\n  has_many :posts\n  has_many :feedback, through: :posts, source: :comments\nend\n")

    expect(described_class.resolve("user.feedback", @root)).to be_nil
    expect(described_class.resolve("user.posts", @root)).to eq(%w[posts post])
  end

  it "resolves nothing through a polymorphic association or an unknown call on one record" do
    expect(described_class.resolve("comment.commentable", @root)).to be_nil
    expect(described_class.resolve("comment.summary", @root)).to be_nil
    expect(described_class.resolve("comments.recent", @root)).to eq(%w[comments comment])
  end
end
