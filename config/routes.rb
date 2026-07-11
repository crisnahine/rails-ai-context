# frozen_string_literal: true

RailsAiContext::Engine.routes.draw do
  # The engine is not namespace-isolated, so the controller must be
  # referenced by its full path or Rails resolves a top-level McpController.
  match "/", to: "rails_ai_context/mcp#handle", via: :all
end
