# frozen_string_literal: true

require "spec_helper"

RSpec.describe RailsAiContext::Introspectors::ModuleAliases do
  around { |example| Dir.mktmpdir { |root| @root = root; example.run } }

  def write(relative, text)
    path = File.join(@root, relative)
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, text)
    path
  end

  def resolve(spec) = described_class.resolve(spec, described_class.table(@root, []))

  before do
    write("lib/index.ts", "")
    write("lib/x.ts", "")
    write("src/widget.ts", "")
  end

  it "matches a tsconfig pattern without a star exactly, never as a prefix" do
    write("tsconfig.json", %({ "compilerOptions": { "paths": { "~lib": ["./lib"] } } }))

    expect(resolve("~lib")).to eq(File.join(@root, "lib/index.ts"))
    expect(resolve("~lib/x")).to be_nil
  end

  it "matches a webpack alias ending in $ exactly, and one without it as a prefix" do
    write("webpack.config.js", %(module.exports = { resolve: { alias: { "~lib$": path.resolve(__dirname, "lib"), "~src": path.resolve(__dirname, "src") } } }))

    expect(resolve("~lib")).to eq(File.join(@root, "lib/index.ts"))
    expect(resolve("~lib/x")).to be_nil
    expect(resolve("~src/widget")).to eq(File.join(@root, "src/widget.ts"))
  end

  it "reads the alias under resolve, not a plugin's option of the same name" do
    write("vite.config.ts", %(export default { plugins: [x({ alias: { "~src": "./lib" } })], resolve: { alias: { "~src": "./src" } } }))

    expect(resolve("~src/widget")).to eq(File.join(@root, "src/widget.ts"))
  end

  it "reads vite's own default, a URL off import.meta.url" do
    write("vite.config.ts", %(export default { resolve: { alias: { "@": fileURLToPath(new URL("./src", import.meta.url)) } } }))

    expect(resolve("@/widget")).to eq(File.join(@root, "src/widget.ts"))
  end
end
