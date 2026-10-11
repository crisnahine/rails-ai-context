# frozen_string_literal: true

require "rake"

# Rake runs a task from the directory its Rakefile is in: at an engine's root
# that is the engine's, while Rails.root is test/dummy. The report names its
# paths from there, as the binary names them from where it was typed.
RSpec.describe "ai:doctor rake task" do
  it "names the report's paths from the directory the task runs in" do
    doctor = instance_double(RailsAiContext::Doctor, run: { checks: [], score: 100 })
    expect(RailsAiContext::Doctor).to receive(:new).with(from: Dir.pwd).and_return(doctor)

    expect(invoke_rake_task("ai:doctor")).to include("AI Readiness Score: 100/100")
  end
end
