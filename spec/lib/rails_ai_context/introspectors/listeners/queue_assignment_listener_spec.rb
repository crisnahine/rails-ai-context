# frozen_string_literal: true

require "spec_helper"
require "prism"

RSpec.describe RailsAiContext::Introspectors::Listeners::QueueAssignmentListener do
  it "reads a class body's @queue and self.queue =, not one assigned inside a method" do
    results = parse_and_dispatch(<<~RUBY)
      class ArchiveJob
        @queue = :archive
        self.queue = "mail"
        self.queue = QUEUE
        def self.perform
          @queue = :later
          self.queue = "later"
        end
      end
    RUBY

    expect(results.map { |r| [ r[:form], r[:queue], r[:source] ] })
      .to eq([ [ :ivar, "archive", ":archive" ], [ :self, "mail", "\"mail\"" ], [ :self, nil, "QUEUE" ] ])
  end

  it "reads a class method named queue as the queue Resque asks the class for" do
    results = parse_and_dispatch(<<~RUBY)
      class ExportJob
        def self.queue
          :exports
        end
        def self.other = :nope
        def queue = :instance
      end
      class ComputedJob
        def self.queue = ENV["QUEUE"]
      end
    RUBY

    expect(results.map { |r| [ r[:form], r[:queue], r[:source] ] })
      .to eq([ [ :method, "exports", ":exports" ], [ :method, nil, "ENV[\"QUEUE\"]" ] ])
  end

  it "reads nothing from an empty or broken source" do
    expect(parse_and_dispatch("")).to eq([])
    expect(parse_and_dispatch("class A\n  @queue =\n")).to all(include(:form))
  end
end
