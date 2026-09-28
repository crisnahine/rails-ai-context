# frozen_string_literal: true

module RailsAiContext
  module Introspectors
    # The app handle every introspector is built with, and the app root as a
    # string. Subclasses declare their own static tier; this class declares none.
    class Base
      attr_reader :app

      def initialize(app)
        @app = app
      end

      private

      def root
        app.root.to_s
      end
    end
  end
end
