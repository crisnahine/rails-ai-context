# frozen_string_literal: true

module RailsAiContext
  module Introspectors
    # Discovers database seed configuration: db/seeds.rb structure,
    # seed files in db/seeds/ directory, and what models they populate.
    class SeedsIntrospector
      attr_reader :app

      def initialize(app)
        @app = app
      end

      # @return [Hash] seed file info and detected models
      def call
        {
          seeds_file: analyze_seeds_file,
          seed_files: discover_seed_files,
          models_seeded: detect_seeded_models
        }
      rescue => e
        { error: e.message }
      end

      private

      def root
        app.root.to_s
      end

      def analyze_seeds_file
        path = File.join(root, "db/seeds.rb")
        return nil unless File.exist?(path)

        content = File.read(path)
        {
          exists: true,
          lines: content.lines.count,
          uses_find_or_create: content.match?(/find_or_create_by/),
          uses_create: content.match?(/\.create[!(]?/),
          uses_upsert: content.match?(/\.upsert/),
          uses_insert_all: content.match?(/\.insert_all/),
          uses_faker: content.match?(/Faker::/),
          uses_factory_bot: content.match?(/FactoryBot/),
          loads_directory: content.match?(/Dir\[|Dir\.glob|load.*seeds/),
          environment_conditional: content.match?(/Rails\.env/)
        }
      rescue => e
        { exists: false, error: e.message }
      end

      def discover_seed_files
        seeds_dir = File.join(root, "db/seeds")
        return [] unless Dir.exist?(seeds_dir)

        Dir.glob(File.join(seeds_dir, "**/*.rb")).sort.map do |path|
          {
            file: path.sub("#{root}/", ""),
            name: File.basename(path, ".rb")
          }
        end
      end

      def detect_seeded_models
        models = Set.new
        seed_files = [ File.join(root, "db/seeds.rb") ]

        seeds_dir = File.join(root, "db/seeds")
        seed_files += Dir.glob(File.join(seeds_dir, "**/*.rb")) if Dir.exist?(seeds_dir)

        non_models = %w[File Dir ENV Rails Faker FactoryBot ActiveRecord IO Pathname YAML JSON CSV]

        seed_files.each do |path|
          next unless File.exist?(path)
          content = File.read(path)

          content.scan(/\b([A-Z][A-Za-z0-9]+(?:::[A-Z][A-Za-z0-9]+)*)\s*\.\s*(?:create|find_or_create_by|upsert|insert_all|new|first_or_create|seed)/).each do |match|
            model_name = match[0]
            models << model_name unless non_models.include?(model_name)
          end
        rescue => e
          $stderr.puts "[rails-ai-context] detect_seeded_models failed: #{e.message}" if ENV["DEBUG"]
          next
        end

        models.sort.to_a
      end
    end
  end
end
