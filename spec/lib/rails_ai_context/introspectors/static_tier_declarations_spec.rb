# frozen_string_literal: true

require "spec_helper"

# The contract for every declaration: files-only means the introspector really
# does answer from files alone, proven against a fixture app with nothing
# booted. The spec grows with declarations at no marginal cost.
RSpec.describe "Static tier declarations" do
  MAPPED = RailsAiContext::Introspector::INTROSPECTOR_MAP

  def fixture_app_root
    File.expand_path("../../../fixtures/static_app", __dir__)
  end

  def with_static_tier
    previous = RailsAiContext.tier
    RailsAiContext.tier = :static
    yield
  ensure
    RailsAiContext.tier = previous
  end

  it "covers every mapped introspector" do
    undeclared = MAPPED.reject { |_name, klass| klass.respond_to?(:static_tier_declared?) && klass.static_tier_declared? }

    expect(undeclared).to be_empty,
      "Introspectors with no static tier declaration: #{undeclared.keys.join(', ')}"
  end

  it "keeps every declaration consistent with its static_call" do
    expect { MAPPED.each_value(&:validate_static_tier!) }.not_to raise_error
  end

  describe "files-only introspectors, against a static app handle" do
    let(:app) { RailsAiContext::StaticApp.new(fixture_app_root) }

    MAPPED.select { |_name, klass| klass.static_tier == :files_only }.each do |name, klass|
      it "#{name} returns data with nothing booted" do
        result = with_static_tier { klass.new(app).call }

        expect(result).to be_a(Hash)
        expect(result[:error]).to be_nil
        expect(result[:unavailable]).to be_nil
      end
    end
  end

  describe "alternate-source introspectors, against a static app handle" do
    let(:app) { RailsAiContext::StaticApp.new(fixture_app_root) }

    MAPPED.select { |_name, klass| klass.static_tier == :alternate_source }.each do |name, klass|
      it "#{name} answers through static_call" do
        result = with_static_tier { klass.new(app).static_call }

        expect(result).to be_a(Hash)
        expect(result[:unavailable]).to be_nil
      end
    end
  end
end
