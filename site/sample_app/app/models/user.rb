class User < ApplicationRecord
  devise :database_authenticatable, :registerable, :recoverable, :rememberable, :validatable

  has_many :articles, foreign_key: :author_id, inverse_of: :author, dependent: :destroy
  has_many :comments, dependent: :destroy

  enum :role, { reader: 0, editor: 1, admin: 2 }

  validates :name, presence: true

  scope :active, -> { where(active: true) }
  scope :staff, -> { where(role: [ :editor, :admin ]) }

  def display_name
    name.presence || email.split("@").first
  end
end
