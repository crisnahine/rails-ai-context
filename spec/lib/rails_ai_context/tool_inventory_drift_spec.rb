# frozen_string_literal: true

require "spec_helper"

# Adding a tool should touch one file. These pin the places that used to
# carry their own copy of the inventory: the generated guide, the docs page,
# and the count phrases scattered through docs.
RSpec.describe "Tool inventory drift" do
  let(:repo_root) { File.expand_path("../../..", __dir__) }
  let(:registered) { RailsAiContext::Tools::BaseTool.registered_tools }
  let(:names) { registered.map(&:tool_name).sort }

  it "gives every tool a guide row" do
    missing = registered.reject(&:guide_row).map(&:tool_name)

    expect(missing).to be_empty,
      "Tools with no guide_row (the generated guide would not list them): #{missing.join(', ')}"
  end

  it "orders guide rows without ties or gaps" do
    orders = registered.filter_map { |t| t.guide_row&.order }

    expect(orders.uniq.size).to eq(orders.size), "duplicate guide_row order values"
    expect(orders.sort).to eq((1..orders.size).to_a)
  end

  it "names a CLI command the CLI can actually resolve" do
    unresolvable = registered.filter_map { |tool|
      cli_name = RailsAiContext::CLI::ToolRunner.short_name(tool.tool_name)
      tool.tool_name unless registered.any? { |t|
        t.tool_name == cli_name ||
          t.tool_name == "rails_#{cli_name}" ||
          t.tool_name == "rails_get_#{cli_name}" ||
          RailsAiContext::CLI::ToolRunner.short_name(t.tool_name) == cli_name
      }
    }

    expect(unresolvable).to be_empty
  end

  it "documents exactly the registered tools on the docs page" do
    page = File.read(File.join(repo_root, "docs", "TOOLS.md"))
    documented = page.scan(/^### `(rails_\w+)`/).flatten.sort

    expect(documented - names).to be_empty, "Documented but not registered: #{(documented - names).join(', ')}"
    expect(names - documented).to be_empty, "Registered but not documented: #{(names - documented).join(', ')}"
  end

  # "the 24 tools below" counts a deliberate subset, so only totals are
  # checked: a bare number in front of "tools" that is not scoped by a
  # nearby "below" or "other".
  TOTAL_PHRASE = /(?<!other )\b(\d+)\s+(?:MCP\s+)?tools\b(?!\s+below)/

  it "quotes the registry's count wherever docs state the total" do
    count = names.size
    offenders = Dir.glob(File.join(repo_root, "docs", "**", "*.md"))
      .concat([ File.join(repo_root, "README.md") ])
      .select { |f| File.exist?(f) }
      .flat_map { |f|
        File.readlines(f).each_with_index.flat_map { |line, i|
          line.scan(TOTAL_PHRASE).flatten.reject { |n| n.to_i == count }.map {
            "#{f.sub("#{repo_root}/", '')}:#{i + 1}: #{line.strip}"
          }
        }
      }

    expect(offenders).to be_empty,
      "Doc lines stating a tool total other than #{count}:\n#{offenders.join("\n")}"
  end
end
