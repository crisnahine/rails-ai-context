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

    # A framework-engine controller per the excluded_route_prefixes config -
    # the boundary between "the app's routes" and what Rails mounts on its own.
    def framework_controller?(name)
      RailsAiContext.configuration.excluded_route_prefixes.any? { |p| name.downcase.start_with?(p) }
    end

    # {controller => deduped routes} for the app's own controllers. One
    # population for every surface that prints a route count, PUT/PATCH update
    # pairs merged, so every generated file and tool quotes one number.
    def app_controllers(routes)
      by_controller(routes)
        .reject { |name, _| framework_controller?(name) }
        .transform_values { |entries| Tools::BaseTool.dedupe_put_patch_routes(Array(entries)) }
    end

    def app_route_count(routes)
      app_controllers(routes).values.sum(&:size)
    end

    def framework_route_count(routes)
      by_controller(routes)
        .select { |name, _| framework_controller?(name) }
        .sum { |_, entries| Tools::BaseTool.dedupe_put_patch_routes(Array(entries)).size }
    end

    def by_controller(routes)
      routes.is_a?(Hash) ? routes[:by_controller] || {} : {}
    end

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
