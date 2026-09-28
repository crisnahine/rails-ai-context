# frozen_string_literal: true

require "json"
require "yaml"

module RailsAiContext
  module Introspectors
    # Detects frontend frameworks, build tools, TypeScript config, monorepo
    # layout, and component file counts from package.json, lockfiles, and
    # bundler configs (Vite, Shakapacker, Webpacker).
    class FrontendFrameworkIntrospector < Base
      extend StaticTier
      static_tier :files_only

      MAX_PACKAGE_JSON_SIZE = 256 * 1024 # 256 KB

      # Order breaks a tie, so the specific framework comes first: react comes along with
      # preact/compat, and an app that declares preact is a Preact app.
      FRAMEWORK_MARKERS = {
        "preact" => :preact,
        "solid-js" => :solid,
        "react" => :react, "react-dom" => :react,
        "next" => :nextjs,
        "vue" => :vue,
        "nuxt" => :nuxt,
        "@angular/core" => :angular,
        "svelte" => :svelte,
        "@sveltejs/kit" => :sveltekit,
        "react-native" => :react_native, "expo" => :expo
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
      COMPONENT_FILE = /(?:#{COMPONENT_EXTENSIONS.map { |ext| Regexp.escape(ext) }.join("|")})\z/

      SCAN_SKIP_DIRS = %w[node_modules dist build .next coverage __tests__].freeze

      VITE_IMPORT_MARKERS = {
        "vite-plugin-ruby" => :vite_rails,
        "@vitejs/plugin-react" => :react,
        "@vitejs/plugin-vue" => :vue,
        "@sveltejs/vite-plugin-svelte" => :svelte
      }.freeze

      def call
        all_deps = read_package_json_deps
        frameworks = detect_frameworks(all_deps)
        mounting = detect_mounting_strategy(all_deps)
        state = labels_for(STATE_MARKERS, all_deps)
        testing = labels_for(TEST_MARKERS, all_deps)
        pkg_mgr = detect_package_manager
        mono = detect_monorepo
        build = detect_build_tool
        vite_fw = detect_vite_config_frameworks
        roots = detect_frontend_roots
        # Merge vite config detected frameworks into main frameworks hash
        vite_fw.each { |sym| frameworks[sym] ||= nil unless frameworks.key?(sym) }
        frameworks = rank_frameworks(frameworks, roots)
        ts = detect_typescript(roots)

        # Enrich each frontend root with component scan data
        enriched_roots = roots.map do |fr|
          full_path = File.join(root, fr[:path])
          counts = scan_components(full_path, component_matcher(frameworks.keys.first))
          primary_fw, primary_version = frameworks.first
          fr.merge(
            framework: primary_fw,
            version: primary_version,
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
          api_clients: labels_for(API_CLIENT_MARKERS, all_deps),
          component_libraries: labels_for(COMPONENT_LIB_MARKERS, all_deps),
          summary: build_summary(frameworks, mounting, build, ts, total_components)
        }
      end

      private

      # ---- Package.json reading ----

      def read_package_json_deps
        RailsAiContext::PackageJson.deps(root)
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

      # What the app is built in, not what it depends on: a config file the framework's CLI
      # writes, then how many of its components the app holds.
      FRAMEWORK_EVIDENCE = {
        angular: { config: "angular.json", components: /\.component\.ts\z/ },
        nextjs: { config: "next.config.*" },
        nuxt: { config: "nuxt.config.*" },
        sveltekit: { config: "svelte.config.*" },
        svelte: { components: /\.svelte\z/ },
        vue: { components: /\.vue\z/ },
        react: { components: /\.[jt]sx\z/ },
        preact: { components: /\.[jt]sx\z/ },
        solid: { components: /\.[jt]sx\z/ }
      }.freeze

      def rank_frameworks(frameworks, roots)
        return frameworks if frameworks.size < 2

        # Only the frontend roots are counted: globbing the app root walks
        # node_modules before anything filters it out.
        dirs = roots.map { |fr| File.join(root, fr[:path]) }
        ranked = frameworks.keys.each_with_index
          .sort_by { |sym, index| [ -framework_evidence(sym, dirs), index ] }
          .map { |sym, _index| [ sym, frameworks[sym] ] }
        ranked.to_h
      end

      def component_matcher(framework)
        FRAMEWORK_EVIDENCE.dig(framework, :components) || COMPONENT_FILE
      end

      def framework_evidence(sym, dirs)
        markers = FRAMEWORK_EVIDENCE[sym]
        return 0 unless markers

        score = 0
        if markers[:config]
          score += 1000 if ([ root ] + dirs).uniq.any? { |dir| Dir.glob(File.join(dir, markers[:config])).any? }
        end
        score += dirs.sum { |dir| component_files(dir, markers[:components]).size } if markers[:components]
        score
      end

      def component_files(dir, matcher)
        FileWalk.each_file(dir, skip: scan_skip_dirs).select { |path| File.basename(path).match?(matcher) }
      end

      def scan_skip_dirs
        RailsAiContext.configuration.excluded_paths + SCAN_SKIP_DIRS
      end

      def detect_mounting_strategy(all_deps)
        MOUNTING_MARKERS.each do |pkg, sym|
          return sym if all_deps.key?(pkg)
        end
        nil
      end

      def labels_for(markers, all_deps)
        markers.filter_map { |pkg, label| label if all_deps.key?(pkg) }.uniq
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

      # An app whose TypeScript lives under frontend/ has no tsconfig.json at
      # its root, so the frontend roots are searched too. The root one wins.
      def detect_typescript(roots)
        dirs = [ root ] + roots.map { |fr| File.join(root, fr[:path]) }
        path = dirs.map { |dir| File.join(dir, "tsconfig.json") }.find { |p| File.exist?(p) }
        return { enabled: false } unless path

        compiler, = ModuleAliases.compiler_options(path)
        return { enabled: false } unless compiler

        {
          enabled: true,
          strict: compiler["strict"] == true,
          path_aliases: compiler["paths"] || {}
        }
      end

      # ---- Monorepo ----

      MONOREPO_MARKERS = { "turbo.json" => "turborepo", "nx.json" => "nx", "lerna.json" => "lerna" }.freeze

      def detect_monorepo
        result = { detected: false, tool: nil, workspaces: [] }

        # pnpm workspaces
        pnpm_ws = File.join(root, "pnpm-workspace.yaml")
        if File.exist?(pnpm_ws)
          data = YAML.safe_load(RailsAiContext::SafeFile.read(pnpm_ws) || "", permitted_classes: []) rescue nil
          if data.is_a?(Hash) && data["packages"].is_a?(Array)
            return result.merge(detected: true, tool: "pnpm", workspaces: data["packages"])
          end
        end

        MONOREPO_MARKERS.each do |file, tool|
          return result.merge(detected: true, tool: tool) if File.exist?(File.join(root, file))
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
            return result.merge(detected: true, tool: "npm/yarn", workspaces: packages) if packages.any?
          end
        end

        result
      end

      # ---- Build tool ----

      def detect_build_tool
        return "vite" if Dir.glob(File.join(root, "vite.config.*")).any?
        return "webpack" if File.exist?(File.join(root, "config/webpacker.yml")) ||
                            File.exist?(File.join(root, "config/shakapacker.yml"))
        return "esbuild" if RailsAiContext::PackageJson.present?(root, "esbuild")

        nil
      end

      # ---- Vite config framework detection ----

      def detect_vite_config_frameworks
        found = []
        %w[vite.config.ts vite.config.js vite.config.mts vite.config.mjs vite.config.cts vite.config.cjs].each do |filename|
          path = File.join(root, filename)
          next unless File.exist?(path)

          content = RailsAiContext::SafeFile.read(path) or next
          VITE_IMPORT_MARKERS.each do |source, sym|
            found << sym if content.match?(/from\s+['"]#{Regexp.escape(source)}['"]/)
          end
        end
        found.uniq
      end

      # ---- Frontend roots ----

      CONFIG_ROOT_READERS = {
        "config/vite.json" => :read_vite_source_dir,
        "config/shakapacker.yml" => :read_yaml_source_path,
        "config/webpacker.yml" => :read_yaml_source_path
      }.freeze

      def detect_frontend_roots
        configured = RailsAiContext.configuration.respond_to?(:frontend_paths) &&
                     RailsAiContext.configuration.frontend_paths
        if configured.is_a?(Array) && configured.any?
          return configured.filter_map { |p| { path: p, detected_from: "configuration" } if usable_dir?(p) }
        end

        CONFIG_ROOT_READERS.each do |source, reader|
          declared = send(reader, source)
          return [ { path: declared, detected_from: source } ] if declared && usable_dir?(declared)
        end

        RailsAiContext::PackageJson::FRONTEND_DIRS.filter_map do |dir|
          { path: dir, detected_from: "convention" } if usable_dir?(dir)
        end
      end

      def usable_dir?(relative)
        full = File.join(root, relative)
        Dir.exist?(full) && safe_path?(full)
      end

      def read_vite_source_dir(relative)
        path = File.join(root, relative)
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

        raw = RailsAiContext::SafeFile.read(path)
        return nil unless raw
        # A webpacker config keeps its shared settings behind an anchor, so
        # refusing aliases loses the source path. Aliases control graph
        # structure only; permitted_classes still bounds instantiation.
        data = YAML.safe_load(raw, permitted_classes: [], aliases: true)
        return nil unless data.is_a?(Hash)

        default_scope = data["default"]
        return nil unless default_scope.is_a?(Hash)

        default_scope["source_path"]
      rescue => _e
        nil
      end

      # ---- Component scanning ----

      # Counted per top-level directory under the root, with the framework's
      # own component file shape: Angular writes `*.component.ts`.
      def scan_components(dir_path, matcher = COMPONENT_FILE)
        return {} unless Dir.exist?(dir_path)

        counts = Hash.new(0)
        component_files(dir_path, matcher).each do |file|
          parts = file.sub("#{dir_path}/", "").split("/")
          counts[parts.size > 1 ? parts.first : "."] += 1
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
        content = RailsAiContext::SafeFile.read(path)
        return nil unless content
        JSON.parse(content)
      rescue JSON::ParserError
        nil
      end

      def safe_path?(full_path)
        SafePath.contained?(File.realpath(full_path), File.realpath(root))
      rescue Errno::ENOENT, Errno::EACCES, Errno::ELOOP, Errno::ENAMETOOLONG
        false
      end

      API_CLIENT_MARKERS = {
        "axios" => "Axios", "ky" => "Ky", "got" => "Got",
        "@tanstack/react-query" => "TanStack Query", "swr" => "SWR",
        "apollo-client" => "Apollo Client", "@apollo/client" => "Apollo Client",
        "urql" => "URQL", "graphql-request" => "graphql-request",
        "relay-runtime" => "Relay"
      }.freeze

      COMPONENT_LIB_MARKERS = {
        "@mui/material" => "MUI", "@chakra-ui/react" => "Chakra UI",
        "@radix-ui/react-dialog" => "Radix UI", "@headlessui/react" => "Headless UI",
        "antd" => "Ant Design", "@mantine/core" => "Mantine",
        "shadcn-ui" => "shadcn/ui", "@shadcn/ui" => "shadcn/ui",
        "daisyui" => "DaisyUI", "flowbite" => "Flowbite",
        "primereact" => "PrimeReact", "vuetify" => "Vuetify",
        "element-plus" => "Element Plus", "naive-ui" => "Naive UI"
      }.freeze
    end
  end
end
