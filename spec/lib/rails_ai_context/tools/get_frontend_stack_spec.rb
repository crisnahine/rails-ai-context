# frozen_string_literal: true

require "spec_helper"

RSpec.describe RailsAiContext::Tools::GetFrontendStack do
  before { described_class.reset_cache! }

  # Mirrors the shape FrontendFrameworkIntrospector actually emits:
  # frameworks: is a hash of framework symbol => version requirement,
  # testing: and state_management: are arrays, mounting_strategy: a symbol.
  let(:frontend_data) do
    {
      frameworks: { react: "^19.0.0" },
      mounting_strategy: :inertia,
      build_tool: "vite",
      state_management: %w[Zustand],
      package_manager: "yarn",
      typescript: {
        enabled: true,
        strict: true,
        path_aliases: {
          "@components" => "src/components",
          "@utils" => "src/utils",
          "@hooks" => "src/hooks"
        }
      },
      testing: %w[Vitest React-Testing-Library],
      frontend_roots: [
        { path: "app/frontend", component_count: 32 },
        { path: "app/frontend/admin", component_count: 15 }
      ],
      monorepo: {
        detected: true,
        tool: "yarn workspaces",
        workspaces: %w[packages/ui packages/shared]
      },
      component_dirs: [
        { path: "app/frontend/components/shared", count: 18 },
        { path: "app/frontend/components/pages", count: 14 },
        { path: "app/frontend/admin/components", count: 15 }
      ],
      build_config: {
        plugins: %w[@vitejs/plugin-react vite-plugin-ruby vite-tsconfig-paths]
      }
    }
  end

  before do
    allow(described_class).to receive(:cached_context).and_return({ frontend_frameworks: frontend_data })
  end

  describe ".call" do
    context "with detail:summary" do
      it "returns a one-liner with framework, tools, and component count" do
        result = described_class.call(detail: "summary")
        text = result.content.first[:text]

        expect(text).to include("React 19.0.0")
        expect(text).to include("Inertia")
        expect(text).to include("Vite")
        expect(text).to include("TypeScript")
        expect(text).to include("Zustand")
        expect(text).to include("(47 components)")
      end
    end

    context "with detail:standard" do
      it "includes framework and version" do
        result = described_class.call(detail: "standard")
        text = result.content.first[:text]

        expect(text).to include("**Framework:** React 19.0.0")
      end

      it "includes mounting strategy" do
        result = described_class.call(detail: "standard")
        text = result.content.first[:text]

        expect(text).to include("**Mounting strategy:** Inertia")
      end

      it "includes build tool" do
        result = described_class.call(detail: "standard")
        text = result.content.first[:text]

        expect(text).to include("**Build tool:** Vite")
      end

      it "includes state management" do
        result = described_class.call(detail: "standard")
        text = result.content.first[:text]

        expect(text).to include("**State management:** Zustand")
      end

      it "includes package manager" do
        result = described_class.call(detail: "standard")
        text = result.content.first[:text]

        expect(text).to include("**Package manager:** yarn")
      end

      it "includes TypeScript with strict mode" do
        result = described_class.call(detail: "standard")
        text = result.content.first[:text]

        expect(text).to include("**TypeScript:** enabled (strict)")
      end

      it "includes testing frameworks" do
        result = described_class.call(detail: "standard")
        text = result.content.first[:text]

        expect(text).to include("**Testing:** Vitest, React-Testing-Library")
      end

      it "includes frontend roots with component counts" do
        result = described_class.call(detail: "standard")
        text = result.content.first[:text]

        expect(text).to include("Frontend Roots")
        expect(text).to include("`app/frontend` - 32 components")
        expect(text).to include("`app/frontend/admin` - 15 components")
      end

      it "shows non-strict when typescript strict is false" do
        frontend_data[:typescript][:strict] = false
        result = described_class.call(detail: "standard")
        text = result.content.first[:text]

        expect(text).to include("**TypeScript:** enabled (non-strict)")
      end
    end

    context "with detail:full" do
      it "includes everything from standard" do
        result = described_class.call(detail: "full")
        text = result.content.first[:text]

        expect(text).to include("**Framework:** React 19.0.0")
        expect(text).to include("**Build tool:** Vite")
        expect(text).to include("**State management:** Zustand")
        expect(text).to include("Frontend Roots")
      end

      it "includes TypeScript path aliases" do
        result = described_class.call(detail: "full")
        text = result.content.first[:text]

        expect(text).to include("TypeScript Path Aliases")
        expect(text).to include("`@components` -> `src/components`")
        expect(text).to include("`@utils` -> `src/utils`")
        expect(text).to include("`@hooks` -> `src/hooks`")
      end

      it "includes monorepo info" do
        result = described_class.call(detail: "full")
        text = result.content.first[:text]

        expect(text).to include("Monorepo")
        expect(text).to include("**Tool:** yarn workspaces")
        expect(text).to include("**Workspaces:** packages/ui, packages/shared")
      end

      it "includes component directory breakdown" do
        result = described_class.call(detail: "full")
        text = result.content.first[:text]

        expect(text).to include("Component Directories")
        expect(text).to include("`app/frontend/components/shared` - 18 components")
        expect(text).to include("`app/frontend/components/pages` - 14 components")
        expect(text).to include("`app/frontend/admin/components` - 15 components")
      end

      it "includes build plugins" do
        result = described_class.call(detail: "full")
        text = result.content.first[:text]

        expect(text).to include("Build Plugins")
        expect(text).to include("@vitejs/plugin-react")
        expect(text).to include("vite-plugin-ruby")
        expect(text).to include("vite-tsconfig-paths")
      end
    end

    context "with detail:summary for a Hotwire app" do
      let(:hotwire_data) do
        {
          frontend_roots: [],
          frameworks: {},
          mounting_strategy: nil,
          state_management: [],
          testing: [],
          package_manager: nil,
          typescript: { enabled: false },
          monorepo: { detected: false, tool: nil, workspaces: [] },
          build_tool: nil
        }
      end

      let(:gems_data) do
        {
          notable_gems: [
            { name: "turbo-rails", version: "2.0.0" },
            { name: "stimulus-rails", version: "1.3.0" },
            { name: "importmap-rails", version: "2.0.0" },
            { name: "tailwindcss-rails", version: "3.0.0" }
          ]
        }
      end

      let(:stimulus_data) do
        {
          total_controllers: 15,
          controllers: Array.new(15) { |i| { name: "controller_#{i}" } }
        }
      end

      before do
        allow(described_class).to receive(:cached_context).and_return({
          frontend_frameworks: hotwire_data,
          gems: gems_data,
          stimulus: stimulus_data
        })
      end

      it "returns a Hotwire one-liner with framework, asset delivery, controllers, and CSS" do
        result = described_class.call(detail: "summary")
        text = result.content.first[:text]

        expect(text).to include("Hotwire (Turbo + Stimulus)")
        expect(text).to include("importmap-rails")
        expect(text).to include("15 Stimulus controllers")
        expect(text).to include("Tailwind CSS")
      end

      it "does not return blank output" do
        result = described_class.call(detail: "summary")
        text = result.content.first[:text]

        expect(text).not_to be_empty
        expect(text).not_to eq("No frontend framework detected.")
      end
    end

    context "when frontend_frameworks data is missing" do
      it "returns a helpful message about enabling the introspector" do
        allow(described_class).to receive(:cached_context).and_return({})
        result = described_class.call
        text = result.content.first[:text]

        expect(text).to include("No frontend framework data available")
        expect(text).to include(":frontend_frameworks")
        expect(text).to include("config.introspectors")
      end
    end

    context "when frontend_frameworks has an error" do
      it "returns a helpful message about enabling the introspector" do
        allow(described_class).to receive(:cached_context).and_return({
          frontend_frameworks: { error: "something went wrong" }
        })
        result = described_class.call
        text = result.content.first[:text]

        expect(text).to include("No frontend framework data available")
        expect(text).to include(":frontend_frameworks")
      end
    end

    context "when frontend_frameworks is unavailable (static tier)" do
      it "reports [UNAVAILABLE] instead of a fabricated empty answer" do
        allow(described_class).to receive(:cached_context).and_return({
          frontend_frameworks: { unavailable: "requires a booted Rails app (RuntimeError: boom)" }
        })
        result = described_class.call
        text = result.content.first[:text]

        expect(text).to include("UNAVAILABLE")
        expect(text).to include("requires a booted Rails app (RuntimeError: boom)")
        expect(text).not_to include("No frontend framework data available")
      end
    end

    context "with unknown detail level" do
      it "returns an error message" do
        result = described_class.call(detail: "verbose")
        text = result.content.first[:text]

        expect(text).to include("Unknown detail level: verbose")
        expect(text).to include("summary, standard, or full")
      end
    end

    context "with minimal data" do
      it "handles missing optional fields gracefully" do
        allow(described_class).to receive(:cached_context).and_return({
          frontend_frameworks: { frameworks: { vue: "3.4.0" } }
        })
        result = described_class.call(detail: "full")
        text = result.content.first[:text]

        expect(text).to include("**Framework:** Vue 3.4.0")
        expect(text).not_to include("Monorepo")
        expect(text).not_to include("Path Aliases")
        expect(text).not_to include("Component Directories")
        expect(text).not_to include("Build Plugins")
      end

      it "does not render a Monorepo section for the always-present undetected monorepo hash" do
        allow(described_class).to receive(:cached_context).and_return({
          frontend_frameworks: {
            frameworks: { vue: "3.4.0" },
            monorepo: { detected: false, tool: nil, workspaces: [] }
          }
        })
        result = described_class.call(detail: "full")
        text = result.content.first[:text]

        expect(text).not_to include("Monorepo")
      end

      it "returns a summary without component count when no roots" do
        allow(described_class).to receive(:cached_context).and_return({
          frontend_frameworks: { frameworks: { vue: "3.4.0" }, build_tool: "vite" }
        })
        result = described_class.call(detail: "summary")
        text = result.content.first[:text]

        expect(text).to include("Vue 3.4.0")
        expect(text).to include("Vite")
        expect(text).not_to include("components")
      end
    end

    context "on an API-only app with no frontend evidence at all" do
      let(:empty_frontend_data) do
        {
          frontend_roots: [],
          frameworks: {},
          mounting_strategy: nil,
          build_tool: nil,
          state_management: [],
          package_manager: nil,
          typescript: { enabled: false },
          testing: []
        }
      end

      before do
        allow(described_class).to receive(:cached_context).and_return({ frontend_frameworks: empty_frontend_data })
      end

      it "says no frontend stack was detected instead of just 'TypeScript: disabled'" do
        result = described_class.call(detail: "standard")
        text = result.content.first[:text]

        expect(text).to include("No frontend stack detected")
        expect(text).not_to include("TypeScript: disabled")
      end

      it "still says so at detail:full" do
        result = described_class.call(detail: "full")
        text = result.content.first[:text]

        expect(text).to include("No frontend stack detected")
      end
    end

    context "on a Hotwire app with TypeScript disabled and no frontend_roots" do
      let(:hotwire_only_data) do
        {
          frontend_roots: [],
          frameworks: {},
          mounting_strategy: nil,
          build_tool: nil,
          state_management: [],
          package_manager: nil,
          typescript: { enabled: false },
          testing: []
        }
      end

      let(:gems_data) do
        { notable_gems: [ { name: "turbo-rails", version: "2.0.0" } ] }
      end

      before do
        allow(described_class).to receive(:cached_context).and_return({
          frontend_frameworks: hotwire_only_data,
          gems: gems_data,
          stimulus: {}
        })
      end

      it "shows the Hotwire stack instead of the no-frontend message" do
        result = described_class.call(detail: "standard")
        text = result.content.first[:text]

        expect(text).to include("Hotwire Stack")
        expect(text).not_to include("No frontend stack detected")
      end
    end
  end
end
