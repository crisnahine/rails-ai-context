# frozen_string_literal: true

module RailsAiContext
  module Introspectors
    # Discovers test infrastructure: framework, factories/fixtures,
    # system tests, helpers, CI config, coverage.
    class TestIntrospector
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
          test_files: detect_test_files,
          vcr_cassettes: detect_vcr,
          ci_config: detect_ci,
          coverage: detect_coverage,
          factory_traits: detect_factory_traits,
          test_count_by_category: detect_test_count_by_category
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
          "unknown"
        end
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

      def detect_system_tests
        dirs = [
          File.join(root, "spec/system"),
          File.join(root, "test/system")
        ]

        dirs.filter_map do |dir|
          next unless Dir.exist?(dir)
          count = Dir.glob(File.join(dir, "**/*.rb")).size
          { location: dir.sub("#{root}/", ""), count: count } if count > 0
        end.first
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
            factories = File.read(path).scan(/factory\s+:(\w+)/).flatten
            names[file] = factories if factories.any?
          rescue => e
            $stderr.puts "[rails-ai-context] detect_factory_names failed: #{e.message}" if ENV["DEBUG"]
            next
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
            content = File.read(path) rescue next
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
          content = File.read(path) rescue next
          content.scan(/(?:config\.)?include\s+([\w:]+)/).each { |m| setup << m[0] }
        end
        setup.uniq
      end

      def detect_test_files
        categories = {}
        %w[models models/concerns controllers requests system services integration features].each do |cat|
          %w[spec test].each do |base|
            dir = File.join(root, base, cat)
            next unless Dir.exist?(dir)
            count = Dir.glob(File.join(dir, "**/*.rb")).size
            categories[cat] = { location: "#{base}/#{cat}", count: count } if count > 0
          end
        end
        categories
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
        gemfile_lock = File.join(root, "Gemfile.lock")
        return nil unless File.exist?(gemfile_lock)
        content = File.read(gemfile_lock)
        return "simplecov" if content.include?("simplecov (")
        nil
      rescue => e
        $stderr.puts "[rails-ai-context] detect_coverage failed: #{e.message}" if ENV["DEBUG"]
        nil
      end

      def detect_factory_traits
        %w[spec/factories test/factories].each do |dir_rel|
          dir = File.join(root, dir_rel)
          next unless Dir.exist?(dir)

          traits = {}
          Dir.glob(File.join(dir, "**/*.rb")).each do |path|
            file = File.basename(path)
            content = File.read(path) rescue next
            found_traits = content.scan(/\btrait\s+:(\w+)/).flatten
            traits[file] = found_traits if found_traits.any?
          end
          return traits if traits.any?
        end
        nil
      rescue => e
        $stderr.puts "[rails-ai-context] detect_factory_traits failed: #{e.message}" if ENV["DEBUG"]
        nil
      end

      def detect_test_count_by_category
        counts = {}
        %w[models controllers requests system services integration features helpers views jobs mailers channels].each do |cat|
          %w[spec test].each do |base|
            dir = File.join(root, base, cat)
            next unless Dir.exist?(dir)
            count = Dir.glob(File.join(dir, "**/*.rb")).size
            counts[cat] = (counts[cat] || 0) + count if count > 0
          end
        end
        counts
      rescue => e
        $stderr.puts "[rails-ai-context] detect_test_count_by_category failed: #{e.message}" if ENV["DEBUG"]
        {}
      end
    end
  end
end
