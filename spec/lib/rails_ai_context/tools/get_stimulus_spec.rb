# frozen_string_literal: true

require "spec_helper"

RSpec.describe RailsAiContext::Tools::GetStimulus do
  before { described_class.reset_cache! }

  let(:stimulus_data) do
    {
      controllers: [
        { name: "hello", targets: %w[name output], actions: %w[greet], values: { "name" => "String" }, outlets: [], classes: [], lifecycle: %w[connect disconnect], file: "hello_controller.js" },
        { name: "search", targets: %w[input results], actions: %w[search clear], values: {}, outlets: %w[hello], classes: %w[active], file: "search_controller.js" },
        { name: "infinite-scroll", targets: [], actions: [], values: { "url" => "String", "page" => "Number" }, outlets: [], classes: [], file: "infinite_scroll_controller.js" }
      ]
    }
  end

  before do
    allow(described_class).to receive(:cached_context).and_return({ stimulus: stimulus_data })
  end

  describe ".call" do
    it "lists controllers with counts for detail:summary" do
      result = described_class.call(detail: "summary")
      text = result.content.first[:text]
      expect(text).to include("**hello** - 2 targets, 1 value, 1 action")
      expect(text).to include("**search** - 2 targets, 2 actions")
    end

    it "lists controllers with targets, values, and actions for detail:standard" do
      result = described_class.call(detail: "standard")
      text = result.content.first[:text]
      expect(text).to include("## hello")
      expect(text).to include("Targets: name, output")
      expect(text).to include("Values: name (String)")
      expect(text).to include("Actions: greet")
    end

    it "shows everything for detail:full" do
      result = described_class.call(detail: "full")
      text = result.content.first[:text]
      expect(text).to include("**Values:** name:String")
      expect(text).to include("**Outlets:** hello")
      expect(text).to include("**Classes:** active")
    end

    it "returns full detail for specific controller" do
      result = described_class.call(controller: "hello")
      text = result.content.first[:text]
      expect(text).to include("## hello")
      expect(text).to include("**Targets:**")
      expect(text).to include("**File:** hello_controller.js")
    end

    it "renders the lifecycle the introspector recorded without reading the file" do
      allow(RailsAiContext::SafeFile).to receive(:read).and_call_original

      text = described_class.call(controller: "hello", detail: "full").content.first[:text]

      expect(text).to include("- **Lifecycle:** connect, disconnect")
      # Matched on to_s: the old code passed a Pathname, which a string matcher
      # would have let through.
      expect(RailsAiContext::SafeFile).not_to have_received(:read)
        .with(satisfy { |path| path.to_s.end_with?("hello_controller.js") })
    end

    it "supports case-insensitive lookup" do
      result = described_class.call(controller: "HELLO")
      text = result.content.first[:text]
      expect(text).to include("## hello")
    end

    it "shows values-only controllers in summary (not lifecycle only)" do
      result = described_class.call(detail: "summary")
      text = result.content.first[:text]
      expect(text).to include("**infinite-scroll** - 2 values")
      expect(text).not_to include("infinite-scroll_ (lifecycle only)")
    end

    it "shows values for values-only controllers in standard detail" do
      result = described_class.call(detail: "standard")
      text = result.content.first[:text]
      expect(text).to include("## infinite-scroll")
      expect(text).to include("Values: url (String), page (Number)")
    end

    it "handles missing controller" do
      result = described_class.call(controller: "nonexistent")
      text = result.content.first[:text]
      expect(text).to include("not found")
      expect(text).to include("hello")
      expect(text).to include("search")
    end

    it "handles missing stimulus data" do
      allow(described_class).to receive(:cached_context).and_return({})
      result = described_class.call
      text = result.content.first[:text]
      expect(text).to include("not available")
    end

    it "handles empty controllers" do
      allow(described_class).to receive(:cached_context).and_return({ stimulus: { controllers: [] } })
      result = described_class.call
      text = result.content.first[:text]
      expect(text).to include("No Stimulus controllers")
    end

    context "with a template naming two controllers" do
      before do
        allow(described_class).to receive(:cached_context).and_return(
          stimulus: {
            controllers: [ { name: "modal", targets: [ "body" ], actions: [ "open" ] } ],
            cross_controller_composition: [ { file: "posts/_modal.html.erb", controllers: %w[modal hello] } ]
          }
        )
      end

      # The row used to interpolate the introspector's hash straight into the
      # answer, so the reader got Ruby syntax instead of a file and its controllers.
      it "renders the composition as prose in standard detail" do
        text = described_class.call.content.first[:text]
        expect(text).to include("- `posts/_modal.html.erb` - modal + hello")
        expect(text).not_to include("{file:")
      end

      it "renders the composition as prose in full detail" do
        text = described_class.call(detail: "full").content.first[:text]
        expect(text).to include("- `posts/_modal.html.erb` - modal + hello")
        expect(text).not_to include("{file:")
      end
    end

    context "when a view is not ERB" do
      around do |example|
        Dir.mktmpdir("stimulus-views") do |dir|
          @root = dir
          FileUtils.mkdir_p(File.join(dir, "app/views/posts"))
          File.write(File.join(dir, "app/views/posts/index.html.haml"),
                     "%div{ data: { controller: \"hello\" } }\n")
          File.write(File.join(dir, "app/views/posts/show.html.slim"),
                     "div data-controller=\"hello\"\n")
          example.run
        end
      end

      before do
        allow(RailsAiContext).to receive(:default_app).and_return(RailsAiContext::StaticApp.new(@root))
      end

      it "lists haml and slim views that use the controller" do
        text = described_class.call(controller: "hello").content.first[:text]

        expect(text).to include("posts/index.html.haml")
        expect(text).to include("posts/show.html.slim")
      end
    end

    context "when a view merely mentions the controller name" do
      around do |example|
        Dir.mktmpdir("stimulus-views") do |dir|
          @root = dir
          FileUtils.mkdir_p(File.join(dir, "app/views/posts"))
          File.write(File.join(dir, "app/views/posts/mentions.html.erb"),
                     "<%= t(\"devise.mailer.hello\") %>\n")
          File.write(File.join(dir, "app/views/posts/routes.html.erb"),
                     "<%= url_for(controller: \"hello\") %>\n")
          File.write(File.join(dir, "app/views/posts/uses.html.erb"),
                     "<div data-controller=\"hello\"></div>\n")
          example.run
        end
      end

      before do
        allow(RailsAiContext).to receive(:default_app).and_return(RailsAiContext::StaticApp.new(@root))
      end

      it "lists only the views whose markup names it as a Stimulus controller" do
        text = described_class.call(controller: "hello").content.first[:text]

        expect(text).to include("posts/uses.html.erb")
        expect(text).not_to include("posts/mentions.html.erb")
        expect(text).not_to include("posts/routes.html.erb")
      end
    end

    context "when a view names the controller only through a target or a helper" do
      around do |example|
        Dir.mktmpdir("stimulus-views") do |dir|
          @root = dir
          FileUtils.mkdir_p(File.join(dir, "app/views/posts"))
          File.write(File.join(dir, "app/views/posts/helper.html.erb"),
                     %(<% content_controller "hello" %>\n))
          File.write(File.join(dir, "app/views/posts/target.html.erb"),
                     %(<div data-hello-target="row"></div>\n))
          File.write(File.join(dir, "app/views/posts/prose.html.erb"),
                     %(<p>say hello</p>\n))
          example.run
        end
      end

      before do
        allow(RailsAiContext).to receive(:default_app).and_return(RailsAiContext::StaticApp.new(@root))
      end

      it "lists them and still skips the one that only mentions the word" do
        text = described_class.call(controller: "hello").content.first[:text]

        expect(text).to include("posts/helper.html.erb")
        expect(text).to include("posts/target.html.erb")
        expect(text).not_to include("posts/prose.html.erb")
      end
    end

    context "when a name could not be confirmed" do
      before do
        allow(described_class).to receive(:cached_context).and_return(
          stimulus: {
            controllers: [ { name: "users--tools--ajax", identifier_inferred: true, targets: [ "row" ], file: "app/javascript/admin/controllers/users/tools/ajax_controller.js" } ]
          }
        )
      end

      it "names the real condition, not a missing controllers directory" do
        text = described_class.call.content.first[:text]

        expect(text).to include("outside `app/javascript/controllers`")
        expect(text).to include("no view or component writes")
        expect(text).not_to include("no `controllers/` directory")
      end

      it "names it the same way in one controller's own detail" do
        text = described_class.call(controller: "users--tools--ajax").content.first[:text]

        expect(text).to include("outside `app/javascript/controllers`")
        expect(text).not_to include("no `controllers/` directory")
      end
    end

    context "when the caller asks by the file-path spelling" do
      before do
        allow(described_class).to receive(:cached_context).and_return(
          stimulus: {
            controllers: [ { name: "admin--custom-fields", path_name: "dynamic--admin--custom-fields",
                             targets: [ "row" ], file: "frontend/src/stimulus/controllers/dynamic/admin/custom-fields.controller.ts" } ]
          }
        )
      end

      it "resolves the path spelling to the name the app uses" do
        text = described_class.call(controller: "dynamic--admin--custom-fields").content.first[:text]

        expect(text).to include("## admin--custom-fields")
        expect(text).not_to include("not found")
      end

      it "says how lookup works without claiming underscores" do
        text = described_class.call(controller: "nope").content.first[:text]

        expect(text).to include("not found")
        expect(text).not_to include("use dashes in HTML, underscores for lookup")
      end
    end

    context "when one controller's path spelling is another's name" do
      before do
        allow(described_class).to receive(:cached_context).and_return(
          stimulus: {
            controllers: [
              { name: "chat--foo", path_name: "foo", identifier_inferred: true, targets: [ "plugin" ],
                file: "admin_plugin/app/javascript/controllers/foo_controller.js" },
              { name: "foo", targets: [ "app" ], file: "app/javascript/controllers/foo_controller.js" }
            ]
          }
        )
      end

      it "answers with the controller that is called that" do
        text = described_class.call(controller: "foo").content.first[:text]

        expect(text).to start_with("## foo\n")
        expect(text).to include("**Targets:** app")
      end
    end

    context "when a controller comes from a package" do
      before do
        allow(described_class).to receive(:cached_context).and_return(
          stimulus: { controllers: [ { name: "reveal", package: "@stimulus-components/reveal" } ] }
        )
      end

      it "lists it as registered from the package, not as lifecycle-only" do
        %w[summary standard].each do |detail|
          text = described_class.call(detail: detail).content.first[:text]

          expect(text).to include("# Stimulus Controllers (1)")
          expect(text).to include("reveal (`@stimulus-components/reveal`)")
          expect(text).not_to include("lifecycle only")
          expect(text).not_to include("Lifecycle only")
        end
      end

      it "says where it came from in its own detail" do
        text = described_class.call(controller: "reveal").content.first[:text]

        expect(text).to include("## reveal")
        expect(text).to include("**Registered from package:** `@stimulus-components/reveal`")
      end
    end

    context "when the caller spells the controller the way it sits on disk" do
      before do
        allow(described_class).to receive(:cached_context).and_return(
          stimulus: {
            controllers: [
              { name: "users--tools--ajax", targets: [ "row" ], file: "app/javascript/admin/controllers/users/tools/ajax_controller.js" },
              { name: "admin--custom-fields", path_name: "dynamic--admin--custom-fields", targets: [ "row" ],
                file: "frontend/src/stimulus/controllers/dynamic/admin/custom-fields.controller.ts" }
            ]
          }
        )
      end

      {
        "users/tools/ajax" => "users--tools--ajax",
        "users__tools__ajax" => "users--tools--ajax",
        "users/tools/ajax_controller.js" => "users--tools--ajax",
        "app/javascript/admin/controllers/users/tools/ajax_controller.js" => "users--tools--ajax",
        "dynamic/admin/custom-fields" => "admin--custom-fields",
        "dynamic/admin/custom_fields.controller.ts" => "admin--custom-fields"
      }.each do |asked, found|
        it "resolves #{asked}" do
          text = described_class.call(controller: asked).content.first[:text]

          expect(text).to start_with("## #{found}\n")
        end
      end
    end

    context "when the caller gives only part of the path, or its file name" do
      before do
        allow(described_class).to receive(:cached_context).and_return(
          stimulus: {
            controllers: [
              { name: "users--tools--ajax", targets: [ "row" ], file: "app/javascript/admin/controllers/users/tools/ajax_controller.js" },
              { name: "admin--list", targets: [ "a" ], file: "app/javascript/controllers/admin/list_controller.js" },
              { name: "public--list", targets: [ "b" ], file: "app/javascript/controllers/public/list_controller.js" }
            ]
          }
        )
      end

      it "resolves the file name when one controller has it" do
        expect(described_class.call(controller: "ajax_controller.js").content.first[:text]).to start_with("## users--tools--ajax\n")
      end

      it "resolves the path written with single underscores" do
        expect(described_class.call(controller: "users_tools_ajax").content.first[:text]).to start_with("## users--tools--ajax\n")
      end

      it "lists every controller a shared file name could mean, rather than picking one" do
        text = described_class.call(controller: "list_controller.js").content.first[:text]

        expect(text).to include("matches 2 controllers")
        expect(text).to include("admin--list", "public--list")
        expect(text).not_to include("## admin--list")
      end
    end

    context "when the controller is written outside app/views" do
      around do |example|
        Dir.mktmpdir("stimulus-views") do |dir|
          @root = dir
          FileUtils.mkdir_p(File.join(dir, "app/views/posts"))
          File.write(File.join(dir, "app/views/posts/index.html.erb"), %(<div data-controller="hello"></div>\n))
          FileUtils.mkdir_p(File.join(dir, "lib/primer/forms"))
          File.write(File.join(dir, "lib/primer/forms/segmented.html.erb"), %(<div data-controller="hello"></div>\n))
          FileUtils.mkdir_p(File.join(dir, "app/forms"))
          File.write(File.join(dir, "app/forms/defaults_form.rb"),
                     %(class DefaultsForm\n  def data = { action: "hello#greet" }\nend\n))
          example.run
        end
      end

      before do
        allow(RailsAiContext).to receive(:default_app).and_return(RailsAiContext::StaticApp.new(@root))
      end

      it "lists every file that names it, from the file set naming reads, views first" do
        text = described_class.call(controller: "hello").content.first[:text]
        used = text[/### Used in\n(.*)/m, 1]

        expect(used.lines.map(&:strip).reject(&:empty?).first(3))
          .to eq([ "- `posts/index.html.erb`", "- `app/forms/defaults_form.rb`", "- `lib/primer/forms/segmented.html.erb`" ])
      end
    end

    context "when the app is API-only" do
      before do
        allow(described_class).to receive(:cached_context).and_return(
          api: { api_only: true },
          stimulus: { controllers: [] }
        )
      end

      it "reports API-only apps as not applicable instead of an empty listing" do
        result = described_class.call
        text = result.content.first[:text]
        expect(text).to include("Not applicable")
        expect(text).to include("API-only")
      end
    end
  end
end
