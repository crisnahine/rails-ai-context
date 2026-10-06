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

  it "marks a write whose paths it cannot read, and leaves out another receiver's" do
    expect(writes_in("FactoryBot.definition_file_paths = paths\nOther.definition_file_paths << \"x\"\n"))
      .to eq([ { replace: true, paths: [], unread: true } ])
  end

  it "resolves a path built from __dir__ or __FILE__ against the helper it is written in" do
    writes = RailsAiContext::Introspectors::SourceIntrospector.walk_source(<<~RUBY, { writes: -> { described_class.new(file: "spec/rails_helper.rb") } })[:writes]
      FactoryBot.definition_file_paths = [File.expand_path("support/factories", __dir__)]
      FactoryBot.definition_file_paths << File.join(__dir__, "more")
    RUBY

    expect(writes).to eq([ { replace: true, paths: [ "spec/support/factories" ] }, { replace: false, paths: [ "spec/more" ] } ])
  end
end
