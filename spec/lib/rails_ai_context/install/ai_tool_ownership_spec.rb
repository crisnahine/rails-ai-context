# frozen_string_literal: true

require "spec_helper"

# #117 asked for the per-AI-tool tables to be deleted or reduced to derived
# views. The ones that survived had already drifted - the rake task printed a
# Copilot row missing `.github/instructions/` - which is the failure mode a
# guard catches and a one-time cleanup does not.
RSpec.describe "AI tool identity ownership" do
  let(:lib_root) { File.expand_path("../../../../lib", __dir__) }
  let(:owner) { File.join(lib_root, "rails_ai_context", "install", "ai_tool.rb") }

  # Naming a tool in prose is fine - the serializers write "Claude Code" into
  # the files they generate. What must not be restated is the association
  # between a tool and its paths, because that is what silently goes stale.
  it "pairs an AI tool with its context files in one file" do
    pairs = /(?:claude|cursor|copilot|opencode|codex)\s*(?:=>|:)\s*["'][^"']*(?:\.md|\.json|\.toml|rules)/i

    offenders = (Dir.glob(File.join(lib_root, "**", "*.rb")) + Dir.glob(File.join(lib_root, "**", "*.rake")))
      .reject { |f| f == owner }
      .select { |f|
        File.readlines(f).reject { |l| l.strip.start_with?("#") }.any? { |l| l.match?(pairs) }
      }
      .map { |f| f.sub("#{File.dirname(lib_root)}/", "") }

    expect(offenders).to be_empty,
      "Files pairing an AI tool with its paths instead of reading Install::AiTool: #{offenders.join(', ')}"
  end

  it "derives doctor's context-file sentinels from the table" do
    expect(RailsAiContext::Doctor::CONTEXT_FILES)
      .to eq(RailsAiContext::Install::AiTool.all.to_h { |t| [ t.key, t.context_paths.first ] })
  end

  it "derives doctor's MCP config paths from the table" do
    paths = RailsAiContext::Doctor.send(:mcp_config_checks).transform_values { |c| c[:path] }

    expect(paths).to eq(RailsAiContext::Install::AiTool.all.to_h { |t| [ t.key, t.mcp_config[:path] ] })
  end

  it "names every registered tool in doctor's MCP labels" do
    labels = RailsAiContext::Doctor.send(:mcp_config_checks).values.map { |c| c[:label] }

    RailsAiContext::Install::AiTool.all.each do |tool|
      expect(labels.join(" ")).to include(tool.name), "no MCP label mentions #{tool.name}"
    end
  end
end
