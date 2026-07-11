# frozen_string_literal: true

require "spec_helper"
require "tmpdir"
require "fileutils"

RSpec.describe RailsAiContext::PathResolver do
  around do |example|
    Dir.mktmpdir do |dir|
      @root = dir
      example.run
    end
  ensure
    RailsAiContext.configuration.extra_app_paths = []
  end

  def mkdirs(*paths)
    paths.each { |p| FileUtils.mkdir_p(File.join(@root, p)) }
  end

  it "returns only the conventional dir for a stock app" do
    mkdirs("app/models")
    expect(described_class.model_dirs(@root)).to eq([ File.join(@root, "app/models") ])
  end

  it "includes packs and engines dirs, conventional first, packs before engines, each sorted" do
    mkdirs("app/models",
           "packs/billing/app/models", "packs/admin/app/models",
           "engines/store/app/models")
    expect(described_class.model_dirs(@root)).to eq([
      File.join(@root, "app/models"),
      File.join(@root, "packs/admin/app/models"),
      File.join(@root, "packs/billing/app/models"),
      File.join(@root, "engines/store/app/models")
    ])
  end

  it "includes configured extra_app_paths" do
    mkdirs("app/models", "src/app/models")
    RailsAiContext.configuration.extra_app_paths = [ "src" ]
    expect(described_class.model_dirs(@root)).to include(File.join(@root, "src/app/models"))
  end

  it "omits directories that do not exist" do
    mkdirs("packs/billing/app/models")
    RailsAiContext.configuration.extra_app_paths = [ "nope" ]
    expect(described_class.model_dirs(@root)).to eq([ File.join(@root, "packs/billing/app/models") ])
  end

  it "resolves controllers and views the same way" do
    mkdirs("app/controllers", "packs/billing/app/views")
    expect(described_class.controller_dirs(@root)).to eq([ File.join(@root, "app/controllers") ])
    expect(described_class.view_dirs(@root)).to eq([ File.join(@root, "packs/billing/app/views") ])
  end

  it "accepts a Pathname root" do
    mkdirs("app/models")
    expect(described_class.model_dirs(Pathname.new(@root))).to eq([ File.join(@root, "app/models") ])
  end
end
