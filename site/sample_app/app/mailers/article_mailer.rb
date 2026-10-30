class ArticleMailer < ApplicationMailer
  def published(article)
    @article = article
    mail to: article.author.email, subject: "\"#{article.title}\" is live"
  end
end
