namespace :articles do
  desc "Publish every reviewed article whose author is active"
  task publish_ready: :environment do
    Article.in_review.find_each do |article|
      PublishArticleJob.perform_later(article) if article.publishable?
    end
  end
end
