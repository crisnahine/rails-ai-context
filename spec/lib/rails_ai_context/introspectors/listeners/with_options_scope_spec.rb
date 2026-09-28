# frozen_string_literal: true

require "spec_helper"

RSpec.describe RailsAiContext::Introspectors::Listeners::WithOptionsScope do
  # The module prepends its own handlers, so a listener with a leave hook of
  # its own only keeps it if the prepended one passes the event on.
  let(:listener_class) do
    Class.new(RailsAiContext::Introspectors::Listeners::BaseListener) do
      include RailsAiContext::Introspectors::Listeners::WithOptionsScope

      def on_call_node_enter(node)
        @results << [ :enter, node.name ] if node.name == :probe
      end

      def on_call_node_leave(node)
        @results << [ :leave, node.name ] if node.name == :probe
      end
    end
  end

  def run(source)
    listener = listener_class.new
    result = Prism.parse(source)
    listener.comments = result.comments
    RailsAiContext::Introspectors::ListenerRegistration.dispatcher_for(listener).dispatch(result.value)
    listener.results
  end

  it "passes the leave event on to the listener's own hook" do
    expect(run("probe :x")).to eq([ [ :enter, :probe ], [ :leave, :probe ] ])
  end

  it "still closes its own scope on the call that opened it" do
    results = run(<<~RUBY)
      with_options on: :create do
        probe :x
      end
      probe :y
    RUBY

    expect(results.count { |event, _| event == :leave }).to eq(2)
  end
end
