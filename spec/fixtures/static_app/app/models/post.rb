# frozen_string_literal: true

class Post < ApplicationRecord
  belongs_to :user
  has_many :comments, dependent: :destroy

  validates :title, presence: true

  scope :published, -> { where(published: true) }
  scope :recent, -> { order(created_at: :desc) }
end
