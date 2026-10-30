# frozen_string_literal: true

require_relative "boot"
require "rails/all"

module Bulletin
  class Application < Rails::Application
    config.load_defaults 7.2
    config.active_job.queue_adapter = :sidekiq
    config.time_zone = "UTC"
  end
end
