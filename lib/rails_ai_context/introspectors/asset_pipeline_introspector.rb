# frozen_string_literal: true

module RailsAiContext
  module Introspectors
    # Discovers asset pipeline configuration: Propshaft/Sprockets,
    # importmap pins, CSS framework, JS bundler.
    class AssetPipelineIntrospector < Base
      extend StaticTier
      static_tier :files_only

      # Every name config/importmap.rb pins, read through the AST so a
      # commented-out pin is not one.
      def self.importmap_pins(root)
        path = File.join(root.to_s, "config/importmap.rb")
        return [] unless File.exist?(path)

        ast_data = SourceIntrospector.walk(path, {
          pins: -> { Listeners::GenericMacroListener.new(:pin, :pin_all_from) }
        })

        ast_data[:pins].filter_map { |macro| macro[:args]&.first&.to_s }.sort
      rescue => e
        RailsAiContext.debug_fail(e, [], label: "importmap_pins")
      end

      def call
        {
          pipeline: detect_pipeline,
          importmap_pins: self.class.importmap_pins(root),
          css_framework: detect_css_framework,
          js_bundler: detect_js_bundler,
          manifest_files: detect_manifests
        }
      end

      private

      def detect_pipeline
        lock = gem_lock
        return "propshaft" if lock.present?("propshaft")
        return "sprockets" if lock.present?("sprockets")
        "none"
      end

      def detect_css_framework
        lock = gem_lock
        return nil if lock.missing?

        return "tailwindcss" if lock.present?("tailwindcss-rails") || package_json_has?("tailwindcss")
        return "bootstrap" if lock.present?("bootstrap") || package_json_has?("bootstrap")
        return "bulma" if package_json_has?("bulma")
        return "foundation" if package_json_has?("foundation-sites")
        return "postcss" if package_json_has?("postcss") && !package_json_has?("tailwindcss")
        nil
      end

      def detect_js_bundler
        return "importmap" if File.exist?(File.join(root, "config/importmap.rb"))

        FrontendFrameworkIntrospector.build_tool(root)
      end

      def detect_manifests
        manifests = []
        manifests << "manifest.js" if File.exist?(File.join(root, "app/assets/config/manifest.js"))
        manifests << "package.json" if File.exist?(File.join(root, "package.json"))
        manifests << "importmap.rb" if File.exist?(File.join(root, "config/importmap.rb"))
        manifests
      end

      def gem_lock
        RailsAiContext::GemLock.for(root)
      end

      def package_json_has?(package)
        RailsAiContext::PackageJson.present?(root, package)
      end
    end
  end
end
