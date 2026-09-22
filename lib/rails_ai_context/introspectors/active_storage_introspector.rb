# frozen_string_literal: true

module RailsAiContext
  module Introspectors
    # Discovers Active Storage usage: attachments, storage service config,
    # direct upload detection.
    class ActiveStorageIntrospector
      extend StaticTier
      static_tier :files_only

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
        attachments = []
        SourceScan.classes(root, kind: "app/models").each do |model_name, record|
          ast_data = SourceIntrospector.walk_source(record.source, { macros: Listeners::MacrosListener })
          ast_data[:macros].each do |m|
            next unless %i[has_one_attached has_many_attached].include?(m[:macro])
            attachments << { model: model_name, name: m[:attribute], type: m[:macro].to_s }
          end
        end

        attachments.sort_by { |a| [ a[:model], a[:name] ] }
      rescue => e
        RailsAiContext.debug_fail(e, [], label: "extract_attachments")
      end

      def extract_storage_services
        config_path = File.join(root, "config/storage.yml")
        return [] unless File.exist?(config_path)

        require "yaml"
        config = YAML.load_file(config_path, permitted_classes: [ Symbol ], aliases: true) || {}
        config.keys.sort
      rescue => e
        RailsAiContext.debug_fail(e, [], label: "extract_storage_services")
      end

      def extract_attachment_validations
        validations = []
        SourceScan.classes(root, kind: "app/models").each do |model, record|
          ast_data = SourceIntrospector.walk_source(record.source, { validations: Listeners::ValidationsListener })
          ast_data[:validations].each do |v|
            attrs = v[:attributes] || []
            attrs.each do |attr|
              validations << { model: model, attachment: attr, type: "content_type" } if attachment_rule?(v, :content_type)
              validations << { model: model, attachment: attr, type: "size" } if attachment_rule?(v, :size)
            end
          end
        end
        validations
      rescue => e
        RailsAiContext.debug_fail(e, [], label: "extract_attachment_validations")
      end

      # `validates :avatar, content_type: [...]` names its validator in the
      # option key, so the listener reports it as the rule's kind; a rule
      # written with the same key beside another kind still carries it as an
      # option.
      def attachment_rule?(rule, key)
        rule[:kind].to_s == key.to_s || rule[:options].key?(key)
      end

      def extract_variants
        variants = []
        SourceScan.classes(root, kind: "app/models").each do |model, record|
          ast_data = SourceIntrospector.walk_source(record.source, { variants: Listeners::VariantCallListener })
          ast_data[:variants].each do |v|
            v[:args].each do |name|
              variants << { model: model, name: name.to_s }
            end
          end
        end
        variants
      rescue => e
        RailsAiContext.debug_fail(e, [], label: "extract_variants")
      end

      def detect_direct_upload
        views_dir = File.join(root, "app/views")
        js_dir = File.join(root, "app/javascript")

        [ views_dir, js_dir ].any? do |dir|
          next false unless Dir.exist?(dir)
          Dir.glob(File.join(dir, "**/*.{erb,haml,slim,js,ts,jsx,tsx,mjs,rb}")).any? do |f|
            next false if File.directory?(f)
            # The glob spans ERB, JS and Ruby, so one text scan covers them all.
            (RailsAiContext::SafeFile.read(f) || "").match?(/direct.upload|DirectUpload|direct_upload/)
          end
        end
      end
    end
  end
end
