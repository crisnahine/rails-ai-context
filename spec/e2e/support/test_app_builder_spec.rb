# frozen_string_literal: true

require_relative "../e2e_helper"

RSpec.describe E2E::TestAppBuilder do
  let(:parent_dir) { Dir.mktmpdir("rails_ai_context_builder") }

  after { FileUtils.remove_entry(parent_dir) if File.exist?(parent_dir) }

  context "when targeting Rails 7.0" do
    around do |example|
      old = ENV["RAILS_VERSION"]
      ENV["RAILS_VERSION"] = "7.0"
      example.run
    ensure
      ENV["RAILS_VERSION"] = old
    end

    it "excludes flags not available in Rails 7.0" do
      builder = described_class.new(
        parent_dir: parent_dir,
        name: "compat_app",
        install_path: :in_gemfile
      )

      expect(builder.rails_new_flags).not_to include("--skip-dev-gems")
      expect(builder.rails_new_flags).not_to include("--skip-rubocop")
      expect(builder.rails_new_flags).not_to include("--skip-ci")
      expect(builder.rails_new_flags).not_to include("--skip-kamal")
      expect(builder.rails_new_flags).not_to include("--skip-solid")
      expect(builder.rails_new_flags).not_to include("--skip-thruster")
      expect(builder.rails_new_flags).not_to include("--skip-docker")
    end
  end

  context "when targeting Rails 7.1+" do
    around do |example|
      old = ENV["RAILS_VERSION"]
      ENV["RAILS_VERSION"] = "7.1"
      example.run
    ensure
      ENV["RAILS_VERSION"] = old
    end

    it "includes newer skip flags that Rails 7.1+ supports" do
      builder = described_class.new(
        parent_dir: parent_dir,
        name: "newer_app",
        install_path: :in_gemfile
      )

      expect(builder.rails_new_flags).to include("--skip-dev-gems")
    end

    it "still includes base flags" do
      builder = described_class.new(
        parent_dir: parent_dir,
        name: "newer_app",
        install_path: :in_gemfile
      )

      expect(builder.rails_new_flags).to include("--skip-git")
      expect(builder.rails_new_flags).to include("--skip-test")
    end
  end
end
