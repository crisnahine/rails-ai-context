# frozen_string_literal: true

module RailsAiContext
  module Introspectors
    # Discovers Action Mailbox setup: mailbox classes, routing patterns.
    class ActionMailboxIntrospector
      attr_reader :app

      def initialize(app)
        @app = app
      end

      def call
        {
          installed: defined?(ActionMailbox) ? true : false,
          mailboxes: extract_mailboxes
        }
      rescue => e
        { error: e.message }
      end

      private

      def root
        app.root.to_s
      end

      def extract_mailboxes
        dir = File.join(root, "app/mailboxes")
        return [] unless Dir.exist?(dir)

        Dir.glob(File.join(dir, "**/*.rb")).filter_map do |path|
          relative = path.sub("#{dir}/", "")
          next if relative == "application_mailbox.rb"

          name = File.basename(path, ".rb").camelize
          ast_data = SourceIntrospector.walk(path, { mailbox: Listeners::MailboxRoutingListener })

          routing = ast_data[:mailbox].select { |r| r[:type] == :routing }.map do |r|
            { pattern: r[:pattern], action: r[:action] }
          end

          callbacks = ast_data[:mailbox].select { |r| r[:type] == :callback }.map do |r|
            { type: r[:callback_type], method: r[:method] }
          end

          entry = { name: name, file: relative, routing: routing }
          entry[:callbacks] = callbacks if callbacks.any?
          entry
        rescue => e
          $stderr.puts "[rails-ai-context] extract_mailboxes failed: #{e.message}" if ENV["DEBUG"]
          nil
        end.compact.sort_by { |m| m[:name] }
      end
    end
  end
end
