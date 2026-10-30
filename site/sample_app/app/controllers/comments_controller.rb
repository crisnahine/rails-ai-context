class CommentsController < ApplicationController
  before_action :set_article

  def create
    @comment = @article.comments.build(comment_params.merge(user: current_user))
    if @comment.save
      respond_to do |format|
        format.html { redirect_to @article }
        format.turbo_stream
      end
    else
      @comments = @article.comments.newest_first
      render "articles/show", status: :unprocessable_entity
    end
  end

  private

  def set_article
    @article = Article.find_by!(slug: params[:article_id])
  end

  def comment_params
    params.require(:comment).permit(:body)
  end
end
