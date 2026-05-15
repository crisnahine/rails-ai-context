# frozen_string_literal: true

require "spec_helper"
require "yaml"

RSpec.describe "support floor" do
  let(:repo_root) { File.expand_path("../../..", __dir__) }
  let(:gemspec) { Gem::Specification.load(File.join(repo_root, "rails-ai-context.gemspec")) }
  let(:gemfile) { File.read(File.join(repo_root, "Gemfile")) }

  let(:ci_matrix) do
    YAML.safe_load_file(
      File.join(repo_root, ".github/workflows/ci.yml"),
      aliases: true
    ).dig("jobs", "test", "strategy", "matrix").tap do |matrix|
      raise "Could not find CI test matrix in .github/workflows/ci.yml" if matrix.nil?
    end
  end

  let(:e2e_includes) do
    YAML.safe_load_file(
      File.join(repo_root, ".github/workflows/e2e.yml"),
      aliases: true
    ).dig("jobs", "e2e", "strategy", "matrix", "include").tap do |includes|
      raise "Could not find E2E include list in .github/workflows/e2e.yml" if includes.nil?
    end
  end

  it "declares Ruby 3.1 and Rails 7.0 as the minimum supported versions" do
    # Ruby floor: 3.1.0 is the boundary — satisfied at the floor, not below
    expect(gemspec.required_ruby_version).to be_satisfied_by(Gem::Version.new("3.1.0"))
    expect(gemspec.required_ruby_version).not_to be_satisfied_by(Gem::Version.new("3.0.9"))

    railties = gemspec.dependencies.find { |dep| dep.name == "railties" }
    # Rails floor: 7.0 is supported, 6.x is not
    expect(railties.requirement).to be_satisfied_by(Gem::Version.new("7.0.0"))
    expect(railties.requirement).not_to be_satisfied_by(Gem::Version.new("6.1.7"))
    # Rails ceiling: 8.x is within range, 9.0+ is not
    expect(railties.requirement).to be_satisfied_by(Gem::Version.new("8.1.0"))
    expect(railties.requirement).not_to be_satisfied_by(Gem::Version.new("9.0.0"))

    expect(gemfile).to include('ENV.fetch("RAILS_VERSION", "7.0")')
  end

  it "adds Rails 7.0 and Ruby 3.1 to the CI matrix dimensions" do
    expect(ci_matrix["ruby"]).to include("3.1")
    expect(ci_matrix["rails"]).to include("7.0")
  end

  it "does not exclude the support-floor pair Ruby 3.1 / Rails 7.0 from the CI matrix" do
    excluded_pairs = (ci_matrix["exclude"] || []).map { |e| [e["ruby"], e["rails"]] }
    expect(excluded_pairs).not_to include(["3.1", "7.0"])
  end

  it "excludes incompatible Rails 8.x + pre-Ruby-3.3 pairs from the CI matrix" do
    excluded_pairs = (ci_matrix["exclude"] || []).map { |e| [e["ruby"], e["rails"]] }
    # Rails 8.x requires Ruby 3.3+
    expect(excluded_pairs).to include(["3.1", "8.0"])
    expect(excluded_pairs).to include(["3.1", "8.1"])
    expect(excluded_pairs).to include(["3.2", "8.0"])
    expect(excluded_pairs).to include(["3.2", "8.1"])
  end

  it "excludes incompatible Ruby 4.0 + Rails 7.x pairs from the CI matrix" do
    excluded_pairs = (ci_matrix["exclude"] || []).map { |e| [e["ruby"], e["rails"]] }
    # Rails 7.x has no upstream Ruby 4.0 support
    expect(excluded_pairs).to include(["4.0", "7.0"])
    expect(excluded_pairs).to include(["4.0", "7.1"])
    expect(excluded_pairs).to include(["4.0", "7.2"])
  end

  it "excludes incompatible Ruby 3.3+ + Rails 7.0 pairs from the CI matrix" do
    excluded_pairs = (ci_matrix["exclude"] || []).map { |e| [e["ruby"], e["rails"]] }
    # Rails 7.0 is not compatible with Ruby 3.3+ (user decision)
    expect(excluded_pairs).to include(["3.3", "7.0"])
    expect(excluded_pairs).to include(["3.4", "7.0"])
  end

  it "does not exclude currently-valid Ruby/Rails pairs from the CI matrix" do
    excluded_pairs = (ci_matrix["exclude"] || []).map { |e| [e["ruby"], e["rails"]] }
    # Representative valid pairs — guards against over-broad exclusion rules
    expect(excluded_pairs).not_to include(["3.3", "8.0"])  # Ruby 3.3 + Rails 8.0 is supported
    expect(excluded_pairs).not_to include(["3.4", "8.1"])  # Ruby 3.4 + Rails 8.1 is supported
    expect(excluded_pairs).not_to include(["4.0", "8.0"])  # Ruby 4.0 + Rails 8.0 is supported
  end

  it "declares a prism dependency compatible with Ruby 3.1 and above" do
    prism = gemspec.dependencies.find { |dep| dep.name == "prism" }
    # prism is bundled as stdlib in Ruby 3.3+; on Ruby 3.1 and 3.2 it must be
    # installed as a gem. The '>= 0.28' lower bound covers the APIs in use
    # (Prism.parse, Prism::Visitor, basic node types) which have been stable
    # since 0.28. The open-ended upper bound is intentional: no breaking
    # changes to these APIs were introduced in the 1.x line.
    expect(prism).not_to be_nil
    expect(prism.requirement).to be_satisfied_by(Gem::Version.new("0.28.0"))
    expect(prism.requirement).not_to be_satisfied_by(Gem::Version.new("0.27.9"))
    expect(prism.requirement).to be_satisfied_by(Gem::Version.new("1.9.0"))
  end

  it "adds the support-floor pair Ruby 3.1 / Rails 7.0 to the E2E matrix" do
    included_pairs = e2e_includes.map { |e| [e["ruby"], e["rails"]] }
    expect(included_pairs).to include(["3.1", "7.0"])
  end
end
