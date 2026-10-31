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

  it "relativizes a file under a pack directory linked in from elsewhere in the app's repository" do
    Dir.mktmpdir do |repo|
      root = File.join(repo, "apps", "web")
      FileUtils.mkdir_p([ File.join(repo, ".git"), File.join(repo, "packages", "billing", "app", "models"), File.join(root, "packs") ])
      File.write(File.join(repo, "packages", "billing", "app", "models", "invoice.rb"), "class Invoice; end\n")
      File.symlink("../../../packages/billing", File.join(root, "packs", "billing"))

      expect(described_class.each(root, kind: "app/models").map(&:file)).to eq([ "packs/billing/app/models/invoice.rb" ])
    end
  end

  it "walks a directory linked in from the app's repository below a walked one, but not one linked from outside it" do
    Dir.mktmpdir do |repo|
      root = File.join(repo, "apps", "web")
      FileUtils.mkdir_p([ File.join(repo, ".git"), File.join(repo, "shared", "billing"), File.join(root, "app", "models") ])
      File.write(File.join(repo, "shared", "billing", "invoice.rb"), "class Billing::Invoice; end\n")
      File.write(File.join(root, "app", "models", "user.rb"), "class User; end\n")
      File.symlink("../../../../shared/billing", File.join(root, "app", "models", "billing"))
      Dir.mktmpdir do |outside|
        File.write(File.join(outside, "secret.rb"), "class Secret; end\n")
        File.symlink(outside, File.join(root, "app", "models", "home"))

        expect(described_class.each(root, kind: "app/models").map(&:file)).to eq([ "app/models/billing/invoice.rb", "app/models/user.rb" ])
      end
    end
  end

  it "lists the classes with a superclass under other app/ roots as model candidates, and survives odd files there" do
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

      files = described_class.model_paths(dir).map(&:file)
      expect(files).to contain_exactly("app/domain/invoice.rb", "app/domain/odd.rb")
      expect(described_class.paths(dir, kind: "app/controllers").map(&:file)).to eq([ "app/controllers/invoices_controller.rb" ])
    end
  end

  it "keeps app/models to the model directories, so a service with a superclass is not counted or read as a model file" do
    Dir.mktmpdir do |dir|
      FileUtils.mkdir_p(File.join(dir, "app/models"))
      FileUtils.mkdir_p(File.join(dir, "app/services"))
      File.write(File.join(dir, "app/models/user.rb"), "class User < ApplicationRecord\nend\n")
      File.write(File.join(dir, "app/services/charge_card.rb"), "class ChargeCard < BaseService\nend\n")

      expect(described_class.paths(dir, kind: "app/models").map(&:file)).to eq([ "app/models/user.rb" ])
      expect(described_class.each(dir, kind: "app/models").map(&:file)).to eq([ "app/models/user.rb" ])
      expect(described_class.model_paths(dir).map(&:file)).to eq([ "app/models/user.rb" ])
    end
  end

  it "reads the models model_details lists with kind :models, top-level concerns left out by default" do
    Dir.mktmpdir do |dir|
      {
        "app/models/user.rb" => "class User < ApplicationRecord\nend\n",
        "app/models/concerns/trackable.rb" => "module Trackable\nend\n",
        "app/domain/invoice.rb" => "class Invoice < ApplicationRecord\nend\n",
        "app/services/charge_card.rb" => "class ChargeCard < BaseService\nend\n"
      }.each do |name, source|
        FileUtils.mkdir_p(File.dirname(File.join(dir, name)))
        File.write(File.join(dir, name), source)
      end

      expect(described_class.each(dir, kind: :models).map(&:file)).to contain_exactly("app/models/user.rb", "app/domain/invoice.rb")
      expect(described_class.each(dir, kind: :models, skip_concerns: false).map(&:file)).to include("app/models/concerns/trackable.rb")
      expect(described_class.classes(dir, kind: :models).map(&:first)).to contain_exactly("User", "Invoice")
    end
  end

  it "reads a class file in the top-level concerns with kind :models, under its bare constant" do
    Dir.mktmpdir do |dir|
      {
        "app/models/concerns/trackable.rb" => "module Trackable\nend\n",
        "app/models/concerns/edition_link.rb" => "class EditionLink < ApplicationRecord\nend\n"
      }.each do |name, source|
        FileUtils.mkdir_p(File.dirname(File.join(dir, name)))
        File.write(File.join(dir, name), source)
      end

      expect(described_class.each(dir, kind: :models).map(&:path_name)).to eq([ "EditionLink" ])
      expect(described_class.classes(dir, kind: :models).map(&:first)).to eq([ "EditionLink" ])
    end
  end

  it "reads a model class in another root's concerns directory, under the constant its file declares" do
    Dir.mktmpdir do |dir|
      {
        "config/application.rb" => "module X\n  class Application < Rails::Application\n    config.eager_load_paths << Rails.root.join(\"enterprise/app/models\")\n  end\nend\n",
        "app/domain/concerns/ledger_entry.rb" => "class LedgerEntry < ApplicationRecord\nend\n",
        "app/domain/concerns/billable.rb" => "module Billable\nend\n",
        "enterprise/app/models/concerns/audit_row.rb" => "module Concerns\n  class AuditRow < ApplicationRecord\n  end\nend\n"
      }.each do |name, source|
        FileUtils.mkdir_p(File.dirname(File.join(dir, name)))
        File.write(File.join(dir, name), source)
      end

      expect(described_class.classes(dir, kind: :models).map(&:first)).to contain_exactly("LedgerEntry", "Concerns::AuditRow")
    end
  end

  it "leaves out a concern that holds an inner class, and keeps the concerns file named for a class with a model superclass" do
    Dir.mktmpdir do |dir|
      {
        "app/models/user.rb" => "class User < ApplicationRecord\nend\n",
        "app/models/concerns/authenticatable.rb" =>
          "module Authenticatable\n  extend ActiveSupport::Concern\n  class InvalidToken < StandardError; end\n  included do\n    has_secure_password\n  end\nend\n",
        "app/models/concerns/token_error.rb" => "class TokenError < StandardError\nend\n",
        "app/models/concerns/admin_user.rb" => "class AdminUser < User\nend\n",
        "app/models/concerns/root_user.rb" => "module Staff\n  class ::RootUser < ::AdminUser\n  end\nend\n"
      }.each do |name, source|
        FileUtils.mkdir_p(File.dirname(File.join(dir, name)))
        File.write(File.join(dir, name), source)
      end

      expect(described_class.each(dir, kind: :models).map(&:path_name)).to contain_exactly("User", "AdminUser", "RootUser")
      expect(described_class.classes(dir, kind: :models).map(&:first)).to contain_exactly("User", "AdminUser", "RootUser")
    end
  end

  [ [ "static", ->(dir) { RailsAiContext::StaticApp.new(dir) } ], [ "booted", ->(dir) { Struct.new(:root).new(Pathname.new(dir)) } ] ].each do |tier, build|
    it "gives the auth, Active Storage, Action Text and database answers no model named for a concern with an inner class, on the #{tier} tier" do
      Dir.mktmpdir do |dir|
        {
          "app/models/user.rb" => "class User < ApplicationRecord\n  include Authenticatable\n  has_one_attached :avatar\nend\n",
          "app/models/concerns/authenticatable.rb" => <<~RUBY
            module Authenticatable
              extend ActiveSupport::Concern
              class InvalidToken < StandardError; end
              included do
                has_secure_password
                has_one_attached :badge
                has_rich_text :bio
                connects_to database: { writing: :primary }
              end
            end
          RUBY
        }.each do |name, source|
          FileUtils.mkdir_p(File.dirname(File.join(dir, name)))
          File.write(File.join(dir, name), source)
        end
        app = build.call(dir)
        answers = [
          RailsAiContext::Introspectors::AuthIntrospector.new(app).call,
          RailsAiContext::Introspectors::ActiveStorageIntrospector.new(app).call,
          RailsAiContext::Introspectors::ActionTextIntrospector.new(app).call,
          RailsAiContext::Introspectors::MultiDatabaseIntrospector.new(app).call
        ]

        expect(answers.inspect).not_to include("Authenticatable")
        expect(answers[1][:attachments]).to include(a_hash_including(model: "User", name: "avatar"))
      end
    end
  end

  it "keeps a concerns class whose superclass only the booted app knows as a record base" do
    Dir.mktmpdir do |dir|
      FileUtils.mkdir_p(File.join(dir, "app/models/concerns"))
      File.write(File.join(dir, "app/models/concerns/blob_copy.rb"), "class BlobCopy < GemRecord\nend\n")
      asked = []

      names = described_class.each(dir, kind: :models, base_model: ->(candidates) { asked << candidates; true }).map(&:path_name)

      expect(names).to eq([ "BlobCopy" ])
      expect(asked).to eq([ [ "GemRecord" ] ])
      expect(described_class.each(dir, kind: :models, base_model: ->(_) { false }).to_a).to be_empty
    end
  end

  it "leaves out a concerns class with no superclass, whatever the booted app says of record bases" do
    Dir.mktmpdir do |dir|
      FileUtils.mkdir_p(File.join(dir, "app/models/concerns"))
      File.write(File.join(dir, "app/models/concerns/tracker.rb"), "class Tracker\nend\n")

      expect(described_class.each(dir, kind: :models, base_model: ->(_) { true }).to_a).to be_empty
    end
  end

  it "reads the concerns namespace from the declarations a file parses to" do
    commented = "# Unlike module Concerns::Noted, this one is top level.\nmodule Noted\n  NOTE = \"module Concerns\"\nend\n"

    expect(described_class.concerns_name("Concerns::Noted", commented)).to eq("Noted")
    expect(described_class.concerns_name("Concerns::AuditRow", "class Concerns::AuditRow < ApplicationRecord\nend\n")).to eq("Concerns::AuditRow")
  end

  it "names a file under a concerns directory without the namespace, unless the file declares it" do
    expect(described_class.concerns_name("Concerns::Billable", "module Billable\nend\n")).to eq("Billable")
    expect(described_class.concerns_name("Concerns::AuditRow", "module Concerns\n  class AuditRow < ApplicationRecord\n  end\nend\n")).to eq("Concerns::AuditRow")
    expect(described_class.concerns_name("Admin::Concerns::Flag", "module Flag\nend\n")).to eq("Admin::Concerns::Flag")
  end

  it "keeps a class outside app/models whose chain reaches a model base through another such class" do
    Dir.mktmpdir do |dir|
      {
        "app/models/user.rb" => "class User < ApplicationRecord\nend\n",
        "app/domain/billing/a_invoice.rb" => "module Billing\n  class AInvoice < Billing::Document\n  end\nend\n",
        "app/domain/billing/document.rb" => "module Billing\n  class Document < ::ActiveRecord::Base\n  end\nend\n",
        "app/domain/admin_user.rb" => "class AdminUser < User\nend\n",
        "app/domain/report.rb" => "class Report < ApplicationService\nend\n",
        "app/domain/notes.rb" => "# subclass Note < ApplicationRecord\nx = \"class Memo < ApplicationRecord\"\n"
      }.each do |name, source|
        FileUtils.mkdir_p(File.dirname(File.join(dir, name)))
        File.write(File.join(dir, name), source)
      end

      expect(described_class.model_paths(dir).map(&:file)).to contain_exactly(
        "app/models/user.rb", "app/domain/billing/a_invoice.rb", "app/domain/billing/document.rb", "app/domain/admin_user.rb"
      )
    end
  end

  it "keeps a class outside app/models whose superclass is written on the line after the <" do
    Dir.mktmpdir do |dir|
      {
        "app/models/user.rb" => "class User < ApplicationRecord\nend\n",
        "app/domain/post.rb" => "class Post <\n  ApplicationRecord\nend\n"
      }.each do |name, source|
        FileUtils.mkdir_p(File.dirname(File.join(dir, name)))
        File.write(File.join(dir, name), source)
      end

      expect(described_class.model_paths(dir).map(&:file)).to contain_exactly("app/models/user.rb", "app/domain/post.rb")
    end
  end

  it "keeps a class outside app/models only when its superclass resolves, from where it is declared, to a model" do
    Dir.mktmpdir do |dir|
      {
        "app/models/queries/base.rb" => "module Queries\n  class Base < ApplicationRecord\n  end\nend\n",
        "app/forms/application_form.rb" => "class ApplicationForm < Primer::Forms::Base\nend\n",
        "app/forms/lost_password_form.rb" => "class LostPasswordForm < ApplicationForm\nend\n",
        "app/services/reports/base.rb" => "module Reports\n  class Base\n  end\nend\n",
        "app/services/reports/daily.rb" => "module Reports\n  class Daily < Base\n  end\nend\n",
        "app/services/queries/saved.rb" => "module Queries\n  class Saved < Base\n  end\nend\n"
      }.each do |name, source|
        FileUtils.mkdir_p(File.dirname(File.join(dir, name)))
        File.write(File.join(dir, name), source)
      end

      expect(described_class.model_paths(dir).map(&:file)).to contain_exactly(
        "app/models/queries/base.rb", "app/services/queries/saved.rb"
      )
    end
  end

  it "reads a superclass written from the root at the top level only" do
    Dir.mktmpdir do |dir|
      {
        "app/models/report.rb" => "class Report < ApplicationRecord\nend\n",
        "app/services/admin/report.rb" => "module Admin\n  class Report\n  end\nend\n",
        "app/services/admin/summary.rb" => "module Admin\n  class Summary < ::Report\n  end\nend\n",
        "app/services/admin/digest.rb" => "module Admin\n  class Digest < Report\n  end\nend\n"
      }.each do |name, source|
        FileUtils.mkdir_p(File.dirname(File.join(dir, name)))
        File.write(File.join(dir, name), source)
      end

      expect(described_class.model_paths(dir).map(&:file)).to contain_exactly(
        "app/models/report.rb", "app/services/admin/summary.rb"
      )
    end
  end

  it "reads a superclass as the class its own namespace declares before an outer model of that name" do
    Dir.mktmpdir do |dir|
      {
        "app/models/reviewable.rb" => "class Reviewable < ApplicationRecord\nend\n",
        "app/seeders/dev/record.rb" => "module Dev\n  class Record\n  end\nend\n",
        "app/seeders/dev/reviewable.rb" => "module Dev\n  class Reviewable < Record\n  end\nend\n",
        "app/seeders/dev/reviewable_post.rb" => "module Dev\n  class ReviewablePost < Reviewable\n  end\nend\n",
        "app/seeders/dev/base.rb" => "module Dev\n  class Base\n  end\nend\n",
        "app/seeders/dev/topic.rb" => "module Dev\n  class Topic < Base\n  end\nend\n",
        "app/models/base.rb" => "class Base < ApplicationRecord\nend\n",
        "app/seeders/flagged.rb" => "class Flagged < Reviewable\nend\n"
      }.each do |name, source|
        FileUtils.mkdir_p(File.dirname(File.join(dir, name)))
        File.write(File.join(dir, name), source)
      end

      expect(described_class.model_paths(dir).map(&:file)).to contain_exactly(
        "app/models/base.rb", "app/models/reviewable.rb", "app/seeders/flagged.rb"
      )
    end
  end

  it "reads a compact declaration's superclass from the top level, where Ruby looks it up" do
    Dir.mktmpdir do |dir|
      {
        "app/models/report.rb" => "class Report < ApplicationRecord\nend\n",
        "app/services/admin/report.rb" => "module Admin\n  class Report\n  end\nend\n",
        "app/services/admin/summary.rb" => "class Admin::Summary < Report\nend\n"
      }.each do |name, source|
        FileUtils.mkdir_p(File.dirname(File.join(dir, name)))
        File.write(File.join(dir, name), source)
      end

      expect(described_class.model_paths(dir).map(&:file)).to contain_exactly(
        "app/models/report.rb", "app/services/admin/summary.rb"
      )
    end
  end

  it "keeps a subclass of a class whose own name is written from the root" do
    Dir.mktmpdir do |dir|
      {
        "app/services/ledger_top.rb" => "class ::LedgerTop < ApplicationRecord\nend\n",
        "app/services/ledger_sub.rb" => "class LedgerSub < LedgerTop\nend\n"
      }.each do |name, source|
        FileUtils.mkdir_p(File.dirname(File.join(dir, name)))
        File.write(File.join(dir, name), source)
      end

      expect(described_class.model_paths(dir).map(&:file)).to contain_exactly(
        "app/services/ledger_top.rb", "app/services/ledger_sub.rb"
      )
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

  it "names a file by its real directory when a link in app/models reaches the same one, in any listing order" do
    Dir.mktmpdir do |dir|
      FileUtils.mkdir_p(File.join(dir, "app/models/admin"))
      FileUtils.mkdir_p(File.join(dir, "app/models/zone/deep"))
      File.write(File.join(dir, "app/models/admin/report.rb"), "class Admin::Report < ApplicationRecord\nend\n")
      File.write(File.join(dir, "app/models/zone/deep/note.rb"), "class Zone::Deep::Note < ApplicationRecord\nend\n")
      File.symlink("admin", File.join(dir, "app/models/aa_admin"))
      File.symlink("admin", File.join(dir, "app/models/zz_admin"))
      File.symlink("zone/deep", File.join(dir, "app/models/a_deep"))

      [ :sort, :reverse ].each do |order|
        RailsAiContext::PathResolver.clear_code_roots
        allow(Dir).to receive(:children).and_wrap_original { |original, path| original.call(path).sort.then { |names| order == :sort ? names : names.reverse } }

        names = described_class.paths(dir, kind: "app/models").map(&:path_name)
        expect(names).to contain_exactly("Admin::Report", "Zone::Deep::Note")
      end
    end
  end

  it "skips the lib subdirectories autoload_lib ignores, as Zeitwerk does" do
    Dir.mktmpdir do |dir|
      files = {
        "config/application.rb" => "class Application < Rails::Application\n  config.autoload_lib(ignore: %w[assets tasks generators])\nend\n",
        "app/models/application_record.rb" => "class ApplicationRecord < ActiveRecord::Base\nend\n",
        "lib/generators/widget/widget_generator.rb" => "class WidgetGenerator < Rails::Generators::NamedBase\nend\n",
        "lib/tasks_helper/thing.rb" => "class TasksHelper::Thing < ApplicationRecord\nend\n",
        "lib/lib_record.rb" => "class LibRecord < ApplicationRecord\nend\n"
      }
      files.each do |name, source|
        FileUtils.mkdir_p(File.dirname(File.join(dir, name)))
        File.write(File.join(dir, name), source)
      end

      files = described_class.model_paths(dir).map(&:file)
      expect(files).to contain_exactly("app/models/application_record.rb", "lib/lib_record.rb", "lib/tasks_helper/thing.rb")
    end
  end

  it "answers nothing for a root that does not exist" do
    expect(described_class.each("/nonexistent/rails-ai-context-root", kind: "app/models").to_a).to eq([])
  end

  # One large app's run asked for app/models five times and app/controllers
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
    # Absolute on every platform, its `..` left as spelled: a path from `/`
    # names no drive, so on Windows it is not absolute.
    def abs(path) = File.join(File.expand_path("/"), path)

    it "rejects a spelled path that climbs out of the root" do
      expect(described_class.under_root?(abs("/app/../outside/secret.rb"), abs("/outside/secret.rb"), abs("/app"), abs("/app"))).to be(false)
    end

    it "rejects a spelled .. that climbs out through a symlink" do
      expect(described_class.under_root?(abs("/app/link/../secret.rb"), abs("/outside/secret.rb"), abs("/app"), abs("/app"))).to be(false)
      expect(described_class.under_root?(abs("/app/x/../a.rb"), abs("/app/a.rb"), abs("/app"), abs("/app"))).to be(true)
    end

    it "keeps a path under either spelling of the root" do
      expect(described_class.under_root?(abs("/private/tmp/app/a.rb"), abs("/private/tmp/app/a.rb"), abs("/tmp/app"), abs("/private/tmp/app")))
        .to be(true)
      expect(described_class.under_root?(abs("/app/packs/billing/a.rb"), abs("/elsewhere/billing/a.rb"), abs("/app"), abs("/app"))).to be(true)
    end
  end
end
