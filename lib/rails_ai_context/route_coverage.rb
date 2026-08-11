# frozen_string_literal: true

module RailsAiContext
  # One answer to "how much of the routing table is this number", for every
  # surface that prints a route count.
  #
  # `RouteIntrospector` records the constructs it refused to fabricate -
  # `devise_for`, a `draw` whose target is computed or too large to parse - in
  # `:dynamic_routes`, and nothing read it. So `rails_get_routes`, `CLAUDE.md`,
  # the Cursor and Copilot rule files, `rails_onboard` and the rake summary all
  # quoted 94 routes on a 723-route app with nothing saying the count was
  # partial. Nine call sites each having to remember is what produced that;
  # this is the seam they share.
  module RouteCoverage
    module_function

    # A suffix rather than a predicate, so no call site needs a conditional of
    # its own - that shape is what let nine of them forget.
    #
    # @param routes [Hash] the :routes section of an introspection context
    # @return [String] a leading-comma clause naming what the count leaves out,
    #   or "" when the count is the whole table
    def suffix(routes)
      return "" unless routes.is_a?(Hash) && !routes[:error]

      unexpanded = routes[:dynamic_routes].to_i
      return "" unless unexpanded.positive?

      ", #{CountPhrase.call(unexpanded, "dynamic construct")} not expanded"
    end
  end
end
