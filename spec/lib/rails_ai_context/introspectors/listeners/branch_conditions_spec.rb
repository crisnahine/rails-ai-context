# frozen_string_literal: true

require "spec_helper"

RSpec.describe RailsAiContext::Introspectors::Listeners::BranchConditions do
  # Records the open condition at each `probe` call, and the chain arm when the else closes the chain.
  let(:listener_class) do
    Class.new(RailsAiContext::Introspectors::Listeners::BaseListener) do
      include RailsAiContext::Introspectors::Listeners::BranchConditions

      def on_call_node_enter(node)
        @results << { condition: current_condition, arm: chain_arm } if node.name == :probe
      end
    end
  end

  def conditions(source)
    listener = listener_class.new
    RailsAiContext::Introspectors::ListenerRegistration.dispatcher_for(listener).dispatch(Prism.parse(source).value)
    listener.results
  end

  it "names the condition of an if, an unless and the else that negates them" do
    source = <<~RUBY
      probe
      if Rails.env.development?
        probe
      else
        probe
      end
      unless ENV["CI"]
        probe
      end
    RUBY

    expect(conditions(source).map { |r| r[:condition] })
      .to eq([ nil, "if Rails.env.development?", "unless Rails.env.development?", "unless ENV[\"CI\"]" ])
  end

  it "joins nested conditions and folds a multi-line predicate onto one line" do
    source = <<~RUBY
      if a &&
         b
        if c
          probe
        end
      end
    RUBY

    expect(conditions(source).first[:condition]).to eq("if a && b and if c")
  end

  it "reads an elsif as running only when the branch before it failed" do
    source = "if a\n  x\nelsif b\n  probe\nend\n"

    expect(conditions(source).first[:condition]).to eq("unless a and if b")
  end

  it "reads a guard on the left of && or ||" do
    expect(conditions("Rails.env.local? && probe").first[:condition]).to eq("if Rails.env.local?")
    expect(conditions("skip? || probe").first[:condition]).to eq("unless skip?")
  end

  it "names case branches by what they match, and the else by what it does not" do
    source = <<~RUBY
      case Rails.env
      when "production", "staging" then probe
      else probe
      end
      case
      when a? then probe
      end
    RUBY

    expect(conditions(source).map { |r| r[:condition] }).to eq([
      'when Rails.env is "production", "staging"',
      'when Rails.env is none of "production", "staging"',
      "if a?"
    ])
  end

  it "places each arm of an if chain that ends in else, and no arm of one that does not" do
    source = "if a\n  probe\nelsif b\n  probe\nelse\n  probe\nend\nif c\n  probe\nend\n"
    arms = conditions(source).map { |r| r[:arm] }

    expect(arms[0..2].map { |arm| arm&.drop(1) }).to eq([ [ 0, 3 ], [ 1, 3 ], [ 2, 3 ] ])
    expect(arms[0..2].map(&:first).uniq.size).to eq(1)
    expect(arms[3]).to be_nil
  end
end
