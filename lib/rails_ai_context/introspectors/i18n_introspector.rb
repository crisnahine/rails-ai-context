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
        {
          default_locale: I18n.default_locale.to_s,
          available_locales: I18n.available_locales.map(&:to_s).sort,
          backend: I18n.backend.class.name,
          locale_files: extract_locale_files,
          total_locale_files: count_locale_files
        }
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
    end
  end
end
