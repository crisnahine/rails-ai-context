# frozen_string_literal: true

# Before Rails 8.0 every engine's routes are drawn at boot, and an app that never loads Action Controller has no base for the endpoint.
if defined?(ActionController::API)
  RailsAiContext::Engine.routes.draw do
    # The class, not "rails_ai_context/mcp", which the router camelizes with the app's inflections.
    match "/", to: RailsAiContext::McpController.action(:handle), via: :all
  end
end
