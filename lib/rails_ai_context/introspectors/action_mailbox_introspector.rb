# frozen_string_literal: true

module RailsAiContext
  module Introspectors
    # Discovers Action Mailbox setup: mailbox classes and the routing that sends mail to them.
    class ActionMailboxIntrospector < Base
      extend StaticTier
      static_tier :files_only

      BASE_FILE = "application_mailbox.rb"

      def call
        mailboxes, routes = extract
        {
          installed: defined?(ActionMailbox) ? true : false,
          mailboxes: mailboxes,
          routes: routes
        }
      end

      private

      # Rails keeps one router for every mailbox, filled in load order, and the base loads first.
      def extract
        dir = File.join(root, "app/mailboxes")
        return [ [], [] ] unless Dir.exist?(dir)

        paths = Dir.glob(File.join(dir, "**/*.rb")).sort_by { |path| [ path == File.join(dir, BASE_FILE) ? 0 : 1, path ] }
        mailboxes = []
        routes = []
        paths.each do |path|
          relative = path.delete_prefix("#{root}/")
          results = SourceIntrospector.walk(path, { mailbox: Listeners::MailboxRoutingListener })[:mailbox]

          results.select { |r| r[:type] == :routing }.each do |r|
            routes << { pattern: r[:pattern], mailbox: "#{r[:action].camelize}Mailbox", file: relative }
          end
          next if path == File.join(dir, BASE_FILE)

          entry = { name: path.delete_prefix("#{dir}/").delete_suffix(".rb").camelize, file: relative }
          callbacks = results.select { |r| r[:type] == :callback }.map { |r| { type: r[:callback_type], method: r[:method] } }
          entry[:callbacks] = callbacks if callbacks.any?
          mailboxes << entry
        rescue => e
          RailsAiContext.debug_fail(e, nil, label: "extract_mailboxes")
        end

        mailboxes.each do |m|
          m[:routed_from] = routes.select { |r| r[:mailbox] == m[:name] }.map { |r| r[:pattern] }
        end
        [ mailboxes.sort_by { |m| m[:name] }.map { |m| m.slice(:name, :file, :routed_from, :callbacks) }, routes ]
      end
    end
  end
end
