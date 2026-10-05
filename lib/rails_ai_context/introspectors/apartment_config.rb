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
          hit = SourceIntrospector.walk_source(source, { config: Listeners::ConfigAssignmentListener })[:config]
                                  .reverse.find { |h| h[:assignment] && h[:path] == [ :excluded_models ] }
          return { excluded_models: [], file: file } unless hit
          return { excluded_models_source: hit[:source], file: file } unless hit[:value].is_a?(Array) && hit[:value].all?(String) && !hit[:value].include?(Confidence::INFERRED)

          return { excluded_models: hit[:value].map { |name| name.delete_prefix("::") }, file: file }
        end
        nil
      rescue StandardError => e
        RailsAiContext.debug_fail(e, nil, label: "ApartmentConfig")
      end
    end
  end
end
