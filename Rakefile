# frozen_string_literal: true

require "bundler/gem_tasks"
require "rspec/core/rake_task"

RSpec::Core::RakeTask.new(:spec)

# E2E harness - runs specs under spec/e2e/ with E2E=1 so they're not
# excluded by spec/spec_helper.rb. Each install-path spec spawns a
# fresh Rails app in a tmpdir and can take minutes.
#
# Usage:
#   bundle exec rake e2e              # full suite
#   bundle exec rake e2e:in_gemfile   # just Path A
#   bundle exec rake e2e:standalone   # just Path B
#   bundle exec rake e2e:zero_config  # just Path C
#   bundle exec rake e2e:mcp          # stdio + HTTP protocol specs
namespace :e2e do
  RSpec::Core::RakeTask.new(:in_gemfile) do |t|
    t.pattern = "spec/e2e/in_gemfile_install_spec.rb"
    ENV["E2E"] = "1"
  end

  RSpec::Core::RakeTask.new(:standalone) do |t|
    t.pattern = "spec/e2e/standalone_install_spec.rb"
    ENV["E2E"] = "1"
  end

  RSpec::Core::RakeTask.new(:zero_config) do |t|
    t.pattern = "spec/e2e/zero_config_install_spec.rb"
    ENV["E2E"] = "1"
  end

  RSpec::Core::RakeTask.new(:mcp) do |t|
    t.pattern = "spec/e2e/mcp_{stdio,http}_protocol_spec.rb"
    ENV["E2E"] = "1"
  end
end

desc "Run the full E2E harness (fresh Rails app per install path)"
RSpec::Core::RakeTask.new(:e2e) do |t|
  t.pattern = "spec/e2e/**/*_spec.rb"
  ENV["E2E"] = "1"
end

namespace :e2e do
  desc "Run e2e specs in parallel via parallel_tests (opt-in; uses all CPUs)"
  task :parallel do
    # Opt-in parallelization. Each parallel_tests worker is a separate
    # process - it will rebuild its own shared-fixture memoization and
    # its own built .gem artefact. Still a net win because rspec-level
    # wall-clock scales with the slowest worker, not the sum.
    #
    # Caveats:
    #   - postgres_install_spec is excluded here because its DB name is
    #     derived from E2E_DB_SUFFIX and workers would collide unless you
    #     pre-create per-worker databases. Run `rake e2e` separately if
    #     you need postgres coverage.
    #   - Shared BUNDLE_PATH is NOT used in parallel mode - two workers
    #     writing to the same bundle path can corrupt native extension
    #     builds. Each worker gets its own implicit bundle directory.
    require "shellwords"
    spec_files = Dir["spec/e2e/**/*_spec.rb"].reject { |p| p.include?("postgres_install_spec") }
    cmd = [
      "bundle", "exec", "parallel_rspec",
      "--serialize-stdout",
      "--"
    ] + spec_files
    env = { "E2E" => "1", "BUNDLE_PATH" => nil }
    sh(env, *cmd) { |ok, _res| abort("parallel_rspec failed") unless ok }
  end
end

task default: :spec
