# frozen_string_literal: true

class UserMailer < ActionMailer::Base
  def welcome(user_id)
    mail(to: "test@example.com", subject: "Welcome")
  end
end
