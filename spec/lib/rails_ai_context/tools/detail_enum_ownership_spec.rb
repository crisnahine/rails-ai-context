# frozen_string_literal: true

require "spec_helper"

RSpec.describe "DetailLevel owns the schema enum" do
  let(:lib_root) { File.expand_path("../../../../../lib", __FILE__) }
  let(:detail_level_path) { File.join(lib_root, "rails_ai_context", "detail_level.rb") }

  it "spells the three levels in exactly one file" do
    offenders = Dir.glob(File.join(lib_root, "**", "*.rb"))
      .reject { |f| f == detail_level_path }
      .select { |f|
        File.readlines(f)
          .reject { |l| l.strip.start_with?("#") }
          .any? { |l| l.match?(/%w\[summary standard full\]|"summary",\s*"standard",\s*"full"/) }
      }
      .map { |f| f.sub("#{lib_root}/", "") }

    expect(offenders).to be_empty,
      "Files spelling the detail levels instead of referencing DetailLevel::ALL: #{offenders.join(', ')}"
  end

  it "builds every tool's detail property, wording aside" do
    config = RailsAiContext::Tools::GetConfig
    renderers = config::SECTIONS.reject(&:app?).map(&:renderer)
    tools = (RailsAiContext::Tools::BaseTool.registered_tools + renderers).select(&:detail_param?)

    expect(tools.size).to be >= 20

    tools.each do |tool|
      declared = tool.input_schema.to_h.dig(:properties, :detail)
      expect(declared).to eq(RailsAiContext::DetailLevel.schema(declared[:description])),
        "#{tool.tool_name} declares #{declared.inspect}"
    end
  end

  it "gives every served tool that takes detail the shared levels" do
    served = RailsAiContext::Server.exposed_tools.select { |tool| tool.respond_to?(:input_schema) }
    with_detail = served.select { |tool| tool.input_schema.to_h.dig(:properties, :detail) }

    expect(with_detail.map(&:tool_name)).to include("rails_onboard")
    with_detail.each do |tool|
      expect(tool.input_schema.to_h.dig(:properties, :detail, :enum)).to eq(RailsAiContext::DetailLevel::ALL),
        "#{tool.tool_name} takes other detail levels"
    end
  end

  it "leaves no tool spelling the detail property by hand" do
    offenders = Dir.glob(File.join(lib_root, "rails_ai_context", "tools", "*.rb"))
      .select { |f| File.read(f).match?(/detail: \{/) }
      .map { |f| File.basename(f) }

    expect(offenders).to be_empty,
      "Tools spelling the detail hash instead of calling DetailLevel.schema: #{offenders.join(', ')}"
  end
end
