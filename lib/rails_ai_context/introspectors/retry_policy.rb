# frozen_string_literal: true

module RailsAiContext
  module Introspectors
    # A job's retry macro as a reader would write it: the exception list, then `attempts:` and
    # `wait:` in that order, read off the call so a multi-line macro reads the same.
    module RetryPolicy
      MACROS = %i[retry_on discard_on sidekiq_options].freeze

      module_function

      # @param hits [Array<Hash>] GenericMacroListener results for MACROS
      # @return [Array<String>]
      def entries(hits)
        Array(hits).filter_map do |hit|
          options = hit[:option_nodes] || {}
          case hit[:macro]
          when :retry_on then with_options("retry_on #{hit[:values].join(', ')}", options)
          when :discard_on then "discard_on #{hit[:values].join(', ')}"
          when :sidekiq_options then "sidekiq retry: #{source_of(options[:retry])}" if options[:retry]
          end
        end
      end

      def with_options(entry, options)
        entry += ", attempts: #{source_of(options[:attempts])}" if options[:attempts]
        entry += ", wait: #{source_of(options[:wait])}" if options[:wait]
        entry
      end

      # The expression as written, on one line: a wait is as often `5.seconds`
      # or a lambda as a number.
      def source_of(node)
        NodeSource.text(node).gsub(/\s+/, " ")
      end
    end
  end
end
