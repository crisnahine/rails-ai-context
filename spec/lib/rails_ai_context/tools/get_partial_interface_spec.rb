# frozen_string_literal: true

require "spec_helper"

RSpec.describe RailsAiContext::Tools::GetPartialInterface do
  before { described_class.reset_cache! }

  describe "an implicit render of a collection or record" do
    around do |example|
      Dir.mktmpdir("implicit-render") do |dir|
        @root = dir
        views = File.join(dir, "app/views")
        %w[admin/posts posts sessions shared].each { |d| FileUtils.mkdir_p(File.join(views, d)) }
        FileUtils.mkdir_p(File.join(dir, "app/models"))
        File.write(File.join(views, "admin/posts/index.html.erb"), "<%= render @posts %>\n")
        File.write(File.join(views, "admin/posts/_post.html.erb"), "<%= post.title %>\n")
        File.write(File.join(views, "posts/show.html.erb"), "<h1>Post</h1>\n\n<%= render @post %>\n")
        File.write(File.join(views, "posts/_post.html.erb"), "<%= post.title %>\n")
        File.write(File.join(views, "sessions/index.html.erb"), "<%= render @sessions %>\n")
        File.write(File.join(views, "shared/_session_row.html.erb"), "<%= session_row.id %>\n")
        File.write(File.join(dir, "app/models/session.rb"),
                   "class Session < ApplicationRecord\n  def to_partial_path\n    \"shared/session_row\"\n  end\nend\n")
        example.run
      end
    end

    before do
      allow(RailsAiContext).to receive(:default_app).and_return(RailsAiContext::StaticApp.new(@root))
      allow(described_class).to receive(:cached_context).and_return({})
    end

    def rendered_from(name)
      described_class.call(partial: name).content.first[:text][/## Rendered From.*?(?=\n\n|\z)/m]
    end

    it "credits a namespaced view to the partial under its namespace" do
      expect(rendered_from("admin/posts/post")).to eq("## Rendered From (1)\n- `app/views/admin/posts/index.html.erb:1`")
      expect(rendered_from("posts/post")).to eq("## Rendered From (1)\n- `app/views/posts/show.html.erb:3`")
    end

    it "follows a to_partial_path the model defines" do
      expect(rendered_from("shared/session_row")).to eq("## Rendered From (1)\n- `app/views/sessions/index.html.erb:1`")
      expect(rendered_from("session_row")).to eq("## Rendered From (1)\n- `app/views/sessions/index.html.erb:1`")
    end

    it "drops the namespace when the app turns the prefix off" do
      FileUtils.mkdir_p(File.join(@root, "config"))
      File.write(File.join(@root, "config/application.rb"), <<~RUBY)
        module Demo
          class Application < Rails::Application
            config.action_view.prefix_partial_path_with_controller_namespace = false
          end
        end
      RUBY

      expect(rendered_from("admin/posts/post")).to be_nil
      expect(rendered_from("posts/post")).to include("app/views/admin/posts/index.html.erb:1", "app/views/posts/show.html.erb:3")
    end
  end

  describe "a strict locals comment in each form Rails accepts" do
    around do |example|
      Dir.mktmpdir("strict-locals") do |dir|
        @root = dir
        notes = File.join(dir, "app/views/notes")
        FileUtils.mkdir_p(notes)
        File.write(File.join(notes, "_dash.html.erb"), %(<%# locals: (title:, tone: "plain") -%>\n<p class="<%= tone %>"><%= title %></p>\n))
        File.write(File.join(notes, "_paren.html.erb"), %(<%# locals: (title: t(".heading"), tone: "plain") %>\n<p class="<%= tone %>"><%= title %></p>\n))
        File.write(File.join(notes, "_none.html.erb"), "<%# locals: () %>\n<p>static</p>\n")
        example.run
      end
    end

    before do
      allow(RailsAiContext).to receive(:default_app).and_return(RailsAiContext::StaticApp.new(@root))
      allow(described_class).to receive(:cached_context).and_return({})
    end

    def interface(name)
      described_class.call(partial: "notes/#{name}").content.first[:text]
    end

    it "reads a comment that ends in -%>" do
      expect(interface("dash")).to include("**Declared locals** (Rails 7.1+ magic comment): title, tone")
    end

    it "reads a default that has parentheses" do
      expect(interface("paren")).to include("**Declared locals** (Rails 7.1+ magic comment): title, tone")
    end

    it "names a keyword rest, which lets any other local through" do
      File.write(File.join(@root, "app/views/notes/_rest.html.erb"), "<%# locals: (title:, **opts) %>\n<%= title %>\n")

      expect(interface("rest")).to include("**Declared locals** (Rails 7.1+ magic comment): title, **opts")
    end

    it "degrades on a partial whose bytes are not valid UTF-8" do
      File.binwrite(File.join(@root, "app/views/notes/_bad.html.erb"), "<%# locals: (title:) %>\n\xFF\xFE<%= title %>\n".b)

      expect { interface("bad") }.not_to raise_error
    end

    it "says an empty list rejects every local" do
      text = interface("none")

      expect(text).to include("**Declared locals** (Rails 7.1+ magic comment): none, so passing any local raises")
      expect(text).not_to include("No local variables detected")
    end
  end

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

    it "offers only templates as available partials" do
      File.write(File.join(@root, "app/views/pdfs/_banner.png"), "not a template")
      FileUtils.mkdir_p(File.join(@root, "app/views/pdfs/_bits"))

      text = described_class.call(partial: "missing/thing").content.first[:text]
      available = text[/^Available: .*$/]

      expect(available).to include("pdfs/summary_fields")
      expect(available).not_to include("pdfs/banner")
      expect(available).not_to include("pdfs/bits")
    end

    it "resolves a .text.erb partial by its Rails name" do
      text = described_class.call(partial: "reports/ai_data/header").content.first[:text]

      expect(text).not_to include("not found")
      expect(text).to include("reports/ai_data/_header.text.erb")
    end

    it "finds a render(partial:) call written with parentheses, on one line or over several" do
      File.write(File.join(@root, "app/views/reports/ai_data/split.html.erb"), <<~ERB)
        <p>x</p>
        <%= render(
              partial: "reports/ai_data/header",
              locals: { title: @title }
            ) %>
        <%= render(partial: "reports/ai_data/header", locals: { order: @order }) %>
      ERB

      text = described_class.call(partial: "reports/ai_data/header", detail: "full").content.first[:text]

      expect(text).to include("`app/views/reports/ai_data/split.html.erb:2` - locals: title")
      expect(text).to include("`app/views/reports/ai_data/split.html.erb:6` - locals: order")
    end

    it "ends a snippet at the call's own last line" do
      File.write(File.join(@root, "app/views/reports/ai_data/badge.html.haml"),
                 "%div\n  = render \"reports/ai_data/header\", title: 1\n  %p next line\n")

      text = described_class.call(partial: "reports/ai_data/header", detail: "full").content.first[:text]

      expect(text).to include("app/views/reports/ai_data/badge.html.haml:2")
      expect(text).not_to include("next line")
    end

    it "counts a render nested in another render's arguments as one site" do
      File.write(File.join(@root, "app/views/reports/ai_data/nested.html.erb"),
                 "<%= render \"reports/ai_data/header\", a: render(\"reports/ai_data/header\") %>\n")

      text = described_class.call(partial: "reports/ai_data/header", detail: "full").content.first[:text]

      expect(text.scan("nested.html.erb:1").size).to eq(1)
    end

    it "says how many calls the list left out" do
      text = described_class.call(partial: "pdfs/summary_fields").content.first[:text]

      expect(text).to include("...and 8 more")
    end
  end

  describe "a partial that calls the app's own helpers" do
    around do |example|
      Dir.mktmpdir("partial-interface") do |dir|
        @root = dir
        FileUtils.mkdir_p(File.join(dir, "app/views/layouts"))
        File.write(File.join(dir, "app/views/layouts/_head.html.erb"),
                   "<%= theme_color_meta_tags %>\n<%= canonical_link_tag %>\n<%= admin_badge %>\n<%= title %>\n")
        FileUtils.mkdir_p(File.join(dir, "app/helpers"))
        File.write(File.join(dir, "app/helpers/application_helper.rb"),
                   "module ApplicationHelper\n  include CanonicalURL::Helpers\n\n  def theme_color_meta_tags = nil\nend\n")
        FileUtils.mkdir_p(File.join(dir, "plugins/chat/app/helpers"))
        FileUtils.mkdir_p(File.join(dir, "plugins/chat/app/models"))
        File.write(File.join(dir, "plugins/chat/plugin.rb"), "# plugin\n")
        File.write(File.join(dir, "plugins/chat/app/helpers/badges_helper.rb"),
                   "module BadgesHelper\n  def admin_badge = nil\nend\n")
        FileUtils.mkdir_p(File.join(dir, "lib"))
        File.write(File.join(dir, "lib/canonical_url.rb"),
                   "module CanonicalURL\n  module Helpers\n    def canonical_link_tag(url = nil) = nil\n  end\nend\n")
        RailsAiContext::PathResolver.clear_code_roots
        example.run
      end
    end

    before do
      allow(RailsAiContext).to receive(:default_app).and_return(RailsAiContext::StaticApp.new(@root))
      allow(described_class).to receive(:cached_context).and_return({})
    end

    it "reads a call to a helper the app defines, in app/helpers or a lib module they include, as no local" do
      text = described_class.call(partial: "layouts/head").content.first[:text]
      locals = text[/## Local Variables\n(.*?)\n\n/m, 1].to_s

      expect(locals).to include("title")
      expect(locals).not_to include("canonical_link_tag", "theme_color_meta_tags", "admin_badge")
    end
  end

  describe "the standard and full renderings" do
    around do |example|
      Dir.mktmpdir("partial-render") do |dir|
        @root = dir
        FileUtils.mkdir_p(File.join(dir, "app/views/widgets"))
        File.write(File.join(dir, "app/views/widgets/_card.html.erb"), <<~ERB)
          <%# locals: (widget:, size:) %>
          <div class="<%= size %>"><%= widget.title %><%= widget.body %></div>
        ERB
        File.write(File.join(dir, "app/views/widgets/index.html.erb"),
                   "<%= render \"widgets/card\", widget: @widget, size: \"lg\" %>\n")
        example.run
      end
    end

    before do
      allow(RailsAiContext).to receive(:default_app).and_return(RailsAiContext::StaticApp.new(@root))
      allow(described_class).to receive(:cached_context).and_return({})
    end

    it "renders the standard detail byte for byte" do
      text = described_class.call(partial: "widgets/card", detail: "standard").content.first[:text]

      expect(text).to eq(<<~MD.chomp)
        # Partial: widgets/_card.html.erb

        **File:** `app/views/widgets/_card.html.erb` (2 lines)
        **Declared locals** (Rails 7.1+ magic comment): widget, size

        ## Local Variables
        - **size**
        - **widget** - calls: body, title

        ## Rendered From (1)
        - `app/views/widgets/index.html.erb:1` - locals: widget, size

        _Next: `rails_get_view(path:"widgets/_card.html.erb")` for full file content_
      MD
    end

    it "renders the full detail byte for byte" do
      text = described_class.call(partial: "widgets/card", detail: "full").content.first[:text]

      expect(text).to eq(<<~MD.chomp)
        # Partial: widgets/_card.html.erb

        **File:** `app/views/widgets/_card.html.erb` (2 lines)
        **Declared locals** (Rails 7.1+ magic comment): widget, size

        ## Local Variables
        - **size**
        - **widget** - calls: body, title

        ## Rendered From (1)
        - `app/views/widgets/index.html.erb:1` - locals: widget, size
          ```erb
          <%= render "widgets/card", widget: @widget, size: "lg" %>
          ```

        ## Source
        ```erb
        <%# locals: (widget:, size:) %>
        <div class="<%= size %>"><%= widget.title %><%= widget.body %></div>

        ```
      MD
    end

    it "caps the render-site list per detail level" do
      (1..26).each do |i|
        File.write(File.join(@root, "app/views/widgets/page#{format('%02d', i)}.html.erb"),
                   "<%= render \"widgets/card\", widget: @widget, size: \"lg\" %>\n")
      end

      standard = described_class.call(partial: "widgets/card", detail: "standard").content.first[:text]
      full = described_class.call(partial: "widgets/card", detail: "full").content.first[:text]

      expect(standard.scan("- `app/views/widgets/").size).to eq(15)
      expect(full.scan("- `app/views/widgets/").size).to eq(25)
      expect(standard).to include("_...and 12 more_")
      expect(full).to include("_...and 2 more_")
    end

    it "says so when nothing renders the partial and it declares no locals" do
      File.write(File.join(@root, "app/views/widgets/_bare.html.erb"), "<p>hi</p>\n")

      text = described_class.call(partial: "widgets/bare", detail: "standard").content.first[:text]

      expect(text).to include("_No local variables detected in this partial._")
      expect(text).to include("_No render calls found for this partial._")
    end

    it "leaves both notes out of the full rendering" do
      File.write(File.join(@root, "app/views/widgets/_bare.html.erb"), "<p>hi</p>\n")

      text = described_class.call(partial: "widgets/bare", detail: "full").content.first[:text]

      expect(text).not_to include("_No local variables detected")
      expect(text).not_to include("_No render calls found")
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

    # Every Rails app has several `_form`, and answering a bare name with the
    # first one in sorted order gave one directory's locals for another's.
    it "asks which one instead of picking a bare name's first match" do
      views_dir = Rails.root.join("app", "views")
      dirs = %w[gpi_a gpi_b].map { |d| views_dir.join("#{d}_#{Process.pid}") }
      dirs.each do |dir|
        FileUtils.mkdir_p(dir)
        File.write(dir.join("_ambiguous_widget.html.erb"), "<%= widget %>")
      end

      text = described_class.call(partial: "ambiguous_widget").content.first[:text]

      expect(text).to include("matches")
      dirs.each { |dir| expect(text).to include("#{File.basename(dir)}/_ambiguous_widget.html.erb") }
    ensure
      dirs&.each { |dir| FileUtils.rm_rf(dir) }
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
