# frozen_string_literal: true

require "spec_helper"

RSpec.describe RailsAiContext::Tools::GetView do
  before { described_class.reset_cache! }

  describe ".call" do
    it "lists views with detail:summary" do
      result = described_class.call(detail: "summary")
      text = result.content.first[:text]
      expect(text).to include("Views")
      expect(text).to include("posts")
    end

    it "lists views for a specific controller" do
      result = described_class.call(controller: "posts", detail: "summary")
      text = result.content.first[:text]
      expect(text).to include("index.html.erb")
      expect(text).to include("show.html.erb")
    end

    it "returns specific view content by path" do
      result = described_class.call(path: "posts/index.html.erb")
      text = result.content.first[:text]
      expect(text).to include("posts/index.html.erb")
      expect(text).to include("Posts")
    end

    it "returns error for non-existent path" do
      result = described_class.call(path: "nonexistent/show.html.erb")
      text = result.content.first[:text]
      expect(text).to include("not found")
    end

    it "prevents path traversal" do
      result = described_class.call(path: "../../etc/passwd")
      text = result.content.first[:text]
      expect(text).to match(/not (found|allowed)/)
    end

    it "returns error for unknown controller" do
      result = described_class.call(controller: "zzz_nonexistent")
      text = result.content.first[:text]
      expect(text).to include("No views for")
    end

    it "returns standard detail with partial and stimulus refs" do
      result = described_class.call(controller: "posts", detail: "standard")
      text = result.content.first[:text]
      expect(text).to include("index.html.erb")
    end

    it "returns full detail with template content for a controller" do
      result = described_class.call(controller: "posts", detail: "full")
      text = result.content.first[:text]
      expect(text).to include("```erb")
      expect(text).to include("Posts")
    end

    it "returns hint when full detail used without controller" do
      result = described_class.call(detail: "full")
      text = result.content.first[:text]
      expect(text).to include("controller:")
    end

    context "with Phlex views" do
      it "lists Phlex views in summary with [phlex] tag" do
        result = described_class.call(controller: "articles", detail: "summary")
        text = result.content.first[:text]
        expect(text).to include("show.rb")
        expect(text).to include("[phlex]")
      end

      it "shows components in summary for Phlex views" do
        result = described_class.call(controller: "articles", detail: "summary")
        text = result.content.first[:text]
        expect(text).to include("components:")
      end

      it "shows components in standard detail for Phlex views" do
        result = described_class.call(controller: "articles", detail: "standard")
        text = result.content.first[:text]
        expect(text).to include("[phlex]")
        expect(text).to include("components:")
        expect(text).to include("Components::Articles::ArticleUser")
      end

      it "shows helpers in standard detail for Phlex views" do
        result = described_class.call(controller: "articles", detail: "standard")
        text = result.content.first[:text]
        expect(text).to include("helpers:")
        expect(text).to include("link_to")
      end

      it "shows stimulus controllers in standard detail for Phlex views" do
        result = described_class.call(controller: "articles", detail: "standard")
        text = result.content.first[:text]
        expect(text).to include("stimulus:")
        expect(text).to include("infinite_scroll")
      end

      it "shows ivars in standard detail for Phlex views" do
        result = described_class.call(controller: "articles", detail: "standard")
        text = result.content.first[:text]
        expect(text).to include("ivars:")
        expect(text).to include("article")
        expect(text).to include("comments")
      end

      it "returns Phlex view content by path" do
        result = described_class.call(path: "articles/show.rb")
        text = result.content.first[:text]
        expect(text).to include("articles/show.rb")
        expect(text).to include("view_template")
      end
    end

    context "C1 symlink hardening (v5.8.1 round 2)" do
      let(:views_dir) { Rails.root.join("app", "views") }

      it "blocks sibling-directory traversal via symlink" do
        sibling_dir = Rails.root.join("app", "views_spec_gv_#{Process.pid}")
        FileUtils.mkdir_p(sibling_dir)
        secret_file = sibling_dir.join("secret.html.erb")
        File.write(secret_file, "<h1>SIBLING SECRET</h1>")

        symlink = views_dir.join("gv_leak_#{Process.pid}.html.erb")
        File.symlink(secret_file, symlink)

        result = described_class.call(path: "gv_leak_#{Process.pid}.html.erb")
        text = result.content.first[:text]
        expect(text).to match(/not allowed/)
        expect(text).not_to include("SIBLING SECRET")
      ensure
        FileUtils.rm_f(symlink) if defined?(symlink)
        FileUtils.rm_rf(sibling_dir) if defined?(sibling_dir)
      end

      it "blocks sensitive files resolved via symlink (post-realpath recheck)" do
        # The caller-supplied path uses an .html.erb extension so the EARLY
        # `sensitive_file?(path)` guard does NOT fire. The block has to come
        # from the post-realpath recheck (line ~262 of get_view.rb), which
        # canonicalizes the symlink target and then re-runs sensitive_file?
        # against the relative real path. This isolates that defense from
        # the early-guard layer.
        secret = Rails.root.join("config", "_gv_test_master_#{Process.pid}.key")
        File.write(secret, "should-never-leak")
        symlink = views_dir.join("gv_leak_secret_#{Process.pid}.html.erb")
        File.symlink(secret, symlink)

        result = described_class.call(path: "gv_leak_secret_#{Process.pid}.html.erb")
        text = result.content.first[:text]
        expect(text).to match(/sensitive|not allowed|denied/)
        expect(text).not_to include("should-never-leak")
      ensure
        FileUtils.rm_f(symlink) if defined?(symlink)
        FileUtils.rm_f(secret) if defined?(secret)
      end

      it "rejects sensitive caller-supplied paths before any filesystem stat" do
        result = described_class.call(path: "../../config/master.key")
        text = result.content.first[:text]
        expect(text).to match(/not allowed|denied|sensitive/)
      end
    end

    context "list_layouts hardening" do
      let(:views_dir) { Rails.root.join("app", "views") }
      let(:layouts_dir) { views_dir.join("layouts") }

      it "does not reveal content of a symlink inside layouts/ that escapes layouts_dir" do
        # Put a secret outside layouts/, symlink it in, and confirm
        # list_layouts(detail:"full") does NOT embed the secret content.
        # The fix applies separator-aware realpath containment per file.
        FileUtils.mkdir_p(layouts_dir)
        secret_dir = Rails.root.join("tmp", "_gv_layout_escape_#{Process.pid}")
        FileUtils.mkdir_p(secret_dir)
        secret_file = secret_dir.join("secret.html.erb")
        File.write(secret_file, "<!-- LAYOUT ESCAPE SECRET -->")

        symlink = layouts_dir.join("gv_escape_#{Process.pid}.html.erb")
        File.symlink(secret_file, symlink)

        result = described_class.call(controller: "layouts", detail: "full")
        text = result.content.first[:text]
        expect(text).not_to include("LAYOUT ESCAPE SECRET")
      ensure
        FileUtils.rm_f(symlink) if defined?(symlink)
        FileUtils.rm_rf(secret_dir) if defined?(secret_dir)
      end

      it "does not read a symlinked sensitive file inside layouts/" do
        FileUtils.mkdir_p(layouts_dir)
        secret = Rails.root.join("config", "_gv_layout_master_#{Process.pid}.key")
        File.write(secret, "should-never-leak-as-layout")
        symlink = layouts_dir.join("gv_layout_key_#{Process.pid}.key")
        File.symlink(secret, symlink)

        result = described_class.call(controller: "layouts", detail: "full")
        text = result.content.first[:text]
        expect(text).not_to include("should-never-leak-as-layout")
      ensure
        FileUtils.rm_f(symlink) if defined?(symlink)
        FileUtils.rm_f(secret) if defined?(secret)
      end
    end
  end
end
