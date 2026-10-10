# frozen_string_literal: true

module RailsAiContext
  module Serializers
    # The names the tool guide's examples call tools with. They sit beside
    # "never reference a name you have not verified", so each is one the app
    # has - its most connected model, a controller, view and partial of its
    # own - or a placeholder no app has. A Post example in an app of Authors
    # and Books read as this project's workflow.
    class GuideExamples
      MODEL = "YourModel"
      CONTROLLER = "YourModelsController"
      PARTIAL = "shared/your_partial"
      COMPONENT = "YourComponent"
      METHOD = "your_method"

      def initialize(context)
        @context = context.is_a?(Hash) ? context : {}
      end

      def model
        model_entry&.first || MODEL
      end

      def model_file
        model_entry ? Payload.model_file(@context, model) : "app/models/#{MODEL.underscore}.rb"
      end

      def table
        model_entry&.last&.dig(:table_name) || model.tableize.tr("/", "_")
      end

      # The word a feature search starts from: the model's own name.
      def feature
        model.demodulize.underscore
      end

      # A method the model's source defines, so a trace finds its definition.
      def method_name
        data = model_entry&.last || {}
        names = Array(data[:source_instance_methods]).map(&:to_s).reject { |m| m.end_with?("=") }
        names += Array(data[:scopes]).map { |s| (s.is_a?(Hash) ? s[:name] : s).to_s }
        names.first || METHOD
      end

      def controller
        controller_entry&.first || CONTROLLER
      end

      def action
        actions = Array(controller_entry&.last&.dig(:actions)).map { |a| a.is_a?(Hash) ? a[:name].to_s : a.to_s }
        actions.include?("create") ? "create" : actions.first || "create"
      end

      def controller_file
        file = Payload.controller_file(@context, controller) if controller_entry
        file || "app/controllers/#{controller.underscore}.rb"
      end

      # The route key of a controller that renders templates, which is what
      # rails_get_view takes.
      def view_controller
        view_entry&.first || CONTROLLER.underscore.delete_suffix("_controller")
      end

      def view_file
        key, templates = view_entry
        return "app/views/#{view_controller}/index.html.erb" unless key

        template = templates.find { |t| t.start_with?("index.") && t.end_with?(".erb") } ||
          templates.find { |t| t.end_with?(".erb") } || templates.first
        "app/views/#{key}/#{template}"
      end

      # As rails_get_partial_interface takes it: "posts/form" for app/views/posts/_form.html.erb.
      def partial
        partials = Payload.section(@context, :views)&.dig(:partials)
        return PARTIAL unless partials.is_a?(Hash)

        per_controller = partials[:per_controller].is_a?(Hash) ? partials[:per_controller] : {}
        own = Array(per_controller[view_controller]).first
        return partial_name(view_controller, own) if own

        shared = Array(partials[:shared]).first
        return partial_name("shared", shared) if shared

        key, files = per_controller.find { |_, list| Array(list).any? }
        key ? partial_name(key, Array(files).first) : PARTIAL
      end

      def component
        components = Payload.section(@context, :components)&.dig(:components)
        name = Array(components).find { |c| c.is_a?(Hash) && c[:name] }&.dig(:name)
        name || COMPONENT
      end

      private

      # The most connected model whose file the walk read and the app owns:
      # a gem's model is no file an example should send the reader to.
      def model_entry
        return @model_entry if defined?(@model_entry)

        models = Payload.models(@context)
        name = Payload.models_by_connection(models).find do |candidate|
          data = models[candidate]
          data.is_a?(Hash) && !data[:error] && !data[:file].to_s.start_with?("gem:")
        end
        @model_entry = name && [ name.to_s, models[name] ]
      end

      # The model's own controller when the app has one, else the first that
      # declares an action.
      def controller_entry
        return @controller_entry if defined?(@controller_entry)

        controllers = Payload.app_controllers(@context).select { |_, info| info.is_a?(Hash) && !info[:error] }
        own = "#{model.pluralize}Controller" if model_entry
        name = controllers.key?(own) ? own : controllers.keys.sort.find { |key| Array(controllers[key][:actions]).any? }
        @controller_entry = name && [ name, controllers[name] ]
      end

      # [route key, templates] for the example controller when it renders
      # any, else for the first controller of the app's that does.
      def view_entry
        return @view_entry if defined?(@view_entry)

        templates = Payload.section(@context, :views)&.dig(:templates)
        templates = templates.is_a?(Hash) ? templates.transform_keys(&:to_s) : {}
        own = Payload.controller_route_key(@context, controller) if controller_entry
        key = own if own && Array(templates[own]).any?
        key ||= templates.keys.sort.find { |k| Array(templates[k]).any? && Payload.controller_for_route_key(@context, k) }
        @view_entry = key && [ key, Array(templates[key]).map(&:to_s) ]
      end

      def partial_name(dir, file)
        "#{dir}/#{File.basename(file.to_s).delete_prefix('_').split('.').first}"
      end
    end
  end
end
