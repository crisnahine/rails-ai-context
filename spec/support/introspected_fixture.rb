# frozen_string_literal: true

# One introspected context for the whole suite, built from the static
# fixture app instead of hand-typed hashes - a spec reading it cannot
# encode a payload shape production never produces, which is how the dead
# engines and turbo keys stayed green for months.
module IntrospectedFixture
  ROOT = File.expand_path("../fixtures/static_app", __dir__)

  def self.context
    @context ||= begin
      app = RailsAiContext::StaticApp.new(ROOT)
      RailsAiContext::Introspector::INTROSPECTOR_MAP.each_with_object({
        app_name: "StaticApp", rails_version: "8.0", ruby_version: RUBY_VERSION
      }) do |(key, klass), ctx|
        next unless klass.answers_statically?

        instance = klass.new(app)
        ctx[key] = if klass.static_tier == RailsAiContext::Introspectors::StaticTier::ALTERNATE_SOURCE
          instance.send(:static_call)
        else
          instance.call
        end
      rescue StandardError => e
        ctx[key] = { error: e.message }
      end.freeze
    end
  end
end
