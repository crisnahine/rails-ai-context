# frozen_string_literal: true

require "spec_helper"

# Every file a run writes, for an app far larger than the test app, stays
# within the byte budget of its kind and keeps each list line to the width.
RSpec.describe "Context files within their budget" do
  let(:budget) { RailsAiContext::Serializers::Budget }

  let(:context) do
    big = RailsAiContext.introspect
    models = (1..400).to_h do |i|
      [ "Model#{i}", { table_name: "model#{i}s",
                       associations: (1..60).map { |j| { type: "has_many", name: "rel_#{i}_#{j}" } },
                       validations: [ { kind: "presence", attributes: [ "name" ] } ],
                       scopes: (1..60).map { |j| { name: "scope_number_#{j}" } } } ]
    end
    tables = (1..400).to_h do |i|
      [ "model#{i}s", { columns: (1..80).map { |j| { name: "column_number_#{j}", type: "string" } },
                        foreign_keys: (1..20).map { |j| { column: "rel_#{j}_id", to_table: "others#{j}" } } } ]
    end
    controllers = (1..300).to_h { |i| [ "Admin::Thing#{i}Controller", { actions: (1..30).map { |j| "action_#{j}" } } ] }
    big.merge(models: models, schema: big[:schema].merge(tables: tables), controllers: { controllers: controllers })
  end

  def files(root_files:, mode:, tool_mode: :mcp)
    Dir.mktmpdir do |dir|
      allow(RailsAiContext.configuration).to receive_messages(output_dir_for: dir, generate_root_files: root_files, context_mode: mode, tool_mode: tool_mode)
      %w[app/models app/controllers].each { |sub| FileUtils.mkdir_p(File.join(dir, sub)) }
      written = RailsAiContext::Serializers::ContextFileSerializer.new(context, format: :all).call[:written]
      written.reject { |path| path.end_with?(".json") }.to_h { |path| [ path.delete_prefix("#{dir}/"), File.read(path) ] }
    end
  end

  def kind(path, mode)
    if path.match?(%r{\A(AGENTS|CLAUDE)\.md\z|copilot-instructions\.md\z|rails-mcp-tools})
      mode == :full && !path.include?("rails-mcp-tools") ? :full : :root
    else
      :rule
    end
  end

  [ [ true, :compact, :mcp ], [ true, :full, :mcp ], [ false, :compact, :mcp ], [ true, :compact, :cli ], [ false, :compact, :cli ] ].each do |root_files, mode, tool_mode|
    context "with root files #{root_files ? "on" : "off"} in #{mode} #{tool_mode} mode" do
      it "keeps every file within the bytes its kind allows" do
        over = files(root_files: root_files, mode: mode, tool_mode: tool_mode).filter_map do |path, text|
          limit = budget::BYTES.fetch(kind(path, mode))
          "#{path}: #{text.bytesize} > #{limit}" if text.bytesize > limit
        end

        expect(over).to eq([])
      end

      # The protocol's numbered rules are fixed prose; every other line is data
      # or a list, which the width holds to.
      it "keeps every list line within the width" do
        wide = files(root_files: root_files, mode: mode, tool_mode: tool_mode).flat_map do |path, text|
          text.lines.map(&:chomp).reject { |line| line.match?(/\A\d+\. \*\*/) || line.size <= budget::LINE_WIDTH }
              .map { |line| "#{path}: #{line[0, 80]}... (#{line.size})" }
        end

        expect(wide).to eq([])
      end
    end
  end
end
