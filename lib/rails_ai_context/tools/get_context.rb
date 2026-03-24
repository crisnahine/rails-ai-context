# frozen_string_literal: true

module RailsAiContext
  module Tools
    class GetContext < BaseTool
      tool_name "rails_get_context"
      description "Get cross-layer context in a single call — combines schema, model, controller, routes, views, stimulus, and tests. " \
        "Use when: you need full context for implementing a feature or modifying an action. " \
        "Specify controller:\"CooksController\" action:\"create\" to get everything for that action in one call."

      input_schema(
        properties: {
          controller: {
            type: "string",
            description: "Controller name (e.g. 'CooksController'). Returns action source, filters, strong params, routes, views."
          },
          action: {
            type: "string",
            description: "Specific action name (e.g. 'create'). Requires controller. Returns full action context."
          },
          model: {
            type: "string",
            description: "Model name (e.g. 'Cook'). Returns schema, associations, validations, scopes, callbacks, tests."
          },
          feature: {
            type: "string",
            description: "Feature keyword (e.g. 'cook'). Like analyze_feature but includes schema columns and scope bodies."
          }
        }
      )

      annotations(read_only_hint: true, destructive_hint: false, idempotent_hint: true, open_world_hint: false)

      def self.call(controller: nil, action: nil, model: nil, feature: nil, server_context: nil)
        if controller && action
          return controller_action_context(controller, action)
        elsif controller
          return controller_context(controller)
        elsif model
          return model_context(model)
        elsif feature
          return feature_context(feature)
        end

        text_response("Provide at least one of: controller, model, or feature.")
      end

      private_class_method def self.controller_action_context(controller_name, action_name)
        lines = []

        # Controller + action source + private methods + instance vars
        ctrl_result = GetControllers.call(controller: controller_name, action: action_name)
        lines << ctrl_result.content.first[:text]

        # Infer model from controller
        snake = controller_name.to_s.underscore.delete_suffix("_controller")
        model_name = snake.split("/").last.singularize.camelize

        # Model details
        model_result = GetModelDetails.call(model: model_name)
        model_text = model_result.content.first[:text]
        unless model_text.include?("not found")
          lines << "" << "---" << "" << model_text
        end

        # Routes for this controller
        route_result = GetRoutes.call(controller: snake)
        route_text = route_result.content.first[:text]
        unless route_text.include?("not found") || route_text.include?("No routes")
          lines << "" << "---" << ""
          lines << route_text
        end

        # Views for this controller
        view_ctrl = snake.split("/").last
        view_result = GetView.call(controller: view_ctrl, detail: "standard")
        view_text = view_result.content.first[:text]
        unless view_text.include?("No views")
          lines << "" << "---" << ""
          lines << view_text
        end

        text_response(lines.join("\n"))
      rescue => e
        text_response("Error assembling context: #{e.message}")
      end

      private_class_method def self.controller_context(controller_name)
        lines = []

        ctrl_result = GetControllers.call(controller: controller_name)
        lines << ctrl_result.content.first[:text]

        snake = controller_name.to_s.underscore.delete_suffix("_controller")
        route_result = GetRoutes.call(controller: snake)
        route_text = route_result.content.first[:text]
        unless route_text.include?("not found")
          lines << "" << "---" << "" << route_text
        end

        text_response(lines.join("\n"))
      rescue => e
        text_response("Error assembling context: #{e.message}")
      end

      private_class_method def self.model_context(model_name)
        lines = []

        model_result = GetModelDetails.call(model: model_name)
        lines << model_result.content.first[:text]

        # Schema for the model's table
        ctx = cached_context
        models = ctx[:models] || {}
        key = models.keys.find { |k| k.downcase == model_name.downcase }
        if key && models[key][:table_name]
          schema_result = GetSchema.call(table: models[key][:table_name])
          lines << "" << "---" << "" << schema_result.content.first[:text]
        end

        # Tests for this model
        test_result = GetTestInfo.call(model: model_name, detail: "standard")
        test_text = test_result.content.first[:text]
        unless test_text.include?("No test file found")
          lines << "" << "---" << "" << test_text
        end

        text_response(lines.join("\n"))
      rescue => e
        text_response("Error assembling context: #{e.message}")
      end

      private_class_method def self.feature_context(feature_name)
        # Delegate to analyze_feature which already does full-stack discovery
        AnalyzeFeature.call(feature: feature_name)
      end
    end
  end
end
