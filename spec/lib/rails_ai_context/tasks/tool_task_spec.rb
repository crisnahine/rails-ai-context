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

  def run_task(*argv)
    previous = [ ARGV.dup, $stdout, $stderr, ENV["JSON"] ]
    ARGV.replace([ "ai:tool[conventions]", *argv ])
    ENV["JSON"] = "1"
    $stdout = StringIO.new
    $stderr = StringIO.new
    Rake::Task["ai:tool"].invoke("conventions")
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
end
