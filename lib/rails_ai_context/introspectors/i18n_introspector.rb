# frozen_string_literal: true

require "yaml"

module RailsAiContext
  module Introspectors
    # Discovers internationalization setup: locales, backends, key counts.
    class I18nIntrospector
      attr_reader :app

      def initialize(app)
        @app = app
      end

      def call
        result = {
          default_locale: I18n.default_locale.to_s,
          available_locales: I18n.available_locales.map(&:to_s).sort,
          backend: I18n.backend.class.name,
          locale_files: extract_locale_files,
          total_locale_files: count_locale_files,
          locale_coverage: detect_locale_coverage
        }
        result.merge!(detect_fallback_config)
        result
      rescue => e
        { error: e.message }
      end

      private

      def root
        app.root.to_s
      end

      def extract_locale_files
        dir = File.join(root, "config/locales")
        return [] unless Dir.exist?(dir)

        Dir.glob(File.join(dir, "**/*.{yml,yaml,rb}")).filter_map do |path|
          relative = path.sub("#{dir}/", "")
          info = { file: relative }

          if path.end_with?(".yml", ".yaml")
            begin
              data = YAML.load_file(path, permitted_classes: [ Symbol ], aliases: true) || {}
              info[:key_count] = count_keys(data)
            rescue => e
              $stderr.puts "[rails-ai-context] extract_locale_files failed: #{e.message}" if ENV["DEBUG"]
              info[:parse_error] = true
            end
          end

          info
        end.sort_by { |f| f[:file] }
      end

      def count_locale_files
        dir = File.join(root, "config/locales")
        return 0 unless Dir.exist?(dir)
        Dir.glob(File.join(dir, "**/*.{yml,yaml,rb}")).size
      end

      def count_keys(hash)
        nested_key_paths(hash).size
      end

      def detect_fallback_config
        config = {}
        config[:fallbacks] = I18n.fallbacks.to_h.transform_values { |v| v.map(&:to_s) } if I18n.respond_to?(:fallbacks) && I18n.fallbacks
        config
      rescue => e
        $stderr.puts "[rails-ai-context] detect_fallback_config failed: #{e.message}" if ENV["DEBUG"]
        {}
      end

      def detect_locale_coverage
        locales = I18n.available_locales
        return {} if locales.size < 2

        # Coverage is the share of the default locale's keys that the other
        # locale also defines. Comparing raw counts instead reports over 100%
        # for a locale that translates few default keys but adds many of its
        # own - the one number a translator must not be told is fine.
        coverage = {}
        default_keys = key_paths_for_locale(I18n.default_locale)
        locales.reject { |l| l == I18n.default_locale }.each do |locale|
          locale_keys = key_paths_for_locale(locale)
          translated = (default_keys & locale_keys).size
          coverage[locale.to_s] = {
            keys: locale_keys.size,
            missing: (default_keys - locale_keys).size,
            extra: (locale_keys - default_keys).size,
            coverage_pct: default_keys.any? ? ((translated.to_f / default_keys.size) * 100).round(1) : 0
          }
        end
        coverage
      rescue => e
        $stderr.puts "[rails-ai-context] detect_locale_coverage failed: #{e.message}" if ENV["DEBUG"]
        {}
      end

      # Dotted key paths a locale defines, with the locale root stripped so
      # `en.posts.title` and `es.posts.title` compare as the same key.
      def key_paths_for_locale(locale)
        loc = locale.to_s
        find_locale_paths(locale).flat_map do |path|
          content = RailsAiContext::SafeFile.read(path)
          next [] unless content
          data = YAML.safe_load(content, permitted_classes: [ Symbol ])
          next [] unless data.is_a?(Hash)

          # A locale root may be written `en:` or `:en:` - both load, and both
          # have to be stripped or this locale's paths compare against nothing.
          root = data.key?(loc) ? data[loc] : data.fetch(locale.to_sym, data)
          nested_key_paths(root)
        rescue StandardError
          []
        end.uniq
      rescue => e
        $stderr.puts "[rails-ai-context] key_paths_for_locale failed: #{e.message}" if ENV["DEBUG"]
        []
      end

      # Finds all YAML files contributing translations for the given locale:
      #   config/locales/en.yml
      #   config/locales/devise.en.yml
      #   config/locales/en/users.yml
      #   config/locales/admin/en.yml
      def find_locale_paths(locale)
        base = File.join(app.root, "config", "locales")
        return [] unless Dir.exist?(base)
        loc = locale.to_s
        Dir.glob(File.join(base, "**/*.{yml,yaml}")).select do |p|
          name = File.basename(p, ".*")
          rel = p.sub("#{base}/", "")
          name == loc || name.end_with?(".#{loc}") || rel.start_with?("#{loc}/") || rel.include?("/#{loc}/")
        end
      end

      def nested_key_paths(hash, prefix = nil, paths = [])
        return paths unless hash.is_a?(Hash)
        hash.each do |key, value|
          path = prefix ? "#{prefix}.#{key}" : key.to_s
          value.is_a?(Hash) ? nested_key_paths(value, path, paths) : paths << path
        end
        paths
      end
    end
  end
end
