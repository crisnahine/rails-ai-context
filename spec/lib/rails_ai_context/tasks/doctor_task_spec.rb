# frozen_string_literal: true

require "rake"

# Rake runs a task from the directory its Rakefile is in: at an engine's root
# that is the engine's, while Rails.root is test/dummy. The report names its
# paths from there, as the binary names them from where it was typed.
RSpec.describe "ai:doctor rake task" do
  let(:doctor) { instance_double(RailsAiContext::Doctor, run: { checks: [], score: 100 }) }

  it "names the report's paths from the directory the task runs in" do
    expect(RailsAiContext::Doctor).to receive(:new).with(from: Dir.pwd).and_return(doctor)

    expect(invoke_rake_task("ai:doctor")).to include("AI Readiness Score: 100/100")
  end

  # Typed in app/models, Rails' `rails` command and rake each moved up to
  # the app's root before the task ran, and every command a fix gave was
  # one for the root: `bin/rails` is no file in app/models. The shell's PWD
  # still names the folder; one outside the task's directory is not where
  # this was typed.
  it "writes the fixes for the folder below it that the shell's PWD names" do
    Dir.mktmpdir do |dir|
      root = File.realpath(dir)
      models = File.join(root, "app/models")
      FileUtils.mkdir_p(models)

      Dir.chdir(root) do
        { models => models, File.dirname(root) => root, "" => root }.each do |pwd, from|
          stub_const("ENV", ENV.to_h.merge("PWD" => pwd))
          expect(RailsAiContext::Doctor).to receive(:new).with(from: from).and_return(doctor)

          invoke_rake_task("ai:doctor")
        end
      end
    end
  end
end
