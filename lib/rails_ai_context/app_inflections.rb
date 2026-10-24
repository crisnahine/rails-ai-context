# frozen_string_literal: true

module RailsAiContext
  # The static tier's inflector. Rails derives table names, route names and
  # constants through the app's inflections, which the static tier never
  # loaded, so a run against a StaticApp reads the literal rules in the app's
  # initializers and answers ActiveSupport::Inflector with them on its own
  # thread until it ends. A booted app's inflector already holds its rules.
  module AppInflections
    KEY = :rails_ai_context_app_inflections

    # Inflector.inflections without a block is the one door every inflection reads through.
    module Scoped
      def inflections(locale = :en)
        scoped = Thread.current[KEY] unless block_given?
        scoped && locale.to_s == "en" ? (scoped.last || super) : super
      end
    end
    ActiveSupport::Inflector.singleton_class.prepend(Scoped)

    module_function

    # With no app, the static tier's default one; a booted app keeps its own inflector.
    def around(app = (RailsAiContext.default_app if RailsAiContext.static_tier?))
      root = app.root.to_s if app.is_a?(StaticApp)
      outer = Thread.current[KEY]
      return yield if root.nil? || outer&.first == root

      begin
        Thread.current[KEY] = [ root, build(root) ]
        yield
      ensure
        Thread.current[KEY] = outer
      end
    end

    # nil when the app declares no rule this tier can read.
    # shortcut: reads config/initializers only, not config/application.rb or an in-repo engine's initializers; widen when an app keeps its rules there.
    def build(root)
      rules = PathResolver.initializer_paths(root).flat_map do |path|
        Introspectors::SourceIntrospector.walk(path, { rules: Introspectors::Listeners::InflectionsListener })[:rules]
      end.select { |rule| rule[:locale] == :en && rule[:literals] }
      return nil if rules.empty?

      stock = ActiveSupport::Inflector::Inflections.instance_or_fallback(:en)
      inflections = stock.dup
      # From 8.1 the dup shares the stock uncountables' word list, which uncountable grows and irregular shrinks.
      inflections.instance_variable_set(:@uncountables, stock.uncountables.class.new.add(stock.uncountables.to_a))
      rules.each do |rule|
        inflections.public_send(rule[:method], *rule[:literals])
      rescue StandardError => e
        RailsAiContext.debug_fail(e, nil, label: "AppInflections #{rule[:method]}")
      end
      inflections
    rescue StandardError => e
      RailsAiContext.debug_fail(e, nil, label: "AppInflections")
    end
  end
end
