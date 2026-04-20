# frozen_string_literal: true

module RailsAiContext
  module Introspectors
    # Extracts the autoloading configuration: Zeitwerk vs Classic, custom
    # inflections, autoload/eager-load paths, collapsed dirs, and ignored
    # paths. Covers RAILS_NERVOUS_SYSTEM.md §3 (Autoloading — Zeitwerk).
    class AutoloadIntrospector
      attr_reader :app

      def initialize(app)
        @app = app
      end

      # @return [Hash] autoloader configuration
      def call
        {
          mode: detect_mode,
          zeitwerk_available: zeitwerk_available?,
          autoloaders: extract_autoloaders,
          autoload_paths: relativize(app.config.autoload_paths),
          autoload_once_paths: relativize(app.config.autoload_once_paths),
          eager_load_paths: relativize(app.config.eager_load_paths),
          eager_load: !!app.config.eager_load,
          custom_inflections: extract_custom_inflections
        }
      rescue => e
        $stderr.puts "[rails-ai-context] AutoloadIntrospector#call failed: #{e.message}" if ENV["DEBUG"]
        { error: e.message }
      end

      private

      def root
        app.root.to_s
      end

      def zeitwerk_available?
        defined?(Zeitwerk) && defined?(Rails) && Rails.respond_to?(:autoloaders) && Rails.autoloaders.respond_to?(:main)
      end

      def detect_mode
        return "zeitwerk" if zeitwerk_available?
        return "classic" if defined?(Rails) && app.config.respond_to?(:autoloader) && app.config.autoloader == :classic
        "unknown"
      end

      # Return per-autoloader metadata: name, collapsed dirs, ignored paths.
      # Rails exposes `Rails.autoloaders.main` and `.once` by default.
      def extract_autoloaders
        return [] unless zeitwerk_available?

        %i[main once].filter_map do |kind|
          loader = Rails.autoloaders.public_send(kind) if Rails.autoloaders.respond_to?(kind)
          next unless loader

          entry = { name: kind.to_s }
          entry[:tag] = loader.tag.to_s if loader.respond_to?(:tag)
          entry[:collapsed] = relativize(extract_collapsed(loader))
          entry[:ignored]   = relativize(extract_ignored(loader))
          entry[:root_dirs] = relativize(extract_root_dirs(loader))
          entry
        rescue => e
          $stderr.puts "[rails-ai-context] extract autoloader #{kind} failed: #{e.message}" if ENV["DEBUG"]
          { name: kind.to_s, error: e.message }
        end
      end

      def extract_collapsed(loader)
        collapsed = loader.instance_variable_get(:@collapse_dirs)
        return [] unless collapsed
        collapsed.respond_to?(:to_a) ? collapsed.to_a.map(&:to_s) : []
      rescue => e
        $stderr.puts "[rails-ai-context] extract_collapsed failed: #{e.message}" if ENV["DEBUG"]
        []
      end

      def extract_ignored(loader)
        ignored = loader.instance_variable_get(:@ignored_paths)
        return [] unless ignored
        ignored.respond_to?(:to_a) ? ignored.to_a.map(&:to_s) : []
      rescue => e
        $stderr.puts "[rails-ai-context] extract_ignored failed: #{e.message}" if ENV["DEBUG"]
        []
      end

      def extract_root_dirs(loader)
        return loader.dirs.to_a if loader.respond_to?(:dirs) && loader.dirs.respond_to?(:to_a)
        roots = loader.instance_variable_get(:@roots)
        return roots.keys.map(&:to_s) if roots.respond_to?(:keys)
        []
      rescue => e
        $stderr.puts "[rails-ai-context] extract_root_dirs failed: #{e.message}" if ENV["DEBUG"]
        []
      end

      # Collect `inflect` blocks and `Zeitwerk::Inflector` customizations
      # declared in config/initializers/*.rb.
      def extract_custom_inflections
        dir = File.join(root, "config/initializers")
        return [] unless Dir.exist?(dir)

        inflections = []
        Dir.glob(File.join(dir, "*.rb")).sort.each do |path|
          content = RailsAiContext::SafeFile.read(path) or next
          rel = path.sub("#{root}/", "")

          # inflect "api" => "API", "xml" => "XML"
          content.scan(/inflect\(?\s*((?:["'][^"']+["']\s*=>\s*["'][^"']+["'],?\s*)+)/).each do |match|
            pairs = match[0].scan(/["']([^"']+)["']\s*=>\s*["']([^"']+)["']/)
            inflections.concat(pairs.map { |k, v| { file: rel, rule: "#{k} => #{v}" } })
          end

          # inflect.acronym "API" / inflect.plural /…/, "…" / inflect.irregular "…", "…"
          # Matches both inside `do |inflect|` blocks and via direct Inflector calls.
          content.scan(/\binflect\.(acronym|plural|singular|irregular|uncountable|human)\s+["']([^"']+)["'](?:\s*,\s*["']([^"']+)["'])?/).each do |method, arg1, arg2|
            rule = arg2 ? "#{method}: #{arg1} => #{arg2}" : "#{method}: #{arg1}"
            inflections << { file: rel, rule: rule }
          end
        end
        inflections.uniq
      rescue => e
        $stderr.puts "[rails-ai-context] extract_custom_inflections failed: #{e.message}" if ENV["DEBUG"]
        []
      end

      def relativize(paths)
        Array(paths).map do |p|
          s = p.to_s
          s.start_with?(root) ? s.sub("#{root}/", "") : s
        end
      end
    end
  end
end
