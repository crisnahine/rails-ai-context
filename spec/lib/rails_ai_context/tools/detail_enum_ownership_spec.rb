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
    tools = RailsAiContext::Tools::BaseTool.registered_tools.select(&:detail_param?)

    expect(tools.size).to be >= 20

    tools.each do |tool|
      declared = tool.input_schema.to_h.dig(:properties, :detail)
      expect(declared).to eq(RailsAiContext::DetailLevel.schema(declared[:description])),
        "#{tool.tool_name} declares #{declared.inspect}"
    end
  end

  it "leaves no tool spelling the detail property by hand" do
    offenders = Dir.glob(File.join(lib_root, "rails_ai_context", "tools", "*.rb"))
      .select { |f| File.read(f).match?(/detail: \{/) }
      .map { |f| File.basename(f) }

    expect(offenders).to eq([ "onboard.rb" ]),
      "Tools spelling the detail hash instead of calling DetailLevel.schema: #{offenders.join(', ')}"
  end
end
