module Api
  module V1
    class ArticlesController < BaseController
      def index
        articles = Article.published.recent.limit(20)
        render json: articles, only: %i[title slug published_at]
      end

      def show
        article = Article.published.find_by!(slug: params[:id])
        render json: article, only: %i[title slug body published_at]
      end
    end
  end
end
