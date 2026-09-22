# frozen_string_literal: true

require "spec_helper"
require "tmpdir"

RSpec.describe RailsAiContext::Tools::GetHelperMethods do
  before { described_class.reset_cache! }

  describe ".call" do
    it "lists all helpers with default params" do
      result = described_class.call
      text = result.content.first[:text]
      expect(text).to be_a(String)
      expect(text.length).to be > 0
      expect(text).to include("Helpers")
    end

    it "lists helpers with method counts for detail:summary" do
      result = described_class.call(detail: "summary")
      text = result.content.first[:text]
      expect(text).to include("ApplicationHelper")
      expect(text).to include("PostsHelper")
      expect(text).to include("- 1 method")
    end

    it "lists helpers with method signatures for detail:standard" do
      result = described_class.call(detail: "standard")
      text = result.content.first[:text]
      expect(text).to include("ApplicationHelper")
      expect(text).to include("page_title")
      expect(text).to include("post_excerpt")
    end

    it "shows framework helper detection for detail:full" do
      result = described_class.call(detail: "full")
      text = result.content.first[:text]
      expect(text).to include("ApplicationHelper")
      expect(text).to include("page_title")
    end

    it "shows specific helper by module name" do
      result = described_class.call(helper: "ApplicationHelper")
      text = result.content.first[:text]
      expect(text).to include("ApplicationHelper")
      expect(text).to include("page_title")
      expect(text).to include("app/helpers/application_helper.rb")
    end

    it "shows specific helper by short name" do
      result = described_class.call(helper: "PostsHelper")
      text = result.content.first[:text]
      expect(text).to include("PostsHelper")
      expect(text).to include("post_excerpt")
    end

    it "answers too-large rather than could-not-read for a helper over the cap" do
      allow(RailsAiContext.configuration).to receive(:max_file_size).and_return(10)

      text = described_class.call(helper: "ApplicationHelper").content.first[:text]
      expect(text).to include("Helper file too large")
    end

    it "returns not-found for unknown helper" do
      result = described_class.call(helper: "NonexistentHelper")
      text = result.content.first[:text]
      expect(text).to include("not found")
      expect(text).to include("ApplicationHelper")
    end

    it "reads an invalid detail level as the default, and says so" do
      text = described_class.call(detail: "bogus").content.first[:text]

      expect(text).to start_with(described_class.call(detail: "standard").content.first[:text])
      expect(text).to include("bogus")
      expect(text).to include("not a valid `detail`")
    end

    it "shows view cross-references at detail:full for a specific helper" do
      result = described_class.call(helper: "ApplicationHelper", detail: "full")
      text = result.content.first[:text]
      expect(text).to include("ApplicationHelper")
      # Should attempt view cross-reference even if none found
      expect(text).to match(/View References|No view references/)
    end

    it "includes method parameter signatures" do
      result = described_class.call(helper: "PostsHelper")
      text = result.content.first[:text]
      # PostsHelper has post_excerpt(post, length: 100)
      expect(text).to include("post_excerpt")
    end

    context "with a def inside a heredoc" do
      it "lists only the methods the helper really defines" do
        Dir.mktmpdir do |root|
          FileUtils.mkdir_p(File.join(root, "app", "helpers"))
          File.write(File.join(root, "app", "helpers", "docs_helper.rb"), <<~RUBY)
            module DocsHelper
              USAGE = <<~USAGE
                def example_usage
                end
              USAGE

              def visible(name); end

              private

              def hidden; end
            end
          RUBY
          allow(described_class).to receive(:rails_app).and_return(RailsAiContext::StaticApp.new(root))

          text = described_class.call(helper: "DocsHelper").content.first[:text]

          expect(text).to include("## Methods (1)")
          expect(text).to include("- `visible(name)`")
          expect(text).not_to include("example_usage")
        end
      end
    end

    context "when helpers live only in a pack" do
      it "lists the pack helper and names its real path" do
        Dir.mktmpdir do |root|
          dir = File.join(root, "packs", "billing", "app", "helpers")
          FileUtils.mkdir_p(dir)
          File.write(File.join(dir, "invoice_helper.rb"), <<~RUBY)
            module InvoiceHelper
              def invoice_total(invoice); end
            end
          RUBY
          allow(described_class).to receive(:rails_app).and_return(RailsAiContext::StaticApp.new(root))

          text = described_class.call(helper: "InvoiceHelper").content.first[:text]
          expect(text).to include("# InvoiceHelper")
          expect(text).to include("packs/billing/app/helpers/invoice_helper.rb")
        end
      end
    end

    context "when an engine and a pack hold the same helper path" do
      def two_root_app(root)
        engine = File.join(root, "engines", "billing", "app", "helpers")
        pack = File.join(root, "packs", "billing", "app", "helpers")
        [ engine, pack ].each { |d| FileUtils.mkdir_p(d) }
        File.write(File.join(engine, "invoice_helper.rb"), <<~RUBY)
          module InvoiceHelper
            def engine_total(invoice); end
          end
        RUBY
        File.write(File.join(pack, "invoice_helper.rb"), <<~RUBY)
          module InvoiceHelper
            def pack_total(invoice); end
          end
        RUBY
        allow(described_class).to receive(:rails_app).and_return(RailsAiContext::StaticApp.new(root))
      end

      it "names the other file behind the module rather than answering as if it were alone" do
        Dir.mktmpdir do |root|
          two_root_app(root)

          text = described_class.call(helper: "InvoiceHelper").content.first[:text]

          expect(text).to include("engines/billing/app/helpers/invoice_helper.rb")
          expect(text).to include("packs/billing/app/helpers/invoice_helper.rb")
          expect(text).to include("Also defined in")
        end
      end

      it "lists the shared module name once in the not-found alternatives" do
        Dir.mktmpdir do |root|
          two_root_app(root)

          text = described_class.call(helper: "NopeHelper").content.first[:text]

          expect(text).to include("Available: InvoiceHelper\n")
        end
      end
    end

    context "when two namespaces hold the same helper file name" do
      def two_namespace_app(root)
        helpers = File.join(root, "app", "helpers")
        FileUtils.mkdir_p(File.join(helpers, "admin"))
        FileUtils.mkdir_p(File.join(helpers, "reports"))
        File.write(File.join(helpers, "admin", "dashboard_helper.rb"), <<~RUBY)
          module Admin
            module DashboardHelper
              def admin_total; end
            end
          end
        RUBY
        File.write(File.join(helpers, "reports", "dashboard_helper.rb"), <<~RUBY)
          module Reports
            module DashboardHelper
              def reports_total; end
            end
          end
        RUBY
        allow(described_class).to receive(:rails_app).and_return(RailsAiContext::StaticApp.new(root))
      end

      it "does not claim the other namespace defines the module in the heading" do
        Dir.mktmpdir do |root|
          two_namespace_app(root)

          text = described_class.call(helper: "DashboardHelper").content.first[:text]

          expect(text).to include("# Admin::DashboardHelper")
          expect(text).not_to include("Also defined in")
        end
      end

      it "names the other module and its path instead of dropping it" do
        Dir.mktmpdir do |root|
          two_namespace_app(root)

          text = described_class.call(helper: "DashboardHelper").content.first[:text]

          expect(text).to include("Same file name, different module")
          expect(text).to include("Reports::DashboardHelper")
          expect(text).to include("app/helpers/reports/dashboard_helper.rb")
        end
      end
    end

    context "when an API-only app has no app/helpers directory" do
      it "answers not applicable instead of not found" do
        Dir.mktmpdir do |root|
          allow(described_class).to receive(:rails_app).and_return(RailsAiContext::StaticApp.new(root))
          allow(described_class).to receive(:cached_context).and_return(api: { api_only: true })

          text = described_class.call.content.first[:text]
          expect(text).to include("Not applicable")
          expect(text).to include("API-only")
        end
      end
    end
  end
end
