# frozen_string_literal: true

module RailsAiContext
  module Introspectors
    # Discovers test infrastructure: framework, factories/fixtures,
    # system tests, helpers, CI config, coverage.
    class TestIntrospector
      extend StaticTier
      static_tier :files_only

      TEST_FILE_GLOB = "*_{spec,test}.rb"

      attr_reader :app

      def initialize(app)
        @app = app
      end

      def call
        {
          framework: detect_framework,
          factories: detect_factories,
          factory_names: detect_factory_names,
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
      rescue => e
        { error: e.message }
      end

      private

      def root
        app.root.to_s
      end

      def detect_framework
        if Dir.exist?(File.join(root, "spec"))
          "rspec"
        elsif Dir.exist?(File.join(root, "test"))
          "minitest"
        else
          # No test/spec directory yet (e.g. an app scaffolded with --skip-test,
          # or before the first test is written). The framework is still
          # knowable from the bundle: rspec-rails means RSpec, otherwise a Rails
          # app uses its bundled minitest default. Reporting "unknown" here
          # contradicts gems/generate_test, which both already resolve it.
          detect_framework_from_lockfile || "unknown"
        end
      end

      # Resolve the test framework from Gemfile.lock when no test directory
      # exists. rspec-rails wins (it replaces the convention); otherwise
      # minitest, which ships with every Rails app. Returns nil when there is
      # no lockfile or no recognizable test gem.
      def detect_framework_from_lockfile
        lock = RailsAiContext::GemLock.for(root)
        return "rspec" if lock.present?("rspec-rails")
        return "minitest" if lock.present?("minitest")

        nil
      rescue => e
        $stderr.puts "[rails-ai-context] detect_framework_from_lockfile failed: #{e.message}" if ENV["DEBUG"]
        nil
      end

      def detect_factories
        dirs = [
          File.join(root, "spec/factories"),
          File.join(root, "test/factories")
        ]

        dirs.each do |dir|
          next unless Dir.exist?(dir)
          count = Dir.glob(File.join(dir, "**/*.rb")).size
          return { location: dir.sub("#{root}/", ""), count: count } if count > 0
        end

        nil
      end

      def detect_fixtures
        dirs = [
          File.join(root, "spec/fixtures"),
          File.join(root, "test/fixtures")
        ]

        dirs.each do |dir|
          next unless Dir.exist?(dir)
          count = Dir.glob(File.join(dir, "**/*.yml")).size
          return { location: dir.sub("#{root}/", ""), count: count } if count > 0
        end

        nil
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
        %w[spec/factories test/factories].each do |dir_rel|
          dir = File.join(root, dir_rel)
          next unless Dir.exist?(dir)

          names = {}
          Dir.glob(File.join(dir, "**/*.rb")).each do |path|
            file = path.sub("#{root}/", "")
            ast_data = SourceIntrospector.walk(path, { factories: -> { Listeners::GenericMacroListener.new(:factory) } })
            factories = ast_data[:factories].map { |e| e[:args].first.to_s }.reject(&:empty?)
            names[file] = factories if factories.any?
          end
          return names if names.any?
        end
        nil
      end

      def detect_fixture_names
        %w[spec/fixtures test/fixtures].each do |dir_rel|
          dir = File.join(root, dir_rel)
          next unless Dir.exist?(dir)

          names = {}
          Dir.glob(File.join(dir, "**/*.yml")).each do |path|
            file = File.basename(path, ".yml")
            content = RailsAiContext::SafeFile.read(path) or next
            # Top-level YAML keys are fixture names
            keys = content.scan(/^(\w+):/).flatten
            names[file] = keys if keys.any?
          end
          return names if names.any?
        end
        nil
      end

      def detect_test_helper_setup
        helpers = %w[
          spec/rails_helper.rb spec/spec_helper.rb
          test/test_helper.rb
        ]

        setup = []
        helpers.each do |rel|
          path = File.join(root, rel)
          next unless File.exist?(path)
          ast = SourceIntrospector.walk(path, {
            bare:    -> { Listeners::GenericMacroListener.new(:include) },
            chained: -> { Listeners::ChainedCallListener.new(:include, receiver: :config) }
          })
          (ast[:bare] + ast[:chained]).each { |hit| setup.concat(hit[:values].map(&:to_s)) }
        end
        setup.uniq
      end

      def detect_vcr
        dirs = [
          File.join(root, "spec/cassettes"),
          File.join(root, "spec/vcr_cassettes"),
          File.join(root, "test/cassettes"),
          File.join(root, "test/vcr_cassettes")
        ]

        dirs.each do |dir|
          next unless Dir.exist?(dir)
          count = Dir.glob(File.join(dir, "**/*.yml")).size
          return { location: dir.sub("#{root}/", ""), count: count } if count > 0
        end

        nil
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
        %w[spec/factories test/factories].each do |dir_rel|
          dir = File.join(root, dir_rel)
          next unless Dir.exist?(dir)

          traits = {}
          Dir.glob(File.join(dir, "**/*.rb")).each do |path|
            file = File.basename(path)
            ast_data = SourceIntrospector.walk(path, { traits: -> { Listeners::GenericMacroListener.new(:trait) } })
            found_traits = ast_data[:traits].map { |e| e[:args].first.to_s }.reject(&:empty?)
            traits[file] = found_traits if found_traits.any?
          end
          return traits if traits.any?
        end
        nil
      rescue => e
        $stderr.puts "[rails-ai-context] detect_factory_traits failed: #{e.message}" if ENV["DEBUG"]
        nil
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
        $stderr.puts "[rails-ai-context] detect_shared_examples failed: #{e.message}" if ENV["DEBUG"]
        []
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
        $stderr.puts "[rails-ai-context] detect_database_cleaner failed: #{e.message}" if ENV["DEBUG"]
        nil
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
        $stderr.puts "[rails-ai-context] test_categories failed: #{e.message}" if ENV["DEBUG"]
        {}
      end
    end
  end
end
