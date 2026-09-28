# frozen_string_literal: true

require "spec_helper"

RSpec.describe RailsAiContext::Introspectors::RetryPolicy do
  # The macros a job introspector walk hands over, from one class's source.
  def entries_for(source)
    hits = RailsAiContext::Introspectors::SourceIntrospector.walk_source(source, {
      macros: -> { RailsAiContext::Introspectors::Listeners::GenericMacroListener.new(*described_class::MACROS) }
    })[:macros]
    described_class.entries(hits)
  end

  # The listing printed the first source line of the macro, so a retry_on
  # written across lines lost its options and kept a dangling comma.
  it "reads a macro written across lines as one entry" do
    source = <<~RUBY
      class SlowJob
        retry_on ActiveRecord::Deadlocked,
                 wait: 5.seconds,
                 attempts: 3
      end
    RUBY

    expect(entries_for(source)).to eq([ "retry_on ActiveRecord::Deadlocked, attempts: 3, wait: 5.seconds" ])
  end

  it "names the macro, the discards and the Sidekiq retry" do
    source = <<~RUBY
      class SlowJob
        # retry_on Net::OpenTimeout, attempts: 9 was flaky
        retry_on Net::OpenTimeout, Timeout::Error, wait: :polynomially_longer, attempts: 3
        discard_on ActiveJob::DeserializationError
        sidekiq_options retry: 5
      end
    RUBY

    expect(entries_for(source)).to eq([
      "retry_on Net::OpenTimeout, Timeout::Error, attempts: 3, wait: :polynomially_longer",
      "discard_on ActiveJob::DeserializationError",
      "sidekiq retry: 5"
    ])
  end

  it "answers nothing for a class that declares none" do
    expect(entries_for("class A; end")).to eq([])
  end
end
