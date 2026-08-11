# frozen_string_literal: true

require "spec_helper"
require "shellwords"

# `rails-ai-context init` reads a selection, prompts, and writes config files
# before it boots the app. Everything it needs in that window has to load on
# its own, because the gem entry pulls in ActiveSupport and Zeitwerk and the
# standalone binary can only get them by splicing the newest installed
# framework paths in. Boot the app after that and it runs one framework tree
# with another already loaded, which cost Rails its own autoloader:
#
#   LoadError: cannot load such file -- <app>/app/channels/application_cable
#
# The list comes from the binary rather than a copy here, so a file added
# there is covered without anyone remembering to add it.
RSpec.describe "Standalone pre-boot load" do
  let(:root) { File.expand_path("../../..", __dir__) }

  let(:files) do
    source = File.read(File.join(root, "exe/rails-ai-context"))
    body = source[/def require_install_files!(.+?)^    end$/m, 1]
    raise "require_install_files! not found in exe/rails-ai-context" unless body

    body[/%w\[(.+?)\]/m, 1].to_s.split
  end

  it "names the files init loads before the boot" do
    expect(files).to include("install/ai_tool", "install/selection_record")
  end

  it "loads every one of them with no framework in the process" do
    script = files.map { |file| "require_relative #{File.join(root, 'lib/rails_ai_context', file).inspect}" }
    script << 'leaked = $LOADED_FEATURES.grep(%r{/(zeitwerk|active_support)/})'
    script << 'puts leaked.empty? ? "CLEAN" : "LEAKED: #{leaked.first(5).join(", ")}"'

    output = Bundler.with_unbundled_env do
      `ruby -e #{script.join("\n").shellescape} 2>&1`
    end

    expect(output).to include("CLEAN"),
      "init's pre-boot files pull in a framework, which breaks the app's autoloader once it boots:\n#{output}"
  end
end
