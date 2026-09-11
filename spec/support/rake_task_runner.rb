# frozen_string_literal: true

# Drives the shipped rakefile the way `bin/rails ai:<task>` does, for the
# specs that read what a task prints.
module RakeTaskRunner
  def repo_root
    File.expand_path("../..", __dir__)
  end

  # A fresh application per call, so a second invoke is not the no-op an
  # already-invoked task returns.
  def invoke_rake_task(name, *args)
    previous_application = Rake.application
    previous_stdout = $stdout
    Rake.application = Rake::Application.new
    Rake.application.rake_require(
      "rails_ai_context", [ File.join(repo_root, "lib", "rails_ai_context", "tasks") ], []
    )
    Rake::Task.define_task(:environment)
    $stdout = StringIO.new
    Rake.application[name].invoke(*args)
    $stdout.string
  ensure
    $stdout = previous_stdout
    Rake.application = previous_application
  end
end

RSpec.configure { |config| config.include RakeTaskRunner }
