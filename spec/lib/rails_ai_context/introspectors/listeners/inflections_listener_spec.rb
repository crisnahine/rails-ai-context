# frozen_string_literal: true

require "spec_helper"

RSpec.describe RailsAiContext::Introspectors::Listeners::InflectionsListener do
  def rules_in(source)
    parse_and_dispatch(source).map { |hit| [ hit[:method], hit[:literals] ] }
  end

  it "reads the directives on any parameter name, a numbered one, the call without a block, a local holding it and instance_eval" do
    source = <<~RUBY
      ActiveSupport::Inflector.inflections(:en) do |inflections|
        inflections.acronym "QAPI"
      end
      ActiveSupport::Inflector.inflections { _1.irregular "hero", "heroes" }
      ActiveSupport::Inflector.inflections(:en).uncountable "sheepish"
      rules = ActiveSupport::Inflector.inflections(:en)
      rules.acronym "QRSS"
      ActiveSupport::Inflector.inflections(:en).instance_eval { acronym "QPDF" }
      ActiveSupport::Inflector.inflections(:en) { acronym "QNOPE" }
    RUBY

    expect(rules_in(source)).to eq([ [ "acronym", [ "QAPI" ] ], [ "irregular", %w[hero heroes] ],
                                     [ "uncountable", [ "sheepish" ] ], [ "acronym", [ "QRSS" ] ], [ "acronym", [ "QPDF" ] ] ])
  end

  # Inflector.inflections yields the rules to the block, so a block that names no parameter calls on its own self.
  it "reads an `it` block and the short Inflector constant, and nothing after the block closes" do
    source = <<~RUBY
      Inflector.inflections { it.acronym "QIT" }
      ActiveSupport::Inflector.inflections(:en) do |inflect|
        inflect.human "legacy_col", "Legacy column"
      end
      %w[QAFTER].each { |inflect| inflect.acronym "QAFTER" }
      acronym "QBARE"
    RUBY

    expect(rules_in(source)).to eq([ [ "acronym", [ "QIT" ] ], [ "human", [ "legacy_col", "Legacy column" ] ] ])
  end

  it "keeps each rule's locale, :en when the call names none" do
    source = <<~RUBY
      ActiveSupport::Inflector.inflections(:es) { |inflect| inflect.irregular "staff", "staffers" }
      ActiveSupport::Inflector.inflections("fr").acronym "QFR"
      ActiveSupport::Inflector.inflections { |inflect| inflect.acronym "QEN" }
    RUBY

    expect(parse_and_dispatch(source).map { |hit| hit[:locale] }).to eq(%i[es fr en])
  end

  it "gives the arguments as Ruby values, a regexp with its flags, and no literals when one is computed" do
    source = <<~'RUBY'
      ActiveSupport::Inflector.inflections(:en) do |inflect|
        inflect.plural(/(octop)us$/i, '\1odes')
        inflect.uncountable %w[moose fish]
        inflect.irregular "cactus", "cact" + SUFFIX
        inflect.singular(/#{STEM}$/, "x")
      end
    RUBY

    hits = parse_and_dispatch(source)

    expect(hits.map { |hit| hit[:literals] }).to eq([ [ /(octop)us$/i, '\1odes' ], [ %w[moose fish] ], nil, nil ])
    expect(hits.map { |hit| hit[:location] }).to eq([ 2, 3, 4, 5 ])
  end
end
