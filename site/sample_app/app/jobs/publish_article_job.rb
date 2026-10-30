class PublishArticleJob < ApplicationJob
  queue_as :publishing

  retry_on ActiveRecord::RecordNotUnique, wait: 5.seconds, attempts: 3

  def perform(article)
    ArticlePublisher.call(article)
  end
end
