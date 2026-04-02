# frozen_string_literal: true

module RailsAiContext
  module Introspectors
    # Discovers Action Text usage: rich text fields per model.
    class ActionTextIntrospector
      attr_reader :app

      def initialize(app)
        @app = app
      end

      def call
        {
          installed: defined?(ActionText) ? true : false,
          rich_text_fields: extract_rich_text_fields
        }
      rescue => e
        { error: e.message }
      end

      private

      def root
        app.root.to_s
      end

      def extract_rich_text_fields
        models_dir = File.join(root, "app/models")
        return [] unless Dir.exist?(models_dir)

        fields = []
        Dir.glob(File.join(models_dir, "**/*.rb")).each do |path|
          content = File.read(path)
          model_name = File.basename(path, ".rb").camelize

          content.scan(/has_rich_text\s+:(\w+)/).each do |match|
            fields << { model: model_name, field: match[0] }
          end
        end

        fields.sort_by { |f| [ f[:model], f[:field] ] }
      rescue => e
        $stderr.puts "[rails-ai-context] extract_rich_text_fields failed: #{e.message}" if ENV["DEBUG"]
        []
      end
    end
  end
end
