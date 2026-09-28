# frozen_string_literal: true

require "spec_helper"

RSpec.describe RailsAiContext::Introspectors::SourceCalls do
  let(:source) do
    <<~RUBY
      class ImportJob < ApplicationJob
        # Account.find is named here, in a comment
        LOG = "Report.call"

        def perform(id)
          account = Account.find(id)
          Billing::Charge.call(account)
          ::Audit::Entry.create!(account: account)
          ImportJob.perform_later(id)
          Rails.logger.info(account)
          UserMailer.welcome(account).deliver_later
        end
      end
    RUBY
  end

  # The regex this replaced counted a call written in a comment or a string,
  # and each tool carried its own copy of the verb and ignore lists.
  it "reads the calls off the nodes, not the text" do
    expect(described_class.calls(source, own: "ImportJob"))
      .to eq([ "Account.find", "Audit::Entry.create!", "Billing::Charge.call" ])
  end

  it "answers the classes alone for a listing that names collaborators" do
    expect(described_class.classes(source, own: "ImportJob"))
      .to eq([ "Account", "Audit::Entry", "Billing::Charge" ])
  end

  it "leaves out the framework and the file's own class" do
    expect(described_class.calls(source, own: "ImportJob")).not_to include(
      a_string_starting_with("Rails."), a_string_starting_with("ImportJob.")
    )
  end

  # A bang method says it changes something, which is the work handed off:
  # Discourse's badge job does nothing but `GithubBadges.grant!`.
  it "lists any bang method called on a class" do
    source = <<~RUBY
      module Jobs
        class GrantGithubBadges < ::Jobs::Scheduled
          def execute(args)
            GithubBadges.grant!
            return if !SiteSetting.enabled
          end
        end
      end
    RUBY

    expect(described_class.calls(source, own: "Jobs::GrantGithubBadges")).to eq([ "GithubBadges.grant!" ])
  end

  it "answers nothing for source it cannot read" do
    expect(described_class.calls(nil)).to eq([])
  end

  describe ".enqueue_calls" do
    let(:helpers) { [ { owner: "Jobs", method: "enqueue", job_arg: 0 } ] }

    it "finds every adapter's enqueue call and the app's own helper, off the nodes" do
      source = <<~RUBY
        def run
          # ReportJob.perform_later is named here, in a comment
          RefreshWorker.perform_in(5.minutes, 1)
          ReminderWorker.perform_at(time)
          Jobs.enqueue(:process_post, id: 1)
          NotifyJob.set(wait: 1.hour).perform_later
        end
      RUBY

      found = described_class.enqueue_calls(source, helpers).map { |hit| "#{hit[:receiver]}.#{hit[:name]}" }
      expect(found).to eq([ "RefreshWorker.perform_in", "ReminderWorker.perform_at", "Jobs.enqueue",
                            "NotifyJob.set(wait: 1.hour).perform_later" ])
    end

    it "does not count another receiver's method of a helper's name" do
      expect(described_class.enqueue_calls("Queue.enqueue(:x)", helpers)).to eq([])
    end
  end

  it "lists a scheduled enqueue among the calls" do
    expect(described_class.calls("RefreshWorker.perform_in(5.minutes, 1)")).to eq([ "RefreshWorker.perform_in" ])
  end
end
