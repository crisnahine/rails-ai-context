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

  describe ".paths" do
    it "answers the model directories' records without reading a file" do
      allow(RailsAiContext::SafeFile).to receive(:read).and_wrap_original do |original, path, *args, **options|
        raise "paths must not read #{path}" if path.to_s.include?("/app/models/")

        original.call(path, *args, **options)
      end
      records = described_class.paths(root, kind: "app/models").to_a
      expect(records.map(&:file)).to include("app/models/post.rb", "packs/billing/app/models/invoice.rb")
      expect(records.map(&:source).uniq).to eq([ nil ])
    end
  end

  it "relativizes a file under a pack directory that is a symlink out of the root" do
    Dir.mktmpdir do |root|
      Dir.mktmpdir do |elsewhere|
        FileUtils.mkdir_p(File.join(elsewhere, "app", "models"))
        File.write(File.join(elsewhere, "app", "models", "invoice.rb"), "class Invoice; end\n")
        FileUtils.mkdir_p(File.join(root, "packs"))
        File.symlink(elsewhere, File.join(root, "packs", "billing"))

        expect(described_class.each(root, kind: "app/models").map(&:file)).to eq([ "packs/billing/app/models/invoice.rb" ])
      end
    end
  end

  it "adds the classes with a superclass under other app/ roots to app/models, and survives odd files there" do
    Dir.mktmpdir do |dir|
      FileUtils.mkdir_p(File.join(dir, "app/models"))
      FileUtils.mkdir_p(File.join(dir, "app/domain/concerns"))
      FileUtils.mkdir_p(File.join(dir, "app/controllers"))
      File.write(File.join(dir, "app/domain/invoice.rb"), "class Invoice < ApplicationRecord\nend\n")
      File.write(File.join(dir, "app/domain/plain.rb"), "module Plain\nend\n")
      File.binwrite(File.join(dir, "app/domain/odd.rb"), "\xFF\xFE\nclass Odd < ApplicationRecord\nend\n")
      File.write(File.join(dir, "app/domain/empty.rb"), "")
      File.write(File.join(dir, "app/domain/concerns/billable.rb"), "class Billable < Base\nend\n")
      File.write(File.join(dir, "app/controllers/invoices_controller.rb"), "class InvoicesController < ApplicationController\nend\n")
      File.symlink(File.join(dir, "app/domain"), File.join(dir, "app/domain/loop"))

      files = described_class.paths(dir, kind: "app/models").map(&:file)
      expect(files).to contain_exactly("app/domain/invoice.rb", "app/domain/odd.rb")
      expect(described_class.paths(dir, kind: "app/controllers").map(&:file)).to eq([ "app/controllers/invoices_controller.rb" ])
    end
  end

  it "follows a symlinked directory or file in app/models to a target inside the app, as Zeitwerk does" do
    Dir.mktmpdir do |dir|
      Dir.mktmpdir do |elsewhere|
        FileUtils.mkdir_p(File.join(dir, "app/models"))
        FileUtils.mkdir_p(File.join(dir, "shared/billing"))
        FileUtils.mkdir_p(File.join(dir, "shared2"))
        File.write(File.join(dir, "shared/billing/invoice.rb"), "module Billing\n  class Invoice < ApplicationRecord\n  end\nend\n")
        File.write(File.join(dir, "shared2/coupon.rb"), "class Coupon < ApplicationRecord\nend\n")
        File.write(File.join(dir, "app/models/user.rb"), "class User < ApplicationRecord\nend\n")
        File.write(File.join(elsewhere, "secret.rb"), "class Secret < ApplicationRecord\nend\n")
        File.symlink("../../shared/billing", File.join(dir, "app/models/billing"))
        File.symlink("../../shared2/coupon.rb", File.join(dir, "app/models/coupon.rb"))
        File.symlink(File.join(elsewhere, "secret.rb"), File.join(dir, "app/models/secret.rb"))
        File.symlink(elsewhere, File.join(dir, "app/models/outside"))
        File.symlink("..", File.join(dir, "app/models/billing_loop"))

        records = described_class.paths(dir, kind: "app/models").to_a
        expect(records.map(&:path_name)).to contain_exactly("Billing::Invoice", "Coupon", "User")
        expect(records.map(&:file)).to contain_exactly("shared/billing/invoice.rb", "shared2/coupon.rb", "app/models/user.rb")
      end
    end
  end

  it "answers nothing for a root that does not exist" do
    expect(described_class.each("/nonexistent/rails-ai-context-root", kind: "app/models").to_a).to eq([])
  end

  # OpenProject's run asked for app/models five times and app/controllers
  # four; the glob and a realpath per file were a fifth of its CPU.
  describe "within one introspection run" do
    it "walks a kind once, and again in the next run" do
      Dir.mktmpdir do |dir|
        FileUtils.mkdir_p(File.join(dir, "app", "models"))
        File.write(File.join(dir, "app", "models", "post.rb"), "class Post; end\n")
        globs = 0
        models = File.join(dir, "app", "models")
        allow(Dir).to receive(:children).and_wrap_original do |original, *args, **kwargs|
          globs += 1 if args.first.to_s == models
          original.call(*args, **kwargs)
        end

        RailsAiContext::RunCache.around do
          2.times { expect(described_class.paths(dir, kind: "app/models").map(&:path_name)).to eq([ "Post" ]) }
        end
        expect(globs).to eq(1)

        File.write(File.join(dir, "app", "models", "tag.rb"), "class Tag; end\n")
        expect(described_class.paths(dir, kind: "app/models").map(&:path_name)).to eq(%w[Post Tag])
      end
    end
  end

  describe ".under_root?" do
    it "rejects a spelled path that climbs out of the root" do
      expect(described_class.under_root?("/app/../outside/secret.rb", "/outside/secret.rb", "/app", "/app")).to be(false)
    end

    it "rejects a spelled .. that climbs out through a symlink" do
      expect(described_class.under_root?("/app/link/../secret.rb", "/outside/secret.rb", "/app", "/app")).to be(false)
      expect(described_class.under_root?("/app/x/../a.rb", "/app/a.rb", "/app", "/app")).to be(true)
    end

    it "keeps a path under either spelling of the root" do
      expect(described_class.under_root?("/private/tmp/app/a.rb", "/private/tmp/app/a.rb", "/tmp/app", "/private/tmp/app")).to be(true)
      expect(described_class.under_root?("/app/packs/billing/a.rb", "/elsewhere/billing/a.rb", "/app", "/app")).to be(true)
    end
  end
end
