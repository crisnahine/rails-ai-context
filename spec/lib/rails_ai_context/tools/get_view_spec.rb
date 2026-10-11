# frozen_string_literal: true

require "spec_helper"
require "tmpdir"

RSpec.describe RailsAiContext::Tools::GetView do
  before { described_class.reset_cache! }

  describe ".call" do
    it "lists views with detail:summary" do
      result = described_class.call(detail: "summary")
      text = result.content.first[:text]
      expect(text).to include("Views")
      expect(text).to include("posts")
    end

    # The template and partial counts left the layouts out, so the numbers in
    # the heading never added up to the files under app/views.
    it "counts layouts in the heading so the file count reconciles" do
      text = described_class.call(detail: "summary").content.first[:text]

      expect(text).to match(/# Views \(\d+ templates?, \d+ partials?, 1 layout\)/)
    end

    it "leaves layouts out of the heading when the listing is one controller" do
      text = described_class.call(controller: "posts", detail: "summary").content.first[:text]

      expect(text).to match(/# Views \(\d+ templates?, \d+ partials?\)/)
      expect(text).not_to include("layout)")
    end

    context "with a template that has no handler extension" do
      let(:worker) { Rails.root.join("app/views/gv_pwa/service-worker.js") }

      before do
        FileUtils.mkdir_p(File.dirname(worker))
        File.write(worker, "self.addEventListener(\"push\", () => {})\n")
        described_class.reset_cache!
      end

      after do
        FileUtils.rm_rf(File.dirname(worker))
        described_class.reset_cache!
      end

      it "lists it, since Rails renders it with the raw handler" do
        text = described_class.call(controller: "gv_pwa", detail: "summary").content.first[:text]

        expect(text).to include("gv_pwa/service-worker.js")
      end

      it "shows its content fenced as what it is" do
        text = described_class.call(path: "gv_pwa/service-worker.js").content.first[:text]

        expect(text).not_to include("No template handler renders this file")
        expect(text).to include("```js\nself.addEventListener")
      end
    end

    # app/views/layouts holds the partials the layouts render, and the partial
    # listing already counts them; counting them again as layouts made the
    # heading claim more layouts than the app has.
    context "with a partial under app/views/layouts" do
      let(:partial) { Rails.root.join("app/views/layouts/_gv_footer.html.erb") }

      before do
        File.write(partial, "<footer></footer>\n")
        described_class.reset_cache!
      end

      after do
        FileUtils.rm_f(partial)
        described_class.reset_cache!
      end

      it "does not count it as a layout" do
        text = described_class.call(detail: "summary").content.first[:text]

        expect(text).to match(/# Views \(\d+ templates?, \d+ partials?, 1 layout\)/)
      end

      it "leaves it out of the layouts listing" do
        text = described_class.call(controller: "layouts", detail: "summary").content.first[:text]

        expect(text).to include("layouts/application.html.erb")
        expect(text).not_to include("_gv_footer")
      end
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

    it "accepts the full repo-relative path (with the app/views/ prefix) the same as the app/views-relative form" do
      result = described_class.call(path: "app/views/posts/index.html.erb")
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

    context "when the payload recorded no Phlex components" do
      around do |example|
        Dir.mktmpdir("phlex-fallback") do |dir|
          @root = dir
          FileUtils.mkdir_p(File.join(dir, "app/views/reports"))
          File.write(File.join(dir, "app/views/reports/show.rb"), <<~RUBY)
            class Reports::Show < ApplicationView
              def view_template
                render Components::Reports::Header.new
                link_to "back", root_path
              end
            end
          RUBY
          example.run
        end
      end

      before do
        allow(RailsAiContext).to receive(:default_app).and_return(RailsAiContext::StaticApp.new(@root))
        allow(described_class).to receive(:cached_context).and_return(
          view_templates: { templates: { "reports/show.rb" => { lines: 6, phlex: true } }, partials: {} }
        )
      end

      it "falls back to reading the components and helpers off the file" do
        text = described_class.call(controller: "reports", detail: "standard").content.first[:text]

        expect(text).to include("components: Components::Reports::Header")
        expect(text).to include("helpers: link_to")
      end
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

    context "caller-supplied paths" do
      it "rejects sensitive caller-supplied paths before any filesystem stat" do
        result = described_class.call(path: "../../config/master.key")
        text = result.content.first[:text]
        expect(text).to match(/not allowed|denied|sensitive/)
      end

      it "denies a sensitive name under app/views" do
        result = described_class.call(path: ".env")
        expect(result.error?).to be(true)
        expect(result.content.first[:text]).to eq("Path not allowed: .env (sensitive file)")
      end
    end

    # The payload-less listing reads the same app/views directory, so its
    # heading has to reconcile against the same files.
    context "when the payload carries no views section" do
      before { allow(described_class).to receive(:cached_context).and_return({}) }

      it "counts layouts and partials in the heading it reads off disk" do
        text = described_class.call(detail: "summary").content.first[:text]

        expect(text).to match(/# Views \(\d+ templates?, \d+ partials?, \d+ layouts?\)/)
      end

      it "answers the pointer its own heading prints" do
        heading = described_class.call(detail: "summary").content.first[:text]
        expect(heading).to include('`controller:"layouts"`')

        text = described_class.call(controller: "layouts", detail: "summary").content.first[:text]

        expect(text).to include("layouts/application.html.erb")
      end

      it "leaves layouts out of the heading when the listing is one controller" do
        text = described_class.call(controller: "posts", detail: "summary").content.first[:text]

        expect(text).to match(/# Views \(\d+ templates?, \d+ partials?\)/)
        expect(text).not_to include("layout)")
      end
    end

    context "with a controller that declares its layout" do
      around do |example|
        Dir.mktmpdir("view-layout") do |root|
          FileUtils.mkdir_p(File.join(root, "app/views/layouts"))
          FileUtils.mkdir_p(File.join(root, "app/views/users"))
          File.write(File.join(root, "app/views/layouts/admin.html.erb"), "")
          File.write(File.join(root, "app/views/users/index.html.erb"), "<h1>Users</h1>\n")
          @root = root
          example.run
        end
      end

      before do
        allow(described_class).to receive(:rails_app).and_return(RailsAiContext::StaticApp.new(@root))
        allow(described_class).to receive(:cached_context).and_return(
          view_templates: { templates: { "users/index.html.erb" => { lines: 1 } }, partials: {} },
          controllers: { controllers: { "UsersController" => { parent_class: "ActionController::Base", layout: { name: "admin", only: [ "index" ] },
                                                               file: "app/controllers/users_controller.rb" } } }
        )
      end

      it "says which layout the controller's views render in, at every detail level" do
        %w[summary standard full].each do |detail|
          text = described_class.call(controller: "users", detail: detail).content.first[:text]

          expect(text).to include("**Layout:** `admin` (declared in UsersController, only: index); other actions: none")
        end
      end
    end

    # The controller's full listing printed each template as written, while
    # the same template read by path, and every layout, had its secrets
    # filtered.
    context "with a template and a partial that hold a literal secret" do
      around do |example|
        Dir.mktmpdir("view-secrets") do |root|
          FileUtils.mkdir_p(File.join(root, "app/views/posts"))
          File.write(File.join(root, "app/views/posts/show.html.erb"), <<~ERB)
            <% api_key = "FAKE-VIEW-KEY-0009" %>
            <%= render "posts/post", post: @post, token: "FAKE-RENDER-SITE-TOKEN-0010" %>
          ERB
          File.write(File.join(root, "app/views/posts/_post.html.erb"), <<~ERB)
            <% secret = "FAKE-PARTIAL-SECRET-0011" %>
            <%= post.title %>
          ERB
          @root = root
          example.run
        end
      end

      before do
        allow(described_class).to receive(:rails_app).and_return(RailsAiContext::StaticApp.new(@root))
        allow(described_class).to receive(:cached_context).and_return(
          view_templates: { templates: { "posts/show.html.erb" => { lines: 2 } }, partials: { "posts/_post.html.erb" => { lines: 2 } } }
        )
      end

      it "filters them in the controller's full listing, as a read by path does" do
        text = described_class.call(controller: "posts", detail: "full").content.first[:text]
        by_path = described_class.call(path: "posts/show.html.erb").content.first[:text]

        expect(text).not_to include("FAKE-")
        expect(text).to include(%(<% api_key = "[FILTERED]" %>), %(token: "[FILTERED]" %>), %(<% secret = "[FILTERED]" %>))
        expect(text).to include("<%= post.title %>")
        expect(by_path).to include(%(<% api_key = "[FILTERED]" %>))
      end
    end

    # A template at the root of app/views has no directory. Splitting its key
    # on "/" made its own filename the group, so the group was empty, the row
    # never printed, and the header counted a file the body never listed.
    context "with a template directly under app/views" do
      before do
        allow(described_class).to receive(:cached_context).and_return(
          view_templates: {
            templates: {
              "notice.text.erb" => { lines: 2 },
              "pdfs/summary.html.erb" => { lines: 2 }
            },
            partials: {}
          }
        )
      end

      it "lists the root template in the standard listing" do
        text = described_class.call.content.first[:text]

        expect(text).to include("# Views (2 templates, 0 partials")
        expect(text).to include("notice.text.erb")
        expect(text).to include("pdfs/summary.html.erb")
      end

      it "groups it under a root heading rather than under its own filename" do
        text = described_class.call(detail: "summary").content.first[:text]

        expect(text).to include("## (app/views root)")
        expect(text).not_to include("## notice.text.erb/")
      end

      # "(" sorts before every letter, so a plain sort put the bucket that is
      # not a directory ahead of every directory.
      it "lists the root group after the directories" do
        text = described_class.call(detail: "summary").content.first[:text]

        expect(text.index("## pdfs")).to be < text.index("## (app/views root)")
      end

      it "does not offer the filename as a directory to filter by" do
        text = described_class.call(controller: "notice").content.first[:text]

        expect(text).to include("Directories with views: pdfs")
        expect(text).not_to include("notice.text.erb")
      end

      it "names it once in the full listing of directories" do
        text = described_class.call(detail: "full").content.first[:text]

        expect(text).to include("`controller:\"pdfs\"`")
        expect(text).not_to include("`controller:\"notice.text.erb\"`")
      end

      # The root bucket is not a directory, so offering it as a filter is the
      # same dead end the filename group was.
      it "does not offer the root bucket as a controller to filter by" do
        text = described_class.call(detail: "full").content.first[:text]

        expect(text).not_to include("controller:\"(app/views root)\"")
        # The old grouping offered the template's own filename as a directory,
        # which matched nothing when passed back.
        expect(text).not_to include("controller:\"notice.text.erb\"")
        expect(text.scan(/controller:"(?!layouts")/).size).to eq(1)
        expect(text).to include("`path:")
      end
    end

    context "when the app is API-only" do
      around do |example|
        Dir.mktmpdir("api-no-views") do |dir|
          @root = dir
          example.run
        end
      end

      before do
        allow(RailsAiContext).to receive(:default_app).and_return(RailsAiContext::StaticApp.new(@root))
        allow(described_class).to receive(:cached_context).and_return(
          api: { api_only: true },
          view_templates: { templates: {}, partials: {} }
        )
      end

      it "reports API-only apps as not applicable instead of an empty listing" do
        response = described_class.call(controller: "users")
        text = response.content.first[:text]
        expect(text).to include("Not applicable")
        expect(text).to include("API-only")
      end
    end

    context "when the app is API-only but has real views (e.g. mailer templates)" do
      before do
        allow(described_class).to receive(:cached_context).and_return(
          api: { api_only: true },
          view_templates: {
            templates: { "user_mailer/welcome.html.erb" => { lines: 10 } },
            partials: {}
          }
        )
      end

      it "says unbooted that the views of the engine a test/dummy runs in are not read" do
        allow(RailsAiContext).to receive(:static_tier?).and_return(true)
        allow(RailsAiContext::PathResolver).to receive(:test_root).and_return("/engine")

        text = described_class.call(controller: "posts").content.first[:text]
        expect(text).to include("_The views of the engine this app runs in are read only with the app booted._")
      end

      it "says unbooted in the view listing and on a path miss that the engine's views are not read" do
        allow(RailsAiContext).to receive(:static_tier?).and_return(true)
        allow(RailsAiContext::PathResolver).to receive(:test_root).and_return("/engine")
        note = "_The views of the engine this app runs in are read only with the app booted._"

        expect(described_class.call.content.first[:text]).to include(note)
        expect(described_class.call(path: "b3eng/widgets/show.html.erb").content.first[:text]).to include(note)
      end

      it "keeps the original recovery copy for a controller filter miss instead of the API-only note" do
        response = described_class.call(controller: "posts")
        text = response.content.first[:text]
        expect(text).to include("No views for 'posts'")
        expect(text).to include("Directories with views: user_mailer")
        expect(text).not_to include("Not applicable")
      end

      it "lists the real views for the unfiltered default call" do
        response = described_class.call
        text = response.content.first[:text]
        expect(text).to include("user_mailer/welcome.html.erb")
        expect(text).not_to include("Not applicable")
      end
    end

    context "when the app is API-only with zero views anywhere and no controller filter" do
      around do |example|
        Dir.mktmpdir("api-no-views") do |dir|
          @root = dir
          example.run
        end
      end

      before do
        allow(RailsAiContext).to receive(:default_app).and_return(RailsAiContext::StaticApp.new(@root))
        allow(described_class).to receive(:cached_context).and_return(
          api: { api_only: true },
          view_templates: { templates: {}, partials: {} }
        )
      end

      it "reports API-only apps as not applicable for the default unfiltered listing" do
        response = described_class.call
        text = response.content.first[:text]
        expect(text).to include("Not applicable")
        expect(text).to include("API-only")
      end
    end

    context "when the app is API-only and keeps the two mailer layouts rails new creates" do
      around do |example|
        Dir.mktmpdir("api-mailer-layouts") do |dir|
          FileUtils.mkdir_p(File.join(dir, "config"))
          File.write(File.join(dir, "config/application.rb"), "module Demo\n  class Application < Rails::Application\n    config.api_only = true\n  end\nend\n")
          layouts = File.join(dir, "app/views/layouts")
          FileUtils.mkdir_p(layouts)
          File.write(File.join(layouts, "mailer.html.erb"), "<html><body><%= yield %></body></html>\n")
          File.write(File.join(layouts, "mailer.text.erb"), "<%= yield %>\n")
          @root = dir
          example.run
        end
      end

      before do
        allow(RailsAiContext).to receive(:default_app).and_return(RailsAiContext::StaticApp.new(@root))
        allow(described_class).to receive(:cached_context).and_return(
          api: { api_only: true },
          view_templates: { templates: {}, partials: {} }
        )
      end

      it "counts the layouts instead of saying app/views does not exist" do
        text = described_class.call.content.first[:text]

        expect(text).not_to include("does not exist")
        expect(text).to include("# Views (0 templates, 0 partials, 2 layouts)")
      end

      it "points the full listing at the layouts" do
        text = described_class.call(detail: "full").content.first[:text]

        expect(text).to include("- `controller:\"layouts\"` (2 layouts)")
      end

      it "says a controller filter miss is a miss, not a missing directory" do
        text = described_class.call(controller: "users").content.first[:text]

        expect(text).not_to include("does not exist")
        expect(text).to include("No views for 'users'. The app has only layouts, listed by `controller:\"layouts\"`.")
      end
    end

    context "when the app puts a view path before app/views, inside it" do
      around do |example|
        Dir.mktmpdir("declared-view-path") do |dir|
          FileUtils.mkdir_p(File.join(dir, "config"))
          File.write(File.join(dir, "config/application.rb"), "config.paths[\"app/views\"].unshift(Rails.root.join(\"app/views/custom\").to_s)\n")
          FileUtils.mkdir_p(File.join(dir, "app/views/custom/posts"))
          File.write(File.join(dir, "app/views/custom/posts/show.html.erb"), "<h1>Post</h1>\n")
          File.write(File.join(dir, "app/views/posts/index.html.erb").tap { |f| FileUtils.mkdir_p(File.dirname(f)) }, "<h1>Posts</h1>\n")
          @root = dir
          example.run
        end
      end

      before do
        allow(RailsAiContext).to receive(:default_app).and_return(RailsAiContext::StaticApp.new(@root))
        allow(described_class).to receive(:cached_context).and_return({})
      end

      it "files its template under the controller that renders it" do
        expect(described_class.call(controller: "posts").content.first[:text]).to include("- posts/index.html.erb", "- posts/show.html.erb")
        expect(described_class.call.content.first[:text]).not_to include("custom/")
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

  describe "a variant and a locale of one template" do
    around do |example|
      Dir.mktmpdir("view-alternates") do |dir|
        @root = File.realpath(dir)
        FileUtils.mkdir_p(File.join(@root, "app/views/posts"))
        File.write(File.join(@root, "app/views/posts/show.html.erb"), "<%= @post.title %>\n")
        File.write(File.join(@root, "app/views/posts/show.html+mobile.erb"), "<%= @post.title %>\n")
        File.write(File.join(@root, "app/views/posts/show.fr.html.erb"), "<%= @post.title %>\n")
        example.run
      end
    end

    before { allow(RailsAiContext).to receive(:default_app).and_return(RailsAiContext::StaticApp.new(@root)) }

    let(:templates) do
      %w[posts/show.html.erb posts/show.html+mobile.erb posts/show.fr.html.erb].to_h { |t| [ t, { lines: 1 } ] }
    end

    %w[summary standard].each do |detail|
      it "ties each to show in the #{detail} listing" do
        allow(described_class).to receive(:cached_context).and_return(view_templates: { templates: templates, partials: {} })
        text = described_class.call(controller: "posts", detail: detail).content.first[:text]

        expect(text).to match(/posts\/show\.html\+mobile\.erb\** \(1 line\).*`mobile` variant of `show`/)
        expect(text).to match(/posts\/show\.fr\.html\.erb\** \(1 line\).*`fr` locale of `show`/)
        expect(text).not_to match(/posts\/show\.html\.erb.*of `show`/)
      end
    end

    %w[summary standard].each do |detail|
      it "ties a partial's variant to its partial in the #{detail} listing" do
        partials = { "posts/_card.html.erb" => { lines: 1 }, "posts/_card.html+mobile.erb" => { lines: 1, fields: %w[title] } }
        allow(described_class).to receive(:cached_context).and_return(view_templates: { templates: {}, partials: partials })
        text = described_class.call(controller: "posts", detail: detail).content.first[:text]

        expect(text).to match(/posts\/_card\.html\+mobile\.erb \(1 line\) `mobile` variant of `card`/)
        expect(text).not_to match(/posts\/_card\.html\.erb.*of `card`/)
      end
    end

    it "labels a locale the app makes available in any spelling, unbooted from the i18n section" do
      listing = { templates: { "posts/index.zh-Hant.html.erb" => { lines: 1 } }, partials: {} }
      allow(described_class).to receive(:cached_context).and_return(view_templates: listing, i18n: { available_locales: [ "zh-Hant" ] })

      expect(described_class.call(controller: "posts", detail: "summary").content.first[:text]).to include("`zh-Hant` locale of `index`")
    end

    it "labels a locale the app makes available in any spelling, booted from I18n" do
      listing = { templates: { "posts/index.zh-Hant.html.erb" => { lines: 1 } }, partials: {} }
      allow(RailsAiContext).to receive(:default_app).and_return(Rails.application)
      allow(described_class).to receive(:cached_context).and_return(view_templates: listing)
      allow(I18n).to receive(:available_locales).and_return([ :en, :"zh-Hant" ])

      expect(described_class.call(controller: "posts", detail: "summary").content.first[:text]).to include("`zh-Hant` locale of `index`")
    end

    it "ties each to show when the listing is read off disk" do
      allow(described_class).to receive(:cached_context).and_return({})
      text = described_class.call(controller: "posts", detail: "summary").content.first[:text]

      expect(text).to include("- posts/show.html+mobile.erb - `mobile` variant of `show`")
      expect(text).to include("- posts/show.fr.html.erb - `fr` locale of `show`")
    end
  end
end
