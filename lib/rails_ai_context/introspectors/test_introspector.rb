# frozen_string_literal: true

require "pathname"

module RailsAiContext
  module Introspectors
    # Discovers test infrastructure: framework, factories/fixtures,
    # system tests, helpers, CI config, coverage.
    class TestIntrospector < Base
      extend StaticTier
      static_tier :files_only

      TEST_FILE_GLOB = "*_{spec,test}.rb"
      RAILS_CI = "config/ci.rb"

      def call
        {
          framework: detect_framework,
          factories: detect_factories,
          factory_names: detect_factory_names,
          computed_factories: factory_definitions[:computed].nonzero?,
          fabricators: detect_fabricators,
          fabricator_names: fabricator_definitions.presence,
          cucumber: detect_cucumber,
          fixtures: detect_fixtures,
          fixture_names: detect_fixture_names,
          system_tests: detect_system_tests,
          test_helpers: detect_test_helpers,
          test_helper_setup: detect_test_helper_setup,
          test_files: test_categories,
          vcr_cassettes: detect_vcr,
          ci_config: detect_ci,
          ci_steps: detect_ci_steps,
          coverage: detect_coverage,
          factory_traits: detect_factory_traits,
          test_count_by_category: detect_test_count_by_category,
          shared_examples: detect_shared_examples,
          database_cleaner: detect_database_cleaner
        }
      end

      private

      def detect_framework
        RailsAiContext::TestFramework.for(root)
      rescue => e
        RailsAiContext.debug_fail(e, "unknown", label: "detect_framework")
      end

      # First listed wins: an app holding the same thing under spec/ and test/
      # reports one location, not both. `detect_system_tests` deliberately
      # answers the other way.
      def first_dir_with(glob, *rels)
        rels.each do |rel|
          dir = File.join(root, rel)
          next unless Dir.exist?(dir)

          count = Dir.glob(File.join(dir, "**", glob)).size
          return { location: rel, count: count } if count > 0
        end
        nil
      end

      def detect_factories
        locations_with_count(factory_sources)
      end

      # factory_bot's definition_file_paths: each is loaded as `path.rb` and
      # as a directory.
      FACTORY_PATHS = %w[factories test/factories spec/factories].freeze
      FABRICATOR_PATHS = %w[test/fabricators spec/fabricators].freeze

      # [location, files] for every place factory_bot loads definitions
      # from, each pack's spec/factories and test/factories included as
      # packs-rails adds them.
      def factory_sources
        @factory_sources ||= (FACTORY_PATHS + pack_factory_paths).flat_map do |rel|
          single = app_files("#{rel}.rb")
          files = app_files(File.join(rel, "**", "*.rb"))
          [ ([ "#{rel}.rb", single ] if single.any?), ([ rel, files ] if files.any?) ].compact
        end
      end

      # ponytail: packs-specification's default pack_paths; a packs.yml that
      # sets its own pack_paths is not read.
      def pack_factory_paths
        Dir.glob(File.join(root, "packs", "{*,*/*}", "package.yml")).sort.flat_map do |manifest|
          pack = File.dirname(manifest)
          next [] if Dir.glob(File.join(pack, "*.gemspec")).any?

          rel = pack.delete_prefix("#{root}/")
          [ File.join(rel, "spec/factories"), File.join(rel, "test/factories") ]
        end
      end

      def fabricator_sources
        @fabricator_sources ||= FABRICATOR_PATHS.filter_map do |rel|
          files = app_files(File.join(rel, "**", "*.rb"))
          [ rel, files ] if files.any?
        end
      end

      def detect_fabricators
        locations_with_count(fabricator_sources)
      end

      def fabricator_definitions
        fabricator_sources.flat_map(&:last).each_with_object({}) do |path, names|
          found = SourceIntrospector.walk(path, { fabricators: -> { Listeners::GenericMacroListener.new(:Fabricator) } })[:fabricators]
          named = found.map { |hit| hit[:args].first.to_s }.reject(&:empty?)
          names[path.delete_prefix("#{root}/")] = named if named.any?
        end
      end

      def detect_cucumber
        features = app_files("features/**/*.feature")
        return nil if features.empty?

        { location: "features", count: features.size, step_definitions: app_files("features/step_definitions/**/*.rb").size }
      end

      def locations_with_count(sources)
        return nil if sources.empty?

        { location: sources.map(&:first).join(", "), count: sources.sum { |_, files| files.size } }
      end

      # The files a glob under the root matches, sorted, leaving out any whose
      # real path leaves the app or names a sensitive file.
      def app_files(pattern)
        real_root = (@real_root ||= File.realpath(root))
        Dir.glob(File.join(root, pattern)).sort.select do |path|
          real = File.realpath(path)
          File.file?(real) && RailsAiContext::SafePath.contained?(real, real_root) &&
            !RailsAiContext::SafePath.sensitive?(real.delete_prefix("#{real_root}/"))
        rescue SystemCallError
          false
        end
      end

      # The YAML fixture sets Rails loads, and apart from them the other files
      # a fixtures directory holds for file_fixture: an app can keep one YAML file
      # beside hundreds of JSON, XML and binary ones.
      def detect_fixtures
        rows = fixture_dirs.map { |rel| [ rel, app_files(File.join(rel, "**", "*")) ] }
        return nil if rows.empty?

        sets = rows.sum { |_, files| files.count { |path| File.extname(path) == ".yml" } }
        others = rows.sum { |_, files| files.count { |path| File.extname(path) != ".yml" } }
        locations = rows.map(&:first)
        found = { location: locations.join(", "), locations: locations, count: sets }
        others.positive? ? found.merge(other_files: others) : found
      end

      DEFAULT_FIXTURE_DIRS = %w[spec/fixtures test/fixtures].freeze

      # The first default directory that holds a set (an app with both reports
      # one, as for factories), then each directory a test helper adds to
      # fixture_paths that holds one and stays inside the app.
      def fixture_dirs
        @fixture_dirs ||= begin
          real_root = File.realpath(root)
          configured = HELPER_FILES.flat_map { |rel| Array(helper_walk(File.join(root, rel))&.dig(:fixture_paths)) }
          candidates = [ DEFAULT_FIXTURE_DIRS.find { |rel| fixture_sets?(rel, real_root) } ] +
                       configured.map { |rel| Pathname.new(rel).cleanpath.to_s }
          candidates.compact.uniq.select { |rel| fixture_sets?(rel, real_root) }
        end
      end

      def fixture_sets?(rel, real_root)
        return false if RailsAiContext::SafePath.traversal?(rel)

        real = File.realpath(File.join(root, rel))
        RailsAiContext::SafePath.contained?(real, real_root) && File.directory?(real) &&
          Dir.glob(File.join(real, "**", "*.yml")).any?
      rescue SystemCallError
        false
      end

      # Both bases are summed: an app that keeps system tests under spec/ and
      # test/ has both, and reporting one hid the other.
      def detect_system_tests
        rows = %w[spec/system test/system].filter_map do |rel|
          dir = File.join(root, rel)
          next unless Dir.exist?(dir)

          count = Dir.glob(File.join(dir, "**/#{TEST_FILE_GLOB}")).size
          [ rel, count ] if count > 0
        end
        return nil if rows.empty?

        { location: rows.map(&:first).join(", "), count: rows.sum(&:last) }
      end

      # Where suites keep helper modules. test/helpers is not one: Rails runs
      # it as a test folder for helper tests.
      HELPER_DIRS = %w[spec/support test/support test/test_helpers].freeze

      def detect_test_helpers
        HELPER_DIRS.flat_map { |rel| Dir.glob(File.join(root, rel, "**/*.rb")) }.map { |f| f.sub("#{root}/", "") }.sort
      end

      def detect_factory_names
        factory_definitions[:names]
      end

      # One walk per factory file for both the factories and their traits.
      # A factory whose name is computed (`factory :"#{model}_comment"` in a
      # loop, as Consul writes) has no name to list, so it is counted apart.
      def factory_definitions
        @factory_definitions ||= begin
          names = {}
          traits = {}
          computed = 0
          factory_sources.flat_map(&:last).each do |path|
            ast_data = SourceIntrospector.walk(path, {
              factories: -> { Listeners::GenericMacroListener.new(:factory) },
              traits: -> { Listeners::GenericMacroListener.new(:trait) }
            })
            named = ast_data[:factories].map { |hit| hit[:args].first.to_s }
            computed += named.count(&:empty?)
            named = named.reject(&:empty?)
            trait_names = ast_data[:traits].map { |hit| hit[:args].first.to_s }.reject(&:empty?)
            names[path.sub("#{root}/", "")] = named if named.any?
            traits[File.basename(path)] = trait_names if trait_names.any?
          end
          { names: names.presence, traits: traits.presence, computed: computed }
        end
      end

      # Each set named as Rails names it, by its path under its directory,
      # with the labels ActiveRecord loads. A file that does not read as YAML
      # still gives the labels its top-level keys spell.
      def detect_fixture_names
        names = {}
        fixture_dirs.each do |rel|
          dir = File.join(root, rel)
          app_files(File.join(rel, "**", "*.yml")).each do |path|
            set = path.delete_prefix("#{dir}/").delete_suffix(".yml")
            next if names.key?(set)

            content = RailsAiContext::SafeFile.read(path) or next
            labels = RailsAiContext::FixtureKeys.parse(content)&.keys ||
                     content.scan(/^(\w+):/).flatten.select { |key| RailsAiContext::FixtureKeys.name?(key) }
            names[set] = labels if labels.any?
          end
        end
        names.presence
      end

      # Calls that configure every test or every system test, shown as written.
      SETUP_MACROS = %i[parallelize fixtures driven_by].freeze

      HELPER_FILES = %w[spec/rails_helper.rb spec/spec_helper.rb test/test_helper.rb].freeze

      def detect_test_helper_setup
        helpers = (HELPER_FILES + %w[test/application_system_test_case.rb]).map { |rel| File.join(root, rel) }
        # Apps also configure helpers in support files (Errbit's spec/support/devise.rb). A bare
        # include there is usually a support module's own mixin, so only config.include counts.
        support = HELPER_DIRS.flat_map { |rel| Dir.glob(File.join(root, rel, "**", "*.rb")).sort }

        setup = []
        calls = []
        (helpers + support).each do |path|
          ast = helper_walk(path) or next
          hits = helpers.include?(path) ? ast[:bare] + ast[:chained] : ast[:chained]
          # `config.include Helpers, :js` scopes Helpers to tagged examples; the tag is no helper.
          hits.each { |hit| setup.concat(hit[:values].map(&:to_s).grep(/\A[A-Z]\w*(?:::[A-Z]\w*)*\z/)) }
          source = AstCache.parse(path).source
          ast[:setup].each { |hit| calls << source.slice(hit[:offset], hit[:end_offset] - hit[:offset]).squish }
        end
        (setup + calls).uniq
      end

      # One walk per helper file serves every reader of it.
      def helper_walk(path)
        @helper_walks ||= {}
        return @helper_walks[path] if @helper_walks.key?(path)

        @helper_walks[path] = File.file?(path) ? SourceIntrospector.walk(path, {
          bare:          -> { Listeners::GenericMacroListener.new(:include) },
          chained:       -> { Listeners::ChainedCallListener.new(:include, receiver: :config) },
          setup:         -> { Listeners::GenericMacroListener.new(*SETUP_MACROS) },
          fixture_paths: Listeners::FixturePathsListener,
          cleaner:       -> { Listeners::ConfigAssignmentListener.new(:DatabaseCleaner) }
        }) : nil
      end

      def detect_vcr
        first_dir_with("*.yml", "spec/cassettes", "spec/vcr_cassettes", "test/cassettes", "test/vcr_cassettes")
      end

      def detect_ci
        configs = []
        configs << "rails_ci" if File.file?(File.join(root, RAILS_CI))
        configs << "github_actions" if Dir.exist?(File.join(root, ".github/workflows"))
        configs << "circleci" if File.exist?(File.join(root, ".circleci/config.yml"))
        configs << "gitlab_ci" if File.exist?(File.join(root, ".gitlab-ci.yml"))
        configs << "travis" if File.exist?(File.join(root, ".travis.yml"))
        configs << "buildkite" if Dir.exist?(File.join(root, ".buildkite")) || Dir.glob(File.join(root, "buildkite.{yml,yaml,json}")).any?
        configs << "jenkins" if File.file?(File.join(root, "Jenkinsfile"))
        configs
      end

      # The steps bin/ci runs, from the `step title, *command` calls of the
      # CI DSL Rails 8.1 generates.
      def detect_ci_steps
        content, = RailsAiContext::SafePath.read(RAILS_CI, under: root)
        return nil unless content

        hits = SourceIntrospector.walk_source(content, steps: -> { Listeners::GenericMacroListener.new(:step) })[:steps]
        steps = hits.filter_map do |hit|
          title, *command = hit[:values]
          { name: title, command: command.join(" ") } if title.is_a?(String)
        end
        steps.presence
      end

      def detect_coverage
        RailsAiContext::GemLock.for(root).present?("simplecov") ? "simplecov" : nil
      end

      def detect_factory_traits
        factory_definitions[:traits]
      rescue => e
        RailsAiContext.debug_fail(e, nil, label: "detect_factory_traits")
      end

      def detect_shared_examples
        shared = []
        %w[spec test].each do |base|
          support_dir = File.join(root, base, "support")
          next unless Dir.exist?(support_dir)
          Dir.glob(File.join(support_dir, "**/*.rb")).each do |path|
            ast_data = SourceIntrospector.walk(path, {
              shared: -> { Listeners::GenericMacroListener.new(:shared_examples, :shared_context, :shared_examples_for) }
            })
            ast_data[:shared].each do |entry|
              name = entry[:args].first&.to_s
              next unless name && !name.empty?
              shared << { name: name, file: path.sub("#{root}/", "") }
            end
          end
        end
        shared.sort_by { |s| s[:name] }
      rescue => e
        RailsAiContext.debug_fail(e, [], label: "detect_shared_examples")
      end

      def detect_database_cleaner
        # Every adapter gem depends on database_cleaner-core, so core is the
        # complete signal; the unsuffixed name is the pre-2.0 single gem.
        if RailsAiContext::GemLock.for(root).any?("database_cleaner", "database_cleaner-core")
          strategy = nil
          HELPER_FILES.each do |helper|
            ast = helper_walk(File.join(root, helper)) or next
            hit = ast[:cleaner].find { |h| h[:assignment] && h[:path] == [ :strategy ] }
            strategy = hit[:value].to_s if hit
          end
          { detected: true, strategy: strategy }.compact
        end
      rescue => e
        RailsAiContext.debug_fail(e, nil, label: "detect_database_cleaner")
      end

      # Kept for the .ai-context.json dump, whose keys are read back by
      # tooling outside this gem. No tool renders it; the Test Files section
      # states the same counts with their locations.
      def detect_test_count_by_category
        test_categories.transform_values { |row| row[:count] }
      end

      # One row per top-level directory under spec/ or test/ that holds test
      # files, plus a row keyed by the base directory for files loose at its
      # root. Naming the categories instead of reading them hid every
      # directory a convention did not predict.
      #
      # Only files named for a test framework are counted. Globbing every .rb
      # counted whatever a project keeps beside its specs - mailer previews,
      # shared contexts, page objects - under a heading that promises tests.
      # Two payload keys are built from this walk, so it runs once per call.
      def test_categories
        @test_categories ||= build_test_categories
      end

      def build_test_categories
        rows = Hash.new { |h, k| h[k] = [] }

        %w[spec test].each do |base|
          base_dir = File.join(root, base)
          next unless Dir.exist?(base_dir)

          Dir.children(base_dir).sort.each do |entry|
            dir = File.join(base_dir, entry)
            next unless File.directory?(dir)

            count = Dir.glob(File.join(dir, "**/#{TEST_FILE_GLOB}")).size
            rows[entry] << [ "#{base}/#{entry}", count ] if count > 0
          end

          loose = Dir.glob(File.join(base_dir, TEST_FILE_GLOB)).size
          rows[base] << [ base, loose ] if loose > 0
        end

        rows
          .transform_values { |pairs| { location: pairs.map(&:first).join(", "), count: pairs.sum(&:last) } }
          .sort_by { |cat, row| [ -row[:count], cat ] }
          .to_h
      rescue => e
        RailsAiContext.debug_fail(e, {}, label: "test_categories")
      end
    end
  end
end
