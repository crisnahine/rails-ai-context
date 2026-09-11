# frozen_string_literal: true

require "spec_helper"
require "rake"

# docs/CLI.md states one rule for both surfaces: a usage error exits 1. The
# rake task answered 3 for a bad argument and 2 for anything else, so a
# wrapper keying on the status got two answers to one typo.
RSpec.describe "the exit status a usage error produces" do
  def status_of
    yield
    0
  rescue SystemExit => e
    e.status
  end

  def with_argv(*words)
    previous = ARGV.dup
    ARGV.replace(words)
    previous_stderr = $stderr
    $stderr = StringIO.new
    yield
  ensure
    ARGV.replace(previous)
    $stderr = previous_stderr
  end

  it "is 1 from the rake task, for a parameter the tool does not take" do
    status = status_of do
      with_argv("ai:tool[schema]", "bogus=1") { invoke_rake_task("ai:tool", "schema") }
    end

    expect(status).to eq(1)
  end

  it "is 1 from the rake task, for a tool that is not there" do
    status = status_of do
      with_argv("ai:tool[no_such_tool]") { invoke_rake_task("ai:tool", "no_such_tool") }
    end

    expect(status).to eq(1)
  end

  # The binary raises out of the runner and its own rescue answers 1; the
  # cli_smoke suite drives that end to end. Here it is the raise the rake
  # rescue keys on.
  it "raises the argument error the two rescues share" do
    runner = RailsAiContext::CLI::ToolRunner.new("schema", { bogus: "1" })

    expect { runner.run }.to raise_error(RailsAiContext::CLI::ToolRunner::InvalidArgumentError, /bogus/)
  end
end
