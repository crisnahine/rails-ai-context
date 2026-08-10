# frozen_string_literal: true

class ExampleJob < ActiveJob::Base
  queue_as :default

  def perform(user_id)
    # no-op for testing
  end
end
