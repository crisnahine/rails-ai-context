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
      # every entry, this assertion fails - catching a silent introspection
      # degradation that other tests would miss.
      with_source = result[:initializers].count { |i| i[:source].is_a?(String) && !i[:source].empty? }
      expect(with_source).to be > 0
    end

    # These sources are written into .ai-context.json, which the app commits.
    # An absolute path is wrong on every other machine, wrong again after a
    # Ruby upgrade, and it carries the generating developer's username.
    it "reports gem-owned sources gem-relative rather than as machine paths" do
      gem_roots = Gem.path.map { |path| File.join(path, "gems") }
      machine_paths = result[:initializers].filter_map { |i| i[:source] }
        .select { |source| gem_roots.any? { |root| source.start_with?(root) } }

      expect(machine_paths).to be_empty
    end

    it "names the gem and version it relativized against" do
      railties = Gem.loaded_specs["railties"]&.full_gem_path
      skip "railties is not installed under a gem root" unless railties &&
        Gem.path.any? { |dir| railties.start_with?(File.join(dir, "gems")) }

      sources = result[:initializers].filter_map { |i| i[:source] }

      expect(sources).to include(a_string_starting_with("#{File.basename(railties)}/"))
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
