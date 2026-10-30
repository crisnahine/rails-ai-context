FactoryBot.define do
  factory :article do
    association :author, factory: :user
    sequence(:title) { |n| "Article #{n}" }
    body { "Enough words to publish." }
    status { :draft }

    trait :in_review do
      status { :in_review }
    end

    trait :published do
      status { :published }
      published_at { 1.day.ago }
    end
  end
end
