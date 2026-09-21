# frozen_string_literal: true

require "spec_helper"

RSpec.describe RailsAiContext::OutputGuard do
  it "redirects $stdout writes to $stderr during the block" do
    captured_out = StringIO.new
    captured_err = StringIO.new
    orig_out = $stdout
    orig_err = $stderr
    begin
      $stdout = captured_out
      $stderr = captured_err
      described_class.quarantine_stdout { puts "boot noise" }
    ensure
      $stdout = orig_out
      $stderr = orig_err
    end
    expect(captured_err.string).to include("boot noise")
    expect(captured_out.string).to be_empty
  end

  it "restores $stdout when the block raises" do
    original = $stdout
    expect {
      described_class.quarantine_stdout { raise ArgumentError, "boom" }
    }.to raise_error(ArgumentError, "boom")
    expect($stdout).to equal(original)
  end

  it "returns the block's value" do
    expect(described_class.quarantine_stdout { :value }).to eq(:value)
  end

  # Bundler re-execs the process from inside this block when the lockfile
  # names a different Bundler than the one running. `exec` keeps file
  # descriptors, so the new image started with fd 1 already pointing at
  # stderr, saved that as its "stdout", and the MCP transport wrote every
  # JSON-RPC response to stderr.
  it "restores the real stdout in a process that re-execs inside the block" do
    require "open3"

    Dir.mktmpdir do |dir|
      script = File.join(dir, "re_exec.rb")
      File.write(script, <<~RUBY)
        require #{File.expand_path("lib/rails_ai_context/output_guard.rb").inspect}

        if ENV["RAC_SECOND_IMAGE"]
          carried = ENV["RAILS_AI_CONTEXT_STDOUT_FD"].to_i
          RailsAiContext::OutputGuard.quarantine_stdout { $stdout.puts "boot noise" }
          $stdout.puts "jsonrpc response"
          $stdout.puts "pointer=\#{ENV['RAILS_AI_CONTEXT_STDOUT_FD'].inspect}"
          open = begin
            IO.new(carried, "w", autoclose: false).stat && true
          rescue StandardError
            false
          end
          $stdout.puts "carried_fd_open=\#{open}"
          $stdout.flush
        else
          RailsAiContext::OutputGuard.quarantine_stdout do
            ENV["RAC_SECOND_IMAGE"] = "1"
            exec(RbConfig.ruby, __FILE__)
          end
        end
      RUBY

      out, err, status = Open3.capture3(RbConfig.ruby, script)

      expect(status).to be_success
      expect(out).to include("jsonrpc response")
      expect(err).to include("boot noise")
      expect(err).not_to include("jsonrpc response")

      # The descriptor exists to survive one exec: left open with
      # close-on-exec cleared, every subprocess the app spawns afterwards
      # inherits a copy of the MCP channel.
      expect(out).to include("pointer=nil")
      expect(out).to include("carried_fd_open=false")
    end
  end
end
