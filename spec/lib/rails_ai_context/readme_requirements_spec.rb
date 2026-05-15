# frozen_string_literal: true

require "spec_helper"

RSpec.describe "documented requirements" do
  let(:repo_root) { File.expand_path("../../..", __dir__) }
  let(:readme) { File.read(File.join(repo_root, "README.md")) }
  let(:contributing) { File.read(File.join(repo_root, "CONTRIBUTING.md")) }

  it "documents Ruby 3.1 and Rails 7.0 in the README requirements section" do
    expect(readme).to include("- **Ruby** >= 3.1")
    expect(readme).to include("**Rails** >= 7.0")
  end

  it "does not revert to the old Ruby 3.2 floor in the README" do
    expect(readme).not_to include("**Ruby** >= 3.2")
  end

  it "does not revert to the old Rails 7.1 floor in the README" do
    expect(readme).not_to include("**Rails** >= 7.1")
  end

  it "updates contributor guidance to the Ruby 3.1 baseline" do
    expect(contributing).to include("Ruby 3.1+")
  end

  it "does not revert to the old Ruby 3.2+ floor in CONTRIBUTING" do
    expect(contributing).not_to include("Ruby 3.2+")
  end
end
