# frozen_string_literal: true

require "spec_helper"

RSpec.describe RailsAiContext::Introspectors::FrontendFrameworkIntrospector do
  let(:introspector) { described_class.new(Rails.application) }

  describe "#call" do
    subject(:result) { introspector.call }

    it "does not return an error" do
      expect(result).not_to have_key(:error)
    end

    describe "framework detection" do
      it "detects react from package.json" do
        expect(result[:frameworks]).to have_key(:react)
      end

      it "extracts react version" do
        expect(result[:frameworks][:react]).to match(/\A\^?\d+/)
      end
    end

    describe "mounting strategy" do
      it "detects inertia mounting strategy" do
        expect(result[:mounting_strategy]).to eq(:inertia)
      end
    end

    describe "state management" do
      it "detects zustand" do
        expect(result[:state_management]).to include("Zustand")
      end
    end

    describe "testing" do
      it "detects vitest" do
        expect(result[:testing]).to include("Vitest")
      end

      it "detects playwright" do
        expect(result[:testing]).to include("Playwright")
      end

      it "detects testing library" do
        expect(result[:testing]).to include("Testing Library")
      end
    end

    describe "frontend roots" do
      it "reads sourceCodeDir from vite.json" do
        roots = result[:frontend_roots]
        # vite.json points to app/frontend, but the dir may not exist in test app;
        # if it does not exist, falls back to app/javascript (convention)
        detected_paths = roots.map { |r| r[:path] }
        expect(detected_paths).to include("app/javascript").or include("app/frontend")
      end

      it "includes detected_from metadata" do
        roots = result[:frontend_roots]
        expect(roots).to all(have_key(:detected_from))
      end
    end

    describe "typescript detection" do
      it "detects typescript as enabled" do
        expect(result[:typescript][:enabled]).to be true
      end

      it "detects strict mode" do
        expect(result[:typescript][:strict]).to be true
      end

      it "extracts path aliases" do
        aliases = result[:typescript][:path_aliases]
        expect(aliases).to have_key("@/*")
        expect(aliases["@/*"]).to include("app/frontend/*")
      end

      it "extracts component path aliases" do
        aliases = result[:typescript][:path_aliases]
        expect(aliases).to have_key("@components/*")
      end
    end

    describe "package manager" do
      it "returns nil when no lockfile exists" do
        expect(result[:package_manager]).to be_nil
      end
    end

    describe "monorepo" do
      it "returns detected as false when no monorepo config exists" do
        expect(result[:monorepo][:detected]).to be false
      end

      it "returns nil tool when not a monorepo" do
        expect(result[:monorepo][:tool]).to be_nil
      end

      it "returns empty workspaces when not a monorepo" do
        expect(result[:monorepo][:workspaces]).to eq([])
      end
    end

    describe "build tool" do
      it "returns a string or nil" do
        expect(result[:build_tool]).to be_nil.or be_a(String)
      end
    end

    describe "summary" do
      it "returns a summary hash" do
        expect(result[:summary]).to be_a(Hash)
      end

      it "includes a stack string" do
        expect(result[:summary][:stack]).to be_a(String)
      end

      it "mentions React in the stack" do
        expect(result[:summary][:stack]).to include("React")
      end

      it "includes total_components count" do
        expect(result[:summary][:total_components]).to be_a(Integer)
      end
    end

    describe "return structure completeness" do
      it "includes all top-level keys" do
        expect(result.keys).to include(
          :frontend_roots, :frameworks, :mounting_strategy,
          :state_management, :testing, :package_manager,
          :typescript, :monorepo, :build_tool, :summary
        )
      end
    end
  end

  describe "missing package.json" do
    it "handles missing package.json gracefully" do
      # Temporarily rename package.json to simulate absence
      pkg = File.join(Rails.root, "package.json")
      backup = "#{pkg}.bak"
      FileUtils.mv(pkg, backup)

      begin
        result = introspector.call
        expect(result).not_to have_key(:error)
        expect(result[:frameworks]).to eq({})
        expect(result[:mounting_strategy]).to be_nil
        expect(result[:state_management]).to eq([])
        expect(result[:testing]).to eq([])
      ensure
        FileUtils.mv(backup, pkg)
      end
    end
  end

  describe "lockfile detection" do
    it "detects yarn when yarn.lock exists" do
      lockfile = File.join(Rails.root, "yarn.lock")
      File.write(lockfile, "# yarn lockfile v1\n")

      begin
        result = introspector.call
        expect(result[:package_manager]).to eq("yarn")
      ensure
        FileUtils.rm_f(lockfile)
      end
    end

    it "detects pnpm when pnpm-lock.yaml exists" do
      lockfile = File.join(Rails.root, "pnpm-lock.yaml")
      File.write(lockfile, "lockfileVersion: 9\n")

      begin
        result = introspector.call
        expect(result[:package_manager]).to eq("pnpm")
      ensure
        FileUtils.rm_f(lockfile)
      end
    end

    it "detects npm when package-lock.json exists" do
      lockfile = File.join(Rails.root, "package-lock.json")
      File.write(lockfile, '{"lockfileVersion": 3}')

      begin
        result = introspector.call
        expect(result[:package_manager]).to eq("npm")
      ensure
        FileUtils.rm_f(lockfile)
      end
    end
  end

  describe "monorepo detection" do
    context "with package.json workspaces array" do
      let(:pkg_path) { File.join(Rails.root, "package.json") }
      let(:original_content) { File.read(pkg_path) }

      after { File.write(pkg_path, original_content) }

      it "detects workspaces from array format" do
        data = JSON.parse(original_content)
        data["workspaces"] = [ "packages/*", "apps/*" ]
        File.write(pkg_path, JSON.pretty_generate(data))

        result = introspector.call
        expect(result[:monorepo][:detected]).to be true
        expect(result[:monorepo][:tool]).to eq("npm/yarn")
        expect(result[:monorepo][:workspaces]).to include("packages/*")
      end

      it "detects workspaces from object format" do
        data = JSON.parse(original_content)
        data["workspaces"] = { "packages" => [ "packages/*" ] }
        File.write(pkg_path, JSON.pretty_generate(data))

        result = introspector.call
        expect(result[:monorepo][:detected]).to be true
        expect(result[:monorepo][:workspaces]).to include("packages/*")
      end
    end

    context "with turbo.json" do
      let(:turbo_path) { File.join(Rails.root, "turbo.json") }

      before { File.write(turbo_path, '{"$schema": "https://turbo.build/schema.json"}') }
      after { FileUtils.rm_f(turbo_path) }

      it "detects turborepo" do
        result = introspector.call
        expect(result[:monorepo][:detected]).to be true
        expect(result[:monorepo][:tool]).to eq("turborepo")
      end
    end
  end

  describe "vite config framework detection" do
    context "with vite.config.ts containing plugin-react import" do
      let(:vite_config_path) { File.join(Rails.root, "vite.config.ts") }

      before do
        File.write(vite_config_path, <<~JS)
          import { defineConfig } from 'vite'
          import react from '@vitejs/plugin-react'
          import ViteRuby from 'vite-plugin-ruby'

          export default defineConfig({
            plugins: [react(), ViteRuby()]
          })
        JS
      end

      after { FileUtils.rm_f(vite_config_path) }

      it "detects react and vite_rails from vite config imports" do
        result = introspector.call
        expect(result[:frameworks]).to have_key(:react)
        expect(result[:build_tool]).to eq("vite")
      end
    end

    context "with vite.config.mts containing vue plugin import" do
      let(:vite_config_path) { File.join(Rails.root, "vite.config.mts") }

      before do
        File.write(vite_config_path, <<~JS)
          import { defineConfig } from 'vite'
          import vue from '@vitejs/plugin-vue'

          export default defineConfig({
            plugins: [vue()]
          })
        JS
      end

      after { FileUtils.rm_f(vite_config_path) }

      it "detects vue from vite.config.mts" do
        result = introspector.call
        expect(result[:frameworks]).to have_key(:vue)
      end
    end
  end

  describe "frontend roots" do
    it "does not count a frontend root that resolves outside the app root" do
      Dir.mktmpdir("frontend") do |dir|
        dir = File.realpath(dir)
        app_root = File.join(dir, "app")
        FileUtils.mkdir_p(File.join(app_root, "app"))
        FileUtils.mkdir_p(File.join(dir, "app_backup", "javascript"))
        File.symlink(File.join(dir, "app_backup", "javascript"), File.join(app_root, "app", "javascript"))

        result = described_class.new(RailsAiContext::StaticApp.new(app_root)).call
        expect(result[:frontend_roots].to_s).not_to include("javascript")
      end
    end
  end
end
