# frozen_string_literal: true

require "spec_helper"
require "tmpdir"
require "fileutils"

RSpec.describe RailsAiContext::Tools::GetServicePattern do
  before { described_class.reset_cache! }

  describe ".call" do
    # Canvas keeps a concern two directories down, under
    # app/services/accessibility/concerns; the listing offered it as a service.
    context "with a concern below the services root" do
      let(:tmpdir) { Dir.mktmpdir }

      before do
        FileUtils.mkdir_p(File.join(tmpdir, "app", "services", "accessibility", "concerns"))
        File.write(File.join(tmpdir, "app", "services", "accessibility", "concerns", "queueable.rb"), <<~RUBY)
          module Accessibility
            module Concerns
              module Queueable
                extend ActiveSupport::Concern

                def queue_it; end
              end
            end
          end
        RUBY
        File.write(File.join(tmpdir, "app", "services", "accessibility", "scan_service.rb"), <<~RUBY)
          class Accessibility::ScanService
            def call; end
          end
        RUBY
        allow(Rails.application).to receive(:root).and_return(Pathname.new(tmpdir))
        described_class.reset_cache!
      end

      after { FileUtils.remove_entry(tmpdir) }

      it "lists the service and not the concern beside it" do
        text = described_class.call(detail: "summary").content.first[:text]

        expect(text).to include("# Service Objects (1)")
        expect(text).to include("- Accessibility::ScanService")
        expect(text).not_to include("Queueable")
      end
    end

    # class_attribute defines a class-side and an instance-side set of the
    # same names; printed bare, every name showed twice with no way to tell.
    context "with a class_attribute and a class << self method" do
      let(:tmpdir) { Dir.mktmpdir }

      before do
        FileUtils.mkdir_p(File.join(tmpdir, "app", "services"))
        File.write(File.join(tmpdir, "app", "services", "content_renderer.rb"), <<~RUBY)
          class ContentRenderer
            class_attribute :processor

            class << self
              def build(x); end
            end

            def process(text); end
          end
        RUBY
        allow(Rails.application).to receive(:root).and_return(Pathname.new(tmpdir))
        described_class.reset_cache!
      end

      after { FileUtils.remove_entry(tmpdir) }

      it "marks each class-side method with self." do
        text = described_class.call(service: "ContentRenderer").content.first[:text]

        methods = text.scan(/^- `(.+)`$/).flatten
        expect(methods).to eq(%w[self.processor self.processor=(value) self.processor? processor processor=(value) processor? self.build(x) process(text)])
      end
    end

    # Packs and engines are searched too, so naming app/services/ alone told a
    # packwerk app to look somewhere the tool had not looked.
    it "names every directory it searched when it found none" do
      result = described_class.call
      text = result.content.first[:text]
      expect(text).to include("No services directory found")
      expect(text).to include("packs/*/app/services/")
      expect(text).to include("engines/*/app/services/")
    end

    # The scan also reads in-repo code roots and configured extra paths, and
    # the answer named only three places.
    context "with an in-repo code root and an extra path, and no services" do
      let(:tmpdir) { Dir.mktmpdir }

      before do
        FileUtils.mkdir_p(File.join(tmpdir, "plugins", "chat", "app", "models"))
        File.write(File.join(tmpdir, "plugins", "chat", "plugin.rb"), "# chat\n")
        allow(Rails.application).to receive(:root).and_return(Pathname.new(tmpdir))
        allow(RailsAiContext.configuration).to receive(:extra_app_paths).and_return([ "custom/app" ])
      end

      after { FileUtils.remove_entry(tmpdir) }

      it "names every place the scan reads" do
        text = described_class.call.content.first[:text]

        expect(text).to include("app/services/, packs/*/app/services/, engines/*/app/services/")
        expect(text).to include("plugins/chat/app/services/")
        expect(text).to include("custom/app/services/")
      end
    end

    # Mastodon registers ActivityPub as an acronym, so its files sit under
    # activitypub/; underscoring the name here, with none of the app's
    # acronyms, looked under activity_pub/ and answered not found.
    context "with a namespace the app spells with an acronym" do
      let(:tmpdir) { Dir.mktmpdir }

      before do
        FileUtils.mkdir_p(File.join(tmpdir, "app", "services", "activitypub"))
        File.write(File.join(tmpdir, "app", "services", "activitypub", "process_account_service.rb"), <<~RUBY)
          class ActivityPub::ProcessAccountService
            def call(username); end
          end
        RUBY
        allow(Rails.application).to receive(:root).and_return(Pathname.new(tmpdir))
      end

      after { FileUtils.remove_entry(tmpdir) }

      # The suggestions camelized the path, so they offered Activitypub::...,
      # a constant the app does not have.
      it "suggests the constants the files declare when a name is not found" do
        text = described_class.call(service: "ActivityPub::NoSuchService").content.first[:text]

        expect(text).to include("ActivityPub::ProcessAccountService")
        expect(text).not_to include("Activitypub::")
      end

      it "answers the name the listing prints" do
        text = described_class.call(service: "ActivityPub::ProcessAccountService").content.first[:text]

        expect(text).to include("# ActivityPub::ProcessAccountService")
        expect(text).not_to include("not found")
      end
    end

    context "with services only in a pack" do
      let(:tmpdir) { Dir.mktmpdir }

      before do
        pack_services = File.join(tmpdir, "packs", "billing", "app", "services")
        FileUtils.mkdir_p(pack_services)
        File.write(File.join(pack_services, "charge_card.rb"), <<~RUBY)
          class ChargeCard
            def initialize(amount:)
              @amount = amount
            end

            def call
              Stripe::Charge.create(amount: @amount)
            end
          end
        RUBY
        allow(Rails.application).to receive(:root).and_return(Pathname.new(tmpdir))
      end

      after { FileUtils.remove_entry(tmpdir) }

      it "lists the pack service and names its real path" do
        text = described_class.call(detail: "full").content.first[:text]
        expect(text).to include("ChargeCard")
        expect(text).to include("packs/billing/app/services/charge_card.rb")
      end

      it "answers for the pack service by name" do
        text = described_class.call(service: "ChargeCard").content.first[:text]
        expect(text).to include("# ChargeCard")
      end
    end

    # A base class is not a service: counted as one it inflates the total and
    # the pattern denominator beside it, and reads as something a caller can
    # invoke.
    context "with a base class other services inherit from" do
      let(:tmpdir) { Dir.mktmpdir }

      before do
        services = File.join(tmpdir, "app", "services")
        FileUtils.mkdir_p(File.join(services, "trackers"))
        File.write(File.join(services, "application_service.rb"),
                   "class ApplicationService\n  def self.perform(*args) = new(*args).perform\nend\n")
        File.write(File.join(services, "trackers", "base.rb"),
                   "module Trackers\n  class Base\n    def call; end\n  end\nend\n")
        File.write(File.join(services, "trackers", "null.rb"),
                   "module Trackers\n  class Null < Base\n    def call; end\n  end\nend\n")
        File.write(File.join(services, "charge_card.rb"),
                   "class ChargeCard\n  def call; end\nend\n")
        allow(Rails.application).to receive(:root).and_return(Pathname.new(tmpdir))
      end

      after { FileUtils.remove_entry(tmpdir) }

      it "leaves the base classes out of the count and says which" do
        text = described_class.call(detail: "summary").content.first[:text]

        expect(text).to include("# Service Objects (2)")
        expect(text).to include("Base classes not counted as services: ApplicationService, Trackers::Base")
      end

      it "leaves them out of the listing" do
        text = described_class.call(detail: "standard").content.first[:text]

        expect(text).to include("**Trackers::Null**")
        expect(text).not_to include("**Trackers::Base**")
        expect(text).not_to include("**ApplicationService**")
      end

      it "still answers for a base class asked for by name" do
        text = described_class.call(service: "Trackers::Base").content.first[:text]

        expect(text).to include("# Trackers::Base")
      end
    end

    # An app whose services directory holds only its ApplicationService has
    # no service anybody calls; the note named what was left out of a listing
    # of nothing.
    context "with only a base class" do
      let(:tmpdir) { Dir.mktmpdir }

      before do
        services = File.join(tmpdir, "app", "services")
        FileUtils.mkdir_p(services)
        File.write(File.join(services, "application_service.rb"),
                   "class ApplicationService\n  def self.perform(*args) = new(*args).perform\nend\n")
        allow(Rails.application).to receive(:root).and_return(Pathname.new(tmpdir))
      end

      after { FileUtils.remove_entry(tmpdir) }

      # Every listing names what it left out, and an empty one is no exception:
      # "no service objects" alone read as a directory with nothing in it.
      it "says there are no services and names the base it left out" do
        text = described_class.call(detail: "summary").content.first[:text]

        expect(text).to include("contains no service objects")
        expect(text).to include("_Base classes not counted as services: ApplicationService.")
      end
    end

    context "with the same relative path under two roots" do
      let(:tmpdir) { Dir.mktmpdir }

      before do
        app = File.join(tmpdir, "app", "services")
        pack = File.join(tmpdir, "packs", "billing", "app", "services")
        [ app, pack ].each { |d| FileUtils.mkdir_p(d) }
        File.write(File.join(app, "create_order.rb"), "class CreateOrder\n  def call; end\nend\n")
        File.write(File.join(pack, "create_order.rb"), "class CreateOrder\n  def call; end\nend\n")
        allow(Rails.application).to receive(:root).and_return(Pathname.new(tmpdir))
      end

      after { FileUtils.remove_entry(tmpdir) }

      it "names both real paths rather than re-prefixing app/services" do
        text = described_class.call(service: "CreateOrder").content.first[:text]

        expect(text).to include("matches 2 files")
        expect(text).to include("- `app/services/create_order.rb`")
        expect(text).to include("- `packs/billing/app/services/create_order.rb`")
      end

      it "does not suggest the name it just refused" do
        text = described_class.call(service: "CreateOrder").content.first[:text]

        expect(text).not_to include("service:\"CreateOrder\"")
        expect(text).to include("same relative path under different roots")
      end

      it "lists the shared constant once in the not-found alternatives" do
        text = described_class.call(service: "Nope").content.first[:text]

        expect(text).to include("Available: CreateOrder\n")
      end
    end

    # A mailer and a module the services mix in are not services, by name or in a listing.
    context "with a mailer and a mixin beside a service" do
      let(:tmpdir) { Dir.mktmpdir }

      before do
        FileUtils.mkdir_p(File.join(tmpdir, "app", "services"))
        File.write(File.join(tmpdir, "app", "services", "digest_mailer.rb"), <<~RUBY)
          class DigestMailer < ApplicationMailer
            def weekly = mail(to: "a@b.c")
          end
        RUBY
        File.write(File.join(tmpdir, "app", "services", "auditable.rb"), <<~RUBY)
          module Auditable
            def audit! = true
          end
        RUBY
        File.write(File.join(tmpdir, "app", "services", "charge_card.rb"), <<~RUBY)
          class ChargeCard
            include Auditable

            def call = audit!
          end
        RUBY
        allow(Rails.application).to receive(:root).and_return(Pathname.new(tmpdir))
      end

      after { FileUtils.remove_entry(tmpdir) }

      it "does not answer the mailer as a service" do
        text = described_class.call(service: "DigestMailer").content.first[:text]

        expect(text).not_to include("## Public Methods")
        expect(text).to include("Available: ChargeCard\n")
      end

      it "offers neither in a miss's alternatives" do
        text = described_class.call(service: "Nope").content.first[:text]

        expect(text).to include("Available: ChargeCard\n")
      end

      it "reads the matched file once" do
        allow(described_class).to receive(:safe_read).and_call_original

        text = described_class.call(service: "ChargeCard").content.first[:text]

        expect(text).to include("# ChargeCard")
        expect(described_class).to have_received(:safe_read).with(satisfy { |path| File.basename(path.to_s) == "charge_card.rb" }).once
      end

      # The caller scan reads the whole tree on purpose, so it is left out here.
      it "reads no other service file and scans no mixins on a hit" do
        allow(described_class).to receive(:find_callers).and_return([ [], false ])
        allow(described_class).to receive(:safe_read).and_call_original
        allow(RailsAiContext::Introspectors::ServiceClasses).to receive(:mixed_in).and_call_original

        described_class.call(service: "ChargeCard")

        expect(described_class).to have_received(:safe_read).once
        expect(RailsAiContext::Introspectors::ServiceClasses).not_to have_received(:mixed_in)
      end

      it "still reads the mixin check for a matched entry-point-less module" do
        text = described_class.call(service: "Auditable").content.first[:text]

        expect(text).not_to include("## Public Methods")
        expect(text).to include("Available: ChargeCard\n")
      end
    end

    context "with two namespaces duplicated across two roots" do
      let(:tmpdir) { Dir.mktmpdir }

      before do
        app = File.join(tmpdir, "app", "services")
        pack = File.join(tmpdir, "packs", "billing", "app", "services")
        [ app, pack ].each do |dir|
          FileUtils.mkdir_p(File.join(dir, "admin"))
          FileUtils.mkdir_p(File.join(dir, "billing"))
          File.write(File.join(dir, "admin", "report.rb"), "module Admin\n  class Report\n    def call; end\n  end\nend\n")
          File.write(File.join(dir, "billing", "report.rb"), "module Billing\n  class Report\n    def call; end\n  end\nend\n")
        end
        allow(Rails.application).to receive(:root).and_return(Pathname.new(tmpdir))
      end

      after { FileUtils.remove_entry(tmpdir) }

      it "does not claim every match declares the same constant" do
        text = described_class.call(service: "Report").content.first[:text]

        expect(text).to include("matches 4 files")
        expect(text).not_to include("they declare the same")
      end

      it "names both constants so the list can be narrowed" do
        text = described_class.call(service: "Report").content.first[:text]

        expect(text).to include("`Admin::Report`")
        expect(text).to include("`Billing::Report`")
      end

      it "still says the paths are equal once one constant is named" do
        text = described_class.call(service: "Billing::Report").content.first[:text]

        expect(text).to include("matches 2 files")
        expect(text).to include("they declare the same `Billing::Report`")
      end
    end

    context "with service fixtures" do
      let(:tmpdir) { Dir.mktmpdir }
      let(:services_dir) { File.join(tmpdir, "app", "services") }

      before do
        FileUtils.mkdir_p(services_dir)

        File.write(File.join(services_dir, "create_order.rb"), <<~RUBY)
          class CreateOrder
            def initialize(user:, items:)
              @user = user
              @items = items
            end

            def call
              order = Order.create!(user: @user)
              @items.each do |item|
                order.line_items.create!(product: item[:product], quantity: item[:quantity])
              end
              OrderMailer.confirmation(@user, order).deliver_later
              order
            rescue ActiveRecord::RecordInvalid => e
              Rails.logger.error("Order creation failed: \#{e.message}")
              nil
            end
          end
        RUBY

        File.write(File.join(services_dir, "send_notification.rb"), <<~RUBY)
          class SendNotification
            def self.call(user:, message:)
              return if user.notification_preferences[:email] == false

              NotificationMailer.notify(user, message).deliver_later
              user.update!(last_notified_at: Time.current)
            end
          end
        RUBY

        File.write(File.join(services_dir, "process_payment.rb"), <<~RUBY)
          class ProcessPayment
            include Loggable

            def initialize(order)
              @order = order
            end

            def call
              result = Stripe::Charge.create(amount: @order.total)
              @order.update!(payment_status: :paid)
              result
            rescue Stripe::CardError => e
              Rails.logger.error("Payment failed: \#{e.message}")
              nil
            end
          end
        RUBY

        allow(Rails.application).to receive(:root).and_return(Pathname.new(tmpdir))
        allow(RailsAiContext.configuration).to receive(:max_file_size).and_return(1_000_000)
      end

      after { FileUtils.remove_entry(tmpdir) }

      it "answers too-large rather than not-found for a service over the cap" do
        allow(RailsAiContext.configuration).to receive(:max_file_size).and_return(10)

        text = described_class.call(service: "CreateOrder").content.first[:text]
        expect(text).to include("Service file too large to analyze.")
      end

      it "lists all services with default params" do
        result = described_class.call
        text = result.content.first[:text]
        expect(text).to include("Service Objects")
        expect(text).to include("CreateOrder")
        expect(text).to include("SendNotification")
        expect(text).to include("ProcessPayment")
      end

      it "lists services with names only for detail:summary" do
        result = described_class.call(detail: "summary")
        text = result.content.first[:text]
        expect(text).to include("CreateOrder")
        expect(text).to include("SendNotification")
        expect(text).to include("ProcessPayment")
      end

      it "lists services with method signatures for detail:standard" do
        result = described_class.call(detail: "standard")
        text = result.content.first[:text]
        expect(text).to include("CreateOrder")
        expect(text).to include("call")
      end

      it "detects common pattern across services" do
        result = described_class.call(detail: "summary")
        text = result.content.first[:text]
        expect(text).to include("Common pattern")
      end

      it "shows specific service by class name" do
        result = described_class.call(service: "CreateOrder")
        text = result.content.first[:text]
        expect(text).to include("CreateOrder")
        expect(text).to include("Initialize:")
        expect(text).to include("user:")
        expect(text).to include("items:")
      end

      it "shows specific service by snake_case name" do
        result = described_class.call(service: "create_order")
        text = result.content.first[:text]
        expect(text).to include("CreateOrder")
      end

      it "extracts dependencies from service" do
        result = described_class.call(service: "CreateOrder")
        text = result.content.first[:text]
        expect(text).to include("Dependencies")
        expect(text).to include("Order")
      end

      it "extracts error handling from service" do
        result = described_class.call(service: "CreateOrder")
        text = result.content.first[:text]
        expect(text).to include("Error Handling")
        expect(text).to include("ActiveRecord::RecordInvalid")
      end

      it "detects side effects in service" do
        result = described_class.call(service: "CreateOrder")
        text = result.content.first[:text]
        expect(text).to include("Side Effects")
        expect(text).to include("email delivery")
      end

      it "returns not-found for unknown service" do
        result = described_class.call(service: "NonexistentService")
        text = result.content.first[:text]
        expect(text).to include("not found")
        expect(text).to include("CreateOrder")
      end

      it "shows full detail for all services at detail:full" do
        result = described_class.call(detail: "full")
        text = result.content.first[:text]
        expect(text).to include("CreateOrder")
        expect(text).to include("Side effects")
      end

      it "detects included modules as dependencies" do
        result = described_class.call(service: "ProcessPayment")
        text = result.content.first[:text]
        expect(text).to include("Loggable")
      end
    end

    context "with services that nest helper classes" do
      let(:tmpdir) { Dir.mktmpdir }
      let(:services_dir) { File.join(tmpdir, "app", "services") }

      before do
        FileUtils.mkdir_p(services_dir)

        File.write(File.join(services_dir, "account_search_service.rb"), <<~RUBY)
          class AccountSearchService < BaseService
            class QueryBuilder
              def initialize(query, account, options = {})
                @query = query
              end

              def build
                :query
              end

              private

              def clause
                :clause
              end
            end

            def call(query, account = nil, options = {})
              QueryBuilder.new.build
            end
          end
        RUBY

        File.write(File.join(services_dir, "notify_service.rb"), <<~RUBY)
          class NotifyService < BaseService
            class BaseCondition
              private

              def check
                true
              end
            end

            class DropCondition < BaseCondition
            end

            class FilterCondition < BaseCondition
            end

            def call(recipient, type, activity, **options)
              recipient
            end
          end
        RUBY

        File.write(File.join(services_dir, "post_status_service.rb"), <<~RUBY)
          class PostStatusService < BaseService
            class UnexpectedMentionsError < StandardError
              def initialize(message, accounts)
                super(message)
              end
            end

            def initialize
              @idempotency_duplicate = nil
            end

            def call(account, options = {})
              account
            end
          end
        RUBY

        File.write(File.join(services_dir, "misnamed_file.rb"), <<~RUBY)
          class ImportRunner
            class Row
              def cells
                []
              end
            end

            def initialize(path)
              @path = path
            end
          end
        RUBY

        File.write(File.join(services_dir, "payloadable.rb"), <<~RUBY)
          module Payloadable
            def serialize_payload(record, serializer, options = {})
              record
            end

            def signing_enabled?
              true
            end
          end
        RUBY

        FileUtils.mkdir_p(File.join(services_dir, "admin"))
        File.write(File.join(services_dir, "admin", "suspend_service.rb"), <<~RUBY)
          module Admin
            class SuspendService < BaseService
              def call(account)
                account
              end
            end
          end
        RUBY

        allow(Rails.application).to receive(:root).and_return(Pathname.new(tmpdir))
        allow(RailsAiContext.configuration).to receive(:max_file_size).and_return(1_000_000)
      end

      after { FileUtils.remove_entry(tmpdir) }

      it "reports the outer class entry point, not a nested class's method" do
        result = described_class.call(detail: "standard")
        text = result.content.first[:text]
        expect(text).to include("**AccountSearchService**")
        expect(text).to match(/\*\*AccountSearchService\*\*[^\n]*call\(query/)
        expect(text).not_to match(/\*\*AccountSearchService\*\*[^\n]*build/)
      end

      it "does not let a nested class's private modifier hide the outer entry point" do
        result = described_class.call(detail: "standard")
        text = result.content.first[:text]
        expect(text).to match(/\*\*NotifyService\*\*[^\n]*call\(recipient/)
        expect(text).not_to match(/\*\*NotifyService\*\*[^\n]*none/)
      end

      it "still lists every public method of a bare module" do
        result = described_class.call(detail: "standard")
        text = result.content.first[:text]
        expect(text).to match(/\*\*Payloadable\*\*[^\n]*serialize_payload/)
        expect(text).to match(/\*\*Payloadable\*\*[^\n]*signing_enabled\?/)
      end

      it "keeps the entry point of a module-namespaced service" do
        result = described_class.call(detail: "standard")
        text = result.content.first[:text]
        expect(text).to match(/\*\*Admin::SuspendService\*\*[^\n]*call\(account\)/)
      end

      it "reports nested-class methods for a single service too" do
        result = described_class.call(service: "AccountSearchService")
        text = result.content.first[:text]
        expect(text).to include("call(query")
        expect(text).not_to include("- `build`")
      end

      it "prints no Initialize line when only a nested class defines one" do
        result = described_class.call(service: "AccountSearchService")
        text = result.content.first[:text]
        expect(text).not_to include("Initialize:")
      end

      # The constructor and the interface have to name the same owner. Read by
      # two walks, a class whose only own method is `initialize` lost the owner
      # election in one of them and kept it in the other, so the outer
      # constructor was printed beside a nested class's methods.
      it "pairs the constructor with the same owner the interface came from" do
        result = described_class.call(service: "misnamed_file")
        text = result.content.first[:text]

        expect(text).to include("**Initialize:** `initialize(path)`")
        expect(text).not_to include("cells")
      end

      it "reports the outer class's own constructor, parentheses or not" do
        result = described_class.call(service: "PostStatusService")
        text = result.content.first[:text]
        expect(text).to include("**Initialize:** `initialize`")
        expect(text).not_to include("initialize(message, accounts)")
      end
    end

    context "with namespaced ActiveInteraction services" do
      let(:tmpdir) { Dir.mktmpdir }
      let(:services_dir) { File.join(tmpdir, "app", "services") }

      before do
        FileUtils.mkdir_p(File.join(services_dir, "api", "v1", "addresses"))
        FileUtils.mkdir_p(File.join(services_dir, "billing", "invoices"))
        FileUtils.mkdir_p(File.join(services_dir, "users"))
        FileUtils.mkdir_p(File.join(services_dir, "reports", "export"))
        FileUtils.mkdir_p(File.join(tmpdir, "app", "workers", "billing", "invoices"))

        File.write(File.join(services_dir, "api", "v1", "addresses", "create.rb"), <<~RUBY)
          class Api::V1::Addresses::Create < ActiveInteraction::Base
            hash :params, strip: false

            def execute; end
          end
        RUBY

        File.write(File.join(services_dir, "billing", "invoices", "create.rb"), <<~RUBY)
          class Billing::Invoices::Create < ActiveInteraction::Base
            object :account

            def execute; end
          end
        RUBY

        File.write(File.join(services_dir, "billing", "invoices", "finalize.rb"), <<~RUBY)
          class Billing::Invoices::Finalize < ActiveInteraction::Base
            object :account

            def execute
              Workers::Billing::Invoices::CreateReminderWorker.perform_in(60)
            end
          end
        RUBY

        File.write(File.join(services_dir, "users", "deactivate.rb"), <<~RUBY)
          class Users::Deactivate < ActiveInteraction::Base
            object :user
            string :reason, default: nil

            def execute; end
          end
        RUBY

        File.write(File.join(services_dir, "reports", "export", "summary_section.rb"), <<~RUBY)
          # This class contains the core code for the summary section.
          class Reports::Export::SummarySection < ActiveInteraction::Base
            string :title

            def execute; end
          end
        RUBY

        File.write(File.join(services_dir, "reports", "constants.rb"), <<~RUBY)
          module Reports::Constants
            STATUSES = %w[draft sent].freeze
          end
        RUBY

        File.write(File.join(tmpdir, "app", "workers", "billing", "invoices", "create_worker.rb"), <<~RUBY)
          class Billing::Invoices::CreateWorker
            include Sidekiq::Job

            def perform(account_id)
              Billing::Invoices::Create.run(account: Account.find(account_id))
            end
          end
        RUBY

        allow(Rails.application).to receive(:root).and_return(Pathname.new(tmpdir))
        allow(RailsAiContext.configuration).to receive(:max_file_size).and_return(1_000_000)
      end

      after { FileUtils.remove_entry(tmpdir) }

      it "names a service by what it declares, not by a word in a comment" do
        text = described_class.call(detail: "standard").content.first[:text]
        expect(text).to include("**Reports::Export::SummarySection**")
        expect(text).not_to include("**contains**")
      end

      it "keeps the namespace of a file that declares only a module" do
        text = described_class.call(detail: "standard").content.first[:text]
        expect(text).to include("**Reports::Constants**")
        expect(text).not_to match(/^- \*\*Constants\*\*/)
      end

      # `billing/invoices/create.rb` shares its basename with
      # `api/v1/addresses/create.rb`, which sorts first, so the basename
      # alternative used to win over the exact path.
      it "resolves a namespaced name to its own file, not the first basename match" do
        text = described_class.call(service: "Billing::Invoices::Create").content.first[:text]

        expect(text).to include("# Billing::Invoices::Create")
        expect(text).to include("app/services/billing/invoices/create.rb")
        expect(text).not_to include("app/services/api/v1/addresses/create.rb")
      end

      it "lists the candidates for an ambiguous bare name and names one that resolves" do
        text = described_class.call(service: "Create").content.first[:text]
        expect(text).to include("matches 2 files")
        expect(text).to include("app/services/api/v1/addresses/create.rb")
        expect(text).to include("app/services/billing/invoices/create.rb")

        suggested = text[/service:"([^"]+)"/, 1]
        expect(described_class.call(service: suggested).content.first[:text])
          .to include("# #{suggested}")
      end

      it "answers not found for a name no file declares" do
        text = described_class.call(service: "Nope::Create").content.first[:text]
        expect(text).to include("not found")
      end

      it "finds the worker that calls the service and drops the substring match" do
        text = described_class.call(service: "Billing::Invoices::Create").content.first[:text]
        expect(text).to include("app/workers/billing/invoices/create_worker.rb")
        expect(text).not_to include("finalize.rb")
        expect(text).not_to include("- `app/services/billing/invoices/create.rb`")
      end

      it "reports the declared ActiveInteraction inputs" do
        text = described_class.call(service: "Users::Deactivate").content.first[:text]
        expect(text).to include("## Inputs (ActiveInteraction)")
        expect(text).to include("`object :user`")
        expect(text).to include("`string :reason` (default: nil)")
      end

      it "names ActiveInteraction as the dominant pattern" do
        text = described_class.call(detail: "standard").content.first[:text]
        expect(text).to include("ActiveInteraction::Base, run with `.run` / `.run!`")
      end
    end

    context "with the same short name declared in a pack" do
      let(:tmpdir) { Dir.mktmpdir }

      before do
        app = File.join(tmpdir, "app", "services")
        pack = File.join(tmpdir, "packs", "billing", "app", "services", "billing")
        controllers = File.join(tmpdir, "app", "controllers")
        [ app, pack, controllers ].each { |d| FileUtils.mkdir_p(d) }
        File.write(File.join(app, "report_builder.rb"), "class ReportBuilder\n  def call; :app_report; end\nend\n")
        File.write(File.join(pack, "report_builder.rb"),
          "module Billing\n  class ReportBuilder\n    def call; :pack_report; end\n  end\nend\n")
        File.write(File.join(controllers, "reports_controller.rb"),
          "class ReportsController\n  def show\n    ReportBuilder.new.call\n  end\nend\n")
        allow(Rails.application).to receive(:root).and_return(Pathname.new(tmpdir))
      end

      after { FileUtils.remove_entry(tmpdir) }

      it "does not count a declaration of the same name as a caller" do
        text = described_class.call(service: "ReportBuilder").content.first[:text]
        expect(text).not_to include("packs/billing/app/services/billing/report_builder.rb")
      end

      it "still names the file that calls it" do
        text = described_class.call(service: "ReportBuilder").content.first[:text]
        expect(text).to include("## Called By")
        expect(text).to include("app/controllers/reports_controller.rb")
      end
    end

    context "with empty services directory" do
      let(:tmpdir) { Dir.mktmpdir }

      before do
        FileUtils.mkdir_p(File.join(tmpdir, "app", "services"))
        allow(Rails.application).to receive(:root).and_return(Pathname.new(tmpdir))
      end

      after { FileUtils.remove_entry(tmpdir) }

      it "returns message when services directory is empty" do
        result = described_class.call
        text = result.content.first[:text]
        expect(text).to include("no service objects")
      end
    end

    # app/services/concerns is its own autoload root, and a module in it is a
    # concern the concern tool lists. Mastodon's Payloadable and
    # SearchStoplight were counted among the app's 99 service objects.
    context "with a service concern" do
      let(:tmpdir) { Dir.mktmpdir }

      before do
        FileUtils.mkdir_p(File.join(tmpdir, "app", "services", "concerns"))
        File.write(File.join(tmpdir, "app", "services", "concerns", "payloadable.rb"), <<~RUBY)
          module Payloadable
            def serialize_payload(record, serializer)
              record
            end
          end
        RUBY
        File.write(File.join(tmpdir, "app", "services", "create_order.rb"), <<~RUBY)
          class CreateOrder
            def call; end
          end
        RUBY
        allow(Rails.application).to receive(:root).and_return(Pathname.new(tmpdir))
      end

      after { FileUtils.remove_entry(tmpdir) }

      it "leaves it out of the listing" do
        text = described_class.call(detail: "full").content.first[:text]

        expect(text).to include("# Service Objects (1)")
        expect(text).not_to include("Payloadable")
      end

      it "does not answer for it by name" do
        text = described_class.call(service: "Payloadable").content.first[:text]

        expect(text).to include("not found")
      end
    end

    context "with a services directory holding only concerns" do
      let(:tmpdir) { Dir.mktmpdir }

      before do
        FileUtils.mkdir_p(File.join(tmpdir, "app", "services", "concerns"))
        File.write(File.join(tmpdir, "app", "services", "concerns", "payloadable.rb"),
                   "module Payloadable\nend\n")
        allow(Rails.application).to receive(:root).and_return(Pathname.new(tmpdir))
      end

      after { FileUtils.remove_entry(tmpdir) }

      it "says the directory holds no service objects" do
        text = described_class.call.content.first[:text]

        expect(text).to include("no service objects")
      end
    end

    # `.filters.keys` is [:order_params, :account]: the two inside the block
    # are keys of the hash filter, and an interaction that is handed them as
    # keyword arguments drops them.
    context "an interaction with a nested hash filter" do
      let(:tmpdir) { Dir.mktmpdir }

      before do
        FileUtils.mkdir_p(File.join(tmpdir, "app", "services", "orders"))
        File.write(File.join(tmpdir, "app", "services", "orders", "create_with_params.rb"), <<~RUBY)
          class Orders::CreateWithParams < ActiveInteraction::Base
            hash :order_params do
              string :title, default: nil
              integer :quantity, default: nil
            end

            object :account

            def execute; end
          end
        RUBY
        allow(Rails.application).to receive(:root).and_return(Pathname.new(tmpdir))
      end

      after { FileUtils.remove_entry(tmpdir) }

      it "shows the nested filters under the hash they belong to" do
        text = described_class.call(service: "Orders::CreateWithParams").content.first[:text]

        expect(text).to include("- `hash :order_params`")
        expect(text).to include("  - `string :title`")
        expect(text).to include("  - `integer :quantity`")
        expect(text).to include("- `object :account`")
      end
    end

    # A subclass of a subclass of ActiveInteraction::Base is still one, and
    # the filters it takes are its own plus the ones it inherits.
    context "an interaction one level down" do
      let(:tmpdir) { Dir.mktmpdir }

      before do
        FileUtils.mkdir_p(File.join(tmpdir, "app", "services", "billing", "invoices"))
        File.write(File.join(tmpdir, "app", "services", "billing", "invoices", "base_request.rb"), <<~RUBY)
          class Billing::Invoices::BaseRequest < ActiveInteraction::Base
            string :token

            def execute; end
          end
        RUBY
        File.write(File.join(tmpdir, "app", "services", "billing", "invoices", "charge.rb"), <<~RUBY)
          class Billing::Invoices::Charge < Billing::Invoices::BaseRequest
            hash :body do
              integer :amount, default: nil
            end

            def execute; end
          end
        RUBY
        allow(Rails.application).to receive(:root).and_return(Pathname.new(tmpdir))
      end

      after { FileUtils.remove_entry(tmpdir) }

      it "lists the inherited filter alongside the class's own" do
        text = described_class.call(service: "Billing::Invoices::Charge").content.first[:text]

        expect(text).to include("## Inputs (ActiveInteraction)")
        expect(text).to include("`hash :body`")
        expect(text).to include("`string :token`")
      end

      it "says which class an inherited filter came from" do
        text = described_class.call(service: "Billing::Invoices::Charge").content.first[:text]

        expect(text).to include("Billing::Invoices::BaseRequest")
      end
    end

    # The six directories the caller scan used to name are not the app's
    # autoload paths: anything else under app/ is invisible to it.
    context "a caller outside the conventional service directories" do
      let(:tmpdir) { Dir.mktmpdir }

      before do
        FileUtils.mkdir_p(File.join(tmpdir, "app", "services", "billing", "invoices"))
        FileUtils.mkdir_p(File.join(tmpdir, "app", "tools"))
        FileUtils.mkdir_p(File.join(tmpdir, "lib", "reporting"))
        File.write(File.join(tmpdir, "app", "services", "billing", "invoices", "create.rb"), <<~RUBY)
          class Billing::Invoices::Create < ActiveInteraction::Base
            object :account

            def execute; end
          end
        RUBY
        File.write(File.join(tmpdir, "app", "tools", "invoice_tool.rb"), <<~RUBY)
          class InvoiceTool
            def call(account)
              Billing::Invoices::Create.run(account: account)
            end
          end
        RUBY
        File.write(File.join(tmpdir, "lib", "reporting", "nightly.rb"), <<~RUBY)
          module Reporting
            class Nightly
              def call(account)
                Billing::Invoices::Create.run(account: account)
              end
            end
          end
        RUBY
        allow(Rails.application).to receive(:root).and_return(Pathname.new(tmpdir))
      end

      after { FileUtils.remove_entry(tmpdir) }

      it "names a caller in any app/ directory" do
        text = described_class.call(service: "Billing::Invoices::Create").content.first[:text]

        expect(text).to include("app/tools/invoice_tool.rb")
      end

      # Booted, the app's own load paths are the direct answer, and an app
      # that autoloads a directory outside app/ and lib/ still has callers in
      # it.
      it "reads a caller in a directory only the app's load paths name" do
        FileUtils.mkdir_p(File.join(tmpdir, "extras"))
        File.write(File.join(tmpdir, "extras", "nightly_run.rb"), <<~RUBY)
          class NightlyRun
            def call(account)
              Billing::Invoices::Create.run(account: account)
            end
          end
        RUBY
        allow(described_class).to receive(:configured_load_paths).and_return([ File.join(tmpdir, "extras") ])

        text = described_class.call(service: "Billing::Invoices::Create").content.first[:text]

        expect(text).to include("extras/nightly_run.rb")
      end

      # Booted, the load paths repeat app/'s own subdirectories, and a file
      # read once per directory naming it hit the ceiling at half the tree.
      it "counts a file the load paths name twice as one file" do
        files = Dir.glob(File.join(tmpdir, "{app,lib}", "**", "*.rb")).size - 1
        stub_const("#{described_class}::MAX_CALLER_SCAN_FILES", files)
        allow(described_class).to receive(:configured_load_paths)
          .and_return(Dir.glob(File.join(tmpdir, "app", "*")).select { |dir| File.directory?(dir) })

        text = described_class.call(service: "Billing::Invoices::Create").content.first[:text]

        expect(text).to include("lib/reporting/nightly.rb")
        expect(text).not_to include("stopped after")
      end

      # Most load paths sit inside app/, which the scan already walks: each
      # one walked again was the tree read once per load path.
      it "walks a load path only when it lies outside app/ and lib/" do
        real_root = File.realpath(tmpdir)
        FileUtils.mkdir_p(File.join(real_root, "extras"))
        allow(described_class).to receive(:configured_load_paths)
          .and_return([ File.join(real_root, "app", "services"), File.join(real_root, "extras") ])

        dirs = described_class.send(:caller_search_dirs, real_root)

        expect(dirs).to include(File.join(real_root, "extras"))
        expect(dirs).not_to include(File.join(real_root, "app", "services"))
      end

      # The scan reads every file under app/ and lib/, so on a large app it
      # has to stop somewhere and say that it did.
      it "says so when the scan stopped at its file ceiling" do
        stub_const("#{described_class}::MAX_CALLER_SCAN_FILES", 1)

        text = described_class.call(service: "Billing::Invoices::Create").content.first[:text]

        expect(text).to include("stopped after 1 file")
      end

      # A list that stops at the limit with no word reads as complete.
      it "says how many callers there are when it lists fewer" do
        stub_const("#{described_class}::CALLER_LIMIT", 1)

        text = described_class.call(service: "Billing::Invoices::Create").content.first[:text]

        expect(text).to match(/_\d+ callers in all; the 1 listed are the first by path\._/)
        expect(text.scan(/^- `(?:app|lib)\//).size).to eq(1)
      end

      it "names a caller under lib/" do
        text = described_class.call(service: "Billing::Invoices::Create").content.first[:text]

        expect(text).to include("lib/reporting/nightly.rb")
      end
    end
  end


  # T::Struct, Dry::Struct, dry-initializer and attr_extras declare the
  # constructor through macros, so there is no `def initialize` to read.
  describe "a constructor declared by macros" do
    let(:tmpdir) { Dir.mktmpdir }

    before do
      dir = File.join(tmpdir, "app", "services")
      FileUtils.mkdir_p(dir)
      File.write(File.join(dir, "line_item_input.rb"), <<~RUBY)
        class LineItemInput < T::Struct
          const :sku, String
          prop :quantity, Integer, default: 1
          prop :note, T.nilable(String)

          class Nested < T::Struct
            const :ignored, String
          end
        end
      RUBY
      File.write(File.join(dir, "charge_service.rb"), <<~RUBY)
        class ChargeService
          extend Dry::Initializer
          param :order
          option :gateway, default: -> { :stripe }
          option :retries, optional: true
          def call = order
        end
      RUBY
      File.write(File.join(dir, "notify_service.rb"), <<~RUBY)
        class NotifyService
          pattr_initialize :channel, [:user!, :message, priority: :low]
          def call = user
        end
      RUBY
      File.write(File.join(dir, "money_value.rb"), <<~RUBY)
        class MoneyValue < Dry::Struct
          attribute :amount, Types::Integer
          attribute :currency, Types::String.default("USD")
          attribute? :memo, Types::String
        end
      RUBY
      File.write(File.join(dir, "form_like.rb"), <<~RUBY)
        class FormLike
          include ActiveModel::Attributes
          attribute :name, :string
          param :not_dry
          def call = name
        end
      RUBY
      File.write(File.join(dir, "explicit_service.rb"), <<~RUBY)
        class ExplicitService
          attr_initialize :a
          def initialize(b); end
          def call = b
        end
      RUBY
      allow(Rails.application).to receive(:root).and_return(Pathname.new(tmpdir))
      described_class.reset_cache!
    end

    after { FileUtils.remove_entry(tmpdir) }

    def single(name)
      described_class.call(service: name).content.first[:text]
    end

    it "reads a T::Struct's const and prop declarations" do
      text = single("LineItemInput")

      expect(text).to include("**Initialize:** `initialize(sku:, quantity: 1, note: nil)`")
      expect(text).to include("## Inputs (T::Struct)")
      expect(text).to include("- `const :sku, String`")
      expect(text).to include("- `prop :quantity, Integer, default: 1`")
      expect(text).not_to include("ignored")
    end

    it "reads dry-initializer params and options" do
      text = single("ChargeService")

      expect(text).to include("**Initialize:** `initialize(order, gateway: :stripe, retries: nil)`")
      expect(text).to include("## Inputs (dry-initializer)")
      expect(text).to include("- `param :order`")
    end

    it "reads an attr_extras initializer" do
      expect(single("NotifyService")).to include("**Initialize:** `initialize(channel, user:, message: nil, priority: :low)`")
    end

    it "reads a Dry::Struct's attributes" do
      expect(single("MoneyValue")).to include("**Initialize:** `initialize(amount:, currency: \"USD\", memo: nil)`")
    end

    it "reads no constructor from macros of the same name outside those libraries" do
      expect(single("FormLike")).not_to include("**Initialize:**")
    end

    it "prefers a def initialize the class writes itself" do
      expect(single("ExplicitService")).to include("**Initialize:** `initialize(b)`")
    end

    it "prints the Initialize line in the full listing" do
      text = described_class.call(detail: "full").content.first[:text]

      expect(text).to include("- **Initialize:** `initialize(sku:, quantity: 1, note: nil)`")
      expect(text).to include("- **Initialize:** `initialize(amount:, currency: \"USD\", memo: nil)`")
    end
  end


  # active_interaction recommends app/interactions and interactor-rails
  # generates into app/interactors; both are service roots.
  describe "interactions and interactors outside app/services" do
    let(:tmpdir) { Dir.mktmpdir }

    before do
      FileUtils.mkdir_p(File.join(tmpdir, "app", "interactions"))
      FileUtils.mkdir_p(File.join(tmpdir, "app", "interactors", "orders"))
      File.write(File.join(tmpdir, "app", "interactions", "create_account.rb"), <<~RUBY)
        class CreateAccount < ActiveInteraction::Base
          string :subdomain
          record :user
          def execute
            Account.create!(subdomain: subdomain)
          end
        end
      RUBY
      File.write(File.join(tmpdir, "app", "interactors", "place_order.rb"), <<~RUBY)
        class PlaceOrder
          include Interactor::Organizer
          organize ChargeCard, SendReceipt
        end
      RUBY
      File.write(File.join(tmpdir, "app", "interactors", "orders", "charge_card.rb"), <<~RUBY)
        module Orders
          class ChargeCard
            include Interactor
            def call; end
          end
        end
      RUBY
      allow(Rails.application).to receive(:root).and_return(Pathname.new(tmpdir))
      described_class.reset_cache!
    end

    after { FileUtils.remove_entry(tmpdir) }

    it "reads an interaction in app/interactions with its filters" do
      text = described_class.call(service: "CreateAccount").content.first[:text]

      expect(text).to include("**File:** `app/interactions/create_account.rb`")
      expect(text).to include("## Inputs (ActiveInteraction)")
      expect(text).to include("- `string :subdomain`")
      expect(text).to include("- `record :user`")
    end

    it "reads an organizer in app/interactors with its steps" do
      text = described_class.call(service: "PlaceOrder").content.first[:text]

      expect(text).to include("## Organizes")
      expect(text).to include("1. `ChargeCard`\n2. `SendReceipt`")
    end

    it "names an interactor by its path under app/interactors" do
      expect(described_class.call(service: "Orders::ChargeCard").content.first[:text]).to include("# Orders::ChargeCard")
    end

    it "lists them all" do
      text = described_class.call(detail: "summary").content.first[:text]

      expect(text).to include("- CreateAccount", "- PlaceOrder", "- Orders::ChargeCard")
    end
  end

  # A scheduled enqueue and the app's own helper enqueue as surely as
  # perform_later does, and a comment naming one does not.
  describe "the job enqueue side effect" do
    before do
      allow(described_class).to receive(:cached_context)
        .and_return(jobs: { enqueue_helpers: [ { owner: "Jobs", method: "enqueue", job_arg: 0 } ] })
    end

    it "is read off the enqueue calls" do
      expect(described_class.send(:extract_side_effects, "RefreshWorker.perform_in(5.minutes)")).to include("job enqueue")
      expect(described_class.send(:extract_side_effects, "Jobs.enqueue(:process_post)")).to include("job enqueue")
      expect(described_class.send(:extract_side_effects, "# SyncJob.perform_later\nx = 1")).not_to include("job enqueue")
    end
  end
end
