# frozen_string_literal: true

module RailsAiContext
  module Tools
    # Brakeman's vendored ruby_parser runs `$DEBUG = true if ENV["DEBUG"]`
    # when it loads, and with $DEBUG on Ruby prints every exception raised
    # anywhere in the process, rescued or not: a `DEBUG=1` run, which this
    # gem's own error text tells users to try, printed some 440 lines of them.
    # Loading and running brakeman with DEBUG out of its sight, and putting
    # $DEBUG back after, leaves that switch the user's.
    module BrakemanGuard
      module_function

      def quietly
        hidden = ENV.delete("DEBUG")
        saved = $DEBUG
        yield
      ensure
        $DEBUG = saved
        ENV["DEBUG"] = hidden if hidden
      end
    end
  end
end
