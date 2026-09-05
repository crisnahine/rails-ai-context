# frozen_string_literal: true

require "spec_helper"
require "rails/generators"
require "generators/rails_ai_context/install/install_generator"
require "rake"

# A file the app has nothing to put in is written by nobody and named by
# every surface. Dropping it silently made a deliberate omission look like
# a failed run.
RSpec.describe "not-applicable context files on every surface" do
  def repo_root
    File.expand_path("../../..", __dir__)
  end

  def capture_stderr
    previous = $stderr
    $stderr = StringIO.new
    yield
    $stderr.string
  ensure
    $stderr = previous
  end

  # Drives the shipped rakefile the way `bin/rails ai:context` does.
  def invoke_rake_context
    previous_application = Rake.application
    previous_stdout = $stdout
    Rake.application = Rake::Application.new
    Rake.application.rake_require(
      "rails_ai_context", [ File.join(repo_root, "lib", "rails_ai_context", "tasks") ], []
    )
    Rake::Task.define_task(:environment)
    $stdout = StringIO.new
    Rake.application["ai:context"].invoke
    $stdout.string
  ensure
    $stdout = previous_stdout
    Rake.application = previous_application
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

  it "names them in the watcher output" do
    watcher = RailsAiContext::Watcher.new(RailsAiContext::StaticApp.new(Dir.pwd))
    allow(RailsAiContext).to receive(:generate_context).and_return(
      written: [], skipped: [], not_applicable: { "/app/.claude/rules/rails-models.md" => "no models" }
    )

    err = capture_stderr { watcher.send(:regenerate) }

    expect(err).to include("  Not applicable: /app/.claude/rules/rails-models.md (no models)")
  end

  it "names them on the rake surface" do
    Dir.mktmpdir do |tmp|
      root = Pathname.new(File.realpath(tmp))
      File.write(root.join(".rails-ai-context.yml"), "ai_tools:\n  - claude\ntool_mode: mcp\n")
      allow(Rails).to receive(:root).and_return(root)
      allow(RailsAiContext).to receive(:generate_context).and_return(
        written: [], skipped: [], not_applicable: { "/app/.claude/rules/rails-models.md" => "no models" }
      )
      allow(RailsAiContext::LegacyCleanup).to receive(:prompt_legacy_files)

      out = invoke_rake_context

      expect(out).to include("  \u2796  /app/.claude/rules/rails-models.md (no models)")
    end
  end

  # The rake task and the install generator print the same emoji wording, so
  # the table is one edit rather than one per surface. Both are driven here
  # with the shared table replaced: a surface holding its own copy keeps
  # printing the old words.
  it "words the emoji surfaces from the one shared table" do
    stub_const(
      "RailsAiContext::ContextFileReport::STYLES",
      RailsAiContext::ContextFileReport::STYLES.merge(
        emoji: RailsAiContext::ContextFileReport::STYLES[:emoji].merge(written: "MARKER %s")
      )
    )
    allow(RailsAiContext).to receive(:generate_context).and_return(
      written: [ "/app/CLAUDE.md" ], skipped: [], not_applicable: {}
    )
    allow(RailsAiContext::LegacyCleanup).to receive(:prompt_legacy_files)

    generator = RailsAiContext::Generators::InstallGenerator.new
    generator.instance_variable_set(:@selected_formats, [ :claude ])
    said = []
    allow(generator).to receive(:say) { |text, *| said << text }
    generator.send(:generate_context_files)

    Dir.mktmpdir do |tmp|
      root = Pathname.new(File.realpath(tmp))
      File.write(root.join(".rails-ai-context.yml"), "ai_tools:\n  - claude\ntool_mode: mcp\n")
      allow(Rails).to receive(:root).and_return(root)

      expect(invoke_rake_context).to include("  MARKER /app/CLAUDE.md")
    end

    expect(said).to include("  MARKER /app/CLAUDE.md")
  end

  # The colour is a fact about the bucket, not about the generator, so it
  # travels with the wording. A surface holding its own copy keeps the old
  # colour and prints nil for a bucket it never heard of.
  it "colours the install surface's lines from the one shared table" do
    stub_const(
      "RailsAiContext::ContextFileReport::COLORS",
      RailsAiContext::ContextFileReport::COLORS.merge(written: :magenta)
    )
    allow(RailsAiContext).to receive(:generate_context).and_return(
      written: [ "/app/CLAUDE.md" ], skipped: [], not_applicable: {}
    )
    allow(RailsAiContext::LegacyCleanup).to receive(:prompt_legacy_files)

    generator = RailsAiContext::Generators::InstallGenerator.new
    generator.instance_variable_set(:@selected_formats, [ :claude ])
    colors = []
    allow(generator).to receive(:say) { |_text, color = nil| colors << color }
    generator.send(:generate_context_files)

    expect(colors).to include(:magenta)
  end
end
