# frozen_string_literal: true

module RailsAiContext
  module Introspectors
    # Scans for Hotwire/Turbo usage: frames, streams, model broadcasts.
    class TurboIntrospector
      attr_reader :app

      def initialize(app)
        @app = app
      end

      def call
        {
          turbo_frames: extract_turbo_frames,
          turbo_streams: extract_turbo_stream_templates,
          model_broadcasts: extract_model_broadcasts,
          morph_meta: detect_morph_meta,
          permanent_elements: extract_permanent_elements,
          turbo_drive_settings: extract_turbo_drive_settings,
          turbo_stream_responses: extract_turbo_stream_responses,
          turbo_native: detect_turbo_native
        }
      rescue => e
        { error: e.message }
      end

      private

      def root
        app.root.to_s
      end

      def views_dir
        File.join(root, "app/views")
      end

      def extract_turbo_frames
        return [] unless Dir.exist?(views_dir)

        frames = []
        Dir.glob(File.join(views_dir, "**/*.{erb,haml,slim}")).each do |path|
          content = File.read(path)
          relative = path.sub("#{views_dir}/", "")

          content.scan(/turbo_frame_tag\s+[:"']?(\w+)/).each do |match|
            frames << { id: match[0], file: relative }
          end
        end

        frames.sort_by { |f| f[:id] }
      rescue => e
        $stderr.puts "[rails-ai-context] extract_turbo_frames failed: #{e.message}" if ENV["DEBUG"]
        []
      end

      def extract_turbo_stream_templates
        return [] unless Dir.exist?(views_dir)

        Dir.glob(File.join(views_dir, "**/*.turbo_stream.erb")).filter_map do |path|
          path.sub("#{views_dir}/", "")
        end.sort
      end

      def extract_model_broadcasts
        models_dir = File.join(root, "app/models")
        return [] unless Dir.exist?(models_dir)

        broadcasts = []
        Dir.glob(File.join(models_dir, "**/*.rb")).each do |path|
          content = File.read(path)
          model_name = File.basename(path, ".rb").camelize

          broadcast_methods = content.scan(/\b(broadcasts_to|broadcasts_refreshes_to|broadcasts)\b/).flatten.uniq
          next if broadcast_methods.empty?

          broadcasts << { model: model_name, methods: broadcast_methods }
        end

        broadcasts.sort_by { |b| b[:model] }
      rescue => e
        $stderr.puts "[rails-ai-context] extract_model_broadcasts failed: #{e.message}" if ENV["DEBUG"]
        []
      end

      def detect_morph_meta
        layouts_dir = File.join(root, "app/views/layouts")
        return false unless Dir.exist?(layouts_dir)

        Dir.glob(File.join(layouts_dir, "*.{erb,haml,slim}")).any? do |path|
          content = File.read(path) rescue next
          content.include?('name="turbo-refresh-method"') && content.include?('content="morph"')
        end
      rescue => e
        $stderr.puts "[rails-ai-context] detect_morph_meta failed: #{e.message}" if ENV["DEBUG"]
        false
      end

      def extract_permanent_elements
        return [] unless Dir.exist?(views_dir)

        elements = []
        Dir.glob(File.join(views_dir, "**/*.{erb,haml,slim}")).each do |path|
          content = File.read(path) rescue next
          relative = path.sub("#{views_dir}/", "")

          content.scan(/<[^>]*data-turbo-permanent[^>]*>/i).each do |tag|
            id = tag.match(/id=["']([^"']+)["']/)&.send(:[], 1)
            elements << { file: relative, id: id }
          end
        end

        # Also scan layouts
        layouts_dir = File.join(root, "app/views/layouts")
        if Dir.exist?(layouts_dir)
          Dir.glob(File.join(layouts_dir, "*.{erb,haml,slim}")).each do |path|
            content = File.read(path) rescue next
            relative = "layouts/#{File.basename(path)}"

            content.scan(/<[^>]*data-turbo-permanent[^>]*>/i).each do |tag|
              id = tag.match(/id=["']([^"']+)["']/)&.send(:[], 1)
              elements << { file: relative, id: id }
            end
          end
        end

        elements.uniq
      rescue => e
        $stderr.puts "[rails-ai-context] extract_permanent_elements failed: #{e.message}" if ENV["DEBUG"]
        []
      end

      def extract_turbo_drive_settings
        return { "data-turbo-false": 0, "data-turbo-action": 0, "data-turbo-preload": 0 } unless Dir.exist?(views_dir)

        counts = { "data-turbo-false": 0, "data-turbo-action": 0, "data-turbo-preload": 0 }
        all_dirs = [ views_dir ]
        layouts_dir = File.join(root, "app/views/layouts")
        all_dirs << layouts_dir if Dir.exist?(layouts_dir)

        all_dirs.each do |dir|
          Dir.glob(File.join(dir, "**/*.{erb,haml,slim}")).each do |path|
            content = File.read(path) rescue next
            counts[:"data-turbo-false"] += content.scan(/data-turbo=["']false["']/).size
            counts[:"data-turbo-action"] += content.scan(/data-turbo-action=["'][^"']*["']/).size
            # Also count Rails data hash syntax: data: { turbo_action: ... }
            counts[:"data-turbo-action"] += content.scan(/turbo_action:\s*["'][^"']*["']/).size
            counts[:"data-turbo-preload"] += content.scan(/data-turbo-preload/).size
          end
        end

        counts
      rescue => e
        $stderr.puts "[rails-ai-context] extract_turbo_drive_settings failed: #{e.message}" if ENV["DEBUG"]
        { "data-turbo-false": 0, "data-turbo-action": 0, "data-turbo-preload": 0 }
      end

      def detect_turbo_native
        controllers_dir = File.join(root, "app/controllers")

        {
          detected: detect_native_include(controllers_dir),
          native_helpers: detect_native_helpers(controllers_dir),
          native_navigation: detect_native_navigation(controllers_dir),
          native_conditionals: detect_native_conditionals
        }
      rescue => e
        $stderr.puts "[rails-ai-context] detect_turbo_native failed: #{e.message}" if ENV["DEBUG"]
        { detected: false, native_helpers: [], native_navigation: [], native_conditionals: 0 }
      end

      def detect_native_include(controllers_dir)
        return false unless Dir.exist?(controllers_dir)

        Dir.glob(File.join(controllers_dir, "**/*.rb")).any? do |path|
          content = File.read(path) rescue next
          content.match?(/include\s+Turbo::Native::Navigation/)
        end
      rescue => e
        $stderr.puts "[rails-ai-context] detect_native_include failed: #{e.message}" if ENV["DEBUG"]
        false
      end

      def detect_native_helpers(controllers_dir)
        return [] unless Dir.exist?(controllers_dir)

        Dir.glob(File.join(controllers_dir, "**/*.rb")).filter_map do |path|
          content = File.read(path) rescue next
          if content.match?(/turbo_native_app\?|hotwire_native_app\?/)
            path.sub("#{root}/", "")
          end
        end.sort
      rescue => e
        $stderr.puts "[rails-ai-context] detect_native_helpers failed: #{e.message}" if ENV["DEBUG"]
        []
      end

      def detect_native_navigation(controllers_dir)
        return [] unless Dir.exist?(controllers_dir)

        navigation_methods = %w[
          recede_or_redirect_to resume_or_redirect_to refresh_or_redirect_to
          recede_or_redirect_back_or_to resume_or_redirect_back_or_to refresh_or_redirect_back_or_to
        ]
        pattern = Regexp.union(navigation_methods)

        results = []
        Dir.glob(File.join(controllers_dir, "**/*.rb")).each do |path|
          content = File.read(path) rescue next
          relative = path.sub("#{root}/", "")

          content.scan(pattern).each do |match|
            results << { file: relative, method: match }
          end
        end

        results.sort_by { |r| [ r[:file], r[:method] ] }
      rescue => e
        $stderr.puts "[rails-ai-context] detect_native_navigation failed: #{e.message}" if ENV["DEBUG"]
        []
      end

      def detect_native_conditionals
        return 0 unless Dir.exist?(views_dir)

        count = 0
        Dir.glob(File.join(views_dir, "**/*.{erb,haml,slim}")).each do |path|
          content = File.read(path) rescue next
          count += content.scan(/turbo_native_app\?|hotwire_native_app\?/).size
        end

        count
      rescue => e
        $stderr.puts "[rails-ai-context] detect_native_conditionals failed: #{e.message}" if ENV["DEBUG"]
        0
      end

      def extract_turbo_stream_responses
        controllers_dir = File.join(root, "app/controllers")
        return [] unless Dir.exist?(controllers_dir)

        responses = []
        Dir.glob(File.join(controllers_dir, "**/*.rb")).each do |path|
          content = File.read(path) rescue next
          controller_name = File.basename(path, ".rb").camelize

          # Parse action names by tracking def ... end blocks
          current_action = nil
          content.each_line do |line|
            if (match = line.match(/^\s*def\s+(\w+)/))
              current_action = match[1]
            end

            if current_action && line.match?(/format\.turbo_stream|respond_to\s*.*turbo_stream/)
              responses << { controller: controller_name, action: current_action }
            end
          end
        end

        responses.uniq.sort_by { |r| [ r[:controller], r[:action] ] }
      rescue => e
        $stderr.puts "[rails-ai-context] extract_turbo_stream_responses failed: #{e.message}" if ENV["DEBUG"]
        []
      end
    end
  end
end
