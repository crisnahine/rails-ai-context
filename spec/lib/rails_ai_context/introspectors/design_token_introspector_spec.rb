# frozen_string_literal: true

require "spec_helper"

RSpec.describe RailsAiContext::Introspectors::DesignTokenIntrospector do
  def make_app(dir)
    FileUtils.mkdir_p(dir)
    File.write(File.join(dir, "Gemfile"), "")
    Struct.new(:root).new(Pathname.new(dir))
  end

  describe "#call" do
    it "extracts CSS custom properties from :root blocks" do
      Dir.mktmpdir do |dir|
        FileUtils.mkdir_p(File.join(dir, "app/assets/stylesheets"))
        File.write(File.join(dir, "app/assets/stylesheets/tokens.css"), <<~CSS)
          :root {
            --color-primary: #3b82f6;
            --color-danger: #ef4444;
            --spacing-base: 1rem;
          }
        CSS
        result = described_class.new(make_app(dir)).call
        expect(result[:tokens]["--color-primary"]).to eq("#3b82f6")
        expect(result[:tokens]["--color-danger"]).to eq("#ef4444")
        expect(result[:tokens]["--spacing-base"]).to eq("1rem")
      end
    end

    it "extracts Tailwind v4 @theme variables" do
      Dir.mktmpdir do |dir|
        FileUtils.mkdir_p(File.join(dir, "app/assets/tailwind"))
        File.write(File.join(dir, "app/assets/tailwind/application.css"), <<~CSS)
          @import "tailwindcss";
          @theme {
            --color-brand: #e67e22;
            --font-display: 'Playfair Display', serif;
          }
        CSS
        result = described_class.new(make_app(dir)).call
        expect(result[:tokens]["--color-brand"]).to eq("#e67e22")
      end
    end

    it "extracts Sass variables from SCSS files" do
      Dir.mktmpdir do |dir|
        FileUtils.mkdir_p(File.join(dir, "app/assets/stylesheets"))
        File.write(File.join(dir, "app/assets/stylesheets/_variables.scss"), <<~SCSS)
          $primary: #0d6efd;
          $secondary: #6c757d;
          $font-family-base: 'Inter', sans-serif;
        SCSS
        result = described_class.new(make_app(dir)).call
        expect(result[:tokens]["$primary"]).to eq("#0d6efd")
        expect(result[:tokens]["$secondary"]).to eq("#6c757d")
      end
    end

    it "skips computed Sass values" do
      Dir.mktmpdir do |dir|
        FileUtils.mkdir_p(File.join(dir, "app/assets/stylesheets"))
        File.write(File.join(dir, "app/assets/stylesheets/_variables.scss"), <<~SCSS)
          $primary: #0d6efd;
          $primary-light: lighten($primary, 10%);
        SCSS
        result = described_class.new(make_app(dir)).call
        expect(result[:tokens]["$primary"]).to eq("#0d6efd")
        expect(result[:tokens]).not_to have_key("$primary-light")
      end
    end

    it "extracts from built CSS output" do
      Dir.mktmpdir do |dir|
        FileUtils.mkdir_p(File.join(dir, "app/assets/builds"))
        File.write(File.join(dir, "app/assets/builds/tailwind.css"), <<~CSS)
          :root { --color-orange-600: oklch(64.6% .222 41.116); --font-sans: ui-sans-serif; }
        CSS
        result = described_class.new(make_app(dir)).call
        expect(result[:tokens]["--color-orange-600"]).to include("oklch")
      end
    end

    it "extracts from Webpacker-era stylesheets" do
      Dir.mktmpdir do |dir|
        FileUtils.mkdir_p(File.join(dir, "app/javascript/stylesheets"))
        File.write(File.join(dir, "app/javascript/stylesheets/variables.scss"), "$brand: #7c3aed;")
        result = described_class.new(make_app(dir)).call
        expect(result[:tokens]["$brand"]).to eq("#7c3aed")
      end
    end

    it "extracts from ViewComponent sidecar CSS" do
      Dir.mktmpdir do |dir|
        FileUtils.mkdir_p(File.join(dir, "app/components/button"))
        File.write(File.join(dir, "app/components/button/button.css"), ":root { --btn-bg: #3b82f6; }")
        result = described_class.new(make_app(dir)).call
        expect(result[:tokens]["--btn-bg"]).to eq("#3b82f6")
      end
    end

    it "returns skipped for empty apps with no tokens" do
      Dir.mktmpdir do |dir|
        FileUtils.mkdir_p(File.join(dir, "app/assets/stylesheets"))
        File.write(File.join(dir, "app/assets/stylesheets/application.css"), "/* no tokens */")
        result = described_class.new(make_app(dir)).call
        expect(result[:skipped]).to be true
      end
    end

    it "detects framework from Gemfile" do
      Dir.mktmpdir do |dir|
        FileUtils.mkdir_p(File.join(dir, "app/assets/stylesheets"))
        File.write(File.join(dir, "app/assets/stylesheets/app.css"), ":root { --x: 1; }")
        app = Struct.new(:root).new(Pathname.new(dir))
        # Write Gemfile AFTER make_app would overwrite it
        File.write(File.join(dir, "Gemfile"), 'gem "tailwindcss-rails"')
        result = described_class.new(app).call
        expect(result[:framework]).to eq("tailwind")
      end
    end

    it "extracts Tailwind v3 hex colors from config" do
      Dir.mktmpdir do |dir|
        FileUtils.mkdir_p(File.join(dir, "config"))
        File.write(File.join(dir, "config/tailwind.config.js"), <<~JS)
          module.exports = {
            theme: { extend: { colors: { brand: { 500: '#e67e22', 600: '#d35400' } } } }
          }
        JS
        result = described_class.new(make_app(dir)).call
        expect(result[:tokens].values).to include("#e67e22")
      end
    end
  end
end
