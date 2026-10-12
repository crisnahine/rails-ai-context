# frozen_string_literal: true

require "spec_helper"
require "prism"

# An answer that names another tool's call writes it through BaseTool.pointer,
# which leaves it out when the app does not serve that tool. A call spelled
# into a string skips that check and sends the reader to a tool tools/list lacks.
RSpec.describe "Pointers to other tools in tool answers" do
  TOOL_DECLARATIONS = %i[tool_name description guide_row].freeze

  def raw_calls(source)
    root = Prism.parse(source).value
    own = []
    found = []
    walk = lambda do |node|
      next unless node.is_a?(Prism::Node)

      if node.is_a?(Prism::CallNode) && node.receiver.nil? && node.arguments && TOOL_DECLARATIONS.include?(node.name)
        own << node.arguments.arguments.first.unescaped if node.name == :tool_name
        next
      end
      if node.is_a?(Prism::StringNode)
        node.unescaped.scan(/\b(rails_\w+)\(/) { |(name)| found << [ name, node.location.start_line ] }
      end
      node.compact_child_nodes.each { |child| walk.call(child) }
    end
    walk.call(root)
    found.reject { |name, _| own.include?(name) }
  end

  it "finds a raw call to another tool in an answer string" do
    source = <<~RUBY
      class Demo < BaseTool
        tool_name "rails_demo"
        description "Like rails_get_schema(table:\\"x\\")"
        def self.call = text_response("_Next: `rails_get_schema(table:\\"\#{t}\\")` for columns_ or rails_demo(x:1)")
      end
    RUBY

    expect(raw_calls(source)).to eq([ [ "rails_get_schema", 4 ] ])
  end

  it "finds none in the tool sources" do
    root = File.expand_path("../../../../lib/rails_ai_context/tools", __dir__)
    offenders = Dir[File.join(root, "*.rb")].sort.flat_map do |path|
      raw_calls(File.read(path)).map { |name, line| "#{File.basename(path)}:#{line} #{name}" }
    end

    expect(offenders).to be_empty
  end
end
