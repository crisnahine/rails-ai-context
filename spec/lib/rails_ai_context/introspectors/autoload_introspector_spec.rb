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
  end
end
