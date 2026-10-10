# frozen_string_literal: true

require "spec_helper"

# json_schemer words an argument error through I18n, which loads every
# locale file the app has. A locale file that does not parse made every
# invalid argument an internal error, with a stack trace on stderr.
RSpec.describe RailsAiContext::Tools::ArgumentSchema do
  let(:schema) { described_class.new(properties: { detail: { type: "string", enum: %w[summary full] } }) }
  # mcp 1.x checks arguments with json_schemer; the 0.13 floor with the
  # json-schema gem, which never asks I18n, so there is nothing to restore.
  let(:memo) { defined?(JSONSchemer) ? JSONSchemer : nil }

  around do |example|
    kept = memo&.class_variable_defined?(:@@i18n) ? [ memo.class_variable_get(:@@i18n) ] : nil
    memo.remove_class_variable(:@@i18n) if kept
    example.run
  ensure
    if kept
      memo.class_variable_set(:@@i18n, kept.first)
    elsif memo&.class_variable_defined?(:@@i18n)
      memo.remove_class_variable(:@@i18n)
    end
  end

  def needs_json_schemer!
    skip "this bundle's mcp (#{MCP::VERSION}) does not check arguments with json_schemer" unless memo
  end

  it "reports an invalid argument as one when the app's locale files do not load" do
    needs_json_schemer!
    allow(I18n).to receive(:exists?).and_raise(
      I18n::InvalidLocaleData.new("config/locales/broken.yml", "found unexpected end of stream")
    )

    expect { schema.validate_arguments(detail: "bogus") }
      .to raise_error(MCP::Tool::InputSchema::ValidationError, /\AInvalid arguments: .*summary/)
  end

  it "leaves json_schemer's translations on for an error that is not a locale's" do
    needs_json_schemer!
    allow_any_instance_of(JSONSchemer::Schema).to receive(:validate).and_raise(Encoding::UndefinedConversionError, "\xFF")

    expect { schema.validate_arguments(detail: "bogus") }.to raise_error(Encoding::UndefinedConversionError)
    expect(memo.class_variable_defined?(:@@i18n)).to be(false)
  end

  it "passes a valid argument" do
    expect { schema.validate_arguments(detail: "full") }.not_to raise_error
  end

  it "is what every tool's arguments are checked with" do
    expect(RailsAiContext::Tools::GetSchema.input_schema).to be_a(described_class)
  end
end
