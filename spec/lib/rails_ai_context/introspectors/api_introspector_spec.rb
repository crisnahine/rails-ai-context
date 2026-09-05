# frozen_string_literal: true

require "spec_helper"
require "tmpdir"

RSpec.describe RailsAiContext::Introspectors::ApiIntrospector do
  let(:introspector) { described_class.new(Rails.application) }

  describe "#call" do
    subject(:result) { introspector.call }

    it "does not return an error" do
      expect(result).not_to have_key(:error)
    end

    it "returns api_only as false for standard app" do
      expect(result[:api_only]).to be false
    end

    it "returns serializers as a hash" do
      expect(result[:serializers]).to be_a(Hash)
    end

    it "returns api versioning array" do
      expect(result[:api_versioning]).to be_an(Array)
    end

    it "returns rate limiting as empty hash when no rate limiting" do
      expect(result[:rate_limiting]).to be_a(Hash)
    end

    it "detects v1 API versioning from directory structure" do
      expect(result[:api_versioning]).to include("v1")
    end

    it "returns nil for graphql when no app/graphql dir" do
      expect(result[:graphql]).to be_nil
    end

    context "with a serializer directory" do
      let(:serializers_dir) { File.join(Rails.root, "app/serializers") }
      let(:serializer_file) { File.join(serializers_dir, "post_serializer.rb") }

      before do
        FileUtils.mkdir_p(serializers_dir)
        File.write(serializer_file, <<~RUBY)
          class PostSerializer
            def call(post)
              { id: post.id, title: post.title }
            end
          end
        RUBY
      end

      after { FileUtils.rm_rf(serializers_dir) }

      it "detects serializer classes" do
        expect(result[:serializers][:serializer_classes]).to include("PostSerializer")
      end
    end

    context "with rack-attack initializer" do
      let(:init_path) { File.join(Rails.root, "config/initializers/rack_attack.rb") }

      before do
        FileUtils.mkdir_p(File.dirname(init_path))
        File.write(init_path, "# Rack::Attack config")
      end

      after { FileUtils.rm_f(init_path) }

      it "detects rack_attack rate limiting" do
        expect(result[:rate_limiting]).to eq({ rack_attack: true })
      end
    end

    describe "openapi_spec" do
      it "returns an empty array when no spec files exist" do
        expect(result[:openapi_spec]).to eq([])
      end

      context "with OpenAPI spec files" do
        let(:openapi_dir) { File.join(Rails.root, "openapi") }
        let(:swagger_dir) { File.join(Rails.root, "swagger") }
        let(:docs_dir) { File.join(Rails.root, "docs") }

        before do
          FileUtils.mkdir_p(openapi_dir)
          FileUtils.mkdir_p(File.join(swagger_dir, "v2"))
          FileUtils.mkdir_p(docs_dir)
          File.write(File.join(openapi_dir, "v1.yaml"), "openapi: 3.0.0")
          File.write(File.join(swagger_dir, "v2", "api.json"), "{}")
          File.write(File.join(docs_dir, "schema.yml"), "---")
        end

        after do
          FileUtils.rm_rf(openapi_dir)
          FileUtils.rm_rf(swagger_dir)
          FileUtils.rm_rf(docs_dir)
        end

        it "detects OpenAPI spec files across all search paths" do
          specs = result[:openapi_spec]
          expect(specs).to include("openapi/v1.yaml")
          expect(specs).to include("swagger/v2/api.json")
          expect(specs).to include("docs/schema.yml")
        end
      end
    end

    describe "cors_config" do
      it "returns nil when no cors initializer exists" do
        expect(result[:cors_config]).to be_nil
      end

      context "with cors initializer" do
        let(:cors_path) { File.join(Rails.root, "config/initializers/cors.rb") }

        before do
          FileUtils.mkdir_p(File.dirname(cors_path))
          File.write(cors_path, <<~RUBY)
            Rails.application.config.middleware.insert_before 0, Rack::Cors do
              allow do
                origins "localhost:3000", "example.com"
                resource "*", headers: :any, methods: [:get, :post]
              end
            end
          RUBY
        end

        after { FileUtils.rm_f(cors_path) }

        it "detects CORS config with origins" do
          cors = result[:cors_config]
          expect(cors[:file]).to eq("config/initializers/cors.rb")
          expect(cors[:origins]).to include("localhost:3000", "example.com")
        end
      end
    end

    describe "api_client_generation" do
      it "detects codegen tools from permanent package.json fixture" do
        # Permanent package.json has openapi-typescript, @graphql-codegen/cli, orval
        expect(result[:api_client_generation]).to include("openapi-typescript", "@graphql-codegen/cli", "orval")
      end

      context "with codegen tools in package.json" do
        let(:package_path) { File.join(Rails.root, "package.json") }
        let!(:original_content) { File.read(package_path) }

        before do
          File.write(package_path, <<~JSON)
            {
              "dependencies": {
                "openapi-typescript": "^6.0.0",
                "@graphql-codegen/cli": "^5.0.0"
              },
              "devDependencies": {
                "orval": "^6.0.0"
              }
            }
          JSON
        end

        after { File.write(package_path, original_content) }

        it "detects API client generation tools" do
          tools = result[:api_client_generation]
          expect(tools).to include("openapi-typescript", "@graphql-codegen/cli", "orval")
        end
      end
    end
  end

  describe "#detect_pagination" do
    around { |example| Dir.mktmpdir { |dir| @root = dir; example.run } }

    def pagination_for(lock)
      File.write(File.join(@root, "Gemfile.lock"), lock)
      described_class.new(double("app", root: @root)).send(:detect_pagination)
    end

    it "sees pagy in the GIT section" do
      lock = <<~LOCK
        GIT
          remote: https://github.com/ddnexus/pagy.git
          revision: 0123456789abcdef0123456789abcdef01234567
          specs:
            pagy (9.3.3)
      LOCK
      expect(pagination_for(lock)).to eq([ "pagy" ])
    end

    it "does not report kaminari for kaminari-actionview alone" do
      lock = <<~LOCK
        GEM
          remote: https://rubygems.org/
          specs:
            kaminari-actionview (1.2.2)
      LOCK
      expect(pagination_for(lock)).to be_nil
    end
  end

  # Everything a pack contributes is read off disk, so a tmpdir app answers
  # these the way the booted one does, without writing into the dummy app.
  describe "a pack" do
    def in_app_with_pack
      Dir.mktmpdir do |root|
        FileUtils.mkdir_p(File.join(root, "app/controllers/api/v1"))
        File.write(File.join(root, "app/controllers/api/v1/posts_controller.rb"),
          "class Api::V1::PostsController < ApplicationController\nend\n")
        yield root
      end
    end

    it "sees a pack's API version and its rate limiting" do
      in_app_with_pack do |root|
        pack = File.join(root, "packs/billing/app/controllers/api/v2")
        FileUtils.mkdir_p(pack)
        File.write(File.join(pack, "invoices_controller.rb"), <<~RUBY)
          class Api::V2::InvoicesController < ApplicationController
            rate_limit to: 10, within: 1.minute
          end
        RUBY

        result = described_class.new(RailsAiContext::StaticApp.new(root)).static_call

        expect(result[:api_versioning]).to include("v1", "v2")
        expect(result[:rate_limiting]).to eq({ rails_rate_limiting: true })
      end
    end

    it "counts a pack's serializers and jbuilder templates" do
      in_app_with_pack do |root|
        pack = File.join(root, "packs/billing/app")
        FileUtils.mkdir_p(File.join(pack, "serializers"))
        FileUtils.mkdir_p(File.join(pack, "views/invoices"))
        File.write(File.join(pack, "serializers/invoice_serializer.rb"), "class InvoiceSerializer\nend\n")
        File.write(File.join(pack, "views/invoices/show.json.jbuilder"), "json.id @invoice.id\n")

        result = described_class.new(RailsAiContext::StaticApp.new(root)).static_call

        expect(result[:serializers][:serializer_classes]).to include("InvoiceSerializer")
        expect(result[:serializers][:jbuilder]).to eq(1)
      end
    end
  end

  describe "#static_call" do
    it "names serializers by the constant they declare, not by camelizing the path" do
      Dir.mktmpdir do |root|
        FileUtils.mkdir_p(File.join(root, "app/serializers/activitypub"))
        File.write(File.join(root, "app/serializers/activitypub/x_serializer.rb"), <<~RUBY)
          class ActivityPub::XSerializer
          end
        RUBY

        static = described_class.new(RailsAiContext::StaticApp.new(root)).static_call
        expect(static[:serializers][:serializer_classes]).to eq([ "ActivityPub::XSerializer" ])
      end
    end

    it "keeps a serializer file that declares no class, under the name its path spells" do
      Dir.mktmpdir do |root|
        FileUtils.mkdir_p(File.join(root, "app/serializers"))
        File.write(File.join(root, "app/serializers/shared_fields.rb"), "module Serializers::Shared\nend\n")
        File.write(File.join(root, "app/serializers/post_serializer.rb"), "class PostSerializer\nend\n")

        static = described_class.new(RailsAiContext::StaticApp.new(root)).static_call
        expect(static[:serializers][:serializer_classes]).to eq([ "PostSerializer", "SharedFields" ])
      end
    end

    it "answers every key the booted tier answers, since only the mode needs a runtime" do
      static = described_class.new(RailsAiContext::StaticApp.new(Rails.root.to_s)).static_call
      booted = described_class.new(Rails.application).call

      expect(static.keys).to match_array(booted.keys)
      expect(static).not_to have_key(:unavailable_sections)
    end

    it "reads the versions, serializers and rate limiting from source" do
      static = described_class.new(RailsAiContext::StaticApp.new(Rails.root.to_s)).static_call
      booted = described_class.new(Rails.application).call

      expect(static[:api_versioning]).to eq(booted[:api_versioning])
      expect(static[:serializers]).to eq(booted[:serializers])
      expect(static[:rate_limiting]).to eq(booted[:rate_limiting])
    end
  end
end
