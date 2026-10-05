# frozen_string_literal: true

require "spec_helper"

RSpec.describe RailsAiContext::Introspectors::Listeners::GrapeApiListener do
  def records(source)
    RailsAiContext::Introspectors::SourceIntrospector.walk_source(source, { grape: described_class })[:grape]
  end

  it "records endpoints with their namespaces and params, and skips calls inside an endpoint body" do
    found = records(<<~RUBY)
      module V1
        class Users < Grape::API
          version "v1", using: :path
          mount Admin => "/admin"
          resource :users do
            params do
              requires :id, type: Integer
              optional :tags, type: Array do
                requires :name
              end
            end
            get(":id") { get "/elsewhere" }
          end
        end
      end
    RUBY

    expect(found).to contain_exactly(
      { kind: :class, owner: "V1::Users", superclass: "Grape::API" },
      { kind: :version, owner: "V1::Users", value: "v1", using: "path" },
      { kind: :mount, owner: "V1::Users", target: "Admin", path: "/admin", namespace: [] },
      { kind: :endpoint, owner: "V1::Users", verb: "GET", path: ":id", namespace: [ "users" ],
        params: [ { name: "id", type: "Integer", required: true }, { name: "tags", type: "Array", required: false } ] }
    )
  end

  it "records nothing outside a class" do
    expect(records("get '/x'\nnamespace(:a) { post }\n")).to eq([])
  end
end
