# frozen_string_literal: true

module RailsAiContext
  module Introspectors
    # Extracts design tokens from CSS/SCSS files across ALL Rails CSS setups:
    # - Tailwind v4 @theme blocks
    # - Tailwind v4 built CSS :root variables
    # - Tailwind v3 tailwind.config.js (simple key-values only)
    # - Bootstrap/Sass $variable definitions
    # - Plain CSS :root custom properties
    # - Webpacker-era stylesheets
    # - ViewComponent sidecar CSS
    #
    # Returns a framework-agnostic hash of design tokens.
    # No external dependencies — pure regex parsing.
    class DesignTokenIntrospector
      attr_reader :app

      def initialize(app)
        @app = app
      end

      def call
        root = app.root.to_s
        tokens = {}

        # Priority order: check each source, merge found tokens
        extract_built_css_vars(root, tokens)
        extract_tailwind_v4_theme(root, tokens)
        extract_tailwind_v3_config(root, tokens)
        extract_scss_variables(root, tokens)
        extract_css_custom_properties(root, tokens)
        extract_webpacker_styles(root, tokens)
        extract_component_css(root, tokens)

        return { skipped: true, reason: "No design tokens found" } if tokens.empty?

        {
          framework: detect_framework(root),
          tokens: tokens
        }
      rescue => e
        { error: e.message }
      end

      private

      def detect_framework(root)
        gemfile = File.join(root, "Gemfile")
        return "unknown" unless File.exist?(gemfile)
        content = File.read(gemfile, encoding: "UTF-8", invalid: :replace, undef: :replace)

        if content.include?("tailwindcss-rails")
          "tailwind"
        elsif content.include?("bootstrap")
          "bootstrap"
        elsif content.include?("dartsass-rails") || content.include?("sassc-rails") || content.include?("sass-rails")
          "sass"
        elsif content.include?("cssbundling-rails")
          "cssbundling"
        else
          "plain_css"
        end
      rescue
        "unknown"
      end

      # 1. Built CSS output (Tailwind v4, cssbundling-rails, dartsass-rails)
      def extract_built_css_vars(root, tokens)
        Dir.glob(File.join(root, "app", "assets", "builds", "*.css")).each do |path|
          content = File.read(path, encoding: "UTF-8", invalid: :replace, undef: :replace) rescue next
          extract_root_vars(content, tokens)
        end
      end

      # 2. Tailwind v4 @theme blocks in source CSS
      def extract_tailwind_v4_theme(root, tokens)
        %w[app/assets/tailwind app/assets/stylesheets].each do |dir|
          Dir.glob(File.join(root, dir, "**", "*.css")).each do |path|
            content = File.read(path, encoding: "UTF-8", invalid: :replace, undef: :replace) rescue next
            content.scan(/@theme\s*(?:inline)?\s*\{([^}]+)\}/m).each do |match|
              match[0].scan(/--([a-zA-Z0-9-]+):\s*([^;]+);/).each do |name, value|
                tokens["--#{name}"] = value.strip
              end
            end
          end
        end
      end

      # 3. Tailwind v3 config (regex on JS — handles nested color palettes)
      def extract_tailwind_v3_config(root, tokens) # rubocop:disable Metrics/MethodLength
        path = File.join(root, "config", "tailwind.config.js")
        path = File.join(root, "tailwind.config.js") unless File.exist?(path)
        return unless File.exist?(path)

        content = File.read(path, encoding: "UTF-8", invalid: :replace, undef: :replace) rescue return

        # Extract ALL hex/rgb/hsl color values with their context
        # Pattern: 'key': '#hex' or "key": "rgb(...)" anywhere in file
        content.scan(/['"]([\w-]+)['"]\s*:\s*['"]([#][\da-fA-F]{3,8})['"]/).each do |name, value|
          tokens["tw3-#{name}"] = value
        end

        # Extract color shades: number keys with hex values (inside palette objects)
        content.scan(/['"]?(\d{2,3})['"]?\s*:\s*['"]([#][\da-fA-F]{3,8})['"]/).each do |shade, value|
          tokens["tw3-shade-#{shade}"] = value
        end

        # Extract named color strings: surface: '#ffffff'
        content.scan(/(\w+)\s*:\s*['"]([#][\da-fA-F]{3,8})['"]/).each do |name, value|
          next if name.match?(/\A\d/)
          tokens["tw3-#{name}"] = value
        end

        # Extract fontFamily arrays
        content.scan(/(\w+)\s*:\s*\[['"]([^'"]+)['"]/).each do |name, font|
          tokens["tw3-font-#{name}"] = font if name.match?(/font|sans|serif|mono|display|heading/)
        end
      end

      # 4. Bootstrap/Sass variable definitions
      def extract_scss_variables(root, tokens)
        %w[app/assets/stylesheets app/assets/stylesheets/config].each do |dir|
          Dir.glob(File.join(root, dir, "**", "*.{scss,sass}")).each do |path|
            content = File.read(path, encoding: "UTF-8", invalid: :replace, undef: :replace) rescue next
            content.scan(/^\$([a-zA-Z][\w-]*)\s*:\s*([^;!]+)/).each do |name, value|
              value = value.strip
              # Skip computed values (references to other variables, functions)
              next if value.match?(/\$\w|lighten|darken|mix|adjust|scale|rgba\(\$/)
              tokens["$#{name}"] = value
            end
          end
        end
      end

      # 5. CSS custom properties in stylesheet files
      def extract_css_custom_properties(root, tokens)
        %w[app/assets/stylesheets].each do |dir|
          Dir.glob(File.join(root, dir, "**", "*.css")).each do |path|
            content = File.read(path, encoding: "UTF-8", invalid: :replace, undef: :replace) rescue next
            extract_root_vars(content, tokens)
          end
        end
      end

      # 6. Webpacker-era stylesheets (Rails 6)
      def extract_webpacker_styles(root, tokens)
        %w[app/javascript/stylesheets app/javascript/css].each do |dir|
          full_dir = File.join(root, dir)
          next unless Dir.exist?(full_dir)

          Dir.glob(File.join(full_dir, "**", "*.{scss,sass,css}")).each do |path|
            content = File.read(path, encoding: "UTF-8", invalid: :replace, undef: :replace) rescue next
            # Sass variables
            content.scan(/^\$([a-zA-Z][\w-]*)\s*:\s*([^;!]+)/).each do |name, value|
              value = value.strip
              next if value.match?(/\$\w|lighten|darken|mix/)
              tokens["$#{name}"] = value
            end
            # CSS custom properties
            extract_root_vars(content, tokens)
          end
        end
      end

      # 7. ViewComponent sidecar CSS
      def extract_component_css(root, tokens)
        dir = File.join(root, "app", "components")
        return unless Dir.exist?(dir)

        Dir.glob(File.join(dir, "**", "*.css")).each do |path|
          content = File.read(path, encoding: "UTF-8", invalid: :replace, undef: :replace) rescue next
          extract_root_vars(content, tokens)
        end
      end

      # Helper: extract :root { --var: value } from CSS content
      def extract_root_vars(content, tokens)
        content.scan(/:root\s*(?:,\s*:host)?\s*\{([^}]+)\}/m).each do |match|
          match[0].scan(/--([a-zA-Z0-9-]+):\s*([^;]+);/).each do |name, value|
            tokens["--#{name}"] = value.strip
          end
        end
      end
    end
  end
end
