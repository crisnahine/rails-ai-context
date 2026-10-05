# frozen_string_literal: true

require "spec_helper"

RSpec.describe RailsAiContext::Introspectors::Listeners::AutoloadIgnoreListener do
  def ignored_in(source)
    RailsAiContext::Introspectors::SourceIntrospector
      .walk_source(source, { ignored: described_class })[:ignored]
  end

  it "reads the literal names autoload_lib and autoload_lib_once ignore, under lib" do
    source = <<~RUBY
      config.autoload_lib(ignore: %w[assets tasks])
      config.autoload_lib_once(ignore: [:generators, "rubocop/cops"])
    RUBY

    expect(ignored_in(source)).to contain_exactly("lib/assets", "lib/tasks", "lib/generators", "lib/rubocop/cops")
  end

  it "reads nothing from a computed, empty, climbing or missing ignore list" do
    source = <<~RUBY
      config.autoload_lib(ignore: IGNORED)
      config.autoload_lib(ignore: [])
      config.autoload_lib(ignore: ["", "../secrets", "\#{x}"])
      config.autoload_lib
      autoload_lib(ignore: %w[tasks])
    RUBY

    expect(ignored_in(source)).to eq([])
  end
end
