module Admin
  class ArticlesController < BaseController
    before_action :set_article, only: %i[show publish]

    def index
      @articles = Article.in_review.recent.includes(:author)
    end

    def show
    end

    def publish
      if @article.publishable?
        PublishArticleJob.perform_later(@article)
        redirect_to admin_article_path(@article), notice: t(".queued", title: @article.title)
      else
        redirect_to admin_article_path(@article), alert: t(".not_ready", title: @article.title)
      end
    end

    private

    def set_article
      @article = Article.find(params[:id])
    end
  end
end
