# frozen_string_literal: true

require "rake"

# The rake entry relays a boot failure too, so it has to carry the same hint
# the CLI does when an initializer calls configure without the gem bundled.
RSpec.describe "rake boot failure reporting" do
  let(:tasks_dir) { File.expand_path("../../../../lib/rails_ai_context/tasks", __dir__) }

  before do
    @previous_application = Rake.application
    Rake.application = Rake::Application.new
    Rake.application.rake_require("rails_ai_context", [ tasks_dir ], [])
    Rake::Task.define_task(:environment)
  end

  after { Rake.application = @previous_application }

  def abort_output(result)
    err = StringIO.new
    previous = $stderr
    begin
      $stderr = err
      abort_boot_failure(result, 60)
    rescue SystemExit
      nil
    ensure
      $stderr = previous
    end
    err.string
  end

  it "names the cause and the two ways out when configure ran without the gem" do
    result = RailsAiContext::BootManager::Result.new(
      status: :failed,
      error: NoMethodError.new("undefined method 'configure' for module RailsAiContext")
    )

    output = abort_output(result)

    expect(output).to include("does not bundle the gem")
    expect(output).to include("bundle add rails-ai-context --group development")
    expect(output).to include(".rails-ai-context.yml")
  end

  it "says nothing about configure for an unrelated boot failure" do
    result = RailsAiContext::BootManager::Result.new(status: :failed, error: RuntimeError.new("boom"))

    output = abort_output(result)

    expect(output).to include("boom")
    expect(output).not_to include("does not bundle the gem")
  end
end
