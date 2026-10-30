module Publishable
  extend ActiveSupport::Concern

  included do
    scope :published, -> { where(status: :published).where.not(published_at: nil) }
  end

  def publishable?
    in_review? && body.present? && author.active?
  end

  def publish!
    raise ArgumentError, "#{self.class.name} #{id} is not ready to publish" unless publishable?

    update!(status: :published, published_at: Time.current)
  end
end
