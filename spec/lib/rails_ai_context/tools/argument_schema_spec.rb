# frozen_string_literal: true

require "spec_helper"

# json_schemer words an argument error through I18n, which loads every
# locale file the app has. A locale file that does not parse made every
# invalid argument an internal error, with a stack trace on stderr.
RSpec.describe RailsAiContext::Tools::ArgumentSchema do
  let(:schema) { described_class.new(properties: { detail: { type: "string", enum: %w[summary full] } }) }
  let(:memo) { JSONSchemer }

  around do |example|
    kept = memo.class_variable_defined?(:@@i18n) ? [ memo.class_variable_get(:@@i18n) ] : nil
    memo.remove_class_variable(:@@i18n) if kept
    example.run
  ensure
    if kept
      memo.class_variable_set(:@@i18n, kept.first)
    elsif memo.class_variable_defined?(:@@i18n)
      memo.remove_class_variable(:@@i18n)
    end
  end

  it "reports an invalid argument as one when the app's locale files do not load" do
    allow(I18n).to receive(:exists?).and_raise(
      I18n::InvalidLocaleData.new("config/locales/broken.yml", "found unexpected end of stream")
    )

    expect { schema.validate_arguments(detail: "bogus") }
      .to raise_error(MCP::Tool::InputSchema::ValidationError, /\AInvalid arguments: .*summary/)
  end

  it "passes a valid argument" do
    expect { schema.validate_arguments(detail: "full") }.not_to raise_error
  end

  it "is what every tool's arguments are checked with" do
    expect(RailsAiContext::Tools::GetSchema.input_schema).to be_a(described_class)
  end
end
