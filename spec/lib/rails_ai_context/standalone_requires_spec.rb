# frozen_string_literal: true

require "spec_helper"

# `require_install_files!` in exe/rails-ai-context loads a short list of files
# without the entry file, on purpose: the install path runs before Rails and
# before Zeitwerk. That makes each one responsible for its own stdlib.
#
# lib/rails_ai_context.rb requires "set" and "date" for exactly this class of
# bug, and the standalone list never reaches it - so `[...].to_set` in
# legacy_cleanup raised NoMethodError on Ruby 3.1, where Set is not autoloaded.
# Ruby 3.2+ hides it, which is why only the CI matrix ever saw it.
RSpec.describe "the files the install path loads on their own" do
  # Read off the exe rather than copied, so the list cannot drift out of step
  # with what the install path actually loads.
  STANDALONE_FILES = File.read(File.expand_path("../../../exe/rails-ai-context", __dir__))
                         .slice(/def require_install_files!\s*\n\s*%w\[(.*?)\]/m, 1).split.freeze

  let(:lib) { File.expand_path("../../../lib", __dir__) }
  let(:exe) { File.expand_path("../../../exe/rails-ai-context", __dir__) }

  # Runs the exe's own require_install_files! rather than a copy of it, so the
  # shims it installs are the ones under test.
  def install_files_preamble
    <<~RUBY
      src = File.read(#{exe.inspect})
      body = src[/^    def require_install_files!\\n(.*?)^    end$/m, 1] or abort("require_install_files! not found")
      Object.new.instance_eval(body, #{exe.inspect}, src[0...src.index(body)].count("\\n") + 1)
    RUBY
  end

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

  # A rescue body that calls a helper the install path never loads turns the
  # error it was catching into NoMethodError, and aborts `init` after the
  # removed-tool cleanup has deleted files but before the MCP config is
  # written. A healthy install never enters this rescue, which is why
  # e2e:standalone cannot see it - so drive it in on purpose.
  it "returns the fallback when a rescue fires on the install path" do
    script = <<~RUBY
      #{install_files_preamble}
      module RailsAiContext
        module GemLock
          class << self
            def for(_root) = raise(Errno::EACCES, "forced")
          end
        end
      end
      puts RailsAiContext::InstallMode.standalone?.inspect
    RUBY
    out = `ruby -e #{script.shellescape} 2>&1`

    expect($?.exitstatus).to eq(0), out
    expect(out.strip).to eq("false")
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
