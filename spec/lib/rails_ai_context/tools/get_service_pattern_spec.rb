# frozen_string_literal: true

require "spec_helper"
require "tmpdir"
require "fileutils"

RSpec.describe RailsAiContext::Tools::GetServicePattern do
  before { described_class.reset_cache! }

  describe ".call" do
    # Packs and engines are searched too, so naming app/services/ alone told a
    # packwerk app to look somewhere the tool had not looked.
    it "names every directory it searched when it found none" do
      result = described_class.call
      text = result.content.first[:text]
      expect(text).to include("No services directory found")
      expect(text).to include("packs/*/app/services/")
      expect(text).to include("engines/*/app/services/")
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
              Workers::Billing::Invoices::CreateOrUpdateSheetWorker.perform_in(60)
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

        File.write(File.join(services_dir, "reports", "export", "profit_section.rb"), <<~RUBY)
          # This class contains the core code for the profit section.
          class Reports::Export::ProfitSection < ActiveInteraction::Base
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
        expect(text).to include("**Reports::Export::ProfitSection**")
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
        expect(text).to include("no Ruby files")
      end
    end
  end
end
