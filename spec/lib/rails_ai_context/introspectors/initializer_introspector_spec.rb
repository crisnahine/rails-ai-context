# frozen_string_literal: true

require "spec_helper"

RSpec.describe RailsAiContext::Introspectors::InitializerIntrospector do
  let(:introspector) { described_class.new(Rails.application) }

  describe "#call" do
    subject(:result) { introspector.call }

    it "returns a Hash with total initializer count" do
      expect(result).to be_a(Hash)
      expect(result[:total]).to be_a(Integer)
      expect(result[:total]).to be > 0
    end

    it "returns initializers as array of primitives" do
      expect(result[:initializers]).to be_an(Array)
      result[:initializers].first(5).each do |entry|
        expect(entry).to be_a(Hash)
        expect(entry[:name]).to be_a(String)
      end
    end

    it "groups initializers by owner" do
      expect(result[:by_owner]).to be_a(Hash)
      expect(result[:by_owner].values).to all(be_a(Integer))
    end

    it "captures before/after ordering edges when present" do
      has_ordering = result[:initializers].any? { |i| i[:before] || i[:after] }
      expect(has_ordering).to eq(true)
    end

    it "captures block source_location for at least some initializers" do
      # Rails initializers defined in railties have Procs with source_location.
      # If the @block ivar is renamed or Proc#source_location returns nil for
      # every entry, this assertion fails — catching a silent introspection
      # degradation that other tests would miss.
      with_source = result[:initializers].count { |i| i[:source].is_a?(String) && !i[:source].empty? }
      expect(with_source).to be > 0
    end

    it "lists application initializer files from config/initializers/" do
      expect(result[:application_initializers]).to be_an(Array)
    end

    it "does not raise on a fresh Rails app" do
      expect(result).not_to have_key(:error)
    end

    context "when Rails.application doesn't expose initializers" do
      let(:introspector) { described_class.new(Object.new) }

      it "returns available: false" do
        expect(result[:available]).to eq(false)
      end
    end
  end
end
