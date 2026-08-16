# frozen_string_literal: true

require "spec_helper"

# `require_install_files!` in exe/rails-ai-context loads these six files
# without the entry file, on purpose: the install path runs before Rails and
# before Zeitwerk. That makes each one responsible for its own stdlib.
#
# lib/rails_ai_context.rb requires "set" and "date" for exactly this class of
# bug, and the standalone list never reaches it - so `[...].to_set` in
# legacy_cleanup raised NoMethodError on Ruby 3.1, where Set is not autoloaded.
# Ruby 3.2+ hides it, which is why only the CI matrix ever saw it.
RSpec.describe "the files the install path loads on their own" do
  STANDALONE_FILES = %w[
    install/ai_tool install/selection_record install/cleanup
    install/program mcp_config_generator legacy_cleanup
  ].freeze

  let(:lib) { File.expand_path("../../../lib", __dir__) }

  # The exe requires them in this order and nothing else, so that is the
  # contract: the list loads as a unit, with no Rails and no entry file.
  it "loads as a unit, in the order the exe requires them" do
    script = STANDALONE_FILES.map { |f| "require #{File.join("rails_ai_context", f).inspect}" }.join("\n")
    out = `ruby -I #{lib.shellescape} -e #{script.shellescape} 2>&1`

    expect($?.exitstatus).to eq(0), out
  end

  # Loading is not the same as running. legacy_cleanup only reached its
  # `to_set` when `init` actually called it.
  it "runs the legacy prompt without the entry file" do
    script = <<~RUBY
      #{STANDALONE_FILES.map { |f| "require #{File.join("rails_ai_context", f).inspect}" }.join("\n")}
      RailsAiContext.define_singleton_method(:log_warn) { |m| }
      RailsAiContext::LegacyCleanup.prompt_legacy_files([ :claude, :cursor ], root: Dir.mktmpdir)
    RUBY
    out = `ruby -rtmpdir -I #{lib.shellescape} -e #{script.shellescape} 2>&1`

    expect($?.exitstatus).to eq(0), out
  end

  # Loading is not enough: Set and Date resolve as constants under Ruby 3.2+
  # whatever anyone required, and the method form is where 3.1 differs.
  it "does not reach for a stdlib method the file never required" do
    offenders = STANDALONE_FILES.filter_map do |file|
      path = File.join(lib, "rails_ai_context", "#{file}.rb")
      source = File.read(path)
      needed = []
      needed << "set"  if source.match?(/\bto_set\b|\bSet\.(new|\[)/) && !source.include?('require "set"')
      needed << "date" if source.match?(/\bDate\.(today|parse|new)\b/) && !source.include?('require "date"')
      "#{file} uses #{needed.join(", ")} without requiring it" if needed.any?
    end

    expect(offenders).to be_empty
  end
end
