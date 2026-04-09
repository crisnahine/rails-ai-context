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

      def count_keys(hash, depth: 0)
        return 0 unless hash.is_a?(Hash)
        hash.sum { |_, v| v.is_a?(Hash) ? count_keys(v, depth: depth + 1) : 1 }
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

        # Compare key counts between default and other locales
        coverage = {}
        default_count = count_keys_for_locale(I18n.default_locale)
        locales.reject { |l| l == I18n.default_locale }.each do |locale|
          locale_count = count_keys_for_locale(locale)
          coverage[locale.to_s] = { keys: locale_count, coverage_pct: default_count > 0 ? ((locale_count.to_f / default_count) * 100).round(1) : 0 }
        end
        coverage
      rescue => e
        $stderr.puts "[rails-ai-context] detect_locale_coverage failed: #{e.message}" if ENV["DEBUG"]
        {}
      end

      def count_keys_for_locale(locale)
        paths = find_locale_paths(locale)
        return 0 if paths.empty?
        paths.sum do |path|
          content = RailsAiContext::SafeFile.read(path)
          next 0 unless content
          data = YAML.safe_load(content, permitted_classes: [ Symbol ])
          count_nested_keys(data)
        rescue StandardError
          0
        end
      rescue => e
        $stderr.puts "[rails-ai-context] count_keys_for_locale failed: #{e.message}" if ENV["DEBUG"]
        0
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

      def count_nested_keys(hash, count = 0)
        return count unless hash.is_a?(Hash)
        hash.each_value { |v| count = v.is_a?(Hash) ? count_nested_keys(v, count) : count + 1 }
        count
      end
    end
  end
end
