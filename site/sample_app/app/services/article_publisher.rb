class ArticlePublisher
  def self.call(article)
    new(article).call
  end

  def initialize(article)
    @article = article
  end

  def call
    return false unless @article.publishable?

    @article.publish!
    ArticleMailer.published(@article).deliver_later
    true
  end
end
