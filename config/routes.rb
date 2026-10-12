# frozen_string_literal: true

RailsAiContext::Engine.routes.draw do
  # The controller itself, not "rails_ai_context/mcp": the router would camelize that name
  # with the app's inflections, and an "AI" acronym names a constant that does not exist.
  match "/", to: RailsAiContext::McpController.action(:handle), via: :all
end
