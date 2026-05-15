# frozen_string_literal: true

require "spec_helper"

RSpec.describe "support floor" do
  let(:repo_root) { File.expand_path("../../..", __dir__) }
  let(:gemspec) { Gem::Specification.load(File.join(repo_root, "rails-ai-context.gemspec")) }
  let(:gemfile) { File.read(File.join(repo_root, "Gemfile")) }
  let(:ci_yml) { File.read(File.join(repo_root, ".github/workflows/ci.yml")) }
  let(:e2e_yml) { File.read(File.join(repo_root, ".github/workflows/e2e.yml")) }

  it "declares Ruby 3.1 and Rails 7.0 as the minimum supported versions" do
    expect(gemspec.required_ruby_version.to_s).to eq(">= 3.1.0")

    railties = gemspec.dependencies.find { |dep| dep.name == "railties" }
    expect(railties.requirement.to_s).to eq(">= 7.0, < 9.0")

    expect(gemfile).to include('ENV.fetch("RAILS_VERSION", "7.0")')
  end

  it "adds Rails 7.0 / Ruby 3.1 to the CI matrix" do
    expect(ci_yml).to include('ruby: ["3.1", "3.2", "3.3", "3.4", "4.0"]')
    expect(ci_yml).to include('rails: ["7.0", "7.1", "7.2", "8.0", "8.1"]')
    expect(ci_yml).to include("- ruby: \"3.1\"\n            rails: \"8.0\"")
    expect(ci_yml).to include("- ruby: \"3.1\"\n            rails: \"8.1\"")
    expect(ci_yml).to include("- ruby: \"4.0\"\n            rails: \"7.0\"")
    expect(ci_yml).to include("- ruby: \"3.3\"\n            rails: \"7.0\"")
    expect(ci_yml).to include("- ruby: \"3.4\"\n            rails: \"7.0\"")
  end

  it "adds Rails 7.0 / Ruby 3.1 to the E2E matrix" do
    expect(e2e_yml).to include("- ruby: \"3.1\"\n            rails: \"7.0\"")
  end
end
