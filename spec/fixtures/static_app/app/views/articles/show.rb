# frozen_string_literal: true

class Views::Articles::Show < Views::Base
  include Phlex::Rails::Helpers::LinkTo
  include Phlex::Rails::Helpers::ContentFor
  include Phlex::Rails::Helpers::DOMID

  def initialize(article:, comments:)
    @article = article
    @comments = comments
  end

  def view_template
    content_for(:title, @article.title)

    div(class: "space-y-6 max-w-6xl mx-auto", data_controller: "infinite_scroll", id: dom_id(@article)) do
      render_article_header
      render_comments_section
    end
  end

  private

  def render_article_header
    header(class: "p-4 md:p-6") do
      render RubyUI::Heading.new(level: 1, class: "text-2xl font-bold") { @article.title }

      div(class: "flex items-center gap-4") do
        render(Components::Articles::ArticleUser.new(article: @article))
        render Components::Likes::Button.new(likeable: @article)
      end

      div(class: "mt-4", data_controller: "clipboard") do
        link_to @article.url, @article.url, target: "_blank"
        image_tag @article.image_url, alt: @article.title if @article.image_url.present?
      end
    end
  end

  def render_comments_section
    div(data: { controller: "reply_form" }) do
      render(Components::Comments::CommentHeader.new(comments: @comments))
      render(Components::Comments::CommentForm.new(article: @article, comment: Post.new))

      @comments.each do |comment|
        render(Components::Comments::Comment.new(
          comment: comment,
          article: @article,
          depth: 0,
          children: {}
        ))
      end
    end
  end
end
