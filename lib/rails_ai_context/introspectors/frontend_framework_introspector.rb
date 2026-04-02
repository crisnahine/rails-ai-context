# frozen_string_literal: true

require "json"
require "yaml"

module RailsAiContext
  module Introspectors
    # Detects frontend frameworks, build tools, TypeScript config, monorepo
    # layout, and component file counts from package.json, lockfiles, and
    # bundler configs (Vite, Shakapacker, Webpacker).
    class FrontendFrameworkIntrospector
      attr_reader :app

      MAX_PACKAGE_JSON_SIZE = 256 * 1024 # 256 KB

      FRAMEWORK_MARKERS = {
        "react" => :react, "react-dom" => :react,
        "next" => :nextjs,
        "vue" => :vue,
        "nuxt" => :nuxt,
        "@angular/core" => :angular,
        "svelte" => :svelte,
        "@sveltejs/kit" => :sveltekit,
        "react-native" => :react_native, "expo" => :expo,
        "solid-js" => :solid,
        "preact" => :preact
      }.freeze

      MOUNTING_MARKERS = {
        "react_ujs" => :react_rails,
        "react-on-rails" => :react_on_rails,
        "@inertiajs/react" => :inertia,
        "@inertiajs/vue3" => :inertia,
        "@inertiajs/svelte" => :inertia,
        "vite-plugin-ruby" => :vite_rails,
        "vite-plugin-rails" => :vite_rails
      }.freeze

      STATE_MARKERS = {
        "redux" => "Redux", "@reduxjs/toolkit" => "Redux Toolkit",
        "zustand" => "Zustand", "jotai" => "Jotai",
        "pinia" => "Pinia", "vuex" => "Vuex",
        "mobx" => "MobX", "@tanstack/react-query" => "TanStack Query"
      }.freeze

      TEST_MARKERS = {
        "jest" => "Jest", "vitest" => "Vitest",
        "@playwright/test" => "Playwright", "cypress" => "Cypress",
        "@testing-library/react" => "Testing Library"
      }.freeze

      COMPONENT_EXTENSIONS = %w[.jsx .tsx .vue .svelte].freeze

      SCAN_SKIP_DIRS = %w[node_modules dist build .next coverage __tests__].freeze

      VITE_IMPORT_MARKERS = {
        "vite-plugin-ruby" => :vite_rails,
        "@vitejs/plugin-react" => :react,
        "@vitejs/plugin-vue" => :vue,
        "@sveltejs/vite-plugin-svelte" => :svelte
      }.freeze

      def initialize(app)
        @app = app
      end

      def call
        all_deps = read_package_json_deps
        frameworks = detect_frameworks(all_deps)
        mounting = detect_mounting_strategy(all_deps)
        state = detect_state_management(all_deps)
        testing = detect_testing(all_deps)
        pkg_mgr = detect_package_manager
        ts = detect_typescript
        mono = detect_monorepo(all_deps)
        build = detect_build_tool
        vite_fw = detect_vite_config_frameworks
        roots = detect_frontend_roots

        # Merge vite config detected frameworks into main frameworks hash
        vite_fw.each { |sym| frameworks[sym] ||= nil unless frameworks.key?(sym) }

        # Enrich each frontend root with component scan data
        enriched_roots = roots.map do |fr|
          full_path = File.join(root, fr[:path])
          counts = scan_components(full_path)
          primary_fw = frameworks.keys.first
          version = frameworks.values.compact.first
          fr.merge(
            framework: primary_fw,
            version: version,
            component_count: counts.values.sum,
            component_dirs: counts
          )
        end

        total_components = enriched_roots.sum { |r| r[:component_count] }

        {
          frontend_roots: enriched_roots,
          frameworks: frameworks,
          mounting_strategy: mounting,
          state_management: state,
          testing: testing,
          package_manager: pkg_mgr,
          typescript: ts,
          monorepo: mono,
          build_tool: build,
          summary: build_summary(frameworks, mounting, build, ts, total_components)
        }
      rescue => e
        { error: e.message }
      end

      private

      def root
        app.root.to_s
      end

      # ---- Package.json reading ----

      def read_package_json_deps
        path = File.join(root, "package.json")
        return {} unless File.exist?(path)
        return {} if File.size(path) > MAX_PACKAGE_JSON_SIZE

        data = parse_json(path)
        return {} unless data.is_a?(Hash)

        deps = (data["dependencies"] || {})
        dev_deps = (data["devDependencies"] || {})
        deps.merge(dev_deps)
      end

      # ---- Framework detection ----

      def detect_frameworks(all_deps)
        found = {}
        FRAMEWORK_MARKERS.each do |pkg, sym|
          next unless all_deps.key?(pkg)
          found[sym] ||= all_deps[pkg]
        end
        found
      end

      def detect_mounting_strategy(all_deps)
        MOUNTING_MARKERS.each do |pkg, sym|
          return sym if all_deps.key?(pkg)
        end
        nil
      end

      def detect_state_management(all_deps)
        STATE_MARKERS.filter_map { |pkg, label| label if all_deps.key?(pkg) }.uniq
      end

      def detect_testing(all_deps)
        TEST_MARKERS.filter_map { |pkg, label| label if all_deps.key?(pkg) }.uniq
      end

      # ---- Package manager ----

      def detect_package_manager
        return "bun" if File.exist?(File.join(root, "bun.lock")) || File.exist?(File.join(root, "bun.lockb"))
        return "pnpm" if File.exist?(File.join(root, "pnpm-lock.yaml"))
        return "yarn" if File.exist?(File.join(root, "yarn.lock"))
        return "npm" if File.exist?(File.join(root, "package-lock.json"))

        nil
      end

      # ---- TypeScript ----

      def detect_typescript
        path = File.join(root, "tsconfig.json")
        return { enabled: false } unless File.exist?(path)

        data = parse_json(path)
        return { enabled: false } unless data.is_a?(Hash)

        compiler = data["compilerOptions"] || {}
        {
          enabled: true,
          strict: compiler["strict"] == true,
          path_aliases: compiler["paths"] || {}
        }
      end

      # ---- Monorepo ----

      def detect_monorepo(all_deps)
        result = { detected: false, tool: nil, workspaces: [] }

        # pnpm workspaces
        pnpm_ws = File.join(root, "pnpm-workspace.yaml")
        if File.exist?(pnpm_ws)
          data = YAML.safe_load(File.read(pnpm_ws, encoding: "bom|utf-8"), permitted_classes: []) rescue nil
          if data.is_a?(Hash) && data["packages"].is_a?(Array)
            result[:detected] = true
            result[:tool] = "pnpm"
            result[:workspaces] = data["packages"]
            return result
          end
        end

        # Turborepo
        if File.exist?(File.join(root, "turbo.json"))
          result[:detected] = true
          result[:tool] = "turborepo"
          return result
        end

        # Nx
        if File.exist?(File.join(root, "nx.json"))
          result[:detected] = true
          result[:tool] = "nx"
          return result
        end

        # Lerna
        if File.exist?(File.join(root, "lerna.json"))
          result[:detected] = true
          result[:tool] = "lerna"
          return result
        end

        # package.json workspaces
        pkg_path = File.join(root, "package.json")
        if File.exist?(pkg_path) && File.size(pkg_path) <= MAX_PACKAGE_JSON_SIZE
          data = parse_json(pkg_path)
          if data.is_a?(Hash) && data.key?("workspaces")
            ws = data["workspaces"]
            packages = case ws
            when Array then ws
            when Hash then ws["packages"] || []
            else []
            end
            if packages.any?
              result[:detected] = true
              result[:tool] = "npm/yarn"
              result[:workspaces] = packages
            end
          end
        end

        result
      end

      # ---- Build tool ----

      def detect_build_tool
        return "vite" if Dir.glob(File.join(root, "vite.config.*")).any?
        return "webpack" if File.exist?(File.join(root, "config/webpacker.yml")) ||
                            File.exist?(File.join(root, "config/shakapacker.yml"))
        return "esbuild" if package_json_has_script?("esbuild")

        nil
      end

      # ---- Vite config framework detection ----

      def detect_vite_config_frameworks
        found = []
        %w[vite.config.ts vite.config.js vite.config.mts vite.config.mjs vite.config.cts vite.config.cjs].each do |filename|
          path = File.join(root, filename)
          next unless File.exist?(path)

          content = File.read(path, encoding: "bom|utf-8") rescue next
          VITE_IMPORT_MARKERS.each do |source, sym|
            found << sym if content.match?(/from\s+['"]#{Regexp.escape(source)}['"]/)
          end
        end
        found.uniq
      end

      # ---- Frontend roots ----

      def detect_frontend_roots
        # 1. User override
        configured = RailsAiContext.configuration.respond_to?(:frontend_paths) &&
                     RailsAiContext.configuration.frontend_paths
        if configured.is_a?(Array) && configured.any?
          return configured.filter_map do |p|
            full = File.join(root, p)
            next unless Dir.exist?(full)
            next unless safe_path?(full)
            { path: p, detected_from: "configuration" }
          end
        end

        # 2. Vite (config/vite.json)
        vite_root = read_vite_source_dir
        if vite_root
          full = File.join(root, vite_root)
          if Dir.exist?(full) && safe_path?(full)
            return [ { path: vite_root, detected_from: "config/vite.json" } ]
          end
        end

        # 3. Shakapacker (config/shakapacker.yml)
        shaka_root = read_yaml_source_path("config/shakapacker.yml")
        if shaka_root
          full = File.join(root, shaka_root)
          if Dir.exist?(full) && safe_path?(full)
            return [ { path: shaka_root, detected_from: "config/shakapacker.yml" } ]
          end
        end

        # 4. Webpacker (config/webpacker.yml)
        wp_root = read_yaml_source_path("config/webpacker.yml")
        if wp_root
          full = File.join(root, wp_root)
          if Dir.exist?(full) && safe_path?(full)
            return [ { path: wp_root, detected_from: "config/webpacker.yml" } ]
          end
        end

        # 5. Common directories
        %w[app/frontend app/javascript frontend client].filter_map do |dir|
          full = File.join(root, dir)
          next unless Dir.exist?(full)
          next unless safe_path?(full)
          { path: dir, detected_from: "convention" }
        end
      end

      def read_vite_source_dir
        path = File.join(root, "config/vite.json")
        return nil unless File.exist?(path)

        data = parse_json(path)
        return nil unless data.is_a?(Hash)

        all_scope = data["all"]
        return nil unless all_scope.is_a?(Hash)

        all_scope["sourceCodeDir"]
      end

      def read_yaml_source_path(relative)
        path = File.join(root, relative)
        return nil unless File.exist?(path)

        data = YAML.safe_load(File.read(path, encoding: "bom|utf-8"), permitted_classes: [])
        return nil unless data.is_a?(Hash)

        default_scope = data["default"]
        return nil unless default_scope.is_a?(Hash)

        default_scope["source_path"]
      rescue => _e
        nil
      end

      # ---- Component scanning ----

      def scan_components(dir_path)
        return {} unless Dir.exist?(dir_path)

        counts = Hash.new(0)
        excluded = RailsAiContext.configuration.excluded_paths + SCAN_SKIP_DIRS

        Dir.glob(File.join(dir_path, "**", "*{#{COMPONENT_EXTENSIONS.join(",")}}")).each do |file|
          relative = file.sub("#{dir_path}/", "")
          parts = relative.split("/")

          # Skip excluded directories
          next if parts.any? { |part| excluded.include?(part) }

          top_dir = parts.size > 1 ? parts.first : "."
          counts[top_dir] += 1
        end

        counts
      end

      # ---- Summary ----

      def build_summary(frameworks, mounting, build, ts, total_components)
        parts = []

        # Primary framework + version
        frameworks.each do |sym, version|
          label = sym.to_s.split("_").map(&:capitalize).join(" ")
          parts << (version ? "#{label} #{version.to_s.delete("^0-9.")}" : label)
          break # only the primary
        end

        parts << mounting.to_s.split("_").map(&:capitalize).join(" ") if mounting
        parts << build.capitalize if build
        parts << "TypeScript" if ts.is_a?(Hash) && ts[:enabled]

        {
          stack: parts.any? ? parts.join(" + ") : "No frontend framework detected",
          total_components: total_components
        }
      end

      # ---- Helpers ----

      def parse_json(path)
        content = File.read(path, encoding: "bom|utf-8")
        JSON.parse(content)
      rescue JSON::ParserError
        nil
      end

      def safe_path?(full_path)
        real = File.realpath(full_path)
        real.start_with?(root)
      rescue Errno::ENOENT, Errno::EACCES
        false
      end

      def package_json_has_script?(name)
        path = File.join(root, "package.json")
        return false unless File.exist?(path)
        content = File.read(path, encoding: "bom|utf-8")
        content.include?("\"#{name}\"")
      rescue => e
        $stderr.puts "[rails-ai-context] package_json_has_script? failed: #{e.message}" if ENV["DEBUG"]
        false
      end
    end
  end
end
