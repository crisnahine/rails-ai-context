# frozen_string_literal: true

require "spec_helper"

RSpec.describe RailsAiContext::Introspectors::AutoloadIntrospector do
  let(:introspector) { described_class.new(Rails.application) }

  describe "#call" do
    subject(:result) { introspector.call }

    it "returns a Hash without error" do
      expect(result).to be_a(Hash)
      expect(result).not_to have_key(:error)
    end

    it "detects the autoloader mode" do
      expect(result[:mode]).to be_in(%w[zeitwerk classic unknown])
    end

    it "reports zeitwerk availability" do
      expect(result[:zeitwerk_available]).to eq(true).or(eq(false))
    end

    it "returns autoload_paths as array of strings" do
      expect(result[:autoload_paths]).to be_an(Array)
      expect(result[:autoload_paths]).to all(be_a(String))
    end

    it "returns eager_load_paths as array of strings" do
      expect(result[:eager_load_paths]).to be_an(Array)
      expect(result[:eager_load_paths]).to all(be_a(String))
    end

    it "returns eager_load as boolean" do
      expect(result[:eager_load]).to eq(true).or(eq(false))
    end

    it "returns autoloaders with expected structure" do
      expect(result[:autoloaders]).to be_an(Array)
      result[:autoloaders].each do |loader|
        expect(loader[:name]).to be_in(%w[main once])
      end
    end

    it "returns custom_inflections as array" do
      expect(result[:custom_inflections]).to be_an(Array)
    end

    context "when an initializer declares an acronym inflection" do
      let(:init_path) { File.join(Rails.root, "config/initializers/inflection_test.rb") }

      before do
        FileUtils.mkdir_p(File.dirname(init_path))
        File.write(init_path, <<~RUBY)
          ActiveSupport::Inflector.inflections(:en) do |inflect|
            inflect.acronym "XYZ"
          end
        RUBY
      end

      after { FileUtils.rm_f(init_path) }

      it "extracts the acronym rule" do
        expect(result[:custom_inflections].map { |i| i[:rule] }).to include("acronym: XYZ")
      end
    end

    context "when an initializer is formatted awkwardly" do
      let(:init_path) { File.join(Rails.root, "config/initializers/inflection_odd_test.rb") }

      before do
        FileUtils.mkdir_p(File.dirname(init_path))
        File.write(init_path, <<~RUBY)
          ActiveSupport::Inflector.inflections(:en) do |inflect|
            inflect.irregular(
              "person",
              "people"
            )
            inflect.uncountable "fish"
            inflect.singular(/(quiz)zes$/i, '\\1')
            inflect.plural(/(quiz)$/i, '\\1zes')
            inflect.human "legacy_col", "Legacy column"
          end

          Rails.autoloaders.each do |loader|
            loader.inflector.inflect(
              "api" => "API",
              "xml" => "XML"
            )
          end
        RUBY
      end

      after { FileUtils.rm_f(init_path) }

      it "reads every directive and the hash form" do
        rules = result[:custom_inflections].map { |i| i[:rule] }

        expect(rules).to include("irregular: person => people")
        expect(rules).to include("uncountable: fish")
        expect(rules).to include("human: legacy_col => Legacy column")
        expect(rules).to include("api => API", "xml => XML")
        expect(rules.grep(/\Aplural: /).size).to eq(1)
        expect(rules.grep(/\Asingular: /).size).to eq(1)
      end
    end

    # Every engine's paths land on the `once` autoloader, under the machine's
    # gem prefix rather than the app root.
    context "when an autoloader roots a directory inside an installed gem" do
      let(:gem_dir) { File.join(Gem.path.first, "gems", "doorkeeper-5.9.5", "app", "controllers") }
      let(:loader) { double("Zeitwerk::Loader", tag: "rails.once", dirs: [ gem_dir ]) }

      before do
        allow(Rails).to receive(:autoloaders).and_return(double("autoloaders", main: loader, once: loader))
      end

      it "reports the gem and version rather than the install prefix" do
        once = result[:autoloaders].find { |l| l[:name] == "once" }

        expect(once[:root_dirs]).to eq([ "doorkeeper-5.9.5/app/controllers" ])
      end
    end

    # `config.autoload_lib` plus an engine leaves lib in the array twice.
    context "when Rails lists a path once per contributing railtie" do
      let(:config) do
        double(
          autoload_paths: [ Rails.root.join("lib"), Rails.root.join("lib") ],
          autoload_once_paths: [],
          eager_load_paths: [ Rails.root.join("lib"), Rails.root.join("app/services"), Rails.root.join("lib") ],
          eager_load: false
        )
      end

      let(:introspector) { described_class.new(double(root: Rails.root, config: config)) }

      it "reports each autoload path once" do
        expect(result[:autoload_paths]).to eq([ "lib" ])
      end

      it "reports each eager-load path once, in declaration order" do
        expect(result[:eager_load_paths]).to eq([ "lib", "app/services" ])
      end
    end
  end
end
