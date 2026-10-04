# frozen_string_literal: true

module RailsAiContext
  # Where a method name ends in source text, `ping` not `ping?`; no lookahead,
  # so each fragment is a ripgrep pattern too.
  module MethodName
    module_function

    # After `def name`: `def ping = 1` is an endless `ping`.
    def definition_end(name)
      name.to_s.match?(/\w\z/) ? "(?:[^\\w?!=]|[!=][=~]|=>|$)" : ""
    end

    # After a call of `name`: `obj.ping = 1` calls `ping=`, while `ping == 1`,
    # `ping => x`, `ping ||= 1` and `ping arg` still read `ping`.
    def call_end(name)
      name.to_s.match?(/\w\z/) ? "(?:[^\\w?!=\\s]|[!=][=~]|=>|$|\\s+(?:[^=\\s]|=[=~>]|$))" : ""
    end
  end
end
