# frozen_string_literal: true

require "spec_helper"

RSpec.describe RailsAiContext::ExcludedPaths do
  let(:root) { File.join(Dir.tmpdir, "shop") }
  let(:excluded) { described_class.matcher(root, %w[app/javascript/legacy log *.min.js]) }

  it "reads an entry with a slash as a path from the root, and one without as a name at any depth" do
    expect(excluded.call("app/javascript/legacy", true)).to be(true)
    expect(excluded.call("legacy", true)).to be(false)
    expect(excluded.call("engines/blog/log", true)).to be(true)
    expect(excluded.call("logo", true)).to be(false)
  end

  it "matches a file entry, and a path spelled under the root" do
    expect(excluded.call(File.join(root, "public/app.min.js"), false)).to be(true)
    expect(excluded.call(File.join(root, "app/javascript/legacy"), true)).to be(true)
    expect(excluded.call("public/app.js", false)).to be(false)
  end
end
