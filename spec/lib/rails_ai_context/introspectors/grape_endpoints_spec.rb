# frozen_string_literal: true

require "spec_helper"
require "tmpdir"
require "fileutils"

RSpec.describe RailsAiContext::Introspectors::GrapeEndpoints do
  around do |example|
    Dir.mktmpdir("grape") do |dir|
      @root = File.realpath(dir)
      example.run
    end
  end

  def write(relative, body)
    path = File.join(@root, relative)
    FileUtils.mkdir_p(File.dirname(path))
    File.binwrite(path, body)
  end

  def endpoints(mounts)
    described_class.call(@root, mounts).transform_values { |list| list.map { |e| described_class.line(e) } }
  end

  it "reads the endpoints of a Grape API mounted in the routes, under its prefix, version and namespaces" do
    write("app/api/v1/users.rb", <<~RUBY)
      module V1
        class Users < Grape::API
          version "v1", using: :path
          format :json

          resource :users do
            params { requires :id, type: Integer }
            get(":id") { { id: params[:id] } }
            post { { ok: true } }
          end
        end
      end
    RUBY

    expect(endpoints([ { engine: "V1::Users", path: "/api" } ])).to eq(
      "V1::Users" => [ "`GET` `/api/v1/users/:id` - params: id (Integer, required)", "`POST` `/api/v1/users`" ]
    )
  end

  it "follows a Grape mount, a prefix, route_param and a base class of the app's own" do
    write("app/api/base.rb", "class Base < Grape::API::Instance\nend\n")
    write("app/api/root.rb", <<~RUBY)
      class Root < Grape::API
        prefix :api
        version "v2", using: :header, vendor: "acme"
        mount Posts
        mount Root
      end
    RUBY
    write("app/api/posts.rb", <<~RUBY)
      class Posts < Base
        namespace :posts do
          route_param :id, type: Integer do
            params do
              optional :full, type: Boolean
            end
            get { Http.get("x") }
          end
        end
      end
    RUBY

    expect(endpoints([ { engine: "Root", path: "/" } ])).to eq(
      "Root" => [ "`GET` `/api/posts/:id` - params: id (Integer, required), full (Boolean)" ]
    )
  end

  it "answers nothing for a mount that is not a Grape API, an empty or unparsable file, and no api dir" do
    expect(described_class.call(@root, [ { engine: "Sidekiq::Web", path: "/sidekiq" } ])).to eq({})

    write("app/api/empty.rb", "")
    write("app/api/broken.rb", "class Broken < Grape::API\n  get do\n")
    write("lib/api/latin.rb", "# encoding: binary\nclass Latin < Grape::API\n  get(\"\xE9\") { }\nend\n".b)

    expect(described_class.call(@root, [ { engine: "Sidekiq::Web", path: "/sidekiq" }, { engine: nil, path: nil } ])).to eq({})
    expect(endpoints([ { engine: "Broken", path: "/b" }, { engine: "Latin", path: nil } ]).keys).to all(be_a(String))
  end
end
