# frozen_string_literal: true

require "yaml"

module RailsAiContext
  module Introspectors
    # Discovers internationalization setup: locales, backends, key counts.
    class I18nIntrospector
      extend StaticTier
      static_tier :alternate_source

      # Both spellings apps use: `config.i18n.default_locale = :es` in
      # application.rb or an environment file, and a bare
      # `I18n.default_locale = :es` in an initializer.
      DEFAULT_LOCALE_ASSIGNMENT = /(?:config\.i18n|I18n)\.default_locale\s*=\s*[:"']([\w-]+)/

      attr_reader :app

      def initialize(app)
        @app = app
      end

      def call
        coverage, untranslated = detect_locale_coverage
        result = {
          default_locale: I18n.default_locale.to_s,
          available_locales: I18n.available_locales.map(&:to_s).sort,
          backend: I18n.backend.class.name,
          locale_files: extract_locale_files,
          total_locale_files: count_locale_files,
          locale_coverage: coverage,
          locales_without_translations: untranslated
        }
        result.merge!(detect_fallback_config)
        result
      rescue => e
        { error: e.message }
      end

      # The locale files are the same files either way; only the list of
      # locales and the default came from a running I18n. Read both from disk
      # rather than report the library's own defaults as the app's.
      def static_call
        locales = locales_from_files
        default = default_locale_from_config
        coverage, untranslated = detect_locale_coverage(locales: locales.map(&:to_sym), default: default.to_sym)

        {
          default_locale: default,
          available_locales: locales,
          backend: nil,
          locale_files: extract_locale_files,
          total_locale_files: count_locale_files,
          locale_coverage: coverage,
          locales_without_translations: untranslated
        }.merge(detect_fallback_config)
      rescue => e
        { error: e.message }
      end

      private

      # Every top-level key across config/locales - the same population Rails
      # builds available_locales from.
      def locales_from_files
        dir = File.join(root, "config/locales")
        return [] unless Dir.exist?(dir)

        Dir.glob(File.join(dir, "**/*.{yml,yaml}")).flat_map do |path|
          content = RailsAiContext::SafeFile.read(path)
          next [] unless content

          # aliases: true, like extract_locale_files. Sharing formats through a
          # YAML anchor is ordinary, and without the flag Psych raises, the
          # rescue swallows it, and every locale in that file disappears while
          # the Locale Files section still lists it.
          data = YAML.safe_load(content, permitted_classes: [ Symbol ], aliases: true)
          data.is_a?(Hash) ? data.keys.map(&:to_s) : []
        rescue StandardError
          []
        end.uniq.sort
      end

      # Rails' own default is :en, so "en" is the right answer when the app
      # never says otherwise - not a guess.
      def default_locale_from_config
        candidates = [ File.join(root, "config", "application.rb") ] +
                     Dir.glob(File.join(root, "config", "environments", "*.rb")) +
                     Dir.glob(File.join(root, "config", "initializers", "*.rb"))

        candidates.each do |path|
          next unless File.exist?(path)

          content = RailsAiContext::SafeFile.read(path)
          match = content&.match(DEFAULT_LOCALE_ASSIGNMENT)
          return match[1] if match
        end
        "en"
      end

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
              # Which locales this file actually serves. The filename is only a
              # convention, and a gem-provided file is named for the gem.
              info[:locales] = data.is_a?(Hash) ? data.keys.map(&:to_s) : []
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

      # @return [Array(Hash, Array<String>)] coverage per locale, and the
      #   locales left out of it because they carry no translations.
      def detect_locale_coverage(locales: I18n.available_locales, default: I18n.default_locale)
        return [ {}, [] ] if locales.size < 2

        # Coverage is the share of the default locale's keys that the other
        # locale also defines. Comparing raw counts instead reports over 100%
        # for a locale that translates few default keys but adds many of its
        # own - the one number a translator must not be told is fine.
        coverage = {}
        untranslated = []
        default_keys = key_paths_for_locale(default)

        # With nothing to measure against - a default_locale the app
        # configures but ships no file for - every locale scores zero, and
        # bucketing them all says something false about each.
        return [ {}, [] ] if default_keys.empty?
        locales.reject { |l| l == default }.each do |locale|
          locale_keys = key_paths_for_locale(locale)
          translated = (default_keys & locale_keys).size
          pct = ((translated.to_f / default_keys.size) * 100).round(1)

          # Below the rounding floor there is nothing to show but zeroes. Rails
          # lists a locale per language when the app keeps a language-name
          # lookup table under config/locales, and such a table shares a key or
          # two with the default by coincidence - on Discourse that produced
          # 138 rows reading "0.0% - 11918 missing", a translation effort
          # nobody had started. Naming those locales is the honest form; a
          # screen of zeroes is not.
          if pct.zero?
            # The key count travels with the name: a locale can define plenty and
            # still share none with the default - GitLab's zh-CN has 109, all
            # from gem-provided files - and a bare name reads as "not
            # translated" when the truth is "translated something else".
            untranslated << { locale: locale.to_s, keys: locale_keys.size }
            next
          end

          coverage[locale.to_s] = {
            keys: locale_keys.size,
            missing: (default_keys - locale_keys).size,
            extra: (locale_keys - default_keys).size,
            coverage_pct: pct
          }
        end
        [ coverage, untranslated ]
      rescue => e
        $stderr.puts "[rails-ai-context] detect_locale_coverage failed: #{e.message}" if ENV["DEBUG"]
        [ {}, [] ]
      end

      # Dotted key paths a locale defines, with the locale root stripped so
      # `en.posts.title` and `es.posts.title` compare as the same key.
      def key_paths_for_locale(locale)
        loc = locale.to_s
        find_locale_paths(locale).flat_map do |path|
          content = RailsAiContext::SafeFile.read(path)
          next [] unless content
          data = YAML.safe_load(content, permitted_classes: [ Symbol ], aliases: true)
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
        base = locales_dir
        return [] unless base

        loc = locale.to_s
        named = locale_file_paths.select do |p|
          name = File.basename(p, ".*")
          rel = p.sub("#{base}/", "")
          name == loc || name.end_with?(".#{loc}") || rel.start_with?("#{loc}/") || rel.include?("/#{loc}/")
        end

        # Nothing requires a locale file to be named for its locale, and a
        # locale can have both: its own file and keys in a shared one. Reading
        # the convention alone scores it on a fraction of what it translates,
        # and reports a locale that lives only in a shared file as having no
        # translations - a positive claim, and a false one.
        (named + paths_by_declared_locale.fetch(loc, [])).uniq
      end

      def locales_dir
        return @locales_dir if defined?(@locales_dir)

        dir = File.join(app.root, "config", "locales")
        @locales_dir = Dir.exist?(dir) ? dir : nil
      end

      def locale_file_paths
        @locale_file_paths ||= locales_dir ? Dir.glob(File.join(locales_dir, "**/*.{yml,yaml}")).sort : []
      end

      # locale => the files declaring it, built in ONE pass. Asking every file
      # about every locale is O(locales x files): 187 locales over 108 files
      # took Discourse's i18n answer from under a second to four and a half
      # minutes.
      def paths_by_declared_locale
        @paths_by_declared_locale ||= locale_file_paths.each_with_object({}) do |path, index|
          top_level_locales(path).each { |loc| (index[loc] ||= []) << path }
        end
      end

      def top_level_locales(path)
        content = RailsAiContext::SafeFile.read(path)
        return [] unless content

        data = YAML.safe_load(content, permitted_classes: [ Symbol ], aliases: true)
        data.is_a?(Hash) ? data.keys.map(&:to_s) : []
      rescue StandardError
        []
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
