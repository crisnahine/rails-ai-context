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
        bundle = GemLock.bundle(root)
        gemfile = bundle[:gemfile] or return []

        read(bundle[:dir], File.basename(gemfile), [], [])
      rescue StandardError => e
        RailsAiContext.debug_fail(e, [], label: "GemfileGems.entries")
      end

      # Bundler evaluates an eval_gemfile file into the same Gemfile, inside
      # the groups around the call. Never read outside the bundle's directory.
      def read(root, relative, groups, seen)
        resolution = SafePath.locate(relative, under: root)
        return [] if !resolution.ok? || seen.include?(resolution.realpath)

        seen << resolution.realpath
        found = Array(SourceIntrospector.walk(resolution.realpath, { gems: -> { Listeners::GemfileDslListener.new } })[:gems])
        found.flat_map do |entry|
          entry = entry.merge(groups: (groups + entry[:groups]).uniq) if groups.any? && %i[gem eval_gemfile].include?(entry[:type])
          next [ entry ] unless entry[:type] == :eval_gemfile

          nested = File.expand_path(entry[:path], File.dirname(File.join(root, relative)))
          next [] unless nested.start_with?("#{File.expand_path(root)}/")

          read(root, nested.delete_prefix("#{File.expand_path(root)}/"), entry[:groups], seen)
        end
      end
      private_class_method :read
    end
  end
end
