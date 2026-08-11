# frozen_string_literal: true

module RailsAiContext
  module Introspectors
    # Explicit rather than implicit, so reaching this constant does not depend
    # on Zeitwerk's `require` decoration surviving. See cli.rb.
    module Listeners
    end
  end
end
