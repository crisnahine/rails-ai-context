# frozen_string_literal: true

require "set"

module RailsAiContext
  module Introspectors
    # One answer to "which classes and modules mix module M in".
    #
    # A written name resolves as Ruby does, from the includer's namespace outward, and the
    # nearest candidate the app declares decides.
    module Includers
      module_function

      # @param sources [Enumerable<Array(String, String)>] [path, source] pairs
      # @param names [Array<String>] the fully qualified modules asked about
      # @param macros [Array<Symbol>] which of include/prepend/extend count
      # @return [Hash{String => Array<String>}] each name mixed in => its includers
      def of(root, sources, names, macros: %i[include prepend extend])
        known = names.to_h { |name| [ name.downcase, name ] }
        return {} if known.empty?

        segments = names.map { |name| name.split("::").last }.uniq
        found = Hash.new { |hash, key| hash[key] = [] }
        # One run, so the directories every resolution walks are listed once for the whole scan.
        RunCache.around { collect(root, sources, segments, known, macros, found) }
        found.transform_values(&:uniq)
      end

      def collect(root, sources, segments, known, macros, found)
        sources.each do |_path, source|
          next unless source && segments.any? { |segment| source.include?(segment) }

          SourceIntrospector.walk_source(source, { mixins: Listeners::MixinsListener })[:mixins].each do |mixin|
            next unless macros.include?(mixin[:macro]) && segments.include?(mixin[:name].split("::").last)

            scope = Array(mixin[:owner]).join("::")
            includer = mixin[:receiver] || scope
            next if includer.empty?

            name = resolve(root, mixin[:name], scope, known)
            found[name] << includer if name
          end
        end
      end

      # The name asked about the written one means, or nil when the nearest
      # candidate the app declares is some other module.
      def resolve(root, written, scope, known)
        ConcernPaths.candidate_names(written, scope.empty? ? nil : scope).each do |candidate|
          return known[candidate.downcase] if known.key?(candidate.downcase)
          return nil if ConcernPaths.find_file(root, candidate)
        end
        nil
      end
    end
  end
end
