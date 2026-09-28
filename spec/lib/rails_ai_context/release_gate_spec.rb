# frozen_string_literal: true

require "spec_helper"
require "yaml"

# CI and the release share one matrix, so this pins the seams: the callers, the input,
# and what the release-only steps run.
RSpec.describe "the release workflow" do
  let(:matrix_path) { "./.github/workflows/unit-matrix.yml" }

  def workflow(name)
    YAML.safe_load_file(File.expand_path("../../../.github/workflows/#{name}", __dir__), aliases: true)
  end

  def matrix_steps
    workflow("unit-matrix.yml")["jobs"]["test"]["steps"]
  end

  # The steps the release gate turns on. A `!` in the condition is the CI-only
  # path, which must not count as coverage of what a publish runs.
  def release_only_script
    matrix_steps.select { |step|
      condition = step["if"].to_s
      condition.include?("inputs.release_gate") && !condition.include?("!inputs.release_gate")
    }.map { |step| step["run"].to_s }.join("\n")
  end

  # release.yml grants itself contents: write and id-token: write for the
  # publish. A called workflow that states nothing inherits them on every one
  # of the 21 test legs, which run third-party gem code.
  it "runs the unit matrix with no more than read access" do
    expect(workflow("unit-matrix.yml")["jobs"]["test"]["permissions"]).to eq("contents" => "read")
  end

  it "installs ripgrep before the steps that run the specs" do
    ripgrep = matrix_steps.index { |step| step["name"].to_s.match?(/ripgrep/i) }
    first_run = matrix_steps.index { |step| step["name"].to_s.match?(/run specs/i) }

    expect(ripgrep).not_to be_nil
    expect(ripgrep).to be < first_run
  end

  it "runs the same unit matrix the per-commit CI runs" do
    expect(workflow("release.yml")["jobs"]["test"]["uses"]).to eq(matrix_path)
    expect(workflow("ci.yml")["jobs"]["test"]["uses"]).to eq(matrix_path)
  end

  it "asks the release gate for the orderings a publish needs" do
    expect(workflow("release.yml")["jobs"]["test"]["with"]).to eq("release_gate" => true)
  end

  it "publishes only after the unit matrix and the e2e gate" do
    expect(workflow("release.yml")["jobs"]["publish"]["needs"]).to contain_exactly("test", "e2e-gate")
  end

  # 27377 is kept because it caught a real cross-example cache leak that a
  # random seed had waved through on the same commit.
  it "runs the three fixed seeds and defined order on the release path" do
    script = release_only_script

    expect(script).to include("1 27377 90210")
    expect(script).to include("--seed")
    expect(script).to include("--order defined")
  end

  # CI covers this in its own lint job, which the release does not have.
  it "runs RuboCop on the release path, on a leg the matrix keeps" do
    rubocop = matrix_steps.find { |step| step["run"].to_s.include?("rubocop --parallel") }
    ruby, rails = rubocop["if"].to_s.scan(/matrix\.(?:ruby|rails) == '([\d.]+)'/).flatten
    matrix = workflow("unit-matrix.yml")["jobs"]["test"]["strategy"]["matrix"]

    expect(release_only_script).to include("rubocop --parallel")
    expect(matrix["ruby"]).to include(ruby)
    expect(matrix["rails"]).to include(rails)
    expect(matrix["exclude"]).not_to include("ruby" => ruby, "rails" => rails)
  end

  # Without this step every CI leg would install ripgrep, run no examples and pass.
  it "runs the specs on the per-commit path" do
    ci_only = matrix_steps.select { |step| step["if"].to_s.include?("!inputs.release_gate") }

    expect(ci_only.map { |step| step["run"].to_s }).to include("bundle exec rspec")
  end
end
