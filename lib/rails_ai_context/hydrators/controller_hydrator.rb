# frozen_string_literal: true

module RailsAiContext
  module Hydrators
    # Parses a controller source file via Prism AST, detects model
    # references, and builds SchemaHint objects for each detected model.
    class ControllerHydrator
      # Hydrate a controller file with schema hints.
      # Returns a HydrationResult with hints for all detected models.
      def self.call(source_path, context:)
        return HydrationResult.new unless source_path && File.exist?(source_path)
        return HydrationResult.new if File.size(source_path) > RailsAiContext.configuration.max_file_size

        model_names = detect_model_references(source_path)
        return HydrationResult.new if model_names.empty?

        hints = SchemaHintBuilder.build_many(model_names, context: context, max: RailsAiContext.configuration.hydration_max_hints)

        warnings = []
        unresolved = model_names - hints.map(&:model_name)
        unresolved.each do |name|
          warnings << "Model '#{name}' referenced but not found in introspection data"
        end

        HydrationResult.new(hints: hints, warnings: warnings)
      rescue => e
        $stderr.puts "[rails-ai-context] ControllerHydrator failed: #{e.message}" if ENV["DEBUG"]
        HydrationResult.new
      end

      # Detect model names referenced in a controller source file using Prism AST.
      def self.detect_model_references(source_path)
        parse_result = AstCache.parse(source_path)
        dispatcher = Prism::Dispatcher.new
        listener = Introspectors::Listeners::ModelReferenceListener.new

        events = []
        events << :on_call_node_enter if listener.respond_to?(:on_call_node_enter)
        events << :on_instance_variable_write_node_enter if listener.respond_to?(:on_instance_variable_write_node_enter)
        dispatcher.register(listener, *events)

        dispatcher.dispatch(parse_result.value)
        listener.results
      rescue => e
        $stderr.puts "[rails-ai-context] detect_model_references failed: #{e.message}" if ENV["DEBUG"]
        []
      end
      private_class_method :detect_model_references
    end
  end
end
