FactoryBot.define do
  factory :comment do
    article
    user
    body { "Well put." }
  end
end
