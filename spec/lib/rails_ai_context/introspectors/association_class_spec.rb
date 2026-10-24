# frozen_string_literal: true

require "spec_helper"

# Expected classes follow ActiveRecord::Reflection#derive_class_name: a collection's name is singularized, any
# other name is kept, class_name wins, and a through association takes its source's class.
RSpec.describe RailsAiContext::Introspectors::AssociationClass do
  let(:models) do
    {
      "Post" => { associations: [
        { name: :comments, type: "has_many" },
        { name: :preferences, type: "belongs_to" },
        { name: :writer, type: "belongs_to", class_name: "Author" },
        { name: :taggings, type: "has_many" },
        { name: :tags, type: "has_many", through: :taggings },
        { name: :labels, type: "has_many", through: :taggings, source: :tag },
        { name: :subject, type: "belongs_to", polymorphic: true },
        { name: :owner, type: "belongs_to", class_name: "owner_class_name" },
        { name: :ghosts, type: "has_many", through: :missing },
        { name: :api_client, type: "belongs_to" },
        { name: :reviewer, type: "belongs_to" }
      ] },
      "Comment" => {}, "Preferences" => {}, "Author" => {}, "Tag" => {}, "APIClient" => {},
      "Tagging" => { associations: [ { name: :tag, type: "belongs_to" } ] }
    }
  end
  let(:by_name) { described_class.by_name(models["Post"][:associations]) }

  def class_of(name)
    described_class.resolve(by_name.fetch(name.to_s), models, by_name: by_name, owner: "Post")
  end

  it "singularizes only a collection's name, as Rails derives the class" do
    expect(class_of(:comments)).to eq("Comment")
    expect(class_of(:preferences)).to eq("Preferences")
  end

  it "takes a declared class_name over the name" do
    expect(class_of(:writer)).to eq("Author")
  end

  it "reads a through association's class off its source on the class the hop lands on" do
    expect(class_of(:tags)).to eq("Tag")
    expect(class_of(:labels)).to eq("Tag")
  end

  it "names no class for a polymorphic association, an expression class_name or a through that names no association" do
    expect(class_of(:subject)).to be_nil
    expect(class_of(:owner)).to be_nil
    expect(described_class.unresolved(by_name["owner"], by_name)).to eq(:unreadable)
    expect(class_of(:ghosts)).to be_nil
    expect(described_class.unresolved(by_name["ghosts"], by_name)).to eq(:through)
  end

  it "spells a derived class as the app declares it, and names a model only when the payload holds one" do
    expect(class_of(:api_client)).to eq("APIClient")
    expect(class_of(:reviewer)).to eq("Reviewer")
    expect(described_class.model(by_name["reviewer"], models, owner: "Post", by_name: by_name)).to be_nil
    expect(described_class.model(by_name["comments"], models, owner: "Post", by_name: by_name)).to eq("Comment")
  end
end
