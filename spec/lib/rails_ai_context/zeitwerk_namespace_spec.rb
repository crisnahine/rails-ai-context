# frozen_string_literal: true

require "spec_helper"

# A directory of Ruby files with no matching `.rb` beside it is an implicit
# namespace: Zeitwerk autoloads the constant from the directory itself, and
# only its decoration of `require` turns that into a module definition. The
# standalone binary rebuilds the gem environment before boot, and constants
# first reached after that point came back as
#
#   LoadError: cannot load such file -- .../lib/rails_ai_context/hydrators
#
# one directory at a time. Each namespace needs a real file.
RSpec.describe "Zeitwerk namespaces" do
  let(:root) { File.expand_path("../../../lib/rails_ai_context", __dir__) }

  it "backs every namespace with a file, not the directory alone" do
    implicit = Dir.glob(File.join(root, "**/")).filter_map { |dir|
      path = dir.chomp("/")

      # Outside the loader, so it defines no constant.
      next if path.start_with?(File.join(root, "polyfill"))
      # Holds no Ruby at any depth, so Zeitwerk names nothing after it.
      next if Dir.glob(File.join(path, "**/*.rb")).empty?
      next if File.exist?("#{path}.rb")

      path.sub("#{File.dirname(root)}/", "")
    }

    expect(implicit).to be_empty,
      "#{implicit.size} implicit namespace(s) - add a file defining each module:\n#{implicit.join("\n")}"
  end
end
