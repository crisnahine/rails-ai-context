# frozen_string_literal: true

require "combustion"

Combustion.initialize! :active_record, :action_controller, :action_mailer do
  config.eager_load = false
end

require "rails_ai_context"

Dir[File.join(__dir__, "support", "**", "*.rb")].sort.each { |f| require f }

RSpec.configure do |config|
  config.expect_with :rspec do |expectations|
    expectations.include_chain_clauses_in_custom_matcher_descriptions = true
  end

  config.mock_with :rspec do |mocks|
    mocks.verify_partial_doubles = true
  end

  config.shared_context_metadata_behavior = :apply_to_host_groups
  config.filter_run_when_matching :focus
  config.example_status_persistence_file_path = "spec/examples.txt"
  config.disable_monkey_patching!
  config.order = :random
  Kernel.srand config.seed

  # Tools share one introspection cache with a TTL fast path that skips
  # fingerprint invalidation. A spec that stubs Rails.application.root fills
  # that cache from its fixture app, and the entry outlives the stub, so the
  # next example to call a tool reads another app's context. Clear between
  # examples so ordering cannot decide whether a spec passes. Runs before
  # rather than after: an example that sets a message expectation on
  # reset_cache! would otherwise count the teardown call as its own.
  config.before(:each) { RailsAiContext::Tools::BaseTool.reset_cache! }

  # Skip e2e specs unless explicitly requested via E2E=1.
  # E2E specs spawn fresh Rails apps per install path and take minutes
  # per run; they belong on a dedicated CI pipeline, not every push.
  # Run them with: E2E=1 bundle exec rspec spec/e2e
  config.filter_run_excluding(type: :e2e) unless ENV["E2E"] == "1"
end
