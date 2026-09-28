# frozen_string_literal: true

module RailsAiContext
  module Introspectors
    # The gems a Gemfile declares, read through the AST: a commented-out
    # `# gem "stripe"` line is not a gem the app uses.
    module GemfileGems
      module_function

      # @return [Array<String>] gem names, in declaration order
      def names(root)
        entries(root).filter_map { |entry| entry[:name] if entry[:type] == :gem }.uniq
      end

      # Every `gem` and `group` entry, with its options and groups.
      # @return [Array<Hash>] empty when there is no Gemfile or it cannot be read
      def entries(root)
        path = File.join(root.to_s, "Gemfile")
        return [] unless File.file?(path)

        Array(SourceIntrospector.walk(path, { gems: -> { Listeners::GemfileDslListener.new } })[:gems])
      rescue StandardError => e
        RailsAiContext.debug_fail(e, [], label: "GemfileGems.entries")
      end
    end
  end
end
