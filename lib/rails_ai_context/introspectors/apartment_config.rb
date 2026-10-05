# frozen_string_literal: true

module RailsAiContext
  module Introspectors
    # The models an Apartment initializer keeps in the shared schema. Every
    # other ActiveRecord model gets one table per tenant schema.
    module ApartmentConfig
      module_function

      # @return [Hash, nil] { excluded_models: [names], file: } or, for a list the
      #   file computes, { excluded_models_source: text, file: }; nil without Apartment.configure
      def read(root)
        PathResolver.initializer_paths(root).each do |path|
          source = SafeFile.read(path, max_size: RailsAiContext.configuration.max_file_size)
          next unless source&.include?("Apartment.configure")
          # A partial tree would read a cut-off list as no list.
          next if AstCache.parse_string(source).errors.any?

          file = path.delete_prefix("#{root}/")
          listener = -> { Listeners::ConfigAssignmentListener.new(block_param(source)) }
          # `+=`, `<<` or `concat` builds on a list the source does not show whole.
          hit = SourceIntrospector.walk_source(source, { config: listener })[:config]
                                  .reverse.find { |h| list_write?(h) }
          return { excluded_models: [], file: file } unless hit
          return { excluded_models_source: hit[:source], file: file } unless hit[:assignment] && literal_names?(hit[:value])

          return { excluded_models: hit[:value].map { |name| name.delete_prefix("::") }, file: file }
        end
        nil
      rescue StandardError => e
        RailsAiContext.debug_fail(e, nil, label: "ApartmentConfig")
      end

      def block_param(source)
        source[/Apartment\.configure\s*(?:do|\{)\s*\|\s*([a-z_]\w*)\s*\|/, 1] || "config"
      end

      # A block on a read (`.each { }`) leaves the list as it was.
      def list_write?(hit)
        return hit[:path].size == 2 && hit[:path].first == :excluded_models if hit[:write] == :call
        return false if hit[:write] == :block

        hit[:path] == [ :excluded_models ] && (hit[:assignment] || hit[:write] == :operator)
      end

      def literal_names?(value)
        value.is_a?(Array) && value.all?(String) && !value.include?(Confidence::INFERRED)
      end
    end
  end
end
