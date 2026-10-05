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
end
