# frozen_string_literal: true

module RailsAiContext
  module Introspectors
    # Discovers asset pipeline configuration: Propshaft/Sprockets,
    # importmap pins, CSS framework, JS bundler.
    class AssetPipelineIntrospector
      attr_reader :app

      def initialize(app)
        @app = app
      end

      def call
        {
          pipeline: detect_pipeline,
          importmap_pins: extract_importmap_pins,
          css_framework: detect_css_framework,
          js_bundler: detect_js_bundler,
          manifest_files: detect_manifests
        }
      rescue => e
        { error: e.message }
      end

      private

      def root
        app.root.to_s
      end

      def detect_pipeline
        lock_content = read_gemfile_lock
        return "propshaft" if lock_content&.include?("propshaft (")
        return "sprockets" if lock_content&.include?("sprockets (")
        "none"
      end

      def extract_importmap_pins
        path = File.join(root, "config/importmap.rb")
        return [] unless File.exist?(path)

        content = File.read(path)
        content.scan(/pin\s+["']([^"']+)["']/).flatten.sort
      rescue => e
        $stderr.puts "[rails-ai-context] extract_importmap_pins failed: #{e.message}" if ENV["DEBUG"]
        []
      end

      def detect_css_framework
        lock_content = read_gemfile_lock
        return nil unless lock_content

        return "tailwindcss" if lock_content.include?("tailwindcss-rails (")
        return "bootstrap" if lock_content.include?("bootstrap (") || package_json_has?("bootstrap")
        return "bulma" if package_json_has?("bulma")
        nil
      end

      def detect_js_bundler
        return "importmap" if File.exist?(File.join(root, "config/importmap.rb"))
        return "esbuild" if package_json_has?("esbuild")
        return "webpack" if File.exist?(File.join(root, "config/webpack")) || package_json_has?("webpack")
        return "vite" if Dir.glob(File.join(root, "vite.config.*")).any?
        return "rollup" if package_json_has?("rollup")
        nil
      end

      def detect_manifests
        manifests = []
        manifests << "manifest.js" if File.exist?(File.join(root, "app/assets/config/manifest.js"))
        manifests << "package.json" if File.exist?(File.join(root, "package.json"))
        manifests << "importmap.rb" if File.exist?(File.join(root, "config/importmap.rb"))
        manifests
      end

      def read_gemfile_lock
        path = File.join(root, "Gemfile.lock")
        File.exist?(path) ? File.read(path) : nil
      rescue => e
        $stderr.puts "[rails-ai-context] read_gemfile_lock failed: #{e.message}" if ENV["DEBUG"]
        nil
      end

      def package_json_has?(package)
        path = File.join(root, "package.json")
        return false unless File.exist?(path)
        File.read(path).include?("\"#{package}\"")
      rescue => e
        $stderr.puts "[rails-ai-context] package_json_has? failed: #{e.message}" if ENV["DEBUG"]
        false
      end
    end
  end
end
