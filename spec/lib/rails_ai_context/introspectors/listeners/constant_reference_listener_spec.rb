# frozen_string_literal: true

require "spec_helper"
require "prism"

RSpec.describe RailsAiContext::Introspectors::Listeners::ConstantReferenceListener do
  it "records each reference to a named constant, qualified or not" do
    results = parse_and_dispatch(<<~RUBY, names: %w[MessageVerifier])
      class Signer < ActiveSupport::MessageVerifier
      end
      MessageVerifier.new(key)
      build(verifier_class: ::ActiveSupport::MessageVerifier)
    RUBY

    expect(results).to eq([
      { name: "MessageVerifier", source: "ActiveSupport::MessageVerifier", line: 1 },
      { name: "MessageVerifier", source: "MessageVerifier", line: 3 },
      { name: "MessageVerifier", source: "::ActiveSupport::MessageVerifier", line: 4 }
    ])
  end

  it "skips a constant that only qualifies a nested one, and mentions in comments and strings" do
    results = parse_and_dispatch(<<~RUBY, names: %w[MessageVerifier])
      # MessageVerifier later
      rescue_from ActiveSupport::MessageVerifier::InvalidSignature, with: :bad
      label = "MessageVerifier"
    RUBY

    expect(results).to eq([])
  end
end
