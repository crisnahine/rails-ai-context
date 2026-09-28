# frozen_string_literal: true

module RailsAiContext
  module Introspectors
    # Discovers database seed configuration: db/seeds.rb structure,
    # seed files in db/seeds/ directory, and what models they populate.
    class SeedsIntrospector < Base
      extend StaticTier
      static_tier :files_only

      # @return [Hash] seed file info and detected models
      def call
        {
          seeds_file: analyze_seeds_file,
          seed_files: discover_seed_files,
          models_seeded: detect_seeded_models
        }
      end

      private

      # Both collectors' macros in one list, so a seed file is walked once.
      SEED_CALLS = %i[
        create create! find_or_create_by find_or_create_by! upsert insert_all
        new first_or_create seed
      ].freeze

      def chained_calls(path)
        @chained_calls ||= {}
        @chained_calls[path] ||= SourceIntrospector.walk(path, {
          chained: -> { Listeners::ChainedCallListener.new(*SEED_CALLS) }
        })[:chained]
      end

      def seed_paths
        @seed_paths ||= begin
          dir = File.join(root, "db/seeds")
          Dir.exist?(dir) ? Dir.glob(File.join(dir, "**/*.rb")).sort : []
        end
      end

      def analyze_seeds_file
        path = File.join(root, "db/seeds.rb")
        return nil unless File.exist?(path)

        content = RailsAiContext::SafeFile.read(path)
        return { exists: false, error: "unreadable" } unless content

        chained = chained_calls(path)

        {
          exists: true,
          lines: content.lines.count,
          uses_find_or_create: chained.any? { |c| c[:method].start_with?("find_or_create_by") },
          uses_create: chained.any? { |c| c[:method].start_with?("create") },
          uses_upsert: chained.any? { |c| c[:method].start_with?("upsert") },
          uses_insert_all: chained.any? { |c| c[:method].start_with?("insert_all") },
          # Which libraries the seed file reaches for is vocabulary, not
          # structure; a mention anywhere is the signal. Regex stays.
          uses_faker: content.match?(/Faker::/),
          uses_factory_bot: content.match?(/FactoryBot/),
          uses_csv: content.match?(/CSV\.|require.*csv/i),
          loads_directory: content.match?(/Dir\[|Dir\.glob|load.*seeds/),
          environment_conditional: content.match?(/Rails\.env/),
          has_ordering: content.match?(/Dir\[.*\*\.rb\]\.sort|load\s+["'].*_\d+\.rb|require_relative\s+["'].*_\d+/)
        }
      rescue => e
        { exists: false, error: e.message }
      end

      def discover_seed_files
        seed_paths.map do |path|
          {
            file: path.sub("#{root}/", ""),
            name: File.basename(path, ".rb")
          }
        end
      end

      def detect_seeded_models
        models = Set.new
        seed_files = [ File.join(root, "db/seeds.rb") ] + seed_paths

        non_models = %w[File Dir ENV Rails Faker FactoryBot ActiveRecord IO Pathname YAML JSON CSV]

        seed_files.each do |path|
          next unless File.exist?(path)

          chained_calls(path).each do |entry|
            model_name = entry[:receiver]
            next unless model_name&.match?(/\A[A-Z]/)
            models << model_name unless non_models.include?(model_name.split("::").first)
          end
        end

        models.sort.to_a
      end
    end
  end
end
