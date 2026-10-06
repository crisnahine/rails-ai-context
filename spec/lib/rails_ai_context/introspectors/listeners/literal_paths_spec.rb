# frozen_string_literal: true

require "spec_helper"

RSpec.describe RailsAiContext::Introspectors::Listeners::LiteralPaths do
  # Reads the argument of each `probe` call; `complete` records whether the whole of it was read.
  let(:listener_class) do
    Class.new(RailsAiContext::Introspectors::Listeners::BaseListener) do
      include RailsAiContext::Introspectors::Listeners::LiteralPaths

      attr_reader :complete

      def initialize(file = nil)
        super()
        @file = file
        @complete = []
      end

      def on_call_node_enter(node)
        @complete << collect_paths(node.arguments.arguments.first) if node.name == :probe
      end
    end
  end

  def read(source, file: nil)
    listener = listener_class.new(file)
    RailsAiContext::Introspectors::ListenerRegistration.dispatcher_for(listener).dispatch(Prism.parse(source).value)
    listener
  end

  it "reads a string, an array of strings and a root-relative join" do
    expect(read(%(probe "/app/services")).results).to eq([ "app/services" ])
    expect(read(%(probe ["lib", "extras"])).results).to eq(%w[lib extras])
    expect(read(%(probe Rails.root.join("lib", "static"))).results).to eq([ "lib/static" ])
    expect(read(%(probe Rails.root.join("lib").to_s)).results).to eq([ "lib" ])
  end

  it "reads an interpolation only when the app root opens it and literals follow" do
    expect(read(%(probe "\#{config.root}/lib_static")).results).to eq([ "lib_static" ])
    expect(read(%(probe "\#{Gem.root}/lib")).results).to eq([])
    expect(read(%(probe "\#{config.root}/\#{name}")).results).to eq([])
  end

  it "reads a path anchored at the walked file only when it knows the file" do
    expect(read(%(probe File.expand_path("../lib", __dir__)), file: "config/application.rb").results).to eq([ "lib" ])
    expect(read(%(probe File.join(__dir__, "extras")), file: "config/application.rb").results).to eq([ "config/extras" ])
    expect(read(%(probe File.join(__dir__, "extras"))).results).to eq([])
  end

  it "says when part of an array stayed unread" do
    listener = read(%(probe ["lib", dynamic_path]))

    expect(listener.results).to eq([ "lib" ])
    expect(listener.complete).to eq([ false ])
  end
end
