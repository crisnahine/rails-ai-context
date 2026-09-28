# frozen_string_literal: true

require "json"

module RailsAiContext
  module Introspectors
    # The bare import specifiers an app maps onto its own source, as tsconfig/jsconfig
    # `paths` and a literal bundler `resolve.alias` declare them; variables are not read.
    module ModuleAliases
      CONFIG_NAMES = %w[tsconfig.json jsconfig.json].freeze
      BUNDLER_CONFIGS = %w[
        vite.config.js vite.config.ts vite.config.mjs vite.config.mts
        webpack.config.js rspack.config.js config/webpack/webpack.config.js
      ].freeze
      EXTENSIONS = [ "", ".ts", ".js", ".tsx", ".jsx", "/index.ts", "/index.js" ].freeze

      # `prefix`: the pattern also matches as a directory (bundlers), not only exactly (tsconfig).
      Alias = Data.define(:pattern, :targets, :prefix)

      module_function

      # @return [Array<Alias>] every alias declared at the app root or in one of
      #   its JS roots, tsconfig/jsconfig first.
      def table(root, js_dirs)
        dirs = ([ root.to_s ] + js_dirs).uniq
        dirs.flat_map { |dir| CONFIG_NAMES.flat_map { |name| ts_paths(File.join(dir, name)) } } +
          dirs.flat_map { |dir| BUNDLER_CONFIGS.flat_map { |name| bundler_aliases(File.join(dir, name)) } }
      end

      def resolve(spec, table)
        table.each do |entry|
          rest = match(entry.pattern, spec, prefix: entry.prefix) or next

          entry.targets.each do |target|
            found = file_for(target.include?("*") ? target.sub("*", rest) : "#{target}#{rest}")
            return found if found
          end
        end
        nil
      end

      def file_for(base)
        EXTENSIONS.each do |ext|
          candidate = File.expand_path("#{base}#{ext}")
          return candidate if File.file?(candidate)
        end
        nil
      end

      # The part of the specifier the pattern's `*` stands for, "" for an
      # exact or prefix match, nil when the pattern does not apply.
      def match(pattern, spec, prefix: false)
        if pattern.include?("*")
          head, tail = pattern.split("*", 2)
          return nil unless spec.start_with?(head) && spec.end_with?(tail.to_s) && spec.length >= head.length + tail.to_s.length

          spec[head.length...(spec.length - tail.to_s.length)]
        elsif spec == pattern
          ""
        elsif prefix && spec.start_with?("#{pattern.chomp('/')}/")
          spec.delete_prefix(pattern.chomp("/"))
        end
      end

      # Paths resolve against baseUrl when one is set anywhere up the `extends` chain,
      # else against the file that declares them.
      def ts_paths(path)
        options, dirs = compiler_options(path)
        paths = options && options["paths"]
        return [] unless paths.is_a?(Hash)

        base = options["baseUrl"] ? File.expand_path(options["baseUrl"].to_s, dirs["baseUrl"]) : dirs["paths"]
        paths.map do |pattern, targets|
          Alias.new(pattern: pattern, targets: Array(targets).map { |t| File.expand_path(t.to_s, base) }, prefix: false)
        end
      end

      # A tsconfig's compilerOptions as its `extends` chain settles them, and
      # the directory each option was declared in; nil when unreadable.
      def compiler_options(path, seen = Set.new)
        return nil if path.nil? || seen.include?(path) || seen.size > MAX_EXTENDS

        seen << path
        text = RailsAiContext::SafeFile.read(path) or return nil
        config = JSON.parse(jsonc(text))
        return nil unless config.is_a?(Hash)

        options = {}
        dirs = {}
        # A config's own value replaces what it extends; a later `extends` entry replaces an earlier one.
        Array(config["extends"]).each do |spec|
          parent, parent_dirs = compiler_options(extended_config(spec.to_s, path), seen)
          options.merge!(parent.to_h)
          dirs.merge!(parent_dirs.to_h)
        end
        (config["compilerOptions"] || {}).each do |key, value|
          options[key] = value
          dirs[key] = File.dirname(path)
        end
        [ options, dirs ]
      rescue JSON::ParserError, SystemCallError
        nil
      end

      MAX_EXTENDS = 10

      # A relative `extends` names a file, `.json` optional. Anything else is
      # a package, read from the nearest node_modules when it is installed.
      def extended_config(spec, from)
        if spec.start_with?(".", "/")
          base = File.expand_path(spec, File.dirname(from))
          return [ base, "#{base}.json" ].find { |candidate| File.file?(candidate) }
        end

        dir = File.dirname(from)
        MAX_EXTENDS.times do
          modules = File.join(dir, "node_modules", spec)
          found = [ modules, "#{modules}.json", File.join(modules, "tsconfig.json") ].find { |c| File.file?(c) }
          return found if found

          parent = File.dirname(dir)
          break if parent == dir

          dir = parent
        end
        nil
      end

      def jsonc(text)
        text.gsub(%r{"(?:\\.|[^"\\])*"|//[^\n]*|/\*.*?\*/}m) { |m| m.start_with?('"') ? m : "" }
            .gsub(/,(\s*[}\]])/, '\1')
      end

      RESOLVE_BLOCK = /\bresolve\s*:\s*\{/
      ALIAS_BLOCK = /\balias\s*:\s*\{/
      LITERAL = /["']([^"']*)["']/
      PATH_CALL = /path\.(?:resolve|join)\s*\(\s*__dirname\s*(?:,\s*["'][^"']*["']\s*)*\)/
      URL_CALL = /fileURLToPath\(\s*new\s+URL\(\s*["'][^"']*["']\s*,\s*import\.meta\.url\s*\)\s*\)/
      ALIAS_ENTRY = /["']?([^"'\s:,{}]+)["']?\s*:\s*(["'][^"']*["']|#{PATH_CALL}|#{URL_CALL})/

      # `resolve: { alias: {...} }`, values a literal string, `path.resolve(__dirname, ...)`
      # or `fileURLToPath(new URL(..., import.meta.url))`; a key ending in `$` is exact.
      def bundler_aliases(path)
        text = RailsAiContext::SafeFile.read(path) or return []
        resolve_at = text.index(RESOLVE_BLOCK) or return []
        resolve = RailsAiContext::Brackets.span(text, text.index("{", resolve_at), comments: :js).to_s
        alias_at = resolve.index(ALIAS_BLOCK) or return []

        dir = File.dirname(path)
        RailsAiContext::Brackets.span(resolve, resolve.index("{", alias_at), comments: :js).to_s.scan(ALIAS_ENTRY).map do |key, value|
          target = File.join(dir, *value.scan(LITERAL).flatten)
          Alias.new(pattern: key.delete_suffix("$"), targets: [ target ], prefix: !key.end_with?("$"))
        end
      end
    end
  end
end
