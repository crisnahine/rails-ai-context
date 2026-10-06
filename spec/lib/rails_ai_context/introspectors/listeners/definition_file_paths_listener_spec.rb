# frozen_string_literal: true

require "spec_helper"

RSpec.describe RailsAiContext::Introspectors::Listeners::DefinitionFilePathsListener do
  def writes_in(source)
    RailsAiContext::Introspectors::SourceIntrospector
      .walk_source(source, { writes: described_class })[:writes]
  end

  it "records each write and load in source order" do
    writes = writes_in(<<~RUBY)
      FactoryBot.definition_file_paths = %w[custom/factories]
      ::FactoryBot.definition_file_paths << "lib/factories"
      FactoryBot.definition_file_paths += ["more/factories"]
      FactoryBot.find_definitions
      FactoryBot.reload
    RUBY

    expect(writes).to eq([
      { replace: true, paths: [ "custom/factories" ] },
      { replace: false, paths: [ "lib/factories" ] },
      { replace: false, paths: [ "more/factories" ] },
      { load: :find_definitions },
      { load: :reload }
    ])
  end

  it "leaves out a write whose paths it cannot read, and another receiver's" do
    expect(writes_in("FactoryBot.definition_file_paths = paths\nOther.definition_file_paths << \"x\"\n")).to eq([])
  end
end
