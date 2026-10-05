# frozen_string_literal: true

require "spec_helper"
require "tmpdir"
require "fileutils"

RSpec.describe RailsAiContext::ConcernPaths do
  describe ".find_named" do
    it "resolves a qualified name from the namespace outward, and answers it once per run" do
      Dir.mktmpdir do |dir|
        FileUtils.mkdir_p(File.join(dir, "app/services/wiki/concerns"))
        File.write(File.join(dir, "app/services/wiki/concerns/request.rb"), "module Wiki::Concerns::Request\nend\n")
        expected = [ "Wiki::Concerns::Request", File.join(dir, "app/services/wiki/concerns/request.rb") ]

        expect(described_class.find_named(dir, "::Concerns::Request", within: "Wiki::Queries::Search")).to be_nil
        RailsAiContext::RunCache.around do
          expect(described_class.find_named(dir, "Concerns::Request", within: "Wiki::Queries::Search")).to eq(expected)
          expect(RailsAiContext::PathResolver).not_to receive(:app_roots)
          expect(described_class.find_named(dir, "Concerns::Request", within: "Wiki::Queries::Search")).to eq(expected)
        end
      end
    end
  end

  describe ".resolve" do
    let(:tmpdir) { Dir.mktmpdir }

    after { FileUtils.remove_entry(tmpdir) }

    it "finds every app/*/concerns directory, not a fixed pair" do
      %w[models controllers mailers serializers].each do |owner|
        FileUtils.mkdir_p(File.join(tmpdir, "app", owner, "concerns"))
      end

      expect(described_class.resolve(tmpdir).map { |d| d.sub("#{tmpdir}/", "") })
        .to eq(%w[
          app/controllers/concerns
          app/mailers/concerns
          app/models/concerns
          app/serializers/concerns
        ])
    end

    # Rails globs `app/{*,*/concerns}`, and app/concerns is one of the `*`:
    # an app that keeps its concerns there has them autoloaded at the top
    # level, and reading only app/*/concerns reported one of Huginn's 25.
    it "reads app/concerns itself, in the root tree and in a pack" do
      FileUtils.mkdir_p(File.join(tmpdir, "app", "concerns"))
      FileUtils.mkdir_p(File.join(tmpdir, "app", "models", "concerns"))
      FileUtils.mkdir_p(File.join(tmpdir, "packs", "billing", "app", "concerns"))

      expect(described_class.resolve(tmpdir).map { |d| d.sub("#{tmpdir}/", "") })
        .to eq(%w[app/concerns app/models/concerns packs/billing/app/concerns])
    end

    it "skips a directory that does not exist" do
      FileUtils.mkdir_p(File.join(tmpdir, "app", "models", "concerns"))

      expect(described_class.resolve(tmpdir).map { |d| d.sub("#{tmpdir}/", "") })
        .to eq(%w[app/models/concerns])
    end

    it "reads a configured directory that lives outside app/" do
      FileUtils.mkdir_p(File.join(tmpdir, "lib", "concerns"))
      allow(RailsAiContext.configuration).to receive(:concern_paths).and_return(%w[lib/concerns])

      expect(described_class.resolve(tmpdir).map { |d| d.sub("#{tmpdir}/", "") })
        .to eq(%w[lib/concerns])
    end

    it "searches only what the app configured, so the setting can narrow" do
      FileUtils.mkdir_p(File.join(tmpdir, "app", "models", "concerns"))
      FileUtils.mkdir_p(File.join(tmpdir, "app", "mailers", "concerns"))
      allow(RailsAiContext.configuration).to receive(:concern_paths).and_return(%w[app/models/concerns])

      expect(described_class.resolve(tmpdir).map { |d| d.sub("#{tmpdir}/", "") })
        .to eq(%w[app/models/concerns])
    end

    it "reads a configured path that is already absolute" do
      outside = Dir.mktmpdir
      FileUtils.mkdir_p(File.join(outside, "shared_concerns"))
      allow(RailsAiContext.configuration).to receive(:concern_paths)
        .and_return([ File.join(outside, "shared_concerns") ])

      expect(described_class.resolve(tmpdir)).to eq([ File.join(outside, "shared_concerns") ])
    ensure
      FileUtils.remove_entry(outside) if outside
    end

    it "skips a configured directory that does not exist" do
      allow(RailsAiContext.configuration).to receive(:concern_paths).and_return(%w[lib/nope])

      expect(described_class.resolve(tmpdir)).to eq([])
    end

    it "auto-discovers when the setting is left alone" do
      FileUtils.mkdir_p(File.join(tmpdir, "app", "mailers", "concerns"))
      allow(RailsAiContext.configuration).to receive(:concern_paths).and_return(nil)

      expect(described_class.resolve(tmpdir).map { |d| d.sub("#{tmpdir}/", "") })
        .to eq(%w[app/mailers/concerns])
    end

    it "ships with the setting unset so discovery is the default" do
      expect(RailsAiContext::Configuration.new.concern_paths).to be_nil
    end

    # `GetConcern`'s includer search resolves packs and engines, so a concern
    # listing that only globbed the root answered from a narrower app than the
    # "Used By" list beside it.
    it "finds concerns under packs and engines, not just the root app tree" do
      FileUtils.mkdir_p(File.join(tmpdir, "app", "models", "concerns"))
      FileUtils.mkdir_p(File.join(tmpdir, "packs", "billing", "app", "models", "concerns"))
      FileUtils.mkdir_p(File.join(tmpdir, "engines", "reporting", "app", "controllers", "concerns"))

      expect(described_class.resolve(tmpdir).map { |d| d.sub("#{tmpdir}/", "") })
        .to eq(%w[
          app/models/concerns
          engines/reporting/app/controllers/concerns
          packs/billing/app/models/concerns
        ])
    end

    it "reads an extra_app_paths tree the same way" do
      FileUtils.mkdir_p(File.join(tmpdir, "custom", "app", "models", "concerns"))
      allow(RailsAiContext.configuration).to receive(:extra_app_paths).and_return(%w[custom])

      expect(described_class.resolve(tmpdir).map { |d| d.sub("#{tmpdir}/", "") })
        .to eq(%w[custom/app/models/concerns])
    end

    it "returns nothing when the app has no concerns at all" do
      expect(described_class.resolve(tmpdir)).to eq([])
    end
  end

  describe ".type_for" do
    it "singularises the owner segment" do
      expect(described_class.type_for("/app/mailers/concerns")).to eq("mailer")
      expect(described_class.type_for("/srv/x/app/models/concerns")).to eq("model")
      expect(described_class.type_for("/srv/x/app/controllers/concerns")).to eq("controller")
    end

    it "falls back to other for a directory outside app/" do
      expect(described_class.type_for("/srv/x/lib/concerns")).to eq("other")
    end

    # An app deployed at /app (the Docker default) has app/concerns at /app/app/concerns.
    it "reads app/concerns as other when the app root itself is named app" do
      expect(described_class.type_for("/app/app/concerns")).to eq("other")
      expect(described_class.type_for("/srv/app/app/models/concerns")).to eq("model")
    end
  end

  describe ".find_file" do
    let(:tmpdir) { Dir.mktmpdir }

    after { FileUtils.remove_entry(tmpdir) }

    # `resolve` sorts, so app/controllers/concerns won a shared basename and
    # a model merged a controller concern's filters into its callbacks.
    it "prefers the concerns directory belonging to the owner kind" do
      %w[controllers models].each do |owner|
        FileUtils.mkdir_p(File.join(tmpdir, "app", owner, "concerns"))
        File.write(File.join(tmpdir, "app", owner, "concerns", "searchable.rb"), "module Searchable\nend\n")
      end

      expect(described_class.find_file(tmpdir, "Searchable", prefer: "model"))
        .to eq(File.join(tmpdir, "app", "models", "concerns", "searchable.rb"))
      expect(described_class.find_file(tmpdir, "Searchable", prefer: "controller"))
        .to eq(File.join(tmpdir, "app", "controllers", "concerns", "searchable.rb"))
    end

    # `include DebugConcern` inside Fasp::Provider resolves at runtime to
    # Fasp::Provider::DebugConcern; underscoring the literal spelling finds
    # nothing.
    it "walks the enclosing namespaces outward" do
      dir = File.join(tmpdir, "app", "models", "concerns", "fasp", "provider")
      FileUtils.mkdir_p(dir)
      File.write(File.join(dir, "debug_concern.rb"), "module DebugConcern\nend\n")

      expect(described_class.find_file(tmpdir, "DebugConcern", within: "Fasp::Provider"))
        .to eq(File.join(dir, "debug_concern.rb"))
      expect(described_class.find_file(tmpdir, "DebugConcern")).to be_nil
    end

    # Canvas declares Role::AssociationHelper in role.rb, which Zeitwerk loads it with.
    it "finds a module with no file of its own in its outer constant's file, and reads only that module" do
      models = File.join(tmpdir, "app", "models")
      FileUtils.mkdir_p(models)
      File.write(File.join(models, "role.rb"), "class Role < ApplicationRecord\n  module AssociationHelper\n    def helped; end\n  end\n\n  def outer; end\nend\n")

      expect(described_class.find_file(tmpdir, "Role::AssociationHelper")).to eq(File.join(models, "role.rb"))
      expect(described_class.find_file(tmpdir, "AssociationHelper", within: "Role")).to eq(File.join(models, "role.rb"))
      expect(described_class.find_file(tmpdir, "Role::Missing")).to be_nil
      expect(described_class.module_source(tmpdir, "Role::AssociationHelper")).to eq("module AssociationHelper\n    def helped; end\n  end")
      expect(described_class.module_source(tmpdir, "Role")).to start_with("class Role")
    end

    # Rails autoloads every app/* directory, and Mastodon's controllers
    # include RoutingHelper and DomainControlHelper from app/helpers.
    it "finds a module in any app/* directory" do
      FileUtils.mkdir_p(File.join(tmpdir, "app", "helpers"))
      File.write(File.join(tmpdir, "app", "helpers", "routing_helper.rb"), "module RoutingHelper\nend\n")

      expect(described_class.find_file(tmpdir, "RoutingHelper", prefer: "controller"))
        .to eq(File.join(tmpdir, "app", "helpers", "routing_helper.rb"))
    end

    it "finds a concern that lives only inside a pack" do
      dir = File.join(tmpdir, "packs", "billing", "app", "models", "concerns")
      FileUtils.mkdir_p(dir)
      File.write(File.join(dir, "auditable.rb"), "module Auditable\nend\n")

      expect(described_class.find_file(tmpdir, "Auditable")).to eq(File.join(dir, "auditable.rb"))
    end

    # Ruby reaches the top level last, so the nested file is the one the
    # reference binds to when both spellings exist.
    it "prefers the innermost namespace over a top-level file of the same name" do
      nested = File.join(tmpdir, "app", "models", "concerns", "fasp", "provider")
      FileUtils.mkdir_p(nested)
      File.write(File.join(nested, "debug_concern.rb"), "module DebugConcern\nend\n")
      File.write(File.join(tmpdir, "app", "models", "concerns", "debug_concern.rb"), "module DebugConcern\nend\n")

      expect(described_class.find_file(tmpdir, "DebugConcern", within: "Fasp::Provider"))
        .to eq(File.join(nested, "debug_concern.rb"))
    end
  end

  # OpenProject names concerns against a hundred roots, and a stat per
  # candidate path was most of its controllers section.
  describe ".find_file within one run" do
    it "stats nothing for a name no listing holds, and finds one that is there" do
      Dir.mktmpdir do |root|
        FileUtils.mkdir_p(File.join(root, "app", "models", "concerns", "billing"))
        File.write(File.join(root, "app", "models", "concerns", "billing", "taxable.rb"), "module Billing::Taxable; end\n")
        allow(File).to receive(:exist?).and_call_original

        RailsAiContext::RunCache.around do
          3.times { expect(described_class.find_file(root, "Shipping::Trackable")).to be_nil }
          expect(File).not_to have_received(:exist?)
          expect(described_class.find_file(root, "Billing::Taxable")).to end_with("concerns/billing/taxable.rb")
        end
      end
    end
  end

  # The listing walk matched case exactly inside a run, while File.exist?
  # outside one follows the filesystem: on a case-insensitive disk a tool call
  # found a concern the context run missed.
  describe ".find_file and letter case" do
    it "answers inside a run what the filesystem answers outside one" do
      Dir.mktmpdir do |root|
        dir = File.join(root, "app", "models", "concerns")
        FileUtils.mkdir_p(dir)
        File.write(File.join(dir, "Taxable.rb"), "module Taxable; end\n")
        on_disk = File.exist?(File.join(dir, "taxable.rb"))

        outside = described_class.find_file(root, "Taxable")
        inside = RailsAiContext::RunCache.around { described_class.find_file(root, "Taxable") }

        expect(inside).to eq(outside)
        expect(!outside.nil?).to eq(on_disk)
      end
    end
  end
end
