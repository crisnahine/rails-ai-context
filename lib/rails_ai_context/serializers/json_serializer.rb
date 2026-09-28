# frozen_string_literal: true

require "json"

module RailsAiContext
  module Serializers
    class JsonSerializer < Base
      def call
        JSON.pretty_generate(context)
      end
    end
  end
end
