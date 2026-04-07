# frozen_string_literal: true

module RailsAiContext
  module Hydrators
    # Resolves instance variable references in views to model schema hints.
    # Maps @post → Post, @posts → Post (singularized), etc.
    class ViewHydrator
      # Hydrate view instance variables with schema hints.
      # ivar_names: array of instance variable names (without @) used in a view.
      # Returns a HydrationResult with hints for resolved models.
      def self.call(ivar_names, context:)
        return HydrationResult.new if ivar_names.nil? || ivar_names.empty?

        model_names = ivar_names.filter_map { |ivar| ivar_to_model_name(ivar) }.uniq
        return HydrationResult.new if model_names.empty?

        hints = SchemaHintBuilder.build_many(model_names, context: context, max: RailsAiContext.configuration.hydration_max_hints)

        warnings = []
        unresolved = model_names - hints.map(&:model_name)
        unresolved.each do |name|
          warnings << "@#{name.underscore} used in view but '#{name}' model not found"
        end

        HydrationResult.new(hints: hints, warnings: warnings)
      rescue => e
        $stderr.puts "[rails-ai-context] ViewHydrator failed: #{e.message}" if ENV["DEBUG"]
        HydrationResult.new
      end

      # Convert an instance variable name to a model name by convention.
      # @post → "Post", @posts → "Post", @current_user → "User"
      def self.ivar_to_model_name(ivar_name)
        name = ivar_name.to_s
        # Skip framework/common non-model ivars
        return nil if SKIP_IVARS.include?(name)

        # Singularize and classify: "posts" → "Post", "order_items" → "OrderItem"
        name.singularize.camelize
      rescue StandardError
        nil
      end
      private_class_method :ivar_to_model_name

      SKIP_IVARS = %w[
        page per_page total_count total_pages
        query search filter sort order
        flash notice alert errors
        breadcrumbs tabs menu
        title description meta
        current_page pagy
        output_buffer virtual_path _request
      ].to_set.freeze
    end
  end
end
