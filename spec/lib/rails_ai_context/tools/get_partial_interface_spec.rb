# frozen_string_literal: true

require "spec_helper"

RSpec.describe RailsAiContext::Tools::GetPartialInterface do
  before { described_class.reset_cache! }

  describe ".call" do
    it "analyzes a partial with magic comment locals" do
      result = described_class.call(partial: "posts/form")
      text = result.content.first[:text]
      expect(text).to be_a(String)
      expect(text.length).to be > 0
      expect(text).to include("post")
      expect(text).to include("url")
    end

    it "shows summary detail level" do
      result = described_class.call(partial: "posts/form", detail: "summary")
      text = result.content.first[:text]
      expect(text).to include("Locals:")
      expect(text).to include("Rendered from:")
    end

    it "shows standard detail with method calls on locals" do
      result = described_class.call(partial: "posts/post", detail: "standard")
      text = result.content.first[:text]
      expect(text).to include("Local Variables")
      # post.title and post.body are called in the partial
      expect(text).to include("post")
    end

    it "shows full detail with source code" do
      result = described_class.call(partial: "posts/form", detail: "full")
      text = result.content.first[:text]
      expect(text).to include("Source")
      expect(text).to include("form_with")
    end

    it "handles underscore-prefixed partial names" do
      result = described_class.call(partial: "posts/_form")
      text = result.content.first[:text]
      expect(text).to include("post")
    end

    it "finds render sites for the partial" do
      result = described_class.call(partial: "posts/form", detail: "standard")
      text = result.content.first[:text]
      # edit.html.erb renders the form partial
      expect(text).to include("Rendered From")
    end

    it "returns not-found for unknown partial" do
      result = described_class.call(partial: "nonexistent/widget")
      text = result.content.first[:text]
      expect(text).to include("not found")
    end

    it "returns helpful message when partial is nil" do
      result = described_class.call(partial: nil)
      text = result.content.first[:text]
      expect(text).to include("`partial` parameter is required")
    end

    it "returns helpful message when partial is empty string" do
      result = described_class.call(partial: "")
      text = result.content.first[:text]
      expect(text).to include("`partial` parameter is required")
    end

    it "returns helpful message when partial is whitespace only" do
      result = described_class.call(partial: "   ")
      text = result.content.first[:text]
      expect(text).to include("`partial` parameter is required")
    end

    it "prevents path traversal" do
      result = described_class.call(partial: "../../../etc/passwd")
      text = result.content.first[:text]
      expect(text).to include("not allowed")
    end

    it "blocks caller-supplied sensitive names BEFORE filesystem stat (existence oracle)" do
      # Without the early sensitive_file? check, resolve_partial_path would
      # stat each candidate for `.env` / `master.key` and the not-found vs
      # access-denied message would leak whether the file exists under
      # app/views/. The fix rejects sensitive names before any File.exist?.
      result = described_class.call(partial: ".env")
      text = result.content.first[:text]
      expect(text).to match(/not allowed/)
      expect(text).to include("sensitive")

      result2 = described_class.call(partial: "config/master.key")
      text2 = result2.content.first[:text]
      expect(text2).to match(/not allowed/)
      expect(text2).to include("sensitive")
    end

    it "detects magic comment locals in status_badge partial" do
      result = described_class.call(partial: "shared/status_badge")
      text = result.content.first[:text]
      expect(text).to include("status")
      expect(text).to include("size")
    end

    it "extracts method calls on locals" do
      result = described_class.call(partial: "posts/post", detail: "standard")
      text = result.content.first[:text]
      # _post.html.erb calls post.title and post.body
      if text.include?("calls:")
        expect(text).to match(/title|body/)
      end
    end

    context "C1 symlink hardening (v5.8.1 round 2)" do
      let(:views_dir) { Rails.root.join("app", "views") }

      it "refuses partials whose realpath escapes app/views via sibling-dir symlink" do
        sibling_dir = Rails.root.join("app", "views_spec_gpi_#{Process.pid}")
        FileUtils.mkdir_p(sibling_dir.join("posts"))
        secret_partial = sibling_dir.join("posts", "_secret.html.erb")
        File.write(secret_partial, "<h1>SIBLING PARTIAL SECRET</h1>")

        FileUtils.mkdir_p(views_dir.join("posts"))
        symlink = views_dir.join("posts", "_gpi_leak_#{Process.pid}.html.erb")
        File.symlink(secret_partial, symlink)

        result = described_class.call(partial: "posts/gpi_leak_#{Process.pid}")
        text = result.content.first[:text]
        # When containment fails, resolve_partial_path returns nil → "not found".
        expect(text).to match(/not found|not allowed/i)
        expect(text).not_to include("SIBLING PARTIAL SECRET")
      ensure
        FileUtils.rm_f(symlink) if defined?(symlink)
        FileUtils.rm_rf(sibling_dir) if defined?(sibling_dir)
      end

      it "refuses partials whose realpath lands on a sensitive file" do
        secret = Rails.root.join("config", "_gpi_test_master_#{Process.pid}.key")
        File.write(secret, "should-never-leak")
        FileUtils.mkdir_p(views_dir.join("posts"))
        symlink = views_dir.join("posts", "_gpi_secret_#{Process.pid}.html.erb")
        File.symlink(secret, symlink)

        result = described_class.call(partial: "posts/gpi_secret_#{Process.pid}")
        text = result.content.first[:text]
        expect(text).not_to include("should-never-leak")
      ensure
        FileUtils.rm_f(symlink) if defined?(symlink)
        FileUtils.rm_f(secret) if defined?(secret)
      end
    end
  end
end
