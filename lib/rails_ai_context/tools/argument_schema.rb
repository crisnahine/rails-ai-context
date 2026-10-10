# frozen_string_literal: true

require "mcp"

module RailsAiContext
  module Tools
    # json_schemer, which mcp 1.x checks tool arguments with, words each error
    # through I18n when the process has I18n, after asking it once whether
    # json_schemer's own translations exist. Asking loads every locale file
    # the app has, so where one does not parse, the question raised on every
    # invalid argument (the answer is only kept when there is one) and the
    # client got an internal error, stderr a stack trace, instead of
    # "Invalid arguments: ...". When it raises, json_schemer is given the
    # answer an app without its translations gets, and the check runs again.
    class ArgumentSchema < MCP::Tool::InputSchema
      def validate_arguments(arguments)
        super
      rescue ValidationError
        raise
      rescue StandardError
        raise unless words_without_i18n!

        super
      end

      private

      # Once: a check that fails the same way again has another cause. The
      # answer is kept on the JSONSchemer module, where Result#i18n? reads it.
      def words_without_i18n!
        return false unless defined?(::JSONSchemer::Result) && ::JSONSchemer::Result.method_defined?(:i18n?)
        return false if ::JSONSchemer.class_variable_defined?(:@@i18n) && ::JSONSchemer.class_variable_get(:@@i18n) == false

        ::JSONSchemer.class_variable_set(:@@i18n, false)
        true
      end
    end
  end
end
