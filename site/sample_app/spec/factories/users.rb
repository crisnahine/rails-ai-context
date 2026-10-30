FactoryBot.define do
  factory :user do
    sequence(:email) { |n| "reader#{n}@example.com" }
    name { "Reader" }
    password { "correct horse battery staple" }
    role { :reader }

    trait :editor do
      role { :editor }
    end

    trait :admin do
      role { :admin }
    end
  end
end
