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

      context "with turbo.json, nx.json and lerna.json all present" do
        let(:paths) { %w[turbo.json nx.json lerna.json].map { |f| File.join(Rails.root, f) } }

        before { paths.each { |p| File.write(p, "{}") } }
        after { paths.each { |p| FileUtils.rm_f(p) } }

        it "reports turborepo" do
          expect(result[:monorepo]).to include(detected: true, tool: "turborepo", workspaces: [])
        end

        context "without turbo.json" do
          before { FileUtils.rm_f(paths.first) }

          it "reports nx" do
            expect(result[:monorepo][:tool]).to eq("nx")
          end
        end

        context "with only lerna.json" do
          before { paths.first(2).each { |p| FileUtils.rm_f(p) } }

          it "reports lerna" do
            expect(result[:monorepo][:tool]).to eq("lerna")
          end
        end
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

  # An Angular app that also depends on react read as React, because the
  # marker list decided the primary framework.
  describe "an app that depends on two frameworks" do
    it "puts the framework the app is built in first and keeps the other" do
      require "tmpdir"
      Dir.mktmpdir do |tmp|
        root = File.realpath(tmp)
        FileUtils.mkdir_p(File.join(root, "frontend/src/app/work_packages"))
        File.write(File.join(root, "frontend/package.json"), <<~JSON)
          { "dependencies": { "@angular/core": "^22.0.7", "react": "^19.2.6" } }
        JSON
        File.write(File.join(root, "frontend/angular.json"), "{}")
        3.times do |i|
          File.write(File.join(root, "frontend/src/app/work_packages/wp#{i}.component.ts"), "")
        end
        File.write(File.join(root, "frontend/src/app/widget.tsx"), "")

        result = described_class.new(RailsAiContext::StaticApp.new(root)).call

        expect(result[:frameworks].keys).to eq([ :angular, :react ])
      end
    end
  end

  describe "a Preact app that also lists react" do
    it "reads as Preact and credits the components to it" do
      require "tmpdir"
      Dir.mktmpdir do |tmp|
        root = File.realpath(tmp)
        FileUtils.mkdir_p(File.join(root, "app/javascript/components"))
        File.write(File.join(root, "package.json"),
                   '{ "dependencies": { "preact": "^10.20.2", "react": "^17.0.0" } }')
        3.times { |i| File.write(File.join(root, "app/javascript/components/c#{i}.jsx"), "") }

        result = described_class.new(RailsAiContext::StaticApp.new(root)).call

        expect(result[:frameworks].keys.first).to eq(:preact)
        expect(result[:frontend_roots].first[:version]).to eq("^10.20.2")
      end
    end
  end

  describe "an Angular app's frontend root" do
    it "counts the components its own framework writes" do
      require "tmpdir"
      Dir.mktmpdir do |tmp|
        root = File.realpath(tmp)
        FileUtils.mkdir_p(File.join(root, "frontend/src/app/work_packages"))
        FileUtils.mkdir_p(File.join(root, "frontend/node_modules/react-dom"))
        File.write(File.join(root, "frontend/package.json"),
                   '{ "dependencies": { "@angular/core": "^22.0.7", "react": "^19.2.6" } }')
        File.write(File.join(root, "frontend/angular.json"), "{}")
        3.times { |i| File.write(File.join(root, "frontend/src/app/work_packages/wp#{i}.component.ts"), "") }
        File.write(File.join(root, "frontend/node_modules/react-dom/index.component.ts"), "")

        result = described_class.new(RailsAiContext::StaticApp.new(root)).call

        expect(result[:frontend_roots].first[:component_count]).to eq(3)
      end
    end
  end

  describe "a frontend root's framework and version" do
    it "takes the version off the framework it names, not off whichever entry has one" do
      require "tmpdir"
      Dir.mktmpdir do |tmp|
        root = File.realpath(tmp)
        FileUtils.mkdir_p(File.join(root, "app/frontend/components"))
        File.write(File.join(root, "package.json"), '{ "dependencies": { "react": "^19.2.6" } }')
        File.write(File.join(root, "vite.config.ts"), "import vue from '@vitejs/plugin-vue'\n")
        2.times { |i| File.write(File.join(root, "app/frontend/components/w#{i}.vue"), "") }

        result = described_class.new(RailsAiContext::StaticApp.new(root)).call
        frontend = result[:frontend_roots].first

        expect(frontend[:framework]).to eq(:vue)
        expect(frontend[:version]).to be_nil
      end
    end
  end

  # A Rails-shaped webpacker config keeps its shared settings behind a YAML
  # anchor, and a reader that refuses aliases silently falls back to the
  # convention path.
  describe "a shakapacker config that uses YAML aliases" do
    it "reads the source path out of the merged default scope" do
      require "tmpdir"
      Dir.mktmpdir do |tmp|
        root = File.realpath(tmp)
        FileUtils.mkdir_p(File.join(root, "config"))
        FileUtils.mkdir_p(File.join(root, "app/frontend"))
        File.write(File.join(root, "config/shakapacker.yml"), <<~YAML)
          default: &default
            source_path: app/frontend
          development:
            <<: *default
        YAML

        result = described_class.new(RailsAiContext::StaticApp.new(root)).call

        expect(result[:frontend_roots]).to include(
          a_hash_including(path: "app/frontend", detected_from: "config/shakapacker.yml")
        )
      end
    end
  end

  # An app whose whole frontend lives under frontend/ has neither a manifest
  # nor a tsconfig at its root, and used to be answered as having no
  # framework and TypeScript disabled in the same breath as naming the root.
  describe "an app whose frontend root holds the manifest" do
    def build(root)
      FileUtils.mkdir_p(File.join(root, "frontend"))
      File.write(File.join(root, "frontend/package.json"), JSON.generate(
        "dependencies" => { "vue" => "3.4.0" },
        "devDependencies" => { "typescript" => "5.4.0" },
        "overrides" => { "esbuild" => "0.25.0" }
      ))
      File.write(File.join(root, "frontend/tsconfig.json"), JSON.generate(
        "compilerOptions" => { "strict" => true }
      ))
      described_class.new(RailsAiContext::StaticApp.new(root)).call
    end

    it "names the framework and finds the TypeScript config" do
      Dir.mktmpdir do |tmp|
        result = build(File.realpath(tmp))

        expect(result[:frameworks]).to include(vue: "3.4.0")
        expect(result[:typescript]).to include(enabled: true, strict: true)
        expect(result[:summary][:stack]).to include("Vue", "TypeScript")
      end
    end

    it "does not let an overrides pin name the build tool" do
      Dir.mktmpdir do |tmp|
        expect(build(File.realpath(tmp))[:build_tool]).to be_nil
      end
    end
  end

  describe "a jsbundling-rails app" do
    {
      "webpack" => [ "webpack.config.js", { "webpack" => "^5.0.0", "webpack-cli" => "^5.0.0" } ],
      "rollup" => [ "rollup.config.js", { "rollup" => "^4.0.0", "@rollup/plugin-node-resolve" => "^15.0.0" } ],
      "bun" => [ "bun.config.js", {} ]
    }.each do |tool, (config, dev_deps)|
      it "names #{tool} as the build tool from the config jsbundling writes" do
        Dir.mktmpdir do |tmp|
          root = File.realpath(tmp)
          File.write(File.join(root, config), "")
          File.write(File.join(root, "package.json"), JSON.generate("devDependencies" => dev_deps))
          result = described_class.new(RailsAiContext::StaticApp.new(root)).call

          expect(result[:build_tool]).to eq(tool)
        end
      end
    end
  end

  describe "a lockfile at the JS workspace root above the app" do
    def workspace(lockfile: "yarn.lock", git: true, workspaces: [ "backend" ])
      Dir.mktmpdir do |tmp|
        repo = File.realpath(tmp)
        root = File.join(repo, "backend")
        FileUtils.mkdir_p(root)
        FileUtils.mkdir_p(File.join(repo, ".git")) if git
        File.write(File.join(repo, "package.json"), JSON.generate("private" => true, "workspaces" => workspaces))
        File.write(File.join(repo, lockfile), "") if lockfile
        File.write(File.join(root, "package.json"), "{}")
        yield repo, root
      end
    end

    it "names the workspace's package manager and the directory its lockfile is in" do
      workspace do |_repo, root|
        result = described_class.new(RailsAiContext::StaticApp.new(root)).call

        expect(result[:package_manager]).to eq("yarn")
        expect(result[:package_manager_dir]).to eq("..")
      end
    end

    it "prefers a lockfile in the app root" do
      workspace do |_repo, root|
        File.write(File.join(root, "package-lock.json"), "{}")
        result = described_class.new(RailsAiContext::StaticApp.new(root)).call

        expect(result[:package_manager]).to eq("npm")
        expect(result[:package_manager_dir]).to be_nil
      end
    end
  end

  describe "a frontend_paths entry outside the app root" do
    def web_client
      Dir.mktmpdir do |tmp|
        base = File.realpath(tmp)
        root = File.join(base, "backend")
        client = File.join(base, "web-client")
        FileUtils.mkdir_p([ root, File.join(client, "src") ])
        File.write(File.join(client, "package.json"), JSON.generate(
          "dependencies" => { "react" => "^19.0.0", "react-dom" => "^19.0.0" },
          "devDependencies" => { "vite" => "^7.0.0", "typescript" => "^5.6.0" }
        ))
        File.write(File.join(client, "src/App.tsx"), "export const App = () => null\n")
        allow(RailsAiContext.configuration).to receive(:frontend_paths).and_return([ "../web-client" ])
        yield root, client
      end
    end

    it "reads its manifests and names it" do
      web_client do |root, client|
        File.write(File.join(client, "yarn.lock"), "")
        File.write(File.join(client, "vite.config.ts"), "export default {}\n")
        result = described_class.new(RailsAiContext::StaticApp.new(root)).call

        expect(result[:frameworks]).to eq(react: "^19.0.0")
        expect(result[:outside_frontend_roots]).to eq([ "../web-client" ])
        expect(result[:package_manager]).to eq("yarn")
        expect(result[:package_manager_dir]).to eq("../web-client")
        expect(result[:build_tool]).to eq("vite")
        expect(result[:frontend_roots]).to be_empty
        expect(result).not_to have_key(:skipped_frontend_paths)
      end
    end

    it "reads its tsconfig.json, and only what it extends inside that directory" do
      web_client do |root, client|
        File.write(File.join(client, "tsconfig.json"), JSON.generate("compilerOptions" => { "strict" => true }))
        result = described_class.new(RailsAiContext::StaticApp.new(root)).call
        expect(result[:typescript]).to include(enabled: true, strict: true)

        File.write(File.join(File.dirname(client), "base.json"), JSON.generate("compilerOptions" => { "strict" => true }))
        File.write(File.join(client, "tsconfig.json"), JSON.generate("extends" => "../base.json", "compilerOptions" => {}))
        result = described_class.new(RailsAiContext::StaticApp.new(root)).call
        expect(result[:typescript]).to include(enabled: true, strict: false)
      end
    end

    it "refuses a manifest symlinked out of that directory" do
      web_client do |root, client|
        Dir.mktmpdir do |elsewhere|
          FileUtils.mv(File.join(client, "package.json"), File.join(elsewhere, "package.json"))
          File.symlink(File.join(elsewhere, "package.json"), File.join(client, "package.json"))
          result = described_class.new(RailsAiContext::StaticApp.new(root)).call

          expect(result[:frameworks]).to be_empty
          expect(result[:outside_frontend_roots]).to eq([ "../web-client" ])
        end
      end
    end

    it "skips an entry that does not exist" do
      web_client do |root, _client|
        allow(RailsAiContext.configuration).to receive(:frontend_paths).and_return([ "../missing" ])
        result = described_class.new(RailsAiContext::StaticApp.new(root)).call

        expect(result[:outside_frontend_roots]).to eq([])
        expect(result[:frameworks]).to be_empty
      end
    end
  end

  it "reads the build tool and lockfile of a frontend_paths entry inside the app root" do
    Dir.mktmpdir do |tmp|
      root = File.realpath(tmp)
      web = File.join(root, "web")
      FileUtils.mkdir_p(web)
      File.write(File.join(web, "package.json"), JSON.generate("devDependencies" => { "vite" => "^7.0.0" }))
      File.write(File.join(web, "vite.config.ts"), "export default {}\n")
      File.write(File.join(web, "pnpm-lock.yaml"), "")
      allow(RailsAiContext.configuration).to receive(:frontend_paths).and_return([ "web" ])

      result = described_class.new(RailsAiContext::StaticApp.new(root)).call

      expect(result[:build_tool]).to eq("vite")
      expect(result[:package_manager]).to eq("pnpm")
      expect(result[:package_manager_dir]).to eq("web")
    end
  end

  describe "frontend roots" do
    it "prefers the vite source dir over a shakapacker one" do
      require "tmpdir"
      Dir.mktmpdir do |tmp|
        root = File.realpath(tmp)
        FileUtils.mkdir_p(File.join(root, "config"))
        FileUtils.mkdir_p(File.join(root, "app/vite"))
        FileUtils.mkdir_p(File.join(root, "app/packs"))
        File.write(File.join(root, "config/vite.json"), JSON.generate("all" => { "sourceCodeDir" => "app/vite" }))
        File.write(File.join(root, "config/shakapacker.yml"), "default:\n  source_path: app/packs\n")

        result = described_class.new(RailsAiContext::StaticApp.new(root)).call

        expect(result[:frontend_roots]).to match([
          a_hash_including(path: "app/vite", detected_from: "config/vite.json")
        ])
      end
    end

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

  describe "a tsconfig written the way tsc --init and shared base configs write it" do
    def typescript_in(root)
      described_class.new(RailsAiContext::StaticApp.new(root)).call[:typescript]
    end

    it "reads one with comments and trailing commas" do
      Dir.mktmpdir do |root|
        File.write(File.join(root, "tsconfig.json"), <<~JSONC)
          {
            "compilerOptions": {
              /* Visit https://aka.ms/tsconfig to read more about this file */
              "strict": true, // enable all strict type-checking options
              "paths": { "@/*": ["./app/javascript/*"], },
            },
          }
        JSONC

        expect(typescript_in(root)).to eq(enabled: true, strict: true, path_aliases: { "@/*" => [ "./app/javascript/*" ] })
      end
    end

    it "takes strict and paths from the config it extends, the child's own values winning" do
      Dir.mktmpdir do |root|
        File.write(File.join(root, "tsconfig.base.json"),
                   %({ "compilerOptions": { "strict": true, "paths": { "~base/*": ["./shared/*"] } } }))
        File.write(File.join(root, "tsconfig.json"), %({ "extends": "./tsconfig.base.json", "compilerOptions": { "target": "es2022" } }))

        expect(typescript_in(root)).to eq(enabled: true, strict: true, path_aliases: { "~base/*" => [ "./shared/*" ] })
      end
    end

    it "is disabled when the tsconfig cannot be read even as JSON with comments" do
      Dir.mktmpdir do |root|
        File.write(File.join(root, "tsconfig.json"), "{ not json")

        expect(typescript_in(root)).to eq(enabled: false)
      end
    end
  end
end
