class Article < ApplicationRecord
  include Publishable

  belongs_to :author, class_name: "User", inverse_of: :articles
  has_many :comments, dependent: :destroy

  enum :status, { draft: 0, in_review: 1, published: 2 }

  validates :title, presence: true, length: { maximum: 120 }
  validates :slug, presence: true, uniqueness: true
  validates :body, presence: true, if: :published?

  before_validation :assign_slug, on: :create
  after_commit :notify_author, on: :update, if: :saved_change_to_status?

  scope :recent, -> { order(published_at: :desc, created_at: :desc) }
  scope :by_author, ->(user) { where(author: user) }

  def to_param
    slug
  end

  private

  def assign_slug
    self.slug ||= title.to_s.parameterize
  end

  def notify_author
    ArticleMailer.published(self).deliver_later if published?
  end
end
