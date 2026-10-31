# frozen_string_literal: true

require "spec_helper"
require "tmpdir"

RSpec.describe RailsAiContext::Introspectors::RecurringSchedules do
  describe ".whenever" do
    def whenever_tasks(schedule)
      Dir.mktmpdir do |dir|
        FileUtils.mkdir_p(File.join(dir, "config"))
        File.write(File.join(dir, "config/schedule.rb"), schedule)
        return described_class.whenever(dir)
      end
    end

    it "takes the runner's class from the job it enqueues, not the first constant it names" do
      tasks = whenever_tasks(<<~RUBY)
        every 1.day do
          runner "Rails.logger.tagged('cron') { DigestJob.perform_later }"
        end
      RUBY

      expect(tasks.first[:class]).to eq("DigestJob")
    end

    it "names no class for a runner that enqueues nothing, so its command shows" do
      tasks = whenever_tasks(<<~RUBY)
        every 1.day do
          runner "Rails.logger.info('x'); Report.build"
          runner "ExportJob.set(wait: 1.hour).perform_later"
        end
      RUBY

      expect(tasks.map { |task| task[:class] }).to eq([ nil, "ExportJob" ])
      expect(tasks.first[:command]).to eq("Rails.logger.info('x'); Report.build")
    end
  end
end
