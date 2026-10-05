# frozen_string_literal: true

require "yaml"

module RailsAiContext
  module Introspectors
    # Discovers internationalization setup: locales, backends, key counts.
    class I18nIntrospector < Base
      extend StaticTier
      static_tier :alternate_source

      # Both spellings apps use: `config.i18n.default_locale = :es` in
      # application.rb or an environment file, and a bare
      # `I18n.default_locale = :es` in an initializer, which may also reach
      # config through `Rails.application.config.i18n`.
      # Anchored past the line start so a commented example does not win:
      # GitLab ships `# config.i18n.default_locale = :de` and every coverage
      # line then measured an English app against German.
      DEFAULT_LOCALE_ASSIGNMENT = /^[^\S\n]*((?:(?:::)?Rails\.(?:application\.config|configuration)|config)\.i18n|I18n)\.default_locale\s*=\s*[:"']([\w-]+)/

      # `config.i18n.available_locales`, and only that: the listener strips the
      # root it matched, so a bare `config.available_locales` is any gem's own
      # setting inside its own configure block.
      CONFIG_AVAILABLE_LOCALES = [ [ :i18n, :available_locales ] ].freeze
      I18N_AVAILABLE_LOCALES = [ [ :available_locales ], [ :config, :available_locales ] ].freeze

      # Railties' `paths.add "config/locales", glob: "**/*.{rb,yml}"`, the same from 7.0 to 8.1.
      RAILS_LOCALE_GLOB = "**/*.{rb,yml}"
      # I18n loads these from an explicit load_path entry (load_rb, load_yml, load_yaml).
      LOAD_PATH_EXTENSIONS = %w[.rb .yml .yaml].freeze

      REFUSED_LOCALE_FILE = {
        parse_error: true, locales: [], key_count: 0, key_paths: []
      }.freeze

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
        result.merge!(in_repo_locale_counts)
        result.merge!(detect_fallback_config)
        result
      end

      # The locale files are the same files either way; only the list of
      # locales and the default came from a running I18n. Read both from disk
      # rather than report the library's own defaults as the app's. The backend
      # and the fallbacks belong to whichever process asks, so both keys stay
      # in the answer and are declared unanswered.
      def static_call
        configured = configured_available_locales
        locales = configured || locales_from_files
        default = default_locale_from_config
        coverage, untranslated = detect_locale_coverage(locales: locales.map(&:to_sym), default: default.to_sym)

        {
          default_locale: default,
          available_locales: locales,
          available_locales_source: configured ? "config" : "locale_files",
          backend: nil,
          locale_files: extract_locale_files,
          total_locale_files: count_locale_files,
          locale_coverage: coverage,
          locales_without_translations: untranslated,
          fallbacks: nil,
          unavailable_sections: %w[backend fallbacks]
        }.merge(in_repo_locale_counts)
      end

      private

      # An in-repo engine's config/locales can dwarf the app's, and parsing them costs most
      # of a run for keys no app-level question asks, so only the count is reported.
      def in_repo_locale_counts
        dirs = PathResolver.locale_roots(root).map { |dir| File.join(dir, "config", "locales") }
        return {} if dirs.empty?

        files = dirs.sum { |dir| Dir.glob(File.join(dir, RAILS_LOCALE_GLOB)).size }
        { in_repo_locale_dirs: dirs.size, in_repo_locale_files: files }
      end

      # Every top-level key across config/locales - the population Rails builds
      # available_locales from while the app leaves the setting alone. The
      # fallback, then: for an app that never assigns the list, and for one
      # whose assignment is there but cannot be evaluated from source.
      def locales_from_files
        locale_file_paths.flat_map { |path| locale_index[path][:locales] }.uniq.sort
      end

      # Rails' own default is :en, so "en" is the right answer when the app
      # never says otherwise - not a guess.
      def default_locale_from_config
        entries = config_candidate_files.flat_map do |path, ambiguous|
          content = RailsAiContext::SafeFile.read(path)
          (content&.scan(DEFAULT_LOCALE_ASSIGNMENT) || []).map do |spelling, locale|
            { spelling: spelling_of(spelling), ambiguous: ambiguous, value: locale }
          end
        end

        resolve_assignments(entries) || "en"
      end

      def spelling_of(prefix)
        prefix == "I18n" ? :i18n : :config
      end

      # I18n::Railtie buffers app.config.i18n and applies it from
      # after_initialize, once every initializer has run, so a `config.i18n`
      # assignment lands on top of a bare `I18n` one wherever either sits.
      # Within one spelling the last assignment executed is the one that lands.
      def resolve_assignments(entries)
        by_spelling = entries.group_by { |entry| entry[:spelling] }
        group = [ :config, :i18n ].lazy.map { |spelling| decided(by_spelling[spelling] || []) }.find(&:any?)
        group&.last&.fetch(:value)
      end

      # Environment files read only because the running one is absent are
      # alternatives, not a sequence. When they disagree, which one runs
      # decides and source cannot say, so they drop out rather than let
      # filename order pick.
      def decided(entries)
        ambiguous = entries.select { |entry| entry[:ambiguous] }
        return entries if ambiguous.map { |entry| entry[:value] }.uniq.size <= 1

        entries - ambiguous
      end

      # The config files Rails runs, in the order it runs them: application.rb,
      # then the environment file, then the initializers. Each pairs with
      # whether it is one of several environments read as a fallback.
      def config_candidate_files
        # Rails runs one environment file, so another environment's assignment
        # says nothing about this one. The rest are read only when the running
        # one is absent, where reading nothing would be the worse answer.
        env = ENV["RAILS_ENV"] || "development"
        all_environments = Dir.glob(File.join(root, "config", "environments", "*.rb")).sort
        running = all_environments.select { |path| File.basename(path, ".rb") == env }
        environments = running.any? ? running.map { |path| [ path, false ] }
                                    : all_environments.map { |path| [ path, true ] }

        ([ [ File.join(root, "config", "application.rb"), false ] ] + environments +
          PathResolver.initializer_paths(root).map { |path| [ path, false ] })
          .select { |path, _ambiguous| File.exist?(path) }
      end

      # The list the app enables, or nil when it never says. Resolved the same
      # way the default locale is: the buffered config.i18n spelling first,
      # last assignment within a spelling.
      def configured_available_locales
        entries = config_candidate_files.flat_map do |path, ambiguous|
          # Every assignment, not only the readable ones: a literal a later
          # computed assignment overwrites is not the list Rails hands I18n,
          # so it falls through to the locale files and says so.
          available_locales_assignments(path).map do |entry|
            { spelling: entry[:spelling], ambiguous: ambiguous, value: literal_locale_list(entry[:value]) }
          end
        end

        resolve_assignments(entries)
      end

      def available_locales_assignments(path)
        walked = config_walk(path)
        return [] unless walked

        entries = walked[:config].select { |entry| CONFIG_AVAILABLE_LOCALES.include?(entry[:path]) }
                                 .map { |entry| entry.merge(spelling: :config) } +
                  walked[:i18n].select { |entry| I18N_AVAILABLE_LOCALES.include?(entry[:path]) }
                               .map { |entry| entry.merge(spelling: :i18n) }
        entries.select { |entry| entry[:assignment] }.sort_by { |entry| entry[:location] }
      end

      # One walk per config file for every i18n setting read from it, and none for
      # a file that never mentions one.
      def config_walk(path)
        @config_walks ||= {}
        return @config_walks[path] if @config_walks.key?(path)

        # Reading first also keeps an unreadable file away from the parser.
        source = RailsAiContext::SafeFile.read(path)
        @config_walks[path] = if source&.match?(/available_locales|load_path/)
          SourceIntrospector.walk(path, {
            config:    -> { Listeners::ConfigAssignmentListener.new("config") },
            i18n:      -> { Listeners::ConfigAssignmentListener.new("I18n") },
            load_path: Listeners::I18nLoadPathListener
          })
        end
      # One initializer this introspector cannot parse must not take the whole
      # I18n answer down through static_call's rescue.
      rescue StandardError => e
        @config_walks[path] = RailsAiContext.debug_fail(e, nil, label: "i18n config walk of #{path}")
      end

      # Files config.i18n.load_path adds, from literal paths and globs under the app root.
      def load_path_files
        real_root = File.realpath(root)
        patterns = config_candidate_files.flat_map { |path, _| config_walk(path)&.dig(:load_path) || [] }
        patterns.reject { |pattern| SafePath.traversal?(pattern) }.flat_map do |pattern|
          Dir.glob(File.join(root, pattern)).select do |file|
            LOAD_PATH_EXTENSIONS.include?(File.extname(file)) && File.file?(file) &&
              File.realpath(file).start_with?("#{real_root}/")
          end
        end
      rescue SystemCallError
        []
      end

      # Only a literal list of names answers the question. `+= [...]`, a method
      # call or a redacted value says the app sets it but not to what.
      def literal_locale_list(value)
        return nil unless value.is_a?(Array) && !value.empty?
        return nil unless value.all? { |element| element.is_a?(Symbol) || element.is_a?(String) }

        value.map(&:to_s).uniq.sort
      end

      def extract_locale_files
        locale_file_paths.map do |path|
          info = { file: display_path(path) }
          entry = locale_index[path]
          if entry && !entry[:parse_error]
            info[:key_count] = entry[:key_count]
            # Which locales this file actually serves. The filename is only a
            # convention, and a gem-provided file is named for the gem.
            info[:locales] = entry[:locales]
          else
            info[:parse_error] = true
          end
          info
        end.sort_by { |f| f[:file] }
      end

      # config/locales files keep their names relative to it; a load_path file is named from the app root.
      def display_path(path)
        base = locales_dir
        base && path.start_with?("#{base}/") ? path.delete_prefix("#{base}/") : path.delete_prefix("#{root}/")
      end

      def count_locale_files
        locale_file_paths.size
      end

      def detect_fallback_config
        return {} unless I18n.backend.class.include?(I18n::Backend::Fallbacks)

        # Fallbacks fills its hash one locale at a time on first lookup, so ask for each.
        fallbacks = I18n.fallbacks
        locales = (I18n.available_locales.map(&:to_sym) + fallbacks.to_h.keys).uniq
        { fallbacks: locales.to_h { |locale| [ locale.to_s, fallbacks[locale].map(&:to_s) ] } }
      rescue => e
        RailsAiContext.debug_fail(e, {}, label: "detect_fallback_config")
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
          pct = Percent.floor(translated, default_keys.size)

          # Below the rounding floor there is nothing to show but zeroes. Rails
          # lists a locale per language when the app keeps a language-name
          # lookup table under config/locales, and such a table shares a key or
          # two with the default by coincidence - on Discourse that produced
          # 138 rows reading "0.0% - 11918 missing", a translation effort
          # nobody had started.
          #
          # The key count travels with the name: a locale can define plenty and
          # still share none with the default, and a bare name reads as "not
          # translated" when the truth is "translated something else".
          #
          # The row is written either way. Naming a locale here only asks the
          # renderer to group it; deleting its numbers would leave a
          # translation genuinely started below the floor with nothing to read.
          untranslated << { locale: locale.to_s, keys: locale_keys.size } if pct.zero?

          coverage[locale.to_s] = {
            keys: locale_keys.size,
            missing: (default_keys - locale_keys).size,
            extra: (locale_keys - default_keys).size,
            coverage_pct: pct
          }
        end
        [ coverage, untranslated ]
      rescue => e
        RailsAiContext.debug_fail(e, [ {}, [] ], label: "detect_locale_coverage")
      end

      # Dotted key paths a locale defines, with the locale root stripped so
      # `en.posts.title` and `es.posts.title` compare as the same key.
      def key_paths_for_locale(locale)
        loc = locale.to_s
        find_locale_paths(locale).flat_map do |path|
          entry = locale_index[path] or next []

          # A locale root may be written `en:` or `:en:` - both load, and both
          # have to be stripped or this locale's paths compare against nothing.
          # A file that names no root for this locale contributes whole paths.
          next entry[:key_paths] unless entry[:locales].include?(loc)

          prefix = "#{loc}."
          entry[:key_paths].filter_map { |path| path.delete_prefix(prefix) if path.start_with?(prefix) }
        end.uniq
      rescue => e
        RailsAiContext.debug_fail(e, [], label: "key_paths_for_locale")
      end

      # Finds all YAML files contributing translations for the given locale:
      #   config/locales/en.yml
      #   config/locales/devise.en.yml
      #   config/locales/en/users.yml
      #   config/locales/admin/en.yml
      def find_locale_paths(locale)
        loc = locale.to_s
        named = locale_file_paths.select do |p|
          name = File.basename(p, ".*")
          rel = display_path(p)
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

      # The files Rails loads: config/locales by its glob, then what config.i18n.load_path adds.
      def locale_file_paths
        @locale_file_paths ||= begin
          defaults = locales_dir ? Dir.glob(File.join(locales_dir, RAILS_LOCALE_GLOB)) : []
          (defaults + load_path_files).uniq.sort
        end
      end

      # locale => the files declaring it, built in ONE pass. Asking every file
      # about every locale is O(locales x files): 187 locales over 108 files
      # took Discourse's i18n answer from under a second to four and a half
      # minutes.
      def paths_by_declared_locale
        @paths_by_declared_locale ||= locale_file_paths.each_with_object({}) do |path, index|
          locale_index[path][:locales].each { |loc| (index[loc] ||= []) << path }
        end
      end

      # Every locale file, parsed once. Only the key paths survive: holding
      # every locale YAML resident trades an i18n-heavy app's CPU spike for a
      # memory one.
      def locale_index
        @locale_index ||= locale_file_paths.to_h { |path| [ path, index_locale_file(path) ] }
      end

      def index_locale_file(path)
        content = RailsAiContext::SafeFile.read(path)
        return REFUSED_LOCALE_FILE unless content

        data = path.end_with?(".rb") ? ruby_locale_data(content) : yaml_locale_data(content)
        key_paths = nested_key_paths(data)

        # Only the locale-rooted paths are kept. The per-locale lists are the
        # same strings without their root, so holding both doubled what an
        # app with a hundred locale files kept resident; key_paths_for_locale
        # strips the root instead.
        {
          parse_error: false,
          locales: data.keys.map(&:to_s),
          key_count: key_paths.size,
          key_paths: key_paths
        }
      rescue StandardError => e
        RailsAiContext.debug_fail(e, REFUSED_LOCALE_FILE, label: "i18n parse of #{path}")
      end

      def yaml_locale_data(content)
        # aliases: true - sharing formats through a YAML anchor is ordinary,
        # and without the flag Psych raises and every locale in that file
        # disappears while the Locale Files section still lists it.
        data = YAML.safe_load(content, permitted_classes: [ Symbol ], aliases: true)
        data.is_a?(Hash) ? data : {}
      end

      # I18n evals a .rb locale file for the Hash it returns. Its literal keys are read
      # from the AST instead, so neither tier runs app code; a non-literal value is a leaf.
      def ruby_locale_data(content)
        result = AstCache.parse_string(content)
        raise ArgumentError, "unparseable Ruby locale file" if result.failure?

        hash = result.value.statements.body.last
        hash.is_a?(Prism::HashNode) ? literal_hash(hash) : {}
      end

      def literal_hash(node)
        node.elements.each_with_object({}) do |element, hash|
          next unless element.is_a?(Prism::AssocNode) && element.key.respond_to?(:unescaped)

          value = element.value
          hash[element.key.unescaped] = value.is_a?(Prism::HashNode) ? literal_hash(value) : true
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
