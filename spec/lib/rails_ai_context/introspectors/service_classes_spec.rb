# frozen_string_literal: true

require "spec_helper"
require "tmpdir"
require "fileutils"

RSpec.describe RailsAiContext::Introspectors::ServiceClasses do
  # The tool's listing and the generated files' Services line each had their
  # own idea of which classes are services and which are only a base.
  it "names the same services the listing names" do
    Dir.mktmpdir do |root|
      FileUtils.mkdir_p(File.join(root, "app", "services", "admin"))
      File.write(File.join(root, "app", "services", "base_service.rb"), "class BaseService; end\n")
      File.write(File.join(root, "app", "services", "follow_service.rb"), "class FollowService < BaseService; end\n")
      File.write(File.join(root, "app", "services", "admin", "suspend_service.rb"), "class Admin::SuspendService; end\n")
      allow(Rails.application).to receive(:root).and_return(Pathname.new(root))
      RailsAiContext::Tools::GetServicePattern.reset_cache!

      listed = RailsAiContext::Tools::GetServicePattern.call(detail: "summary").content.first[:text]
        .lines.filter_map { |l| l[/\A- (.+)\n/, 1] }

      expect(described_class.names(root)).to eq(listed.sort)
    end
  end

  # `include ServiceHelper` in AssetManager names AssetManager::ServiceHelper;
  # matching the last segment left out Billing::ServiceHelper too, which
  # nothing mixes in.
  it "leaves out only the module an include resolves to" do
    Dir.mktmpdir do |root|
      %w[asset_manager billing].each { |dir| FileUtils.mkdir_p(File.join(root, "app", "services", dir)) }
      File.write(File.join(root, "app", "services", "asset_manager", "service_helper.rb"), "module AssetManager\n  module ServiceHelper\n    def upload; end\n  end\nend\n")
      File.write(File.join(root, "app", "services", "billing", "service_helper.rb"), "module Billing\n  module ServiceHelper\n    def charge; end\n  end\nend\n")
      File.write(File.join(root, "app", "services", "asset_manager", "upload_service.rb"),
                 "module AssetManager\n  class UploadService\n    include ServiceHelper\n  end\nend\n")

      expect(described_class.names(root)).to eq(%w[AssetManager::UploadService Billing::ServiceHelper])
    end
  end

  # Every mixin hook is Ruby's to call, append_features included, so a module
  # whose only class method is one is still a mixin when something mixes it in.
  it "leaves out a mixed-in module whose only class method is a mixin hook" do
    Dir.mktmpdir do |root|
      FileUtils.mkdir_p(File.join(root, "app", "services"))
      File.write(File.join(root, "app", "services", "tracked.rb"),
                 "module Tracked\n  def self.append_features(base)\n    super\n  end\n\n  def track; end\nend\n")
      File.write(File.join(root, "app", "services", "upload_service.rb"), "class UploadService\n  include Tracked\nend\n")

      expect(described_class.names(root)).to eq(%w[UploadService])
    end
  end

  # Canvas keeps app/services/accessibility/concerns/course_statistics_queueable.rb.
  # Only the top-level app/services/concerns was left out, so a mixin one
  # directory deeper was listed as a service an agent could call.
  it "leaves out a concern in any concerns directory under the root" do
    Dir.mktmpdir do |root|
      FileUtils.mkdir_p(File.join(root, "app", "services", "accessibility", "concerns"))
      FileUtils.mkdir_p(File.join(root, "app", "services", "concerns"))
      File.write(File.join(root, "app", "services", "accessibility", "concerns", "queueable.rb"), <<~RUBY)
        module Accessibility
          module Concerns
            module Queueable
              extend ActiveSupport::Concern
            end
          end
        end
      RUBY
      File.write(File.join(root, "app", "services", "concerns", "payloadable.rb"), "module Payloadable; end\n")
      File.write(File.join(root, "app", "services", "accessibility", "scan_service.rb"),
                 "class Accessibility::ScanService; end\n")

      expect(described_class.names(root)).to eq(%w[Accessibility::ScanService])
    end
  end

  # A concern does not have to sit in a directory named for it.
  it "leaves out a module that declares itself a concern" do
    Dir.mktmpdir do |root|
      FileUtils.mkdir_p(File.join(root, "app", "services"))
      File.write(File.join(root, "app", "services", "queueable.rb"), <<~RUBY)
        module Queueable
          extend ActiveSupport::Concern
        end
      RUBY
      File.write(File.join(root, "app", "services", "scan_service.rb"), "class ScanService; end\n")

      expect(described_class.names(root)).to eq(%w[ScanService])
    end
  end

  # Whitehall's AssetManager::ServiceHelper is a module two services and a
  # job include. Something the app mixes in is not something it calls.
  context "with a helper module the app includes" do
    def tree(root)
      FileUtils.mkdir_p(File.join(root, "app", "services", "asset_manager"))
      FileUtils.mkdir_p(File.join(root, "app", "sidekiq"))
      File.write(File.join(root, "app", "services", "asset_manager", "service_helper.rb"), <<~RUBY)
        module AssetManager::ServiceHelper
          class AssetNotFound < StandardError; end

        private

          def asset_manager; end
        end
      RUBY
      File.write(File.join(root, "app", "services", "asset_manager", "asset_deleter.rb"), <<~RUBY)
        class AssetManager::AssetDeleter
          include AssetManager::ServiceHelper

          def self.call(id); end
        end
      RUBY
      File.write(File.join(root, "app", "sidekiq", "create_asset_job.rb"), <<~RUBY)
        class CreateAssetJob
          include Sidekiq::Job
          include AssetManager::ServiceHelper
        end
      RUBY
    end

    it "leaves the included module out and keeps the class that includes it" do
      Dir.mktmpdir do |root|
        tree(root)

        expect(described_class.names(root)).to eq(%w[AssetManager::AssetDeleter])
      end
    end

    # A pre-Concern mixin's only class method is the hook Ruby calls when it is
    # mixed in; nobody calls it, so it is no entry point.
    it "leaves out an included module whose only class method is a hook" do
      Dir.mktmpdir do |root|
        tree(root)
        File.write(File.join(root, "app", "services", "auditable.rb"), <<~RUBY)
          module Auditable
            def self.included(base)
              base.extend(ClassMethods)
            end

            def audit!; end
          end
        RUBY
        File.write(File.join(root, "app", "services", "audit_service.rb"), <<~RUBY)
          class AuditService
            include Auditable

            def self.call; end
          end
        RUBY

        expect(described_class.names(root)).to eq(%w[AssetManager::AssetDeleter AuditService])
      end
    end

    # A module with an entry point of its own is called, however it is written.
    it "keeps a module service with a module_function or self.call entry point" do
      Dir.mktmpdir do |root|
        tree(root)
        File.write(File.join(root, "app", "services", "slugger.rb"), <<~RUBY)
          module Slugger
            module_function

            def call(text) = text.parameterize
          end
        RUBY
        File.write(File.join(root, "app", "services", "pinger.rb"), <<~RUBY)
          module Pinger
            def self.call(url); end
          end
        RUBY

        expect(described_class.names(root)).to eq(%w[AssetManager::AssetDeleter Pinger Slugger])
      end
    end

    it "lists the same set the tool does" do
      Dir.mktmpdir do |root|
        tree(root)
        allow(Rails.application).to receive(:root).and_return(Pathname.new(root))
        RailsAiContext::Tools::GetServicePattern.reset_cache!

        listed = RailsAiContext::Tools::GetServicePattern.call(detail: "summary").content.first[:text]
          .lines.filter_map { |l| l[/\A- (.+)\n/, 1] }

        expect(listed).to eq(%w[AssetManager::AssetDeleter])
      end
    end
  end

  # OpenProject keeps IncomingEmails::MailHandler, an ApplicationMailer, in
  # app/services; the mailers listing counts it by its chain, so the services
  # one must not count it too.
  context "with a mailer kept in app/services" do
    def tree(root)
      FileUtils.mkdir_p(File.join(root, "app", "services", "incoming_emails"))
      FileUtils.mkdir_p(File.join(root, "app", "mailers"))
      File.write(File.join(root, "app", "mailers", "application_mailer.rb"), "class ApplicationMailer < ActionMailer::Base; end\n")
      File.write(File.join(root, "app", "services", "incoming_emails", "mail_handler.rb"), <<~RUBY)
        class IncomingEmails::MailHandler < ApplicationMailer
          def receive(email); end
        end
      RUBY
      File.write(File.join(root, "app", "services", "incoming_emails", "sorter.rb"), <<~RUBY)
        class IncomingEmails::Sorter
          def self.call(email); end
        end
      RUBY
    end

    it "leaves it out of the service names" do
      Dir.mktmpdir do |root|
        tree(root)
        expect(described_class.names(root)).to eq(%w[IncomingEmails::Sorter])
      end
    end

    it "leaves it out of the tool's listing too" do
      Dir.mktmpdir do |root|
        tree(root)
        allow(Rails.application).to receive(:root).and_return(Pathname.new(root))
        RailsAiContext::Tools::GetServicePattern.reset_cache!

        listed = RailsAiContext::Tools::GetServicePattern.call(detail: "summary").content.first[:text]
          .lines.filter_map { |l| l[/\A- (.+)\n/, 1] }

        expect(listed).to eq(%w[IncomingEmails::Sorter])
      end
    end
  end

  it "answers nothing for an app with no service directory" do
    Dir.mktmpdir { |root| expect(described_class.names(root)).to eq([]) }
  end

  # A walk per file for a name almost no service spells was 40% of the scan on
  # an app with 1687 services.
  it "does not walk a source that never names ActiveSupport::Concern" do
    allow(RailsAiContext::Introspectors::SourceIntrospector).to receive(:walk_source).and_call_original

    expect(described_class.concern?("pay_service.rb", "class PayService\n  extend Forwardable\nend\n")).to be(false)
    expect(described_class.concern?("x.rb", "module X\n  extend ActiveSupport::Concern\nend\n")).to be(true)
    expect(RailsAiContext::Introspectors::SourceIntrospector).to have_received(:walk_source).once
  end
end
