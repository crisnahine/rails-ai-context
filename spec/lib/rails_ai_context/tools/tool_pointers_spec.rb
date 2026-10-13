# frozen_string_literal: true

require "spec_helper"
require "prism"

# BaseTool.pointer leaves out a call to a tool the app does not serve; a call
# spelled into an answer string sends the reader to a tool tools/list lacks.
RSpec.describe "Pointers to other tools in tool answers" do
  let(:declarations) { %i[tool_name description guide_row] }

  def raw_calls(source)
    root = Prism.parse(source).value
    own = []
    found = []
    walk = lambda do |node|
      next unless node.is_a?(Prism::Node)

      if node.is_a?(Prism::CallNode) && node.receiver.nil? && node.arguments && declarations.include?(node.name)
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

  # [tool name, source of the other arguments, line] of each pointer call that names its tool.
  def pointer_calls(source)
    found = []
    walk = lambda do |node|
      next unless node.is_a?(Prism::Node)

      first, *rest = node.arguments&.arguments.to_a if node.is_a?(Prism::CallNode) && node.name == :pointer
      found << [ first.unescaped, rest.map(&:slice).join(", "), node.location.start_line ] if first.is_a?(Prism::StringNode)
      node.compact_child_nodes.each { |child| walk.call(child) }
    end
    walk.call(Prism.parse(source).value)
    found
  end

  # A section has one way into a pointer, its retired name, which is where the served check reads it.
  def wrong_pointers(source)
    known = RailsAiContext::Tools::BaseTool.registered_tools.map(&:tool_name) + RailsAiContext::Tools::GetConfig::SECTIONS.map(&:tool_name)
    pointer_calls(source).filter_map do |name, arguments, line|
      next [ line, "#{name} is not a tool" ] unless known.include?(name)

      [ line, "a section goes by its retired name" ] if name == "rails_get_config" && arguments.include?("section:")
    end
  end

  it "finds a pointer that spells a config section into its arguments, or names no tool" do
    source = <<~'RUBY'
      pointer("rails_get_config", 'section:"gems"')
      pointer("rails_get_config", %(section:"#{name}", detail:"full"), "for more")
      pointer("rails_get_gems", 'category:"auth"')
      pointer("rails_get_config")
      pointer("rails_get_nothing")
      pointer(name, 'section:"gems"')
    RUBY

    expect(wrong_pointers(source)).to eq([ [ 1, "a section goes by its retired name" ], [ 2, "a section goes by its retired name" ],
                                           [ 5, "rails_get_nothing is not a tool" ] ])
  end

  it "finds none in the gem" do
    root = File.expand_path("../../../../lib", __dir__)
    offenders = Dir[File.join(root, "**", "*.rb")].sort.flat_map do |path|
      wrong_pointers(File.read(path)).map { |line, why| "#{path.delete_prefix("#{root}/")}:#{line} #{why}" }
    end

    expect(offenders).to be_empty
  end
end
