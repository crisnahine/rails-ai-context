# frozen_string_literal: true

require "spec_helper"

RSpec.describe RailsAiContext::Introspectors::Listeners::ClassDefinitionListener do
  def classes(source)
    RailsAiContext::Introspectors::SourceIntrospector.walk_source(source, {
      classes: described_class
    })[:classes]
  end

  it "reads a class and its superclass" do
    results = classes("class Post < ApplicationRecord; end")

    expect(results.first).to include(name: "Post", superclass: "ApplicationRecord")
  end

  it "resolves namespaced names on both sides" do
    results = classes("class Admin::User < Admin::BaseRecord; end")

    expect(results.first).to include(name: "Admin::User", superclass: "Admin::BaseRecord")
  end

  it "resolves a class nested inside a module" do
    results = classes(<<~RUBY)
      module Admin
        class User < ApplicationRecord
        end
      end
    RUBY

    expect(results.first[:name]).to eq("User")
  end

  it "reports nil for a class with no superclass" do
    expect(classes("class Plain; end").first[:superclass]).to be_nil
  end

  it "reports nil for a computed superclass" do
    results = classes("class Point < Struct.new(:x, :y); end")

    expect(results.first).to include(name: "Point", superclass: nil)
  end

  it "returns every class in source order with its line" do
    results = classes(<<~RUBY)
      class First < ApplicationRecord
      end

      class Second < First
      end
    RUBY

    expect(results.map { |c| [ c[:name], c[:location] ] }).to eq([ [ "First", 1 ], [ "Second", 4 ] ])
  end

  it "ignores singleton class bodies" do
    results = classes(<<~RUBY)
      class Post < ApplicationRecord
        class << self
          def scope_names = []
        end
      end
    RUBY

    expect(results.map { |c| c[:name] }).to eq([ "Post" ])
  end
end
