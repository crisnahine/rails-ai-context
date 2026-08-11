# frozen_string_literal: true

module RailsAiContext
  # Explicit rather than implicit, so reaching this constant does not depend
  # on Zeitwerk's `require` decoration surviving. See cli.rb.
  module Hydrators
  end
end
