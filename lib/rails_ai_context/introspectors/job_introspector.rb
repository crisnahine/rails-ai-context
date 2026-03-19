# frozen_string_literal: true

module RailsAiContext
  module Introspectors
    # Discovers background jobs (ActiveJob/Sidekiq), mailers,
    # and Action Cable channels.
    class JobIntrospector
      attr_reader :app

      def initialize(app)
        @app = app
      end

      # @return [Hash] async workers, mailers, and channels
      def call
        {
          jobs: extract_jobs,
          mailers: extract_mailers,
          channels: extract_channels
        }
      end

      private

      def extract_jobs
        return [] unless defined?(ActiveJob::Base)

        ActiveJob::Base.descendants.filter_map do |job|
          next if job.name.nil? || job.name == "ApplicationJob" ||
                  job.name.start_with?("ActionMailer", "ActiveStorage::", "ActionMailbox::", "Turbo::", "Sentry::")

          queue = job.queue_name
          queue = begin queue.call rescue "default" end if queue.is_a?(Proc)

          {
            name: job.name,
            queue: queue.to_s,
            priority: job.priority
          }.compact
        end.sort_by { |j| j[:name] }
      rescue
        []
      end

      def extract_mailers
        return [] unless defined?(ActionMailer::Base)

        ActionMailer::Base.descendants.filter_map do |mailer|
          next if mailer.name.nil?

          actions = mailer.instance_methods(false).map(&:to_s).sort
          next if actions.empty?

          {
            name: mailer.name,
            actions: actions,
            delivery_method: mailer.delivery_method.to_s
          }
        end.sort_by { |m| m[:name] }
      rescue
        []
      end

      def extract_channels
        return [] unless defined?(ActionCable::Channel::Base)

        ActionCable::Channel::Base.descendants.filter_map do |channel|
          next if channel.name.nil? || channel.name == "ApplicationCable::Channel"

          {
            name: channel.name,
            stream_methods: channel.instance_methods(false)
              .select { |m| m.to_s.start_with?("stream_") || m == :subscribed }
              .map(&:to_s)
          }
        end.sort_by { |c| c[:name] }
      rescue
        []
      end
    end
  end
end
