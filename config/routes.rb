# frozen_string_literal: true

RailsAiContext::Engine.routes.draw do
  # The class, not "rails_ai_context/mcp", which the router camelizes with the app's inflections.
  match "/", to: RailsAiContext::McpController.action(:handle), via: :all
end
