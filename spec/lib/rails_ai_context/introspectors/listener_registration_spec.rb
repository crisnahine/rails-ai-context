# frozen_string_literal: true

require "spec_helper"
require "prism"

RSpec.describe RailsAiContext::Introspectors::ListenerRegistration do
  # Listeners defined here rather than reusing production ones so the spec
  # states its own expectations about handler shapes.
  class SingleEventListener
    attr_reader :seen

    def initialize
      @seen = []
    end

    def on_call_node_enter(node)
      @seen << node.name
    end
  end

  class InheritingListener < SingleEventListener
  end

  class LeaveOnlyListener
    attr_reader :left

    def initialize
      @left = []
    end

    def on_class_node_leave(node)
      @left << node.name
    end
  end

  class PrivateHandlerListener
    def on_call_node_enter(node); end

    private

    def on_def_node_enter(node); end
  end

  class HelperMethodListener
    def on_call_node_enter(node); end

    def results
      []
    end

    def on_boarding_complete?
      true
    end
  end

  class TypoHandlerListener
    def on_call_node_entr(node); end
  end

  class NoHandlerListener
  end

  describe ".events_for" do
    it "finds a handler defined on the listener class" do
      expect(described_class.events_for(SingleEventListener.new)).to eq([ :on_call_node_enter ])
    end

    it "finds a handler inherited from a superclass" do
      expect(described_class.events_for(InheritingListener.new)).to eq([ :on_call_node_enter ])
    end

    it "finds leave events" do
      expect(described_class.events_for(LeaveOnlyListener.new)).to eq([ :on_class_node_leave ])
    end

    it "ignores private handlers, which the dispatcher could never call" do
      expect(described_class.events_for(PrivateHandlerListener.new)).to eq([ :on_call_node_enter ])
    end

    it "ignores public methods that are not events" do
      expect(described_class.events_for(HelperMethodListener.new)).to eq([ :on_call_node_enter ])
    end

    it "returns nothing for a listener with no handlers" do
      expect(described_class.events_for(NoHandlerListener.new)).to eq([])
    end

    it "raises on a handler name prism does not dispatch, naming it" do
      expect { described_class.events_for(TypoHandlerListener.new) }
        .to raise_error(described_class::UnknownEventError, /on_call_node_entr/)
    end

    it "names the listener class in the raised message" do
      expect { described_class.events_for(TypoHandlerListener.new) }
        .to raise_error(described_class::UnknownEventError, /TypoHandlerListener/)
    end
  end

  describe ".known_event?" do
    it "accepts every event the running prism dispatches" do
      expect(described_class.known_event?(:on_instance_variable_write_node_enter)).to be(true)
      expect(described_class.known_event?(:on_call_node_leave)).to be(true)
      expect(described_class.known_event?(:on_case_node_enter)).to be(true)
    end

    it "rejects a name prism does not dispatch" do
      expect(described_class.known_event?(:on_call_node_entr)).to be(false)
      expect(described_class.known_event?(:on_controller_node_enter)).to be(false)
    end
  end

  describe ".dispatcher_for" do
    it "returns a dispatcher that fires the listener's handler" do
      listener   = SingleEventListener.new
      dispatcher = described_class.dispatcher_for(listener)
      dispatcher.dispatch(Prism.parse("foo(1)").value)

      expect(listener.seen).to eq([ :foo ])
    end

    it "fires a handler the listener only inherits" do
      listener   = InheritingListener.new
      dispatcher = described_class.dispatcher_for(listener)
      dispatcher.dispatch(Prism.parse("foo(1)").value)

      expect(listener.seen).to eq([ :foo ])
    end

    it "wires several listeners onto one walk" do
      calls   = SingleEventListener.new
      classes = LeaveOnlyListener.new
      dispatcher = described_class.dispatcher_for(calls, classes)
      dispatcher.dispatch(Prism.parse("class User; foo(1); end").value)

      expect(calls.seen).to eq([ :foo ])
      expect(classes.left).to eq([ :User ])
    end

    it "raises before dispatching when any listener has a bad handler" do
      expect { described_class.dispatcher_for(SingleEventListener.new, TypoHandlerListener.new) }
        .to raise_error(described_class::UnknownEventError)
    end
  end

  describe ".register" do
    it "registers onto a dispatcher the caller already has" do
      dispatcher = Prism::Dispatcher.new
      listener   = SingleEventListener.new
      described_class.register(dispatcher, listener)
      dispatcher.dispatch(Prism.parse("foo(1)").value)

      expect(listener.seen).to eq([ :foo ])
    end

    it "returns the events it registered" do
      expect(described_class.register(Prism::Dispatcher.new, LeaveOnlyListener.new))
        .to eq([ :on_class_node_leave ])
    end
  end
end
