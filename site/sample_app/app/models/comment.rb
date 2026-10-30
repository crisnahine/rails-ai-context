class Comment < ApplicationRecord
  belongs_to :article, counter_cache: true
  belongs_to :user

  validates :body, presence: true, length: { maximum: 2000 }

  scope :newest_first, -> { order(created_at: :desc) }
end
