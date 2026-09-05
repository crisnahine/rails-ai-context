# frozen_string_literal: true

require "rake"

# Drives the shipped rakefile through a throwaway Rake::Application, so the
# task's exit status is asserted the way `bin/rails` sees it.
RSpec.describe "ai:preset rake task" do
  let(:tasks_dir) { File.expand_path("../../../../lib/rails_ai_context/tasks", __dir__) }

  before do
    @previous_application = Rake.application
    @previous_stdout = $stdout
    @previous_stderr = $stderr

    Rake.application = Rake::Application.new
    Rake.application.rake_require("rails_ai_context", [ tasks_dir ], [])
    Rake::Task.define_task(:environment)
  end

  after do
    Rake.application = @previous_application
    $stdout = @previous_stdout
    $stderr = @previous_stderr
  end

  def invoke(*args)
    out = StringIO.new
    err = StringIO.new
    status = 0
    begin
      $stdout = out
      $stderr = err
      Rake.application["ai:preset"].invoke(*args)
    rescue SystemExit => e
      status = e.status
    ensure
      $stdout = @previous_stdout
      $stderr = @previous_stderr
    end
    [ status, out.string, err.string ]
  end

  it "names the rejected preset on stderr, lists the valid ones, and exits 1" do
    status, out, err = invoke("bogus")

    expect(err).to include("Unknown preset: bogus")
    expect(err).to include("Available presets:")
    expect(status).to eq(1)
    expect(out).to be_empty
  end

  it "echoes the name the user typed, not the normalized one" do
    _status, _out, err = invoke("BOGUS")

    expect(err).to include("Unknown preset: BOGUS")
  end

  it "prints the listing on stdout and exits 0 with no name" do
    status, out, err = invoke

    expect(out).to include("Available presets:")
    expect(out).to include("rails 'ai:preset[architecture]'")
    expect(status).to eq(0)
    expect(err).to be_empty
  end

  it "runs a preset under the normalized key" do
    allow(RailsAiContext::Presets).to receive(:run).and_return(true)

    status, = invoke("Migration")

    expect(RailsAiContext::Presets).to have_received(:run).with("migration")
    expect(status).to eq(0)
  end

  it "exits 1 when the preset resolves but its run answers false" do
    allow(RailsAiContext::Presets).to receive(:run).and_return(false)

    status, = invoke("migration")

    expect(status).to eq(1)
  end
end
