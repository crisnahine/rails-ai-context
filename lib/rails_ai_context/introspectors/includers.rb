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
        kinds(root, sources, names, macros: macros).transform_values(&:keys)
      end

      # As `of`, each includer as its declaration makes it: :concern, :module or :class.
      #
      # @return [Hash{String => Hash{String => Symbol}}]
      def kinds(root, sources, names, macros: %i[include prepend extend])
        known = names.to_h { |name| [ name.downcase, name ] }
        return {} if known.empty?

        segments = names.map { |name| name.split("::").last }.uniq
        found = Hash.new { |hash, key| hash[key] = {} }
        # One run, so the directories every resolution walks are listed once for the whole scan.
        RunCache.around { collect(root, sources, segments, known, macros, found) }
        found
      end

      def collect(root, sources, segments, known, macros, found)
        sources.each do |_path, source|
          next unless source && segments.any? { |segment| source.include?(segment) }

          mixins = mixins_of(source)
          mixins.each do |mixin|
            next unless macros.include?(mixin[:macro]) && segments.include?(mixin[:name].split("::").last)

            owners = Array(mixin[:owner])
            nesting = DeclaredConstant.record_nesting(mixin)
            next if owners.empty? && !mixin[:receiver]

            name = resolve(root, mixin[:top_level] ? "::#{mixin[:name]}" : mixin[:name], nesting, known)
            next unless name

            if mixin[:receiver]
              includer, path = receiver_file(root, mixin[:receiver], nesting)
              found[name][includer] ||= path ? kind_in_file(path, includer) : :class
            else
              found[name][owners.join("::")] ||= kind(source, mixins, owners.join("::"))
            end
          end
        end
      end

      def mixins_of(source)
        SourceIntrospector.walk_source(source, { mixins: Listeners::MixinsListener })[:mixins]
      end

      # @param source [String] the includer's file
      # @param mixins [Array<Hash>] its MixinsListener records
      def kind(source, mixins, name)
        return :class unless DeclaredConstant.declared_module_names(source).include?(name)

        concern = mixins.any? { |mixin| mixin[:macro] == :extend && mixin[:name] == "ActiveSupport::Concern" && Array(mixin[:owner]).join("::") == name }
        concern ? :concern : :module
      end

      # [the constant `Widget.include(M)` names where it is written, its file or nil].
      def receiver_file(root, receiver, nesting)
        ConcernPaths.reach(root, receiver, nesting) { |candidate| ConcernPaths.declared(root, candidate) } || [ receiver.delete_prefix("::"), nil ]
      end

      def kind_in_file(path, name)
        source = SafeFile.read(path)
        source ? kind(source, mixins_of(source), name) : :class
      end

      # The name asked about the written one means, or nil when the nearest
      # candidate the app declares is some other module.
      def resolve(root, written, nesting, known)
        found = ConcernPaths.reach(root, written, nesting) { |candidate| known.key?(candidate.downcase) ? candidate : ConcernPaths.declared(root, candidate)&.first }
        found && known[found.downcase]
      end
    end
  end
end
