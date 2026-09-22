# frozen_string_literal: true

require "spec_helper"

RSpec.describe RailsAiContext::Tools::GetPartialInterface do
  before { described_class.reset_cache! }

  # Two of the app's three partials are `.text.erb`, and the resolver's fixed
  # extension list refused the name its own Available list had just printed.
  describe "a partial outside the html.erb extension list" do
    around do |example|
      Dir.mktmpdir("partial-interface") do |dir|
        @root = dir
        FileUtils.mkdir_p(File.join(dir, "app/views/reports/ai_data"))
        FileUtils.mkdir_p(File.join(dir, "app/views/pdfs"))
        File.write(File.join(dir, "app/views/reports/ai_data/_header.text.erb"),
                   "<%= title %> for order <%= order.number %>\n")
        File.write(File.join(dir, "app/views/reports/ai_data/summary.text.erb"),
                   "<%= render partial: 'reports/ai_data/header', locals: { order: @order, title: 'summary' } -%>\n")
        File.write(File.join(dir, "app/views/pdfs/_summary_fields.html.erb"),
                   (1..18).map { |i| "<p><%= prediction.field_#{format('%02d', i)} %></p>" }.join("\n") + "\n")
        example.run
      end
    end

    before do
      allow(RailsAiContext).to receive(:default_app).and_return(RailsAiContext::StaticApp.new(@root))
      allow(described_class).to receive(:cached_context).and_return({})
    end

    it "resolves a .text.erb partial by its Rails name" do
      text = described_class.call(partial: "reports/ai_data/header").content.first[:text]

      expect(text).not_to include("not found")
      expect(text).to include("reports/ai_data/_header.text.erb")
    end

    it "says how many calls the list left out" do
      text = described_class.call(partial: "pdfs/summary_fields").content.first[:text]

      expect(text).to include("...and 8 more")
    end
  end

  describe ".call" do
    it "analyzes a partial with magic comment locals" do
      result = described_class.call(partial: "posts/form")
      text = result.content.first[:text]
      expect(text).to be_a(String)
      expect(text.length).to be > 0
      expect(text).to include("post")
      expect(text).to include("url")
    end

    it "reports a partial over the size cap" do
      allow(RailsAiContext.configuration).to receive(:max_file_size).and_return(10)

      result = described_class.call(partial: "posts/form")
      expect(result.content.first[:text]).to include("Partial file too large")
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

    it "does not list the same partial twice when it exists under multiple extensions" do
      views_dir = Rails.root.join("app", "views")
      dir = views_dir.join("gpi_dup_#{Process.pid}")
      FileUtils.mkdir_p(dir)
      File.write(dir.join("_widget.html.erb"), "<%= widget %>")
      File.write(dir.join("_widget.json.jbuilder"), "json.name widget.name")

      result = described_class.call(partial: "nonexistent/widget")
      text = result.content.first[:text]
      candidate = "gpi_dup_#{Process.pid}/widget"

      expect(text.scan(candidate).size).to eq(1)
    ensure
      FileUtils.rm_rf(dir) if defined?(dir)
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

    context "when the app is API-only" do
      it "reports API-only apps as not applicable instead of an empty listing" do
        Dir.mktmpdir("rac_gpi_api_only") do |tmp|
          allow(described_class).to receive(:cached_context).and_return(api: { api_only: true })
          allow(described_class).to receive(:rails_app).and_return(double(root: Pathname.new(tmp)))

          result = described_class.call(partial: "shared/status_badge")
          text = result.content.first[:text]
          expect(text).to include("Not applicable")
          expect(text).to include("API-only")
        end
      end
    end
  end

  describe "extract_local_variable_references" do
    def locals_in(source)
      described_class.send(:extract_local_variable_references, source)
    end

    it "sees a local rendered through a raw output tag" do
      expect(locals_in("<%== title %>\n")).to include("title")
    end

    it "still sees a local rendered through an escaping tag" do
      expect(locals_in("<%= title %>\n")).to include("title")
    end

    it "ignores a commented-out tag body" do
      expect(locals_in("<%# title %>\n")).not_to include("title")
    end
  end
end
