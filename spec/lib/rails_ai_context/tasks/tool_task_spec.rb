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
    Rake::Task["ai:tool"].invoke(tool)
    [ $stdout.string, $stderr.string ]
  ensure
    ARGV.replace(previous[0])
    $stdout, $stderr = previous[1], previous[2]
    ENV["JSON"] = previous[3]
  end

  it "keeps what the app prints while it boots off a JSON=1 envelope" do
    stdout, stderr = run_task

    expect(JSON.parse(stdout)).to include("tool" => "rails_get_conventions", "error" => false)
    expect(stderr).to include("hello from an initializer")
  end

  # `pattern=params[:id]` holds a bracket, and the task dropped every
  # argument that did, answering "Pattern is required".
  it "passes a value holding a bracket, and skips only the task itself" do
    expect(RailsAiContext::CLI::ToolRunner).to receive(:new)
      .with("search_code", { pattern: "params[:id]", path: "app/models" }, json_mode: true).and_call_original

    run_task("pattern=params[:id]", "path=app/models", tool: "search_code")
  end
end
