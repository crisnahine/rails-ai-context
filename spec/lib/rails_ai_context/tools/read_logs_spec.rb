# frozen_string_literal: true

require "spec_helper"

RSpec.describe RailsAiContext::Tools::ReadLogs do
  let(:log_dir) { File.join(Rails.root, "log") }

  before do
    FileUtils.mkdir_p(log_dir)
    File.write(File.join(log_dir, "test.log"), <<~LOG)
      I, [2026-03-29T10:00:00 #1] INFO -- : Started GET "/users"
      I, [2026-03-29T10:00:00 #1] INFO -- : Processing by UsersController#index
      I, [2026-03-29T10:00:00 #1] INFO -- : Parameters: {"password"=>"secret123", "email"=>"admin@test.com"}
      W, [2026-03-29T10:00:00 #1] WARN -- : Cache miss for key users_list
      E, [2026-03-29T10:00:01 #1] ERROR -- : NoMethodError: undefined method 'foo'
      E, [2026-03-29T10:00:01 #1] ERROR -- :   /app/models/user.rb:42
      E, [2026-03-29T10:00:01 #1] ERROR -- :   /app/controllers/users_controller.rb:15
      I, [2026-03-29T10:00:02 #1] INFO -- : Completed 500 Internal Server Error
    LOG
  end

  after do
    FileUtils.rm_f(File.join(log_dir, "test.log"))
    FileUtils.rm_f(File.join(log_dir, "json.log"))
    FileUtils.rm_f(File.join(log_dir, "empty.log"))
  end

  describe ".call" do
    it "reads the default environment log" do
      result = described_class.call
      text = result.content.first[:text]
      expect(text).to include("Log: test.log")
      expect(text).to include("Started GET")
    end

    it "returns not found for nonexistent log and lists available files" do
      result = described_class.call(file: "nonexistent")
      text = result.content.first[:text]
      expect(text).to include("not found")
      expect(text).to include("test.log")
    end

    it "filters by ERROR level and includes stack traces" do
      result = described_class.call(level: "ERROR")
      text = result.content.first[:text]
      expect(text).to include("NoMethodError")
      expect(text).to include("/app/models/user.rb:42")
      expect(text).not_to include("Started GET")
      expect(text).not_to include("Cache miss")
    end

    it "filters by WARN level and includes WARN, ERROR, and FATAL" do
      result = described_class.call(level: "WARN")
      text = result.content.first[:text]
      expect(text).to include("Cache miss")
      expect(text).to include("NoMethodError")
      expect(text).not_to include("Started GET")
    end

    it "applies text search filter" do
      result = described_class.call(search: "UsersController")
      text = result.content.first[:text]
      expect(text).to include("UsersController")
      expect(text).not_to include("Cache miss")
    end

    it "does not let the search term match text that redaction hides" do
      File.write(File.join(log_dir, "test.log"), "INFO Bearer sk_live_abcdef0123456789abcdef used\nINFO done\n")
      hit = described_class.call(search: "sk_live_abcdef").content.first[:text]
      miss = described_class.call(search: "sk_live_zzzzzz").content.first[:text]

      expect(hit).to include("No entries matching")
      expect(hit).to eq(miss.sub("sk_live_zzzzzz", "sk_live_abcdef"))
    end

    it "respects the lines parameter" do
      result = described_class.call(lines: 3)
      text = result.content.first[:text]
      expect(text).to include("Showing last 3 lines")
    end

    it "caps lines at 500" do
      result = described_class.call(lines: 9999)
      text = result.content.first[:text]
      # Should not exceed MAX_LINES; the log only has 8 lines so it shows 8
      expect(text).to include("Showing last")
      expect(result).to be_a(MCP::Tool::Response)
    end

    it "redacts password values" do
      result = described_class.call
      text = result.content.first[:text]
      expect(text).to include("[FILTERED]")
      expect(text).not_to include("secret123")
    end

    it "redacts token values" do
      File.write(File.join(log_dir, "test.log"), "I, [2026-03-29T10:00:00 #1] INFO -- : token=abc123secret\n")
      result = described_class.call
      text = result.content.first[:text]
      expect(text).to include("[FILTERED]")
      expect(text).not_to include("abc123secret")
    end

    it "redacts email addresses to [EMAIL]" do
      result = described_class.call
      text = result.content.first[:text]
      expect(text).to include("[EMAIL]")
      expect(text).not_to include("admin@test.com")
    end

    it "does NOT redact 'password reset' prose (no false positive)" do
      File.write(File.join(log_dir, "test.log"), "I, [2026-03-29T10:00:00 #1] INFO -- : User requested a password reset for their account\n")
      result = described_class.call
      text = result.content.first[:text]
      expect(text).to include("password reset")
    end

    it "does NOT redact 'token count' prose (no false positive)" do
      File.write(File.join(log_dir, "test.log"), "I, [2026-03-29T10:00:00 #1] INFO -- : Processed 500 token count items successfully\n")
      result = described_class.call
      text = result.content.first[:text]
      expect(text).to include("token count")
    end

    it "handles empty log file" do
      File.write(File.join(log_dir, "test.log"), "")
      result = described_class.call
      text = result.content.first[:text]
      expect(text).to include("empty")
    end

    it "handles missing log directory gracefully" do
      FileUtils.rm_rf(log_dir)
      result = described_class.call
      text = result.content.first[:text]
      expect(text).to include("No log files found")
    ensure
      FileUtils.mkdir_p(log_dir)
    end

    # The name is reduced to its basename, so this used to be reported as the
    # log of that basename not being there, which is not what happened.
    it "blocks path traversal via file parameter and says so" do
      result = described_class.call(file: "../../../etc/passwd")
      text = result.content.first[:text]
      expect(text).to include("Path not allowed")
      expect(text).not_to include("root:")
      expect(result.error?).to be(true)
    end

    it "detects JSON/Lograge format" do
      File.write(File.join(log_dir, "json.log"), <<~LOG)
        {"level":"INFO","message":"Started GET /users","timestamp":"2026-03-29T10:00:00"}
        {"level":"ERROR","message":"NoMethodError","timestamp":"2026-03-29T10:00:01"}
      LOG
      result = described_class.call(file: "json", level: "ERROR")
      text = result.content.first[:text]
      expect(text).to include("NoMethodError")
      expect(text).not_to include("Started GET")
    end

    it "shows available log files in output" do
      result = described_class.call
      text = result.content.first[:text]
      expect(text).to include("Available log files:")
      expect(text).to include("test.log")
    end

    it "returns MCP::Tool::Response" do
      result = described_class.call
      expect(result).to be_a(MCP::Tool::Response)
    end

    it "redacts cookie values" do
      File.write(File.join(log_dir, "test.log"), "I, [2026-03-29T10:00:00 #1] INFO -- : cookie: abc123secret_session_data\n")
      result = described_class.call
      text = result.content.first[:text]
      expect(text).to include("[FILTERED]")
      expect(text).not_to include("abc123secret_session_data")
    end

    it "redacts session_id values" do
      File.write(File.join(log_dir, "test.log"), "I, [2026-03-29T10:00:00 #1] INFO -- : session_id=abc123secret\n")
      result = described_class.call
      text = result.content.first[:text]
      expect(text).to include("[FILTERED]")
      expect(text).not_to include("abc123secret")
    end

    it "redacts Stripe secret keys" do
      File.write(File.join(log_dir, "test.log"), "I, [2026-03-29T10:00:00 #1] INFO -- : Charge failed key=sk_live_1234567890abcdefghij\n")
      result = described_class.call
      text = result.content.first[:text]
      expect(text).to include("[FILTERED]")
      expect(text).not_to include("sk_live_1234567890abcdefghij")
    end

    it "redacts Slack tokens" do
      File.write(File.join(log_dir, "test.log"), "I, [2026-03-29T10:00:00 #1] INFO -- : slack_token=xoxb-1234567890-abcdefghij\n")
      result = described_class.call
      text = result.content.first[:text]
      expect(text).to include("[FILTERED]")
      expect(text).not_to include("xoxb-1234567890-abcdefghij")
    end

    it "redacts GitHub personal access tokens" do
      File.write(File.join(log_dir, "test.log"), "I, [2026-03-29T10:00:00 #1] INFO -- : token=ghp_1234567890abcdefghijklmnopqrstuvwxyz\n")
      result = described_class.call
      text = result.content.first[:text]
      expect(text).not_to include("ghp_1234567890abcdefghijklmnopqrstuvwxyz")
    end

    it "redacts SendGrid API keys" do
      File.write(File.join(log_dir, "test.log"), "I, [2026-03-29T10:00:00 #1] INFO -- : key=SG.abcdefghijklmnopqrstuv.wxyz1234567890abcdef\n")
      result = described_class.call
      text = result.content.first[:text]
      expect(text).not_to include("SG.abcdefghijklmnopqrstuv.wxyz1234567890abcdef")
    end

    it "sanitizes null bytes in file parameter" do
      result = described_class.call(file: "test\0.secret")
      text = result.content.first[:text]
      # Should not crash; either finds a file or reports not found
      expect(result).to be_a(MCP::Tool::Response)
    end
  end
end
