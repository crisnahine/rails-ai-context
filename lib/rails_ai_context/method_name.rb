# frozen_string_literal: true

module RailsAiContext
  # Where a method name ends in source text, `ping` not `ping?`; no lookahead,
  # so each fragment is a ripgrep pattern too.
  module MethodName
    # Ruby's `\w` and `\s` are ASCII and ripgrep's Unicode, so every class stays
    # in ASCII; Ruby reads any other character as part of a name.
    SPACE = "[\\t\\n\\v\\f\\r ]"

    module_function

    # After `def name`: `def ping = 1` is an endless `ping`.
    def definition_end(name)
      name_end?(name) ? "(?:[\\x00-\\x7F&&[^\\w?!=]]|[!=][=~]|=>|$)" : ""
    end

    # After a call of `name`: `obj.ping = 1` calls `ping=`, while `ping == 1`,
    # `ping => x`, `ping ||= 1` and `ping arg` still read `ping`.
    def call_end(name)
      return "" unless name_end?(name)

      "(?:[\\x00-\\x7F&&[^\\w?!=\\s]]|[!=][=~]|=>|$|#{SPACE}+(?:[^=\\t\\n\\v\\f\\r ]|=[=~>]|$))"
    end

    def name_end?(name)
      name.to_s.match?(/(?:\w|[^\x00-\x7F])\z/)
    end
  end
end
