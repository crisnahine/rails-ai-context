# frozen_string_literal: true

RailsAiContext::Engine.routes.draw do
  match "/", to: "mcp#handle", via: :all
end
