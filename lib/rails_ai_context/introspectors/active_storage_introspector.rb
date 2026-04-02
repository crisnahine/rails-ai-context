# frozen_string_literal: true

module RailsAiContext
  module Introspectors
    # Discovers Active Storage usage: attachments, storage service config,
    # direct upload detection.
    class ActiveStorageIntrospector
      attr_reader :app

      def initialize(app)
        @app = app
      end

      def call
        {
          installed: defined?(ActiveStorage) ? true : false,
          attachments: extract_attachments,
          storage_services: extract_storage_services,
          direct_upload: detect_direct_upload
        }
      rescue => e
        { error: e.message }
      end

      private

      def root
        app.root.to_s
      end

      def extract_attachments
        models_dir = File.join(root, "app/models")
        return [] unless Dir.exist?(models_dir)

        attachments = []
        Dir.glob(File.join(models_dir, "**/*.rb")).each do |path|
          content = File.read(path)
          model_name = File.basename(path, ".rb").camelize

          content.scan(/has_one_attached\s+:(\w+)/).each do |match|
            attachments << { model: model_name, name: match[0], type: "has_one_attached" }
          end

          content.scan(/has_many_attached\s+:(\w+)/).each do |match|
            attachments << { model: model_name, name: match[0], type: "has_many_attached" }
          end
        end

        attachments.sort_by { |a| [ a[:model], a[:name] ] }
      rescue => e
        $stderr.puts "[rails-ai-context] extract_attachments failed: #{e.message}" if ENV["DEBUG"]
        []
      end

      def extract_storage_services
        config_path = File.join(root, "config/storage.yml")
        return [] unless File.exist?(config_path)

        require "yaml"
        config = YAML.load_file(config_path, permitted_classes: [ Symbol ], aliases: true) || {}
        config.keys.sort
      rescue => e
        $stderr.puts "[rails-ai-context] extract_storage_services failed: #{e.message}" if ENV["DEBUG"]
        []
      end

      def detect_direct_upload
        views_dir = File.join(root, "app/views")
        js_dir = File.join(root, "app/javascript")

        [ views_dir, js_dir ].any? do |dir|
          next false unless Dir.exist?(dir)
          Dir.glob(File.join(dir, "**/*")).any? do |f|
            next false if File.directory?(f)
            File.read(f).match?(/direct.upload|DirectUpload|direct_upload/)
          rescue => e
            $stderr.puts "[rails-ai-context] detect_direct_upload failed: #{e.message}" if ENV["DEBUG"]
            false
          end
        end
      end
    end
  end
end
