# frozen_string_literal: true

# Concrete mailer whose only deliverable action is `digest` - the protected
# helper beside it is not one.
class NotificationMailer < ApplicationMailer
  def digest(user_id)
    mail(to: "test@example.com", subject: "Digest")
  end

  protected

  def unsubscribe_url_for(user_id)
    "https://example.com/unsubscribe/#{user_id}"
  end
end
