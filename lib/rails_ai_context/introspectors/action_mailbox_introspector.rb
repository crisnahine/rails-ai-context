# frozen_string_literal: true

module RailsAiContext
  module Introspectors
    # Discovers Action Mailbox setup: mailbox classes, routing patterns.
    class ActionMailboxIntrospector < Base
      extend StaticTier
      static_tier :files_only

      def call
        {
          installed: defined?(ActionMailbox) ? true : false,
          mailboxes: extract_mailboxes
        }
      end

      private

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
          RailsAiContext.debug_fail(e, nil, label: "extract_mailboxes")
        end.compact.sort_by { |m| m[:name] }
      end
    end
  end
end
