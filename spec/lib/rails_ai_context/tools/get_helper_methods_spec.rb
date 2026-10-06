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

    context "framework helper detection" do
      around do |example|
        Dir.mktmpdir("helper-frameworks") do |dir|
          @root = dir
          FileUtils.mkdir_p(File.join(dir, "app/views/posts"))
          FileUtils.mkdir_p(File.join(dir, "app/helpers"))
          File.write(File.join(dir, "app/helpers/application_helper.rb"),
                     "module ApplicationHelper\n  def page_title = \"t\"\nend\n")
          File.write(File.join(dir, "Gemfile"), <<~GEMFILE)
            gem "devise"
            gem "turbo-rails"
            gem "will_paginate"
            gem "simple_form"
            gem "inline_svg"
            gem "meta-tags"
            gem "pagy"
            # gem "pundit"
          GEMFILE
          File.write(File.join(dir, "app/views/posts/index.html.erb"), <<~ERB)
            <%= current_user %>
            <%= turbo_frame_tag "posts" %>
            <%= will_paginate @posts %>
            <%= simple_form_for @post %>
            <%= inline_svg_tag "logo.svg" %>
            <%= display_meta_tags %>
          <%= policy(@post) %>
          ERB
          example.run
        end
      end

      before do
        allow(RailsAiContext).to receive(:default_app).and_return(RailsAiContext::StaticApp.new(@root))
        allow(described_class).to receive(:cached_context).and_return({})
      end

      it "names the gems whose Gemfile entry does not match the library name" do
        text = described_class.call(detail: "full").content.first[:text]

        expect(text).to include("**Devise:** current_user")
        expect(text).to include("**Turbo:** turbo_frame_tag")
        expect(text).to include("**WillPaginate:** will_paginate")
        expect(text).to include("**SimpleForm:** simple_form_for")
        expect(text).to include("**InlineSvg:** inline_svg_tag")
        expect(text).to include("**MetaTags:** display_meta_tags")
      end

      it "leaves out a gem the Gemfile only names in a comment" do
        text = described_class.call(detail: "full").content.first[:text]

        expect(text).not_to include("**Pundit:**")
      end
    end

    context "when a template lives in a view path the app appends" do
      around do |example|
        Dir.mktmpdir("helper-overlay") do |dir|
          @root = dir
          FileUtils.mkdir_p(File.join(dir, "app/views"))
          FileUtils.mkdir_p(File.join(dir, "enterprise/app/views/posts"))
          FileUtils.mkdir_p(File.join(dir, "app/helpers"))
          FileUtils.mkdir_p(File.join(dir, "config"))
          File.write(File.join(dir, "config/application.rb"), "config.paths[\"app/views\"] << \"enterprise/app/views\"\n")
          File.write(File.join(dir, "app/helpers/application_helper.rb"), "module ApplicationHelper\n  def page_title = \"t\"\nend\n")
          File.write(File.join(dir, "Gemfile"), "gem \"devise\"\n")
          File.write(File.join(dir, "enterprise/app/views/posts/index.html.erb"), "<%= page_title %> <%= current_user %>\n")
          example.run
        end
      end

      before do
        allow(RailsAiContext).to receive(:default_app).and_return(RailsAiContext::StaticApp.new(@root))
        allow(described_class).to receive(:cached_context).and_return({})
      end

      it "reads it for view references and framework helpers" do
        helper = described_class.call(helper: "ApplicationHelper", detail: "full").content.first[:text]
        expect(helper).to include("`page_title` used in: posts/index.html.erb")
        expect(described_class.call(detail: "full").content.first[:text]).to include("**Devise:** current_user")
      end

      it "leaves out a class kept under app/helpers, which no view mixes in" do
        FileUtils.mkdir_p(File.join(@root, "app/helpers/wiki_pages"))
        File.write(File.join(@root, "app/helpers/wiki_pages/at_version.rb"),
                   "module WikiPages\n  class AtVersion < SimpleDelegator\n    def latest_version = 1\n  end\nend\n")

        text = described_class.call(detail: "standard").content.first[:text]
        expect(text).to include("# Helpers (1)", "ApplicationHelper")
        expect(text).not_to include("AtVersion")
      end

      it "skips a view in it that links out of the app or loops" do
        Dir.mktmpdir("outside") do |outside|
          File.write(File.join(outside, "leak.html.erb"), "<%= page_title %>\n")
          File.symlink(File.join(outside, "leak.html.erb"), File.join(@root, "enterprise/app/views/posts/leak.html.erb"))
          File.symlink("loop.html.erb", File.join(@root, "enterprise/app/views/posts/loop.html.erb"))

          text = described_class.call(helper: "ApplicationHelper", detail: "full").content.first[:text]
          expect(text).to include("`page_title` used in: posts/index.html.erb")
          expect(text).not_to include("leak.html.erb")
          expect(text).not_to include("loop.html.erb")
        end
      end
    end

    # An app that registers an acronym keeps JsonLdHelper in jsonld_helper.rb;
    # underscoring the name here, knowing none of the app's acronyms, looked
    # for json_ld_helper.rb.
    context "with a helper the app names through an acronym" do
      let(:tmpdir) { Dir.mktmpdir }

      before do
        FileUtils.mkdir_p(File.join(tmpdir, "app", "helpers", "activitypub"))
        File.write(File.join(tmpdir, "app", "helpers", "jsonld_helper.rb"), <<~RUBY)
          module JsonLdHelper
            def context_url; end
          end
        RUBY
        File.write(File.join(tmpdir, "app", "helpers", "activitypub", "links_helper.rb"), <<~RUBY)
          module ActivityPub::LinksHelper
            def actor_url; end
          end
        RUBY
        allow(Rails.application).to receive(:root).and_return(Pathname.new(tmpdir))
      end

      after { FileUtils.remove_entry(tmpdir) }

      it "finds it by the name the app writes" do
        text = described_class.call(helper: "JsonLdHelper").content.first[:text]
        expect(text).to include("context_url")
        expect(text).not_to include("not found")
      end

      it "finds a helper under an acronym namespace" do
        text = described_class.call(helper: "ActivityPub::LinksHelper").content.first[:text]
        expect(text).to include("actor_url")
      end
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

    # Packs and engines are searched too, so naming app/helpers/ alone told a
    # packwerk app to look somewhere the tool had not looked.
    context "when nothing anywhere holds a helper" do
      it "names every directory it searched" do
        Dir.mktmpdir do |root|
          FileUtils.mkdir_p(File.join(root, "packs", "billing", "app", "helpers"))
          allow(described_class).to receive(:rails_app).and_return(RailsAiContext::StaticApp.new(root))

          text = described_class.call.content.first[:text]
          expect(text).to include("No helper files found in app/helpers/, packs/*/app/helpers/ or engines/*/app/helpers/.")
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

    # A Discourse plugin nests its tree under its own namespace:
    # plugins/discourse-chat-integration/app/helpers/helper.rb declares
    # DiscourseChatIntegration::Helper, which the path names "Helper".
    context "when a plugin's helper declares a namespace its path does not carry" do
      def plugin_app(root)
        plugin = File.join(root, "plugins", "discourse-chat-integration")
        FileUtils.mkdir_p(File.join(plugin, "app", "helpers"))
        File.write(File.join(plugin, "plugin.rb"), "# name: discourse-chat-integration\n")
        File.write(File.join(plugin, "app", "helpers", "helper.rb"), <<~RUBY)
          module DiscourseChatIntegration
            module Helper
              def self.process_command; end

              def channel_name; end
            end
          end
        RUBY
        FileUtils.mkdir_p(File.join(root, "app", "helpers"))
        allow(described_class).to receive(:rails_app).and_return(RailsAiContext::StaticApp.new(root))
      end

      it "lists it and answers it under the constant the file declares" do
        Dir.mktmpdir do |root|
          plugin_app(root)

          expect(described_class.call.content.first[:text]).to include("DiscourseChatIntegration::Helper")

          text = described_class.call(helper: "DiscourseChatIntegration::Helper").content.first[:text]
          expect(text).to include("# DiscourseChatIntegration::Helper")
          expect(text).to include("channel_name")
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

    context "with view helpers a controller declares with helper_method" do
      around do |example|
        Dir.mktmpdir("helper-method") do |dir|
          @root = dir
          FileUtils.mkdir_p(File.join(dir, "app/helpers"))
          FileUtils.mkdir_p(File.join(dir, "app/controllers/concerns"))
          File.write(File.join(dir, "app/helpers/application_helper.rb"), "module ApplicationHelper\nend\n")
          File.write(File.join(dir, "app/controllers/application_controller.rb"), <<~RUBY)
            class ApplicationController < ActionController::Base
              helper_method :current_user, :authenticated?
              private
              def current_user; end
              def authenticated? = current_user.present?
            end
          RUBY
          File.write(File.join(dir, "app/controllers/concerns/authentication.rb"), <<~RUBY)
            module Authentication
              extend ActiveSupport::Concern
              included do
                helper_method def signed_in_as = Current.user
              end
            end
          RUBY
          File.write(File.join(dir, "app/controllers/posts_controller.rb"), "class PostsController < ApplicationController\nend\n")
          example.run
        end
      end

      before do
        allow(described_class).to receive(:rails_app).and_return(RailsAiContext::StaticApp.new(@root))
        allow(described_class).to receive(:cached_context).and_return({})
      end

      it "lists each one with the controller or concern that declares it" do
        text = described_class.call(detail: "full").content.first[:text]

        expect(text).to include("## Declared in controllers with helper_method (3)")
        expect(text).to include("- `current_user` (ApplicationController, `app/controllers/application_controller.rb`)")
        expect(text).to include("- `authenticated?` (ApplicationController, `app/controllers/application_controller.rb`)")
        expect(text).to include("- `signed_in_as` (Authentication, `app/controllers/concerns/authentication.rb`)")
      end

      it "reads past a controller it cannot parse or decode" do
        File.write(File.join(@root, "app/controllers/broken_controller.rb"), "class BrokenController\n  helper_method :x,\n")
        File.binwrite(File.join(@root, "app/controllers/odd_controller.rb"), "class OddController\n  # \xFF\n  helper_method :odd\nend\n")

        text = described_class.call(detail: "standard").content.first[:text]

        expect(text).to include("- `current_user` (ApplicationController")
        expect(text).to include("- `odd` (OddController")
      end

      it "counts them in the summary" do
        text = described_class.call(detail: "summary").content.first[:text]

        expect(text).to include("- **helper_method in controllers** - 3 methods")
      end

      it "lists the ones a module outside app/controllers declares when a controller includes it" do
        FileUtils.mkdir_p(File.join(@root, "lib/spree/core/controller_helpers"))
        File.write(File.join(@root, "lib/spree/core/controller_helpers/order.rb"), <<~RUBY)
          module Spree
            module Core
              module ControllerHelpers
                module Order
                  def self.included(base)
                    base.class_eval { helper_method :current_order }
                  end
                end
              end
            end
          end
        RUBY
        File.write(File.join(@root, "lib/spree/authentication_helpers.rb"), <<~RUBY)
          module Spree::AuthenticationHelpers
            def self.included(receiver)
              receiver.helper_method :spree_current_user
            end
          end
        RUBY
        File.write(File.join(@root, "lib/unused_helpers.rb"), "module UnusedHelpers\n  helper_method :never\nend\n")
        File.write(File.join(@root, "app/controllers/base_controller.rb"), <<~RUBY)
          class BaseController < ApplicationController
            include Spree::Core::ControllerHelpers::Order
            include Spree::AuthenticationHelpers
          end
        RUBY

        text = described_class.call(detail: "standard").content.first[:text]

        expect(text).to include("- `current_order` (Spree::Core::ControllerHelpers::Order, `lib/spree/core/controller_helpers/order.rb`)")
        expect(text).to include("- `spree_current_user` (Spree::AuthenticationHelpers, `lib/spree/authentication_helpers.rb`)")
        expect(text).not_to include("never")
      end

      it "lists the ones a module kept in its outer constant's lib file declares" do
        FileUtils.mkdir_p(File.join(@root, "lib"))
        File.write(File.join(@root, "lib/canonical.rb"), <<~RUBY)
          module Canonical
            helper_method :outside_the_module

            module ControllerExtensions
              def self.included(base)
                base.helper_method :default_canonical
              end
            end
          end
        RUBY
        File.write(File.join(@root, "app/controllers/base_controller.rb"), <<~RUBY)
          class BaseController < ApplicationController
            include Canonical::ControllerExtensions
          end
        RUBY

        text = described_class.call(detail: "standard").content.first[:text]

        expect(text).to include("- `default_canonical` (Canonical::ControllerExtensions, `lib/canonical.rb`)")
        expect(text).not_to include("outside_the_module")
      end
    end

    # module_function leaves a private instance copy, which a view calls like any helper.
    it "lists a module_function helper with the others" do
      Dir.mktmpdir("helper-mf") do |dir|
        FileUtils.mkdir_p(File.join(dir, "app/helpers"))
        File.write(File.join(dir, "app/helpers/database_helper.rb"), <<~RUBY)
          module DatabaseHelper
            def replica_enabled?
              true
            end
            module_function :replica_enabled?

            def with_primary(&block); end

            private

            def internal; end
          end
        RUBY
        allow(described_class).to receive(:rails_app).and_return(RailsAiContext::StaticApp.new(dir))
        allow(described_class).to receive(:cached_context).and_return({})

        listing = described_class.call(detail: "standard").content.first[:text]
        shown = described_class.call(helper: "DatabaseHelper").content.first[:text]

        expect(listing).to include("- `replica_enabled?`\n- `with_primary(&block)`")
        expect(listing).not_to include("internal")
        expect(shown).to include("## Methods (2)")
      end
    end
  end
end
