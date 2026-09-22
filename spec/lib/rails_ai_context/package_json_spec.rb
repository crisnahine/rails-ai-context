# frozen_string_literal: true

require "spec_helper"
require "tmpdir"
require "fileutils"

RSpec.describe RailsAiContext::PackageJson do
  around { |example| Dir.mktmpdir { |dir| @root = dir; example.run } }

  def write(contents)
    File.write(File.join(@root, "package.json"), contents)
  end

  it "merges dependencies and devDependencies and ignores every other block" do
    write(JSON.generate(
      "dependencies" => { "vite" => "^5.0.0" },
      "devDependencies" => { "typescript" => "^5.0.0" },
      "overrides" => { "esbuild" => "^0.25.0" },
      "peerDependencies" => { "react" => "^18.0.0" },
      "scripts" => { "build" => "esbuild app.js" }
    ))

    expect(described_class.deps(@root).keys).to contain_exactly("vite", "typescript")
    expect(described_class.present?(@root, "esbuild")).to be(false)
    expect(described_class.present?(@root, "vite")).to be(true)
  end

  it "counts a tool reached through its own scope" do
    write(JSON.generate("devDependencies" => { "@tailwindcss/vite" => "^4.0.0" }))

    expect(described_class.present?(@root, "tailwindcss")).to be(true)
    expect(described_class.present?(@root, "vite")).to be(false)
  end

  # The cap is the configuration's, in both directions: an app that lowers
  # max_file_size is obeyed, and one that leaves the default reads a
  # package.json well past 256 KB.
  it "obeys a max_file_size the app lowered" do
    write(JSON.generate("dependencies" => { "vite" => "^5.0.0" }))
    allow(RailsAiContext.configuration).to receive(:max_file_size).and_return(8)

    expect(described_class.deps(@root)).to eq({})
  end

  it "reads a package.json larger than a quarter megabyte" do
    padding = (0...6_000).to_h { |i| [ "@scope/package-with-a-long-name-#{i}", "^1.0.0" ] }
    write(JSON.generate("dependencies" => padding.merge("bulma" => "^1.0.0")))

    expect(File.size(File.join(@root, "package.json"))).to be > 256 * 1024
    expect(described_class.present?(@root, "bulma")).to be(true)
  end

  # A Rails app can keep a root package.json for importmap and a whole Vue
  # app under frontend/. Both are the app's dependencies.
  describe "a manifest outside the app root" do
    def write_frontend(dir, contents)
      FileUtils.mkdir_p(File.join(@root, dir))
      File.write(File.join(@root, dir, "package.json"), contents)
    end

    it "reads a conventional frontend directory's manifest" do
      write_frontend("frontend", JSON.generate(
        "dependencies" => { "vue" => "3.4.0" },
        "devDependencies" => { "typescript" => "5.4.0" }
      ))

      expect(described_class.deps(@root).keys).to contain_exactly("vue", "typescript")
      expect(described_class.present?(@root, "vue")).to be(true)
    end

    it "reads a directory the app declared through frontend_paths" do
      write_frontend("web", JSON.generate("dependencies" => { "svelte" => "4.0.0" }))
      allow(RailsAiContext.configuration).to receive(:frontend_paths).and_return([ "web" ])

      expect(described_class.present?(@root, "svelte")).to be(true)
    end

    it "lets the root manifest win a version disagreement" do
      write(JSON.generate("dependencies" => { "vue" => "2.7.0" }))
      write_frontend("frontend", JSON.generate("dependencies" => { "vue" => "3.4.0" }))

      expect(described_class.deps(@root)["vue"]).to eq("2.7.0")
    end

    it "still refuses an overrides pin in a frontend manifest" do
      write_frontend("frontend", JSON.generate(
        "dependencies" => { "vue" => "3.4.0" },
        "overrides" => { "esbuild" => "^0.25.0" }
      ))

      expect(described_class.present?(@root, "esbuild")).to be(false)
    end

    it "does not follow a frontend directory that resolves outside the app root" do
      outside = File.join(Dir.mktmpdir, "elsewhere")
      FileUtils.mkdir_p(outside)
      File.write(File.join(outside, "package.json"), JSON.generate("dependencies" => { "vue" => "3.4.0" }))
      File.symlink(outside, File.join(@root, "frontend"))

      expect(described_class.present?(@root, "vue")).to be(false)
    end
  end

  it "answers an empty hash for a missing or unparseable file" do
    expect(described_class.deps(@root)).to eq({})
    write("{ not json")
    expect(described_class.deps(@root)).to eq({})
  end
end
