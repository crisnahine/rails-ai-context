require "rails_helper"

RSpec.describe Article, type: :model do
  describe "#publishable?" do
    it "is true for a reviewed article with a body by an active author" do
      article = build(:article, :in_review)

      expect(article).to be_publishable
    end

    it "is false while the article is still a draft" do
      expect(build(:article)).not_to be_publishable
    end

    it "is false when the author was deactivated" do
      article = build(:article, :in_review, author: build(:user, active: false))

      expect(article).not_to be_publishable
    end
  end

  describe "#publish!" do
    it "raises when the article is not publishable" do
      expect { create(:article).publish! }.to raise_error(ArgumentError, /not ready/)
    end
  end
end
