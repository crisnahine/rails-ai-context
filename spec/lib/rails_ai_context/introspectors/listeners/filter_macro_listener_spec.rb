# frozen_string_literal: true

require "spec_helper"
require "prism"

RSpec.describe RailsAiContext::Introspectors::Listeners::FilterMacroListener do
  it "names each positional argument at its node, keyword options left out" do
    source = "before_action :a, \"b\", ::Gate, Timing.new, Class.new {}, lambda { c }, proc { d }, Proc.new { e }, -> { f }, pick, only: :show\n"

    expect(parse_and_dispatch(source, :before_action).first[:callbacks])
      .to eq([ [ :name, "a" ], [ :name, "b" ], [ :name, "Gate" ], [ :object, "Timing" ], [ :object, "Class" ],
               [ :block ], [ :block ], [ :block ], [ :block ], [ :unread, "pick" ] ])
  end

  it "keeps the branch condition its parent records" do
    result = parse_and_dispatch("before_action :x if Rails.env.test?\n", :before_action).first

    expect(result[:callbacks]).to eq([ [ :name, "x" ] ])
    expect(result[:condition]).to include("Rails.env.test?")
  end
end
