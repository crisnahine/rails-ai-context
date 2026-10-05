# frozen_string_literal: true

require "spec_helper"

RSpec.describe RailsAiContext::FixtureKeys do
  it "reads an ordinary top-level key as a fixture name" do
    expect(described_class.name?("admin")).to be(true)
    expect(described_class.name?(:one)).to be(true)
  end

  # ActiveRecord drops both, so `users(:DEFAULTS)` raises "No fixture named".
  it "does not read the DEFAULTS anchor or an underscored key as one" do
    expect(described_class.name?("DEFAULTS")).to be(false)
    expect(described_class.name?("_fixture")).to be(false)
  end

  describe ".parse" do
    it "reads a file whose first line is an ERB tag, as Rails renders ERB before YAML" do
      parsed = described_class.parse(<<~YAML)
        <% password_digest = BCrypt::Password.create("password") %>

        one:
          email_address: one@example.com
          password_digest: <%= password_digest %>
      YAML

      expect(parsed).to eq("one" => { "email_address" => "one@example.com", "password_digest" => "erb_value" })
    end

    it "follows the DEFAULTS alias and drops the anchor, _fixture and the labels it ignores" do
      parsed = described_class.parse(<<~YAML)
        DEFAULTS: &DEFAULTS
          name: Default
        _fixture:
          model_class: Post
          ignore: base
        base:
          title: Base
        alice:
          <<: *DEFAULTS
          email: alice@example.com
      YAML

      expect(parsed).to eq("alice" => { "name" => "Default", "email" => "alice@example.com" })
    end

    it "takes an ignore list" do
      expect(described_class.parse("_fixture:\n  ignore: [a, b]\na: {x: 1}\nb: {x: 2}\nc: {x: 3}\n").keys).to eq(%w[c])
    end

    it "answers nil for a file it cannot read as fixtures, and an empty hash for an empty one" do
      expect(described_class.parse("one: [unclosed\n")).to be_nil
      expect(described_class.parse("- a\n- b\n")).to be_nil
      expect(described_class.parse("")).to eq({})
      expect(described_class.parse("# only a comment\n")).to eq({})
    end
  end
end
