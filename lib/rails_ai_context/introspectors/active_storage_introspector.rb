# frozen_string_literal: true

module RailsAiContext
  module Introspectors
    # Discovers Active Storage usage: attachments, storage service config,
    # direct upload detection.
    class ActiveStorageIntrospector < Base
      extend StaticTier
      static_tier :files_only

      def call
        {
          installed: defined?(ActiveStorage) ? true : false,
          attachments: model_facts[:attachments],
          storage_services: extract_storage_services,
          direct_upload: detect_direct_upload,
          validations: model_facts[:validations],
          variants: model_facts[:variants]
        }
      end

      private

      # One walk per model answers all three model questions.
      def model_facts
        @model_facts ||= begin
          attachments = []
          validations = []
          variants = []

          model_classes.each do |model_name, record|
            ast = SourceIntrospector.walk_source(record.source, {
              macros: Listeners::MacrosListener,
              validations: Listeners::ValidationsListener,
              variants: Listeners::VariantCallListener
            })

            ast[:macros].each do |m|
              next unless %i[has_one_attached has_many_attached].include?(m[:macro])
              attachments << { model: model_name, name: m[:attribute], type: m[:macro].to_s }
            end

            ast[:validations].each do |v|
              (v[:attributes] || []).each do |attr|
                validations << { model: model_name, attachment: attr, type: "content_type" } if attachment_rule?(v, :content_type)
                validations << { model: model_name, attachment: attr, type: "size" } if attachment_rule?(v, :size)
              end
            end

            ast[:variants].each do |v|
              v[:args].each { |name| variants << { model: model_name, name: name.to_s } }
            end
          end

          {
            attachments: attachments.sort_by { |a| [ a[:model], a[:name] ] },
            validations: validations,
            variants: variants
          }
        rescue => e
          RailsAiContext.debug_fail(e, { attachments: [], validations: [], variants: [] }, label: "model_facts")
        end
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

      # `validates :avatar, content_type: [...]` names its validator in the
      # option key, so the listener reports it as the rule's kind; a rule
      # written with the same key beside another kind still carries it as an
      # option.
      def attachment_rule?(rule, key)
        rule[:kind].to_s == key.to_s || rule[:options].key?(key)
      end

      def detect_direct_upload
        views_dir = File.join(root, "app/views")
        js_dir = File.join(root, "app/javascript")

        [ views_dir, js_dir ].any? do |dir|
          FileWalk.glob(dir, "**/*.{erb,haml,slim,js,ts,jsx,tsx,mjs,rb}", root: root).any? do |f|
            # The glob spans ERB, JS and Ruby, so one text scan covers them all.
            (RailsAiContext::SafeFile.read(f) || "").match?(/direct.upload|DirectUpload|direct_upload/)
          end
        end
      end
    end
  end
end
