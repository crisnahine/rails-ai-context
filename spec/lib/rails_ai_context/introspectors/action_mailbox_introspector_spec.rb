# frozen_string_literal: true

require "spec_helper"

RSpec.describe RailsAiContext::Introspectors::ActionMailboxIntrospector do
  let(:introspector) { described_class.new(Rails.application) }

  describe "#call" do
    subject(:result) { introspector.call }

    it "does not return an error" do
      expect(result).not_to have_key(:error)
    end

    it "returns installed as false when ActionMailbox is not loaded" do
      expect(result[:installed]).to be false
    end

    it "returns empty mailboxes array when no mailboxes directory" do
      expect(result[:mailboxes]).to eq([])
    end

    context "with a mailbox file" do
      let(:mailboxes_dir) { File.join(Rails.root, "app/mailboxes") }
      let(:mailbox_file) { File.join(mailboxes_dir, "forwards_mailbox.rb") }

      before do
        FileUtils.mkdir_p(mailboxes_dir)
        File.write(mailbox_file, <<~RUBY)
          class ForwardsMailbox < ApplicationMailbox
            routing /forwards/i => :forward

            def process
              # handle forwarded email
            end
          end
        RUBY
      end

      after { FileUtils.rm_rf(mailboxes_dir) }

      it "discovers mailbox classes" do
        expect(result[:mailboxes].size).to eq(1)
        expect(result[:mailboxes].first[:name]).to eq("ForwardsMailbox")
      end

      it "names the file from the app root" do
        expect(result[:mailboxes].first[:file]).to eq("app/mailboxes/forwards_mailbox.rb")
      end
    end

    # The generator puts routing in ApplicationMailbox, and Rails keeps one router for every mailbox.
    context "with routing declared in ApplicationMailbox" do
      let(:mailboxes_dir) { File.join(Rails.root, "app/mailboxes") }

      before do
        FileUtils.mkdir_p(mailboxes_dir)
        File.write(File.join(mailboxes_dir, "application_mailbox.rb"), <<~RUBY)
          class ApplicationMailbox < ActionMailbox::Base
            routing(/^support@/i => :support)
            routing all: :catchall
          end
        RUBY
        File.write(File.join(mailboxes_dir, "support_mailbox.rb"), <<~RUBY)
          class SupportMailbox < ApplicationMailbox
            before_processing :require_user
            def process; end
          end
        RUBY
      end

      after { FileUtils.rm_rf(mailboxes_dir) }

      it "lists each route in order with the mailbox it sends to" do
        expect(result[:routes]).to eq([
          { pattern: "/^support@/i", mailbox: "SupportMailbox", file: "app/mailboxes/application_mailbox.rb" },
          { pattern: ":all", mailbox: "CatchallMailbox", file: "app/mailboxes/application_mailbox.rb" }
        ])
      end

      it "gives each mailbox the patterns routed to it and what runs before it" do
        expect(result[:mailboxes]).to eq([
          { name: "SupportMailbox", file: "app/mailboxes/support_mailbox.rb", routed_from: [ "/^support@/i" ],
            callbacks: [ { type: "before_processing", method: "require_user" } ] }
        ])
      end
    end

    it "reads a mailbox it cannot parse without failing the others" do
      dir = File.join(Rails.root, "app/mailboxes")
      FileUtils.mkdir_p(dir)
      File.write(File.join(dir, "broken_mailbox.rb"), "class BrokenMailbox < ApplicationMailbox\n  routing(\n")
      File.write(File.join(dir, "ok_mailbox.rb"), "class OkMailbox < ApplicationMailbox\nend\n")

      expect(result[:mailboxes].map { |m| m[:name] }).to include("OkMailbox")
    ensure
      FileUtils.rm_rf(dir)
    end
  end

  # A computed acronym never reaches the static run; the file still declares the constant Zeitwerk loads.
  it "names a mailbox and the route to it from the class its file declares when the acronym is computed" do
    Dir.mktmpdir do |dir|
      FileUtils.mkdir_p(File.join(dir, "config", "initializers"))
      FileUtils.mkdir_p(File.join(dir, "app", "mailboxes"))
      File.write(File.join(dir, "config", "initializers", "inflections.rb"),
                 "ActiveSupport::Inflector.inflections(:en) do |inflect|\n  %w[API SMS].each { |a| inflect.acronym a }\nend\n")
      File.write(File.join(dir, "app", "mailboxes", "application_mailbox.rb"),
                 "class ApplicationMailbox < ActionMailbox::Base\n  routing(/^sms@/i => :sms)\n  routing(/^gone@/i => :gone)\nend\n")
      File.write(File.join(dir, "app", "mailboxes", "sms_mailbox.rb"), "class SMSMailbox < ApplicationMailbox\nend\n")

      result = RailsAiContext::Introspector.new(RailsAiContext::StaticApp.new(dir)).call[:action_mailbox]

      expect(result[:routes].map { |r| r[:mailbox] }).to eq(%w[SMSMailbox GoneMailbox])
      expect(result[:mailboxes].map { |m| m.slice(:name, :routed_from) }).to eq([ { name: "SMSMailbox", routed_from: [ "/^sms@/i" ] } ])
    end
  end
end
