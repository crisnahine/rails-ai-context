# frozen_string_literal: true

require "combustion"

Combustion.initialize! :active_record, :action_controller, :action_mailer do
  config.eager_load = false
end

require "rails_ai_context"

# A commit starts git's auto maintenance, which runs in the background from
# git 2.47 on and writes under .git while the spec that committed removes the
# repository (ENOENT on .git/objects/maintenance.lock). Every git the suite
# starts inherits this.
ENV["GIT_CONFIG_COUNT"] = "1"
ENV["GIT_CONFIG_KEY_0"] = "maintenance.auto"
ENV["GIT_CONFIG_VALUE_0"] = "false"

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

  # Same reason for the path caches: a spec that writes a pack or an in-repo
  # engine under Rails.root and removes it again would otherwise be decided by
  # whether an earlier example already resolved that root.
  config.before(:each) { RailsAiContext::PathResolver.clear_code_roots }
  # A spec that counts parses or walks needs a cold parse cache, whatever ran before it.
  config.before(:each) { RailsAiContext::AstCache.clear }
  # Building a server turns on the per-call file check for the whole process;
  # under this suite's test environment, which does not reload, it also
  # starts noting the code it loaded. Each example starts with none of it, so
  # a file one example writes cannot drop the caches, or put a stale-code
  # note, under the next.
  config.before(:each) do
    RailsAiContext::Tools::BaseTool::FILE_CHECK.merge!(snapshot: nil, running: nil, finished: nil, stale_code: nil)
    RailsAiContext::CodeReloader::LOADED_CODE[:mutex].synchronize { RailsAiContext::CodeReloader::LOADED_CODE[:files] = nil }
  end

  # On Windows the MCP configs start the server through `cmd /c`. The specs
  # that write and read configs expect the command line every other platform
  # writes, wherever they run; the Windows form has examples of its own
  # (mcp_config_generator_windows_spec.rb), which turn this back on.
  config.before(:each) { allow(RailsAiContext::McpConfigGenerator).to receive(:windows_shell?).and_return(false) }

  # CI's macOS and Windows legs set this, so an example left waiting on a
  # process the platform starts differently fails under its own name rather
  # than holding the whole run until the job's limit.
  if (limit = ENV["RSPEC_EXAMPLE_TIMEOUT"])
    require "timeout"
    config.around(:each) { |example| Timeout.timeout(Float(limit)) { example.run } }
  end

  # Skip e2e specs unless explicitly requested via E2E=1.
  # E2E specs spawn fresh Rails apps per install path and take minutes
  # per run; they belong on a dedicated CI pipeline, not every push.
  # Run them with: E2E=1 bundle exec rspec spec/e2e
  config.filter_run_excluding(type: :e2e) unless ENV["E2E"] == "1"
end
