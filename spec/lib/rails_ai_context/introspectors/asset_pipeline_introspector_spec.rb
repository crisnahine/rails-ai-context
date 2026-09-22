# frozen_string_literal: true

require "spec_helper"
require "tmpdir"

RSpec.describe RailsAiContext::Introspectors::AssetPipelineIntrospector do
  let(:introspector) { described_class.new(Rails.application) }

  describe "#call" do
    subject(:result) { introspector.call }

    it "does not return an error" do
      expect(result).not_to have_key(:error)
    end

    it "returns pipeline as 'none' when no Gemfile.lock" do
      expect(result[:pipeline]).to eq("none")
    end

    it "returns empty importmap pins when no importmap.rb exists" do
      expect(result[:importmap_pins]).to eq([])
    end

    it "returns manifest files as array" do
      expect(result[:manifest_files]).to be_an(Array)
    end

    it "returns css_framework" do
      expect(result).to have_key(:css_framework)
    end

    it "returns js_bundler" do
      expect(result).to have_key(:js_bundler)
    end

    context "with an importmap.rb" do
      let(:importmap_path) { File.join(Rails.root, "config/importmap.rb") }

      before do
        File.write(importmap_path, <<~RUBY)
          pin "application"
          pin "@hotwired/turbo-rails", to: "turbo.min.js"
          pin "@hotwired/stimulus", to: "stimulus.min.js"
        RUBY
      end

      after { FileUtils.rm_f(importmap_path) }

      it "extracts importmap pins" do
        expect(result[:importmap_pins]).to contain_exactly(
          "@hotwired/stimulus", "@hotwired/turbo-rails", "application"
        )
      end

      it "detects importmap as js_bundler" do
        expect(result[:js_bundler]).to eq("importmap")
      end

      it "includes importmap.rb in manifest files" do
        expect(result[:manifest_files]).to include("importmap.rb")
      end
    end

    context "with a vite.config.ts file" do
      let(:vite_config) { File.join(Rails.root, "vite.config.ts") }

      before { File.write(vite_config, "export default {}") }
      after { FileUtils.rm_f(vite_config) }

      it "detects vite as js_bundler" do
        expect(result[:js_bundler]).to eq("vite")
      end
    end
  end

  describe "gem detection through the lockfile" do
    around { |example| Dir.mktmpdir { |dir| @root = dir; example.run } }

    def introspect(lock)
      File.write(File.join(@root, "Gemfile.lock"), lock)
      described_class.new(double("app", root: @root))
    end

    it "does not report propshaft for a gem whose name merely contains it" do
      lock = <<~LOCK
        GEM
          remote: https://rubygems.org/
          specs:
            propshaft-rails (0.1.0)
      LOCK
      expect(introspect(lock).send(:detect_pipeline)).to eq("none")
    end

    it "reports propshaft from the PATH section" do
      lock = <<~LOCK
        PATH
          remote: vendor/propshaft
          specs:
            propshaft (1.1.0)
      LOCK
      expect(introspect(lock).send(:detect_pipeline)).to eq("propshaft")
    end

    it "reports tailwindcss from the GIT section" do
      lock = <<~LOCK
        GIT
          remote: https://github.com/rails/tailwindcss-rails.git
          revision: 0123456789abcdef0123456789abcdef01234567
          specs:
            tailwindcss-rails (3.0.0)
      LOCK
      expect(introspect(lock).send(:detect_css_framework)).to eq("tailwindcss")
    end
  end

  describe "package detection through package.json" do
    around { |example| Dir.mktmpdir { |dir| @root = dir; example.run } }

    def introspect(package_json)
      File.write(File.join(@root, "package.json"), JSON.generate(package_json))
      File.write(File.join(@root, "Gemfile.lock"), <<~LOCK)
        GEM
          remote: https://rubygems.org/
          specs:
            propshaft (1.1.0)
      LOCK
      described_class.new(double("app", root: @root))
    end

    let(:vite_app) do
      {
        "dependencies" => { "vite" => "^5.0.0", "vite-plugin-ruby" => "^5.0.0" },
        "overrides" => { "webpack" => "^5.76.0", "postcss" => "^8.4.31", "esbuild" => "^0.25.0" }
      }
    end

    it "ignores an overrides pin when naming the bundler" do
      File.write(File.join(@root, "vite.config.js"), "export default {}")
      expect(introspect(vite_app).send(:detect_js_bundler)).to eq("vite")
    end

    it "ignores an overrides pin when naming the CSS framework" do
      expect(introspect(vite_app).send(:detect_css_framework)).to be_nil
    end

    it "reports tailwindcss reached through a scoped plugin package" do
      pkg = { "devDependencies" => { "@tailwindcss/vite" => "^4.0.0" } }
      expect(introspect(pkg).send(:detect_css_framework)).to eq("tailwindcss")
    end

    it "reports a dependency named outright" do
      pkg = { "devDependencies" => { "esbuild" => "^0.25.0" } }
      expect(introspect(pkg).send(:detect_js_bundler)).to eq("esbuild")
    end
  end
end
