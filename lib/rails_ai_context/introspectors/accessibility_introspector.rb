# frozen_string_literal: true

module RailsAiContext
  module Introspectors
    # Scans view templates for accessibility patterns: ARIA attributes,
    # semantic HTML elements, screen reader text, alt text, label associations.
    class AccessibilityIntrospector
      attr_reader :app

      def initialize(app)
        @app = app
      end

      def call
        views = collect_view_content
        {
          aria_attributes: extract_aria_attributes(views),
          roles: extract_roles(views),
          semantic_elements: count_semantic_elements(views),
          screen_reader_text: count_screen_reader_text(views),
          images: analyze_images(views),
          labels: analyze_labels(views),
          landmarks: extract_landmarks(views),
          summary: build_summary(views)
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

      def components_dir
        File.join(root, "app/components")
      end

      def collect_view_content
        views = []

        [ views_dir, components_dir ].each do |dir|
          next unless Dir.exist?(dir)

          Dir.glob(File.join(dir, "**/*.{erb,haml,slim,html}")).each do |path|
            content = File.read(path, encoding: "UTF-8", invalid: :replace, undef: :replace)
            views << { file: path.sub("#{root}/", ""), content: content }
          rescue => e
            $stderr.puts "[rails-ai-context] collect_view_content failed: #{e.message}" if ENV["DEBUG"]
            next
          end
        end

        views
      end

      def extract_aria_attributes(views)
        attributes = Hash.new(0)
        views.each do |view|
          view[:content].scan(/aria-(\w+[-\w]*)/) do |attr,|
            attributes["aria-#{attr}"] += 1
          end
        end
        attributes.sort_by { |_, count| -count }.to_h
      end

      def extract_roles(views)
        roles = Hash.new(0)
        views.each do |view|
          view[:content].scan(/role=["'](\w+)["']/) do |role,|
            roles[role] += 1
          end
        end
        roles.sort_by { |_, count| -count }.to_h
      end

      def count_semantic_elements(views)
        elements = %w[nav main header footer article section aside figure figcaption details summary dialog]
        counts = {}

        all_content = views.map { |v| v[:content] }.join("\n")
        elements.each do |el|
          count = all_content.scan(/<#{el}[\s>]/).size
          counts[el] = count if count > 0
        end

        counts
      end

      def count_screen_reader_text(views)
        all_content = views.map { |v| v[:content] }.join("\n")

        {
          sr_only: all_content.scan(/\bsr-only\b/).size,
          visually_hidden: all_content.scan(/\bvisually-hidden\b/).size,
          aria_hidden: all_content.scan(/aria-hidden=["']true["']/).size
        }
      end

      def analyze_images(views)
        all_content = views.map { |v| v[:content] }.join("\n")

        # Count img tags with and without alt
        img_with_alt = all_content.scan(/<img\b[^>]*\balt=/).size
        img_total = all_content.scan(/<img\b/).size
        # image_tag helper always generates alt (from filename if not provided)
        image_tag_count = all_content.scan(/image_tag\b/).size

        {
          total: img_total + image_tag_count,
          with_alt: img_with_alt + image_tag_count,
          missing_alt: [ img_total - img_with_alt, 0 ].max,
          decorative: all_content.scan(/alt=["']\s*["']/).size
        }
      end

      def analyze_labels(views)
        all_content = views.map { |v| v[:content] }.join("\n")

        {
          label_for: all_content.scan(/<label\b[^>]*\bfor=/).size +
                     all_content.scan(/\.label\s+:\w+/).size,
          aria_label: all_content.scan(/aria-label=/).size,
          aria_labelledby: all_content.scan(/aria-labelled?by=/).size,
          aria_describedby: all_content.scan(/aria-describedby=/).size
        }
      end

      def extract_landmarks(views)
        all_content = views.map { |v| v[:content] }.join("\n")

        landmarks = {}
        %w[banner navigation main complementary contentinfo search form].each do |role|
          count = all_content.scan(/role=["']#{role}["']/).size
          landmarks[role] = count if count > 0
        end

        # Semantic elements that imply landmarks
        { "banner" => "header", "navigation" => "nav", "main" => "main",
          "complementary" => "aside", "contentinfo" => "footer" }.each do |role, el|
          tag_count = all_content.scan(/<#{el}[\s>]/).size
          landmarks[role] = (landmarks[role] || 0) + tag_count if tag_count > 0
        end

        landmarks
      end

      def build_summary(views)
        all_content = views.map { |v| v[:content] }.join("\n")

        aria_count = all_content.scan(/aria-\w+/).size
        role_count = all_content.scan(/role=["']\w+["']/).size
        semantic_count = %w[nav main header footer article section aside].sum { |el|
          all_content.scan(/<#{el}[\s>]/).size
        }

        total_signals = aria_count + role_count + semantic_count
        file_count = views.size

        score = if file_count == 0
          0
        else
          signals_per_file = total_signals.to_f / file_count
          case signals_per_file
          when 0..0.5 then 1
          when 0.5..1.5 then 2
          when 1.5..3 then 3
          when 3..5 then 4
          else 5
          end
        end

        {
          files_scanned: file_count,
          total_aria_attributes: aria_count,
          total_roles: role_count,
          total_semantic_elements: semantic_count,
          accessibility_score: score,
          score_label: %w[none minimal basic good excellent][score > 0 ? score - 1 : 0]
        }
      end
    end
  end
end
