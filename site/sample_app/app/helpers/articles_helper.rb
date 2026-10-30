module ArticlesHelper
  def status_badge(article)
    tag.span(article.status.humanize, class: "badge badge-#{article.status}")
  end

  def published_on(article)
    return "Unpublished" if article.published_at.nil?

    l(article.published_at.to_date, format: :long)
  end
end
