module ApplicationHelper
  def page_title(title = nil)
    [ title, "Bulletin" ].compact.join(" · ")
  end
end
