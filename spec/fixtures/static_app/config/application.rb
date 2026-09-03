# frozen_string_literal: true

require_relative "boot"
require "rails/all"

module StaticApp
  class Application < Rails::Application
    config.load_defaults 7.2
  end
end
