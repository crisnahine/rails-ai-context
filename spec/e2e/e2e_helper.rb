# frozen_string_literal: true

# E2E helper - does NOT load combustion. Each e2e spec spawns a real Rails
# application in a tmpdir. Tag specs with `type: :e2e` so the default
# `bundle exec rspec` run skips them (see spec/spec_helper.rb).

require "fileutils"
require "open3"
require "json"
require "net/http"
require "tmpdir"
require "timeout"
require "socket"

require_relative "support/test_app_builder"
require_relative "support/cli_runner"
require_relative "support/mcp_stdio_client"
require_relative "support/http_server_harness"
require_relative "support/shared_apps"

RSpec.configure do |config|
  config.expect_with :rspec do |expectations|
    expectations.include_chain_clauses_in_custom_matcher_descriptions = true
  end

  config.shared_context_metadata_behavior = :apply_to_host_groups
  config.filter_run_when_matching :focus
  config.disable_monkey_patching!
  config.order = :random

  # Test apps pull the gem in as a path source, and Bundler commands that
  # resolve it rewrite the gem's own Gemfile.lock with the app's resolution.
  # That lock is gitignored, so the damage outlives the run - the next
  # `bundle exec rspec` dies loading a database adapter. Put it back.
  config.before(:suite) do
    lockfile = File.join(E2E::GEM_ROOT, "Gemfile.lock")
    contents = File.exist?(lockfile) ? File.read(lockfile) : nil
    next unless contents

    # Bundler rewrites by replace, so the lock can also be missing here.
    # at_exit rather than after(:suite): it also fires on an interrupted
    # run, which is exactly when a half-written lock would otherwise survive.
    at_exit do
      File.write(lockfile, contents) unless File.exist?(lockfile) && File.read(lockfile) == contents
    end
  end
end

module E2E
  # Absolute path to the gem being tested - resolved dynamically so the
  # harness works regardless of where the repo is checked out.
  GEM_ROOT = File.expand_path("../..", __dir__)
  TMPDIR_PREFIX = "rails-ai-context-e2e-"

  # Single shared tmpdir across the e2e suite. Each describe block creates
  # its own subdirectory (per install path). Cleaned up via `at_exit` so
  # a partial run still leaves forensics available until the next run.
  def self.root
    @root ||= Dir.mktmpdir(TMPDIR_PREFIX).tap do |path|
      at_exit { FileUtils.remove_entry(path) if File.exist?(path) }
    end
  end
end
