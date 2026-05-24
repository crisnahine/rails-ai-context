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
          rich_text_fields: extract_rich_text_fields,
          trix_customizations: detect_trix_customizations
        }
      rescue => e
        { error: e.message }
      end

      private

      def root
        app.root.to_s
      end

      def detect_trix_customizations
        customs = []
        js_dirs = [ File.join(app.root, "app", "javascript"), File.join(app.root, "app", "assets", "javascripts") ]
        js_dirs.each do |dir|
          next unless Dir.exist?(dir)
          Dir.glob(File.join(dir, "**", "*.{js,ts}")).each do |path|
            content = RailsAiContext::SafeFile.read(path) or next
            customs << "custom_toolbar" if content.match?(/Trix\.config\.toolbar/)
            customs << "custom_attachment" if content.match?(/trix-attachment|Trix\.Attachment/)
            customs << "custom_editor" if content.match?(/trix-initialize|trix-change/)
          end
        end
        customs.uniq
      rescue => e
        $stderr.puts "[rails-ai-context] detect_trix_customizations failed: #{e.message}" if ENV["DEBUG"]
        []
      end

      def extract_rich_text_fields
        models_dir = File.join(root, "app/models")
        return [] unless Dir.exist?(models_dir)

        fields = []
        Dir.glob(File.join(models_dir, "**/*.rb")).each do |path|
          model_name = File.basename(path, ".rb").camelize
          ast_data = SourceIntrospector.walk(path, { macros: Listeners::MacrosListener })
          ast_data[:macros].each do |m|
            next unless m[:macro] == :has_rich_text
            fields << { model: model_name, field: m[:attribute] }
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
