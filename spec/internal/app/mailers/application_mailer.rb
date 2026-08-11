# frozen_string_literal: true

# Abstract base with no deliverable action. The callback makes ActiveSupport
# alias `_run_process_action_callbacks` onto this class, and the helpers are
# protected, so `instance_methods(false)` reports three actions where Rails
# dispatches on none.
class ApplicationMailer < ActionMailer::Base
  default from: "noreply@example.com"
  after_action :set_reply_headers!

  protected

  def locale_for_account(account)
    account
  end

  def set_reply_headers!
    headers["Auto-Submitted"] = "auto-generated"
  end
end
