# frozen_string_literal: true

require "spec_helper"
require "open3"
require "rails/generators"
require "generators/rails_ai_context/install/install_generator"

# The copy-paste prompts are pasted into AI tools and saved in team wikis, so
# a prompt that names a flag the install does not have, or a README copy that
# drifted from the prompt it claims to be, fails where nobody is watching.
RSpec.describe "the copy-paste prompts" do
  root = File.expand_path("../../..", __dir__)
  prompts_doc = File.read(File.join(root, "docs/PROMPTS.md"))
  readme = File.read(File.join(root, "README.md"))

  prompts = prompts_doc.scan(/^### (.+?)\n.*?```text\n(.*?)```/m).to_h

  # A heading's anchor, as GitHub and the docs site spell it.
  anchors = prompts_doc.scan(/^#+ (.+)$/).flatten.map { |heading| heading.downcase.gsub(/[^a-z0-9 -]/, "").tr(" ", "-") }

  # Every install command line the docs show, wherever it is written.
  docs = Dir[File.join(root, "{README.md,docs/*.md}")].to_h { |path| [ File.basename(path), File.read(path) ] }
  command_lines = docs.flat_map do |name, text|
    text.scan(/(?:rails generate rails_ai_context:install|rails-ai-context init)(?: [^`\n#|]*)?/)
        .map { |line| [ name, line.strip ] }
  end

  def self.long_flags(line)
    line.split.select { |word| word.start_with?("--") }.map { |flag| flag.delete_prefix("--").split("=").first }
  end

  it "has a prompt under every heading the picker links to" do
    picked = prompts_doc[/## Pick your prompt.*?\n---/m].scan(/\]\(#([a-z0-9-]+)\)/).flatten

    expect(picked - anchors).to be_empty
  end

  it "keeps the README's install prompt identical to the recommended one" do
    copy = readme[/<!-- BEGIN install-prompt.*?-->\n```text\n(.*?)```\n<!-- END install-prompt -->/m, 1]

    expect(copy).not_to be_nil
    expect(copy).to eq(prompts.fetch("Install (recommended)"))
  end

  it "links only to prompts that exist" do
    links = docs.values.join("\n").scan(/PROMPTS\.md#([a-z0-9-]+)/).flatten.uniq

    expect(links - anchors).to be_empty
  end

  generator_flags = RailsAiContext::Generators::InstallGenerator.class_options.keys.map { |key| key.to_s.tr("_", "-") }
  # Read from the binary's own help, once and only when an example needs it,
  # so a flag added to init is known here.
  read_flags = nil
  define_method(:init_flags) do
    read_flags ||= begin
      help, = Open3.capture2e(RbConfig.ruby, "-I", File.join(root, "lib"), File.join(root, "exe/rails-ai-context"), "help", "init")
      help.scan(/--(?:\[no-\])?([a-z][a-z-]*)/).flatten.uniq
    end
  end

  command_lines.each do |(file, line)|
    it "#{file}: `#{line}` uses only flags the command has" do
      known = line.start_with?("rails generate") ? generator_flags : init_flags
      flags = self.class.long_flags(line)

      expect(flags - known).to be_empty
    end
  end

  # A `--tools` value in a prompt is either the TOOL placeholder the prompt
  # fills in, a list name, or tool names the install accepts.
  it "names only real AI tools after --tools" do
    # A line showing what a bad value does names one on purpose.
    lines = docs.values.join("\n").lines.grep_v(/exits? 1|not an AI tool/)
    values = lines.join.scan(/--tools[ =]([^\s`]+)/).flatten.uniq - %w[TOOL LIST NEWLIST]

    values.each do |value|
      expect { RailsAiContext::Install::Program.tools_flag(value) }.not_to raise_error, value
    end
  end

  it "never passes two setup flags together" do
    clashing = command_lines.select { |(_, line)| (self.class.long_flags(line) & %w[mcp cli mcp-only]).size > 1 }

    expect(clashing).to be_empty
  end

  # Each install prompt runs unattended: one that runs the install without
  # --defaults would stop on a question in a terminal nobody types into.
  prompts.each do |title, body|
    body.scan(/(?:rails generate rails_ai_context:install|rails-ai-context init)[^`\n]*/).each do |line|
      it "#{title}: `#{line}` asks nothing" do
        expect(line).to include("--defaults")
      end
    end
  end
end
