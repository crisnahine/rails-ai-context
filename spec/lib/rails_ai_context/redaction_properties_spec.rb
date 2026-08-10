# frozen_string_literal: true

require "spec_helper"

# Example-by-example review kept finding one more shape the seam mishandled,
# because the input space is open-ended: any setting name crossed with any
# value Ruby can express. These assert properties over a generated cross
# product instead, so a new hole shows up as a failure rather than waiting
# for someone to think of the example.
#
# Deterministic by construction - no randomness, so a failure names the exact
# input every time.
RSpec.describe "Redaction properties" do
  R = RailsAiContext::Redaction

  # Credentials this seam can recognise on sight - a vendor prefix, a hex
  # blob, a URI with userinfo. These must never survive, wherever they sit.
  SHAPED = [
    "sk_live_abcdefghijkl",
    "deadbeefcafe1234",
    "redis://user:hunter2pw@cache:6379"
  ].freeze

  # A credential with no structure at all. Nothing distinguishes it from an
  # ordinary config string, so it is only catchable when a name says so -
  # the setting's, or the key it sits under. Asserting more than that is how
  # over-redaction starts: it is the same shape as a `.env.example`
  # placeholder, which must stay readable.
  SHAPELESS = "hunter2plainvalue"

  CREDENTIALS = (SHAPED + [ SHAPELESS ]).freeze

  SECRET_NAMES = %i[secret_key api_key password token pepper salt master_key credentials].freeze
  ORDINARY_NAMES = %i[eager_load cache_store smtp_settings timeout_in adapter stores].freeze
  DESCRIPTOR_NAMES = %i[password_length token_expiry secret_key_format api_key_params].freeze

  # Every shape the AST extractor can hand a listener, each built around one
  # credential so the survivor check is meaningful.
  def shapes_for(credential)
    [
      credential,
      [ credential ],
      [ credential, "harmless" ],
      { password: credential },
      { user_name: "app", password: credential },
      { token: [ credential ] },
      { outer: { inner: { secret: credential } } },
      [ :adapter, { url: credential } ],
      { list: [ { api_key: credential }, { public: "fine" } ] }
    ]
  end

  # What the listener would have as the raw slice for that value.
  def slice_for(value)
    value.inspect
  end

  def each_case
    (SECRET_NAMES + ORDINARY_NAMES + DESCRIPTOR_NAMES).each do |name|
      CREDENTIALS.each do |credential|
        shapes_for(credential).each do |value|
          yield name, credential, value, slice_for(value)
        end
      end
    end
  end

  it "never lets a recognisable credential survive in either field" do
    survivors = []

    each_case do |name, credential, value, source|
      next unless SHAPED.include?(credential)

      result = R.redact_assignment(name, value: value, source: source)

      %i[value source].each do |field|
        rendered = result[field].inspect
        survivors << "#{name} #{field}: #{rendered}" if rendered.include?(credential)
      end
    end

    expect(survivors).to be_empty,
      "A credential survived redaction in #{survivors.size} case(s):\n#{survivors.first(10).join("\n")}"
  end

  # The shapeless one is only catchable by name. Under a secret setting, or
  # under a secret key inside an ordinary one, it must still go.
  it "catches a shapeless credential whenever a name marks it" do
    survivors = []

    SECRET_NAMES.each do |name|
      [ SHAPELESS, [ SHAPELESS ], { password: SHAPELESS } ].each do |value|
        result = R.redact_assignment(name, value: value, source: slice_for(value))
        survivors << "#{name}: #{result[:value].inspect}" if result[:value].inspect.include?(SHAPELESS)
      end
    end

    ORDINARY_NAMES.each do |name|
      [ { password: SHAPELESS }, { outer: { secret: SHAPELESS } } ].each do |value|
        result = R.redact_assignment(name, value: value, source: slice_for(value))
        survivors << "#{name}: #{result[:value].inspect}" if result[:value].inspect.include?(SHAPELESS)
      end
    end

    expect(survivors).to be_empty,
      "A named credential survived in #{survivors.size} case(s):\n#{survivors.first(10).join("\n")}"
  end

  # Story 10: a consumer pattern-matching the marker must not find it on one
  # field and the datum on the other.
  it "marks both fields or neither" do
    disagreements = []

    each_case do |name, _credential, value, source|
      result = R.redact_assignment(name, value: value, source: source)

      in_value  = result[:value].inspect.include?(R::FILTERED)
      in_source = result[:source].to_s.include?(R::FILTERED)

      disagreements << "#{name} #{value.inspect} -> #{result.inspect}" if in_value != in_source
    end

    expect(disagreements).to be_empty,
      "#{disagreements.size} case(s) marked one field but not the other:\n#{disagreements.first(10).join("\n")}"
  end

  it "leaves a value carrying no credential untouched" do
    harmless = [
      [ :eager_load, true ],
      [ :timeout_in, 30 ],
      [ :queue_adapter, :sidekiq ],
      [ :reset_password_keys, [ :email ] ],
      [ :password_length, 6..128 ],
      [ :send_password_change_notification, false ],
      [ :hosts, [ "example.com", "www.example.com" ] ],
      [ :smtp_settings, { address: "smtp.example.com", port: 587 } ]
    ]

    changed = harmless.filter_map { |name, value|
      result = R.redact_assignment(name, value: value, source: slice_for(value))
      "#{name}: #{value.inspect} -> #{result[:value].inspect}" if result[:value] != value
    }

    expect(changed).to be_empty,
      "Redaction altered #{changed.size} value(s) that carried no credential:\n#{changed.join("\n")}"
  end

  it "never raises, whatever it is handed" do
    odd = [ nil, "", [], {}, [ [] ], { {} => "x" }, { 1 => "x" }, :sym, 0, -1, 1.5, (1..2), Object.new ]

    odd.each do |value|
      (SECRET_NAMES + ORDINARY_NAMES).each do |name|
        expect { R.redact_assignment(name, value: value, source: value.inspect) }
          .not_to raise_error, "raised for #{name} = #{value.inspect}"
      end
    end
  end

  it "leaves the structure's shape readable" do
    result = R.redact_assignment(:cfg, value: { user_name: "app", password: "sk_live_abcdefghijkl" },
                                       source: '{ user_name: "app", password: "sk_live_abcdefghijkl" }')

    expect(result[:value]).to be_a(Hash)
    expect(result[:value].keys).to eq(%i[user_name password])
  end
end
