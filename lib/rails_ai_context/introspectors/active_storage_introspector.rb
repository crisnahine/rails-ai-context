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
          direct_upload: detect_direct_upload,
          validations: extract_attachment_validations,
          variants: extract_variants
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
          model_name = File.basename(path, ".rb").camelize
          ast_data = SourceIntrospector.walk(path, { macros: Listeners::MacrosListener })
          ast_data[:macros].each do |m|
            next unless %i[has_one_attached has_many_attached].include?(m[:macro])
            attachments << { model: model_name, name: m[:attribute], type: m[:macro].to_s }
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

      def extract_attachment_validations
        validations = []
        models_dir = File.join(app.root, "app", "models")
        return validations unless Dir.exist?(models_dir)

        Dir.glob(File.join(models_dir, "**", "*.rb")).each do |path|
          model = File.basename(path, ".rb").camelize
          ast_data = SourceIntrospector.walk(path, { validations: Listeners::ValidationsListener })
          ast_data[:validations].each do |v|
            attrs = v[:attributes] || []
            attrs.each do |attr|
              validations << { model: model, attachment: attr, type: "content_type" } if v[:options].key?(:content_type)
              validations << { model: model, attachment: attr, type: "size" } if v[:options].key?(:size)
            end
          end
        end
        validations
      rescue => e
        $stderr.puts "[rails-ai-context] extract_attachment_validations failed: #{e.message}" if ENV["DEBUG"]
        []
      end

      def extract_variants
        variants = []
        models_dir = File.join(app.root, "app", "models")
        return variants unless Dir.exist?(models_dir)

        Dir.glob(File.join(models_dir, "**", "*.rb")).each do |path|
          model = File.basename(path, ".rb").camelize
          ast_data = SourceIntrospector.walk(path, { variants: Listeners::VariantCallListener })
          ast_data[:variants].each do |v|
            v[:args].each do |name|
              variants << { model: model, name: name.to_s }
            end
          end
        end
        variants
      rescue => e
        $stderr.puts "[rails-ai-context] extract_variants failed: #{e.message}" if ENV["DEBUG"]
        []
      end

      def detect_direct_upload
        views_dir = File.join(root, "app/views")
        js_dir = File.join(root, "app/javascript")

        [ views_dir, js_dir ].any? do |dir|
          next false unless Dir.exist?(dir)
          Dir.glob(File.join(dir, "**/*.{erb,haml,slim,js,ts,jsx,tsx,mjs,rb}")).any? do |f|
            next false if File.directory?(f)
            (RailsAiContext::SafeFile.read(f) || "").match?(/direct.upload|DirectUpload|direct_upload/)
          end
        end
      end
    end
  end
end
