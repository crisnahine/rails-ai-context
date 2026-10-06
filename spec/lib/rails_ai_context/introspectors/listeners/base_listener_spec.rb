# frozen_string_literal: true

require "spec_helper"

RSpec.describe RailsAiContext::Introspectors::Listeners::BaseListener do
  # Records what the shared readers make of each `probe` call's first argument.
  let(:probe_listener) do
    Class.new(described_class) do
      def on_call_node_enter(node)
        return unless node.name == :probe

        arg = node.arguments&.arguments&.first
        @results << { one: literal_string(arg), many: literal_strings(arg) }
      end
    end
  end

  def read(source)
    listener = probe_listener.new
    RailsAiContext::Introspectors::ListenerRegistration.dispatcher_for(listener).dispatch(Prism.parse(source).value)
    listener.results.first
  end

  it "reads a string and a symbol by their characters, escapes applied" do
    expect(read(%(probe "plain"))[:one]).to eq("plain")
    expect(read(%(probe :"tab\\tname"))[:one]).to eq("tab\tname")
  end

  it "reads nothing from an interpolated or non-literal argument" do
    expect(read(%(probe "a\#{b}"))).to eq(one: nil, many: [])
    expect(read(%(probe some_call))).to eq(one: nil, many: [])
  end

  it "reads an array's literals and drops what it cannot read" do
    expect(read(%(probe [:a, "b", c, :"d\\te"]))[:many]).to eq([ "a", "b", "d\te" ])
  end

  it "wraps a single literal in an array" do
    expect(read(%(probe :only))[:many]).to eq([ "only" ])
  end

  it "reads every proc spelling as a proc default, and a named callable as not one" do
    listener = Class.new(described_class) do
      def on_call_node_enter(node)
        @results << proc_default?(node) if node.name == :probe
      end
    end.new
    source = "probe default: -> { 1 }\nprobe default: lambda { 1 }\nprobe default: proc { 1 }\n" \
             "probe default: Proc.new { 1 }\nprobe default: ::Proc.new { 1 }\nprobe default: Clock.new { 1 }\nprobe default: :now"
    RailsAiContext::Introspectors::ListenerRegistration.dispatcher_for(listener).dispatch(Prism.parse(source).value)

    expect(listener.results).to eq([ true, true, true, true, true, false, false ])
  end

  describe "keyword options" do
    let(:options_listener) do
      Class.new(described_class) do
        def on_call_node_enter(node)
          return unless node.name == :probe

          @results << { literal: extract_keyword_options(node), source: extract_keyword_sources(node) }
        end
      end
    end

    def options(source)
      listener = options_listener.new
      RailsAiContext::Introspectors::ListenerRegistration.dispatcher_for(listener).dispatch(Prism.parse(source).value)
      listener.results.first
    end

    # A value nested in an option hash used to come back as the marker even
    # when the caller asked for the source.
    it "reads a nested expression as its source, the way a top-level one reads" do
      read = options(%(probe inclusion: { in: proc { Date.parse("1900-01-01").. } }, if: :draft?))

      expect(read[:source]).to eq(inclusion: { in: %(proc { Date.parse("1900-01-01").. }) }, if: :draft?)
      expect(read[:literal]).to eq(inclusion: { in: "[INFERRED]" }, if: :draft?)
    end

    it "reads a nested expression inside an array as its source" do
      read = options(%(probe in: [ "a", SOME_CONST, other_call ]))

      expect(read[:source]).to eq(in: [ "a", "SOME_CONST", "other_call" ])
    end

    it "leaves a nested literal alone" do
      read = options(%(probe length: { maximum: 255, allow_nil: true }))

      expect(read[:source]).to eq(length: { maximum: 255, allow_nil: true })
      expect(read[:source]).to eq(read[:literal])
    end
  end
end
