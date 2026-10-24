# frozen_string_literal: true

require "rake"

# JSON=1 promises an envelope a script can parse. The task booted through the
# environment prerequisite, so whatever the app printed while it booted
# landed on stdout ahead of it.
RSpec.describe "ai:tool rake task" do
  let(:tasks_dir) { File.expand_path("../../../../lib/rails_ai_context/tasks", __dir__) }

  before do
    @previous_application = Rake.application
    Rake.application = Rake::Application.new
    Rake.application.rake_require("rails_ai_context", [ tasks_dir ], [])
    Rake::Task.define_task(:environment) { $stdout.puts "hello from an initializer" }
  end

  after { Rake.application = @previous_application }

  def run_task(*argv, tool: "conventions")
    previous = [ ARGV.dup, $stdout, $stderr, ENV["JSON"] ]
    ARGV.replace([ "ai:tool[#{tool}]", *argv ])
    ENV["JSON"] = "1"
    $stdout = StringIO.new
    $stderr = StringIO.new
    %w[ai:tool environment].each { |task| Rake::Task[task].reenable }
    status = begin
      Rake::Task["ai:tool"].invoke(tool)
      nil
    rescue SystemExit => e
      e.status
    end
    [ $stdout.string, $stderr.string, status ]
  ensure
    ARGV.replace(previous[0])
    $stdout, $stderr = previous[1], previous[2]
    ENV["JSON"] = previous[3]
  end

  it "keeps what the app prints while it boots off a JSON=1 envelope" do
    stdout, stderr = run_task

    expect(JSON.parse(stdout)).to include("tool" => "rails_get_config", "error" => false)
    expect(stderr).to include("hello from an initializer")
  end

  # `pattern=params[:id]` holds a bracket, and the task dropped every
  # argument that did, answering "Pattern is required".
  it "passes a value holding a bracket, and skips only the task itself" do
    expect(RailsAiContext::CLI::ToolRunner).to receive(:new)
      .with("search_code", { pattern: "params[:id]", path: "app/models" }, json_mode: true).and_call_original

    run_task("pattern=params[:id]", "path=app/models", tool: "search_code")
  end

  # Rake applies a trailing NAME=value word to ENV and leaves it in ARGV.
  it "leaves a trailing env var word such as JSON=1 or RAILS_ENV=test to rake, and boots in that environment" do
    previous_env = ENV["RAILS_ENV"]
    booted_in = nil
    Rake::Task[:environment].clear_actions
    Rake::Task.define_task(:environment) { booted_in = ENV["RAILS_ENV"] }
    Rake.application.collect_command_line_tasks([ "ai:tool[conventions]", "JSON=1", "RAILS_ENV=test" ])

    stdout, stderr, status = run_task("JSON=1", "RAILS_ENV=test")

    expect(status).to be_nil, stderr
    expect(JSON.parse(stdout)).to include("tool" => "rails_get_config", "error" => false)
    expect(booted_in).to eq("test")
  ensure
    ENV["RAILS_ENV"] = previous_env
  end

  it "answers an unknown param, an unknown tool and a failed boot with JSON=1 as one envelope, at exit 1" do
    [
      [ [ "limt=5", "pattern=User" ], "search_code", "rails_search_code", "did you mean 'limit='?" ],
      [ [], "shema", "shema", "Did you mean 'schema'?" ]
    ].each do |argv, tool, named, message|
      stdout, _, status = run_task(*argv, tool: tool)

      expect(status).to eq(1)
      expect(JSON.parse(stdout)).to include("tool" => named, "error" => true, "output" => a_string_including(message))
    end

    Rake::Task["environment"].clear_actions
    Rake::Task.define_task(:environment) { raise "the database is down" }
    stdout, stderr, status = run_task

    expect(status).to eq(1)
    expect(stderr).to include("the database is down")
    expect(JSON.parse(stdout)).to include("tool" => "conventions", "error" => true)
  end

  it "answers a boot that exits with JSON=1 as the envelope the binary gives" do
    Rake::Task["environment"].clear_actions
    Rake::Task.define_task(:environment) { exit 1 }
    stdout, _, status = run_task

    expect(status).to eq(1)
    expect(JSON.parse(stdout)).to eq("tool" => "conventions", "error" => true,
                                     "output" => "The tool did not run: rails-ai-context stopped before it could. stderr says why.")
  end

  it "still reads a lowercase tool param beside an all-caps env var word" do
    expect(RailsAiContext::CLI::ToolRunner).to receive(:new)
      .with("search_code", { pattern: "User" }, json_mode: true).and_call_original

    run_task("pattern=User", "JSON=1", tool: "search_code")
  end
end
