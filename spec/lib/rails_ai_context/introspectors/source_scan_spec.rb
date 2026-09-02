# frozen_string_literal: true

require "spec_helper"

RSpec.describe RailsAiContext::Introspectors::SourceScan do
  let(:root) { IntrospectedFixture::ROOT }

  it "walks every model directory PathResolver resolves, packs included" do
    files = described_class.each(root, kind: "app/models").map(&:file)
    expect(files).to include("app/models/post.rb", "packs/billing/app/models/invoice.rb", "app/models/admin/user.rb")
  end

  it "names a file by its directory-derived path name and carries the source" do
    record = described_class.each(root, kind: "app/models").find { |r| r.file == "app/models/admin/user.rb" }
    expect(record.path_name).to eq("Admin::User")
    expect(record.source).to include("class Admin::User")
  end

  it "skips concerns unless asked to keep them" do
    Dir.mktmpdir do |dir|
      FileUtils.mkdir_p(File.join(dir, "app/models/concerns"))
      File.write(File.join(dir, "app/models/concerns/taggable.rb"), "module Taggable; end\n")
      File.write(File.join(dir, "app/models/post.rb"), "class Post; end\n")

      expect(described_class.each(dir, kind: "app/models").map(&:file)).to eq([ "app/models/post.rb" ])
      expect(described_class.each(dir, kind: "app/models", skip_concerns: false).map(&:file))
        .to contain_exactly("app/models/concerns/taggable.rb", "app/models/post.rb")
    end
  end

  it "skips a file over the size cap" do
    allow(RailsAiContext.configuration).to receive(:max_file_size).and_return(10)
    expect(described_class.each(root, kind: "app/models").to_a).to eq([])
  end

  it "answers declared class names for the files that declare one" do
    names = described_class.classes(root, kind: "app/models").map(&:first)
    expect(names).to include("Post", "Admin::User", "Invoice", "ApplicationRecord")
  end

  it "answers nothing for a kind the app does not have" do
    expect(described_class.each(root, kind: "app/channels").to_a).to eq([])
  end
end
