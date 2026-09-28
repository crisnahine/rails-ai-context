# frozen_string_literal: true

module RailsAiContext
  module Introspectors
    # What a file hands work to: a constant receiver with a verb below or any bang method,
    # read off the AST so comments and strings do not count. The job and service tools use it.
    module SourceCalls
      # `set` is here because in `Job.set(wait: 1.hour).perform_later` its receiver is the job.
      ENQUEUE_CALLS = %w[perform_later perform_async perform_in perform_at perform_bulk set].freeze

      QUEUEING = (ENQUEUE_CALLS - %w[set] + %w[perform_all_later]).freeze

      VERBS = (%w[new call run perform_now create find where deliver_later deliver_now] + QUEUEING).freeze

      # Any bang method (`create!`, `grant!`) changes something; `\w` keeps out unary `!x`.
      BANG = /\w!\z/

      # Receivers that say nothing about this file's own dependencies: the
      # framework, the standard library, and the app's record base.
      IGNORED = %w[
        Rails ActiveRecord ApplicationRecord File Dir ENV String Integer Float
        Array Hash Set Time Date DateTime URI Regexp
      ].freeze

      # `::Foo::Bar` and `Foo::Bar` are one constant; the root operator is not part of the name.
      CONSTANT_RECEIVER = /\A[A-Z][\w:]*\z/

      module_function

      # The listener spec, for a caller already walking the file for something
      # else: its hits go to `calls_from`, and the tree is walked once.
      def listener
        -> { Listeners::MethodCallListener.new(names: VERBS, pattern: BANG) }
      end

      # @return [Array<Array(String, String)>] class and verb, uniq, sorted
      def pairs(source, own: nil)
        return [] if source.nil?

        pairs_from(SourceIntrospector.walk_source(source, { calls: listener })[:calls], own: own)
      rescue StandardError, ScriptError => e
        RailsAiContext.debug_fail(e, [], label: "SourceCalls")
      end

      def pairs_from(hits, own: nil)
        Array(hits).filter_map { |hit|
          receiver = hit[:receiver].to_s.delete_prefix("::")
          next unless CONSTANT_RECEIVER.match?(receiver)
          next if receiver == own.to_s || IGNORED.include?(receiver)

          [ receiver, hit[:name] ]
        }.uniq.sort
      end

      # `Mailer.welcome`, `Service.call`: the call as a reader would write it.
      def calls(source, own: nil)
        pairs(source, own: own).map { |receiver, verb| "#{receiver}.#{verb}" }
      end

      def calls_from(hits, own: nil)
        pairs_from(hits, own: own).map { |receiver, verb| "#{receiver}.#{verb}" }
      end

      # The calls that put a job on a queue, in source order: each adapter's
      # own, and the app's enqueue helpers (`Jobs.enqueue(:x)`) on their owner.
      def enqueue_calls(source, helpers = [])
        return [] if source.nil?

        names = QUEUEING + helpers.map { |helper| helper[:method].to_s }
        hits = SourceIntrospector.walk_source(source, { calls: -> { Listeners::MethodCallListener.new(names: names) } })[:calls]
        hits.select do |hit|
          receiver = hit[:receiver].to_s.delete_prefix("::")
          next false if receiver.empty?

          QUEUEING.include?(hit[:name]) ||
            helpers.any? { |helper| helper[:owner] == receiver && helper[:method].to_s == hit[:name] }
        end
      end

      # The classes alone, for a listing that names collaborators rather than calls.
      def classes(source, own: nil)
        pairs(source, own: own).map(&:first).uniq
      end
    end
  end
end
