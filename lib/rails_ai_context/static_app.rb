# frozen_string_literal: true

require "pathname"

module RailsAiContext
  # Stand-in for Rails.application when serving the static tier (app not
  # booted). Introspectors only need #root from the app object; any other
  # method call is a genuine runtime dependency and should surface as
  # NoMethodError so the per-section isolation reports it honestly.
  class StaticApp
    attr_reader :root

    def initialize(root_path)
      @root = Pathname.new(root_path.to_s)
    end
  end
end
