# frozen_string_literal: true

require_relative "../e2e_helper"

RSpec.describe E2E::TestAppBuilder do
  let(:parent_dir) { Dir.mktmpdir("rails_ai_context_builder") }

  after { FileUtils.remove_entry(parent_dir) if File.exist?(parent_dir) }

  it "uses only cross-version rails new flags" do
    builder = described_class.new(
      parent_dir: parent_dir,
      name: "compat_app",
      install_path: :in_gemfile
    )

    expect(builder.rails_new_flags).to include("--skip-dev-gems")
    expect(builder.rails_new_flags).not_to include("--skip-kamal")
    expect(builder.rails_new_flags).not_to include("--skip-solid")
    expect(builder.rails_new_flags).not_to include("--skip-thruster")
    expect(builder.rails_new_flags).not_to include("--skip-docker")
  end
end
