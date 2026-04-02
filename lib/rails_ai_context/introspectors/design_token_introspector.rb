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
        extract_apply_directives(root, tokens)

        return { skipped: true, reason: "No design tokens found" } if tokens.empty?

        {
          framework: detect_framework(root),
          tokens: tokens,
          categorized: categorize_tokens(tokens),
          font_loading: extract_font_loading(root),
          css_layers: extract_css_layers(root),
          postcss_plugins: extract_postcss_plugins(root)
        }
      rescue => e
        { error: e.message }
      end

      private

      def detect_framework(root)
        gemfile = File.join(root, "Gemfile")
        package_json = File.join(root, "package.json")
        gemfile_content = File.exist?(gemfile) ? (File.read(gemfile, encoding: "UTF-8", invalid: :replace, undef: :replace) rescue "") : ""
        pkg_content = File.exist?(package_json) ? (File.read(package_json, encoding: "UTF-8", invalid: :replace, undef: :replace) rescue "") : ""

        framework = if gemfile_content.include?("tailwindcss-rails")
          "tailwind"
        elsif gemfile_content.include?("bootstrap")
          "bootstrap"
        elsif gemfile_content.include?("dartsass-rails") || gemfile_content.include?("sassc-rails") || gemfile_content.include?("sass-rails")
          "sass"
        elsif gemfile_content.include?("cssbundling-rails")
          "cssbundling"
        else
          "plain_css"
        end

        # DS17: Detect Tailwind plugin libraries
        plugins = []
        plugins << "daisyui" if pkg_content.include?("daisyui") || gemfile_content.include?("daisyui")
        plugins << "flowbite" if pkg_content.include?("flowbite")
        plugins << "headlessui" if pkg_content.include?("headlessui") || pkg_content.include?("@headlessui")

        plugins.any? ? "#{framework}+#{plugins.join('+')}" : framework
      rescue => e
        $stderr.puts "[rails-ai-context] detect_framework failed: #{e.message}" if ENV["DEBUG"]
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

        # Extract fontSize configuration
        content.scan(/fontSize\s*:\s*\{([^}]+)\}/m).each do |match|
          match[0].scan(/['"]([\w-]+)['"]\s*:\s*['"]([^'"]+)['"]/).each do |name, value|
            tokens["tw3-fontSize-#{name}"] = value
          end
        end

        # Extract screens (breakpoints)
        content.scan(/screens\s*:\s*\{([^}]+)\}/m).each do |match|
          match[0].scan(/['"]([\w-]+)['"]\s*:\s*['"]([^'"]+)['"]/).each do |name, value|
            tokens["tw3-screen-#{name}"] = value
          end
        end

        # Extract spacing overrides
        content.scan(/spacing\s*:\s*\{([^}]+)\}/m).each do |match|
          match[0].scan(/['"]([\w.-]+)['"]\s*:\s*['"]([^'"]+)['"]/).each do |name, value|
            tokens["tw3-spacing-#{name}"] = value
          end
        end

        # Extract borderRadius overrides
        content.scan(/borderRadius\s*:\s*\{([^}]+)\}/m).each do |match|
          match[0].scan(/['"]([\w-]+)['"]\s*:\s*['"]([^'"]+)['"]/).each do |name, value|
            tokens["tw3-radius-#{name}"] = value
          end
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

      def categorize_tokens(tokens)
        categories = {
          colors: {},
          typography: {},
          spacing: {},
          sizing: {},
          borders: {},
          shadows: {},
          other: {}
        }

        tokens.each do |name, value|
          category = case name
          when /color|brand|primary|secondary|danger|success|warning|accent|neutral|bg|surface/i
            :colors
          when /font|text-size|leading|tracking|letter-spacing|line-height/i
            :typography
          when /spacing|gap|margin|padding|space|inset/i
            :spacing
          when /width|height|size|radius|rounded|screen|breakpoint/i
            :sizing
          when /border|ring|outline|divide/i
            :borders
          when /shadow/i
            :shadows
          else
            name.match?(/shade-\d+|#[\da-fA-F]/) ? :colors : :other
          end

          categories[category][name] = value
        end

        categories.reject { |_, v| v.empty? }
      end

      # DS16: Extract @apply directives as named component classes
      def extract_apply_directives(root, tokens)
        %w[app/assets/stylesheets app/assets/tailwind].each do |dir|
          Dir.glob(File.join(root, dir, "**", "*.css")).each do |path|
            content = File.read(path, encoding: "UTF-8", invalid: :replace, undef: :replace) rescue next
            content.scan(/\.([a-zA-Z][\w-]*)\s*\{[^}]*@apply\s+([^;]+);/m).each do |name, classes|
              tokens["@apply-#{name}"] = classes.strip
            end
          end
        end
      end

      def extract_font_loading(root)
        result = { font_face: 0, google_fonts: false, system_fonts: false }

        # Scan CSS/SCSS files for @font-face
        css_dirs = %w[app/assets/stylesheets app/assets/builds app/assets/tailwind]
        css_dirs.each do |dir|
          Dir.glob(File.join(root, dir, "**", "*.{css,scss,sass}")).each do |path|
            content = File.read(path, encoding: "UTF-8", invalid: :replace, undef: :replace) rescue next
            result[:font_face] += content.scan(/@font-face/).size
            result[:google_fonts] = true if content.include?("fonts.googleapis.com")
            result[:system_fonts] = true if content.match?(/system-ui|-apple-system/)
          end
        end

        # Scan view files for Google Fonts links and system font references
        views_dir = File.join(root, "app/views")
        if Dir.exist?(views_dir)
          Dir.glob(File.join(views_dir, "**", "*.{erb,haml,slim}")).each do |path|
            content = File.read(path, encoding: "UTF-8", invalid: :replace, undef: :replace) rescue next
            result[:google_fonts] = true if content.include?("fonts.googleapis.com")
            result[:system_fonts] = true if content.match?(/system-ui|-apple-system/)
          end
        end

        result
      rescue => e
        $stderr.puts "[rails-ai-context] extract_font_loading failed: #{e.message}" if ENV["DEBUG"]
        { font_face: 0, google_fonts: false, system_fonts: false }
      end

      def extract_css_layers(root)
        layers = []
        css_dirs = %w[app/assets/stylesheets app/assets/builds app/assets/tailwind]
        css_dirs.each do |dir|
          Dir.glob(File.join(root, dir, "**", "*.{css,scss}")).each do |path|
            content = File.read(path, encoding: "UTF-8", invalid: :replace, undef: :replace) rescue next
            content.scan(/@layer\s+([\w-]+)/).each do |match|
              layers << match[0]
            end
          end
        end
        layers.uniq
      rescue => e
        $stderr.puts "[rails-ai-context] extract_css_layers failed: #{e.message}" if ENV["DEBUG"]
        []
      end

      def extract_postcss_plugins(root)
        plugins = []
        %w[postcss.config.js postcss.config.mjs postcss.config.cjs].each do |filename|
          path = File.join(root, filename)
          next unless File.exist?(path)

          content = File.read(path, encoding: "UTF-8", invalid: :replace, undef: :replace) rescue next
          # Match plugin names in various PostCSS config formats:
          # require('plugin-name'), 'plugin-name': {}, "plugin-name", plugins: [require('name')]
          content.scan(/require\s*\(\s*["']([^"']+)["']\)/).each { |m| plugins << m[0] }
          content.scan(%r{["']([\w@/\-]+)["']\s*:}).each { |m| plugins << m[0] }
          # Also match array-style: plugins: ['autoprefixer', 'postcss-import']
          content.scan(/plugins\s*:\s*\[([^\]]+)\]/m).each do |match|
            match[0].scan(%r{["']([\w@/\-]+)["']}).each { |m| plugins << m[0] }
          end
        end
        plugins.uniq
      rescue => e
        $stderr.puts "[rails-ai-context] extract_postcss_plugins failed: #{e.message}" if ENV["DEBUG"]
        []
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
