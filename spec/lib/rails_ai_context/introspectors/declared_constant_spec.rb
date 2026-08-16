# frozen_string_literal: true

require "spec_helper"

RSpec.describe RailsAiContext::Introspectors::DeclaredConstant do
  describe ".resolve" do
    it "prefers the constant the source declares over the path" do
      source = "class ActivityPub::CollectionsController < ApplicationController\nend\n"

      expect(described_class.resolve(source, "Activitypub::CollectionsController"))
        .to eq("ActivityPub::CollectionsController")
    end

    it "reads the name through module nesting" do
      source = "module OAuth\n  class TokensController\n  end\nend\n"

      expect(described_class.resolve(source, "Oauth::TokensController")).to eq("OAuth::TokensController")
    end

    # A bare name in a namespaced directory is the shape the path exists for:
    # only the path carries the namespace, so only the path can name the class.
    it "keeps the path name when the source declares fewer segments" do
      source = "class Channel\nend\n"

      expect(described_class.resolve(source, "ApplicationCable::Channel")).to eq("ApplicationCable::Channel")
    end

    it "keeps the path name when the source declares no class" do
      source = "SOME_CONSTANT = 1\n"

      expect(described_class.resolve(source, "Admin::WidgetsController")).to eq("Admin::WidgetsController")
    end

    # Prism recovers from a syntax error into a partial tree, so a half-written
    # file still declares something. Naming the file after it would rename the
    # controller on every reader's screen.
    it "keeps the path name when the declared name is not this file's" do
      source = "class Broken < ApplicationController\n  def index\n" # never closed

      expect(described_class.resolve(source, "BrokenController")).to eq("BrokenController")
    end

    it "keeps the path name when there is no source to read" do
      expect(described_class.resolve(nil, "WidgetsController")).to eq("WidgetsController")
    end

    it "takes the outermost class when one is nested inside another" do
      source = "class PostsController < ApplicationController\n  class Error < StandardError\n  end\nend\n"

      expect(described_class.resolve(source, "PostsController")).to eq("PostsController")
    end
  end
end
