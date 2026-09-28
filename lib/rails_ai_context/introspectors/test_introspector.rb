# frozen_string_literal: true

module RailsAiContext
  module Introspectors
    # Discovers test infrastructure: framework, factories/fixtures,
    # system tests, helpers, CI config, coverage.
    class TestIntrospector < Base
      extend StaticTier
      static_tier :files_only

      TEST_FILE_GLOB = "*_{spec,test}.rb"

      def call
        {
          framework: detect_framework,
          factories: detect_factories,
          factory_names: detect_factory_names,
          computed_factories: factory_definitions[:computed].nonzero?,
          fixtures: detect_fixtures,
          fixture_names: detect_fixture_names,
          system_tests: detect_system_tests,
          test_helpers: detect_test_helpers,
          test_helper_setup: detect_test_helper_setup,
          test_files: test_categories,
          vcr_cassettes: detect_vcr,
          ci_config: detect_ci,
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
        first_dir_with("*.rb", "spec/factories", "test/factories")
      end

      # The YAML fixture sets Rails loads, and apart from them the other files
      # a fixtures directory holds for file_fixture: an app can keep one YAML file
      # beside hundreds of JSON, XML and binary ones.
      def detect_fixtures
        found = first_dir_with("*.yml", "spec/fixtures", "test/fixtures") or return nil

        dir = File.join(root, found[:location])
        others = Dir.glob(File.join(dir, "**", "*")).count { |path| File.file?(path) && File.extname(path) != ".yml" }
        others.positive? ? found.merge(other_files: others) : found
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

      def detect_test_helpers
        dirs = [
          File.join(root, "spec/support"),
          File.join(root, "test/helpers")
        ]

        dirs.filter_map do |dir|
          next unless Dir.exist?(dir)
          Dir.glob(File.join(dir, "**/*.rb")).map { |f| f.sub("#{root}/", "") }
        end.flatten.sort
      end

      def detect_factory_names
        factory_definitions[:names]
      end

      # One walk per factory file for both the factories and their traits.
      # A factory whose name is computed (`factory :"#{model}_comment"` in a
      # loop, as Consul writes) has no name to list, so it is counted apart.
      # The first factory directory that has any factory wins.
      def factory_definitions
        @factory_definitions ||= begin
          found = { names: nil, traits: nil, computed: 0 }
          %w[spec/factories test/factories].each do |dir_rel|
            dir = File.join(root, dir_rel)
            next unless Dir.exist?(dir)

            names = {}
            traits = {}
            computed = 0
            Dir.glob(File.join(dir, "**/*.rb")).each do |path|
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
            next if names.empty? && traits.empty? && computed.zero?

            found = { names: names.presence, traits: traits.presence, computed: computed }
            break
          end
          found
        end
      end

      def detect_fixture_names
        %w[spec/fixtures test/fixtures].each do |dir_rel|
          dir = File.join(root, dir_rel)
          next unless Dir.exist?(dir)

          names = {}
          Dir.glob(File.join(dir, "**/*.yml")).each do |path|
            # The set's name, as Rails reads it: its path under the directory.
            file = path.delete_prefix("#{dir}/").delete_suffix(".yml")
            content = RailsAiContext::SafeFile.read(path) or next
            keys = content.scan(/^(\w+):/).flatten.select { |key| RailsAiContext::FixtureKeys.name?(key) }
            names[file] = keys if keys.any?
          end
          return names if names.any?
        end
        nil
      end

      def detect_test_helper_setup
        helpers = %w[spec/rails_helper.rb spec/spec_helper.rb test/test_helper.rb].map { |rel| File.join(root, rel) }
        # Apps also configure helpers in support files (Errbit's spec/support/devise.rb). A bare
        # include there is usually a support module's own mixin, so only config.include counts.
        support = %w[spec/support test/support].flat_map { |rel| Dir.glob(File.join(root, rel, "**", "*.rb")).sort }

        setup = []
        (helpers + support).each do |path|
          next unless File.file?(path)
          ast = SourceIntrospector.walk(path, {
            bare:    -> { Listeners::GenericMacroListener.new(:include) },
            chained: -> { Listeners::ChainedCallListener.new(:include, receiver: :config) }
          })
          hits = helpers.include?(path) ? ast[:bare] + ast[:chained] : ast[:chained]
          hits.each { |hit| setup.concat(hit[:values].map(&:to_s)) }
        end
        setup.uniq
      end

      def detect_vcr
        first_dir_with("*.yml", "spec/cassettes", "spec/vcr_cassettes", "test/cassettes", "test/vcr_cassettes")
      end

      def detect_ci
        configs = []
        configs << "github_actions" if Dir.exist?(File.join(root, ".github/workflows"))
        configs << "circleci" if File.exist?(File.join(root, ".circleci/config.yml"))
        configs << "gitlab_ci" if File.exist?(File.join(root, ".gitlab-ci.yml"))
        configs << "travis" if File.exist?(File.join(root, ".travis.yml"))
        configs
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
          %w[spec/rails_helper.rb spec/spec_helper.rb test/test_helper.rb].each do |helper|
            path = File.join(root, helper)
            next unless File.exist?(path)
            ast = SourceIntrospector.walk(path, {
              cleaner: -> { Listeners::ConfigAssignmentListener.new(:DatabaseCleaner) }
            })
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
