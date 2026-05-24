# frozen_string_literal: true

require "spec_helper"
require "prism"

RSpec.describe RailsAiContext::Introspectors::Listeners::MailboxRoutingListener do
  def parse_and_dispatch(source)
    result     = Prism.parse(source)
    dispatcher = Prism::Dispatcher.new
    listener   = described_class.new
    dispatcher.register(listener, :on_call_node_enter)
    dispatcher.dispatch(result.value)
    listener.results
  end

  it "detects routing declarations" do
    results = parse_and_dispatch(<<~RUBY)
      class ForwardsMailbox < ApplicationMailbox
        routing /forwards/i => :forward
        routing "support@example.com" => :support
      end
    RUBY

    routing = results.select { |r| r[:type] == :routing }
    expect(routing.size).to eq(2)
    expect(routing.map { |r| r[:action] }).to contain_exactly("forward", "support")
  end

  it "detects lifecycle callbacks" do
    results = parse_and_dispatch(<<~RUBY)
      class InboxMailbox < ApplicationMailbox
        before_processing :validate_sender
        after_processing :log_receipt
        around_processing :with_tracking
      end
    RUBY

    callbacks = results.select { |r| r[:type] == :callback }
    expect(callbacks.size).to eq(3)
    expect(callbacks.map { |c| c[:callback_type] }).to contain_exactly(
      "before_processing", "after_processing", "around_processing"
    )
    expect(callbacks.map { |c| c[:method] }).to contain_exactly(
      "validate_sender", "log_receipt", "with_tracking"
    )
  end

  it "includes line locations" do
    results = parse_and_dispatch(<<~RUBY)
      routing /test/i => :test
    RUBY

    expect(results.first[:location]).to eq(1)
  end

  it "returns empty results for non-mailbox code" do
    results = parse_and_dispatch(<<~RUBY)
      class User < ApplicationRecord
        validates :email, presence: true
      end
    RUBY

    expect(results).to be_empty
  end
end
