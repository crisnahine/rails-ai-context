# frozen_string_literal: true

module ApplicationHelper
  def page_title(title)
    content_tag(:h1, title)
  end
end
