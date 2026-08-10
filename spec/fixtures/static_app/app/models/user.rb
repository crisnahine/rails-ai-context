# frozen_string_literal: true

class User < ApplicationRecord
  has_many :posts, dependent: :destroy
  has_many :comments, dependent: :destroy

  validates :email, presence: true

  enum :role, { member: 0, admin: 1 }

  scope :active, -> { where(active: true) }
  scope :admins, -> { where(role: :admin) }
end
