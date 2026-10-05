# frozen_string_literal: true

require "spec_helper"
require "open3"

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

# A standalone install runs on whatever zeitwerk the app's bundle locked, and
# railties 7.0 allows 2.5, whose for_gem takes no arguments.
RSpec.describe "Zeitwerk loader for the gem" do
  let(:entry) { File.expand_path("../../../lib/rails_ai_context.rb", __dir__) }

  it "calls for_gem with no arguments" do
    expect(File.read(entry).scan(/Loader\.for_gem(\S*)/)).to eq([ [ "" ] ])
  end

  # 2.5 names a module after a directory that holds no Ruby, and
  # RailsAiContext::Data then hides the Data class every value object defines.
  it "ignores every directory that holds no Ruby" do
    root = File.join(File.dirname(entry), "rails_ai_context")
    rubyless = Dir.children(root).select { |name|
      path = File.join(root, name)
      File.directory?(path) && Dir.glob(File.join(path, "**/*.rb")).empty?
    }

    expect(rubyless).not_to be_empty
    rubyless.each { |name| expect(File.read(entry)).to include(%(loader.ignore("\#{__dir__}/rails_ai_context/#{name}"))) }
  end

  it "loads without a zeitwerk warning about extra files under lib" do
    lib = File.dirname(entry)
    _out, err, status = Open3.capture3(RbConfig.ruby, "-I", lib, "-e", 'require "rails_ai_context"')

    expect(status).to be_success, err
    expect(err).not_to include("Zeitwerk")
  end
end
