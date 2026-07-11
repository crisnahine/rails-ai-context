# frozen_string_literal: true

require "spec_helper"
require "tmpdir"
require "fileutils"

RSpec.describe RailsAiContext::Tools::GetServicePattern do
  before { described_class.reset_cache! }

  describe ".call" do
    it "returns message when no services directory exists" do
      result = described_class.call
      text = result.content.first[:text]
      expect(text).to include("No app/services/ directory found")
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
