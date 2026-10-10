# frozen_string_literal: true

require "rake"

# Both serve tasks boot through the guard rather than the environment
# prerequisite, so app boot output stays off the JSON-RPC stream.
RSpec.describe "ai:serve rake tasks" do
  let(:tasks_dir) { File.expand_path("../../../../lib/rails_ai_context/tasks", __dir__) }

  before do
    @previous_application = Rake.application
    Rake.application = Rake::Application.new
    Rake.application.rake_require("rails_ai_context", [ tasks_dir ], [])
    Rake::Task.define_task(:environment)
  end

  after do
    Rake.application = @previous_application
    RailsAiContext::BootManager.default_timeout = nil
  end

  around do |example|
    original = ENV.delete("RAILS_AI_CONTEXT_BOOT_TIMEOUT")
    example.run
  ensure
    ENV["RAILS_AI_CONTEXT_BOOT_TIMEOUT"] = original if original
  end

  # A stdio client gives up on `initialize` after about 30 seconds, so the
  # stdio task's boot gets less than that; an HTTP client is not waiting.
  { "ai:serve" => [ :stdio, 20 ], "ai:serve_http" => [ :http, 60 ] }.each do |task_name, (transport, timeout)|
    it "guards the boot for #{timeout}s and starts the #{transport} transport" do
      expect(RailsAiContext::BootManager).to receive(:guard)
        .with(timeout: timeout)
        .and_return(RailsAiContext::BootManager::Result.new(status: :booted))
      expect(RailsAiContext).to receive(:start_mcp_server).with(transport: transport)

      Rake::Task[task_name].invoke
    end
  end

  it "aborts when the boot fails, without starting a server" do
    allow(RailsAiContext::BootManager).to receive(:guard)
      .and_return(RailsAiContext::BootManager::Result.new(status: :failed, error: RuntimeError.new("boom")))
    expect(RailsAiContext).not_to receive(:start_mcp_server)

    expect { Rake::Task["ai:serve"].invoke }.to raise_error(SystemExit).and output(/boom/).to_stderr
  end
end
