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

        content = RailsAiContext::SafeFile.read(path)
        return { exists: false, error: "unreadable" } unless content

        # Use ChainedCallListener for method calls with receivers
        ast_data = SourceIntrospector.walk(path, {
          chained: -> { Listeners::ChainedCallListener.new(:create, :create!, :find_or_create_by, :find_or_create_by!, :upsert, :insert_all) }
        })
        chained = ast_data[:chained]

        {
          exists: true,
          lines: content.lines.count,
          uses_find_or_create: chained.any? { |c| c[:method].start_with?("find_or_create_by") },
          uses_create: chained.any? { |c| c[:method].start_with?("create") },
          uses_upsert: chained.any? { |c| c[:method].start_with?("upsert") },
          uses_insert_all: chained.any? { |c| c[:method].start_with?("insert_all") },
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

          # Use ChainedCallListener to find model creation calls via AST,
          # then extract receiver constant names from the source lines at
          # detected locations. The listener confirms the method call;
          # the receiver name comes from the source at the AST-reported line.
          ast_data = SourceIntrospector.walk(path, {
            chained: -> { Listeners::ChainedCallListener.new(:create, :create!, :find_or_create_by, :find_or_create_by!, :upsert, :insert_all, :new, :first_or_create, :seed) }
          })

          next if ast_data[:chained].empty?
          content = RailsAiContext::SafeFile.read(path) or next
          lines = content.lines

          ast_data[:chained].each do |entry|
            line = lines[entry[:location] - 1]
            next unless line
            if (m = line.match(/\b([A-Z][A-Za-z0-9]+(?:::[A-Z][A-Za-z0-9]+)*)\s*\.\s*#{Regexp.escape(entry[:method])}/))
              model_name = m[1]
              models << model_name unless non_models.include?(model_name.split("::").first)
            end
          end
        end

        models.sort.to_a
      end
    end
  end
end
