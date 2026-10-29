# frozen_string_literal: true

require "spec_helper"

# For every selection of AI tools, what each chosen tool loads at the start of
# a session, read the way it reads them: its root files, an import expanded
# where it expands one, and every rule its frontmatter applies always. The
# root content arrives once, within the root file's budget.
RSpec.describe "What each AI tool loads at session start" do
  let(:context) { RailsAiContext.introspect }
  let(:budget) { RailsAiContext::Serializers::Budget::BYTES.fetch(:root) }
  let(:tools) { RailsAiContext::Install::AiTool.all }

  # A rule the tool applies to every request: a Claude rule without paths, a
  # Cursor rule with alwaysApply, a Copilot file applying to every file.
  def always_rules(tool, dir)
    return [] unless tool.rules_dir

    Dir.glob(File.join(dir, tool.rules_dir, "*")).select do |file|
      head = File.read(file)[/\A---\n.*?\n---\n/m].to_s
      case tool.key
      when :claude then !head.include?("paths:")
      when :cursor then head.include?("alwaysApply: true")
      else head.include?(%(applyTo: "**/*"))
      end
    end
  end

  # every: true for what all of the tool's surfaces load; false for its widest one.
  def loaded(tool, dir, every: true)
    roots = tool.reads.select { |read| read.every_surface || !every }.filter_map do |read|
      file = File.join(dir, read.path)
      next unless File.exist?(file)

      text = File.read(file)
      read.imports ? text.gsub(/^@(\S+)$/) { File.exist?(File.join(dir, ::Regexp.last_match(1))) ? File.read(File.join(dir, ::Regexp.last_match(1))) : "" } : text
    end
    roots + always_rules(tool, dir).map { |file| File.read(file) }
  end

  (1..5).flat_map { |n| %i[claude cursor copilot opencode codex].combination(n).to_a }.each do |selection|
    it "loads the root content once in each of #{selection.join(", ")}" do
      Dir.mktmpdir do |dir|
        allow(RailsAiContext.configuration).to receive_messages(output_dir_for: dir, ai_tools: selection)
        %w[app/models app/controllers].each { |sub| FileUtils.mkdir_p(File.join(dir, sub)) }
        RailsAiContext::Serializers::ContextFileSerializer.new(context, format: selection).call

        tools.select { |tool| selection.include?(tool.key) }.each do |tool|
          texts = loaded(tool, dir)
          guides = texts.sum { |text| text.scan("Anti-Hallucination Protocol").size }

          expect(guides).to eq(1), "#{tool.key} loads the guide #{guides} times"
          expect(texts.sum(&:bytesize)).to be <= budget + 200, "#{tool.key} loads #{texts.sum(&:bytesize)} bytes"

          # VS Code Copilot also attaches AGENTS.md and CLAUDE.md, beside the copy
          # every other Copilot surface needs: two copies at most, never three.
          widest = loaded(tool, dir, every: false).sum { |text| text.scan("Anti-Hallucination Protocol").size }
          expect(widest).to be <= 2, "#{tool.key}'s widest surface loads the guide #{widest} times"
        end
      end
    end
  end
end
