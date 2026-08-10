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

  it "publishes the same enum every tool declares" do
    tools = RailsAiContext::Tools::BaseTool.registered_tools.select(&:detail_param?)

    expect(tools.size).to be >= 20

    tools.each do |tool|
      enum = tool.input_schema.to_h.dig(:properties, :detail, :enum)
      expect(enum).to eq(RailsAiContext::DetailLevel::ALL), "#{tool.tool_name} declares #{enum.inspect}"
    end
  end
end
