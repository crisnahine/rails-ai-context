# frozen_string_literal: true

require "spec_helper"
require "yaml"

# The release gate has to be at least as strong as the per-commit one. The
# search_code examples skip themselves when ripgrep is absent, so a matrix
# that runs them without installing it publishes on a smaller suite than CI
# checked.
RSpec.describe "the release workflow" do
  def workflow(name)
    YAML.safe_load_file(File.expand_path("../../../.github/workflows/#{name}", __dir__), aliases: true)
  end

  def step_names(job)
    job["steps"].map { |step| step["name"].to_s }
  end

  it "installs ripgrep before the job that runs the specs" do
    job = workflow("release.yml")["jobs"]["test"]

    expect(step_names(job)).to include(a_string_matching(/ripgrep/i))
  end

  it "runs the specs on the same dependency as CI" do
    ci = workflow("ci.yml")["jobs"]["test"]
    release = workflow("release.yml")["jobs"]["test"]
    rg_step = ->(job) { job["steps"].find { |step| step["name"].to_s.match?(/ripgrep/i) } }

    expect(rg_step.call(release)["run"]).to eq(rg_step.call(ci)["run"])
  end
end
