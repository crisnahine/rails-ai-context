# frozen_string_literal: true

require "spec_helper"
require "rails/generators"
require "generators/rails_ai_context/install/install_generator"

# A file the app has nothing to put in is written by nobody and named by
# every surface. Dropping it silently made a deliberate omission look like
# a failed run.
RSpec.describe "not-applicable context files on every surface" do
  def repo_root
    File.expand_path("../../..", __dir__)
  end

  it "names them in the install generator output" do
    generator = RailsAiContext::Generators::InstallGenerator.new
    generator.instance_variable_set(:@selected_formats, [ :claude ])
    allow(RailsAiContext).to receive(:generate_context).and_return(
      written: [], skipped: [], not_applicable: { "/app/.claude/rules/rails-models.md" => "no models" }
    )
    allow(RailsAiContext::LegacyCleanup).to receive(:prompt_legacy_files)
    said = []
    allow(generator).to receive(:say) { |text, *| said << text }

    generator.send(:generate_context_files)

    expect(said).to include("  ➖  /app/.claude/rules/rails-models.md (no models)")
  end

  it "names them in the standalone CLI output" do
    exe = File.join(repo_root, "exe", "rails-ai-context")
    lib = File.join(repo_root, "lib")

    Dir.mktmpdir do |tmp|
      dir = File.realpath(tmp)
      FileUtils.mkdir_p(File.join(dir, "config"))
      File.write(File.join(dir, "config", "application.rb"), "module Bare; class Application; end; end\n")
      File.write(File.join(dir, "config", "environment.rb"), "\n")

      out = `ruby -I #{lib} #{exe} context --app-path #{dir} --no-boot 2>&1`

      expect($?.exitstatus).to eq(0), out
      expect(out).to include("Not applicable: #{File.join(dir, '.claude', 'rules', 'rails-models.md')} (no models)")
      expect(File.exist?(File.join(dir, ".claude", "rules", "rails-models.md"))).to be false
    end
  end

  # The rake task builds its own printer rather than calling the CLI's, so
  # only a parity check keeps the two surfaces from drifting apart again.
  it "names them on every surface that prints the other two buckets" do
    surfaces = [
      File.join(repo_root, "exe", "rails-ai-context"),
      File.join(repo_root, "lib", "rails_ai_context", "tasks", "rails_ai_context.rake"),
      File.join(repo_root, "lib", "rails_ai_context", "watcher.rb"),
      File.join(repo_root, "lib", "generators", "rails_ai_context", "install", "install_generator.rb")
    ]

    silent = surfaces.reject { |path| File.read(path).include?("result[:not_applicable]") }

    expect(silent).to be_empty
  end
end
