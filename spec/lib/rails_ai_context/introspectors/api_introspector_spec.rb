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
        expect(result[:rate_limiting]).to eq({ rack_attack: true, file: "config/initializers/rack_attack.rb" })
      end
    end

    context "with a rack-attack initializer spelled with a hyphen and a load-order prefix" do
      let(:init_path) { File.join(Rails.root, "config/initializers/009-rack-attack.rb") }

      before do
        FileUtils.mkdir_p(File.dirname(init_path))
        File.write(init_path, "# Rack::Attack config")
      end

      after { FileUtils.rm_f(init_path) }

      it "detects it and names the file the app has" do
        expect(result[:rate_limiting]).to eq({ rack_attack: true, file: "config/initializers/009-rack-attack.rb" })
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

    context "with a serializer layer inside an in-repo engine" do
      let(:engine_dir) { File.join(Rails.root, "engines/billing/app/services/serializers") }

      before do
        FileUtils.mkdir_p(engine_dir)
        File.write(File.join(engine_dir, "invoice_serializer.rb"), "class InvoiceSerializer; end\n")
      end

      after { FileUtils.rm_rf(File.join(Rails.root, "engines")) }

      it "names it the way it names the app's own" do
        expect(result[:serializers][:serializer_dirs])
          .to include({ path: "engines/billing/app/services/serializers", files: 1 })
      end
    end

    context "with an ActiveRecord coder under app/models/serializers" do
      let(:coder_dir) { File.join(Rails.root, "app/models/serializers") }

      before do
        FileUtils.mkdir_p(coder_dir)
        File.write(File.join(coder_dir, "indifferent_hash_serializer.rb"), <<~RUBY)
          module Serializers
            module IndifferentHashSerializer
              module_function

              def dump(hash) = hash

              def load(value) = value.to_h.with_indifferent_access
            end
          end
        RUBY
      end

      after { FileUtils.rm_rf(coder_dir) }

      it "does not call it a serializer layer" do
        expect(result[:serializers][:serializer_dirs]).to be_nil
      end
    end

    context "with a Grape API under lib/api" do
      let(:grape_dir) { File.join(Rails.root, "lib/api/v3/work_packages") }

      before do
        FileUtils.mkdir_p(grape_dir)
        File.write(File.join(grape_dir, "api.rb"), "module API; module V3; class WorkPackagesAPI < ::API::OpenProjectAPI; end; end; end\n")
      end

      after { FileUtils.rm_rf(File.join(Rails.root, "lib/api")) }

      it "reports the version and the directory it came from" do
        expect(result[:api_versioning]).to include("v3")
        expect(result[:api_versioning_dirs]).to include("lib/api/v3")
      end
    end

    context "with a GraphQL schema whose query fields come from a macro" do
      let(:graphql_dir) { File.join(Rails.root, "app/graphql") }

      before do
        FileUtils.mkdir_p(File.join(graphql_dir, "types"))
        FileUtils.mkdir_p(File.join(graphql_dir, "mutations"))
        File.write(File.join(graphql_dir, "types/base_object.rb"), "module Types; class BaseObject; end; end\n")
        File.write(File.join(graphql_dir, "types/user_type.rb"), "module Types; class UserType < BaseObject; end; end\n")
        File.write(File.join(graphql_dir, "mutations/base_mutation.rb"),
                   "module Mutations; class BaseMutation < GraphQL::Schema::RelayClassicMutation; end; end\n")
        File.write(File.join(graphql_dir, "types/query_type.rb"), <<~RUBY)
          module Types
            class QueryType < Types::BaseObject
              collection_and_object_by_id_fields :user, Types::UserType
            end
          end
        RUBY
      end

      after { FileUtils.rm_rf(graphql_dir) }

      it "counts a concrete type that subclasses graphql-ruby directly" do
        File.write(File.join(graphql_dir, "types/speed_grader_settings_type.rb"),
                   "module Types; class SpeedGraderSettingsType < GraphQL::Schema::Object; end; end\n")

        expect(result[:graphql][:types]).to eq(3)
      end

      it "counts a type whose file also declares a graphql-ruby loader" do
        File.write(File.join(graphql_dir, "types/learning_outcome_type.rb"), <<~RUBY)
          module Types
            class LearningOutcomeType < Types::BaseObject
              class AssessedLoader < GraphQL::Batch::Loader
              end
            end
          end
        RUBY

        expect(result[:graphql][:types]).to eq(3)
      end

      it "counts a type that names itself in the schema even when something inherits it" do
        File.write(File.join(graphql_dir, "types/assignment_type.rb"), <<~RUBY)
          module Types
            class AssignmentType < Types::BaseObject
              graphql_name "Assignment"
            end
          end
        RUBY
        File.write(File.join(graphql_dir, "types/quiz_assignment_type.rb"),
                   "module Types; class QuizAssignmentType < Types::AssignmentType; end; end\n")

        expect(result[:graphql][:types]).to eq(4)
      end

      it "counts a Base-named graphql-ruby subclass that puts values in the schema" do
        File.write(File.join(graphql_dir, "types/base_currency_type.rb"), <<~RUBY)
          module Types
            class BaseCurrencyType < GraphQL::Schema::Enum
              value "USD"
              value "EUR"
            end
          end
        RUBY

        expect(result[:graphql][:types]).to eq(3)
      end

      it "leaves out a base that puts nothing in the schema, inherited or not" do
        File.write(File.join(graphql_dir, "types/base_scalar.rb"),
                   "module Types; class BaseScalar < GraphQL::Schema::Scalar; end; end\n")

        expect(result[:graphql][:types]).to eq(2)
      end

      it "counts a type whose name starts with Base but which nothing inherits from" do
        File.write(File.join(graphql_dir, "types/base_currency_type.rb"),
                   "module Types; class BaseCurrencyType < Types::BaseObject; end; end\n")

        expect(result[:graphql][:types]).to eq(3)
      end

      it "leaves out the base classes and says the query fields are not countable" do
        graphql = result[:graphql]

        expect(graphql[:types]).to eq(2)
        expect(graphql[:mutations]).to eq(0)
        expect(graphql).not_to have_key(:queries)
        expect(graphql[:query_root]).to eq(
          { file: "app/graphql/types/query_type.rb", fields: 0, macro_declared: true }
        )
      end
    end

    describe "cors_config" do
      context "with an if/elsif/else chain of origins" do
        let(:cors_path) { File.join(Rails.root, "config/initializers/cors.rb") }

        before do
          FileUtils.mkdir_p(File.dirname(cors_path))
          File.write(cors_path, <<~RUBY)
            Rails.application.config.middleware.insert_before 0, Rack::Cors do
              allow do
                if Rails.env.production?
                  origins "https://app.example.com"
                elsif Rails.env.staging?
                  origins "https://staging.example.com"
                else
                  origins "*"
                end
                resource "*"
              end
            end
          RUBY
        end

        after { FileUtils.rm_f(cors_path) }

        it "gives each branch its own condition and marks the last as otherwise" do
          expect(result[:cors_config][:allows].first[:origins]).to eq([
            { value: "https://app.example.com", condition: "Rails.env.production?" },
            { value: "https://staging.example.com", condition: "Rails.env.staging?" },
            { value: "*", otherwise: true }
          ])
        end
      end

      it "returns nil when no cors initializer exists" do
        expect(result[:cors_config]).to be_nil
      end

      context "with the allow block commented out and no gem named" do
        let(:cors_path) { File.join(Rails.root, "config/initializers/cors.rb") }

        before do
          FileUtils.mkdir_p(File.dirname(cors_path))
          File.write(cors_path, <<~RUBY)
            # allow do
            #   origins "example.com"
            #   resource "*", headers: :any
            # end
          RUBY
        end

        after { FileUtils.rm_f(cors_path) }

        it "reads it as a CORS config with nothing active in it" do
          expect(result[:cors_config]).to eq(
            { file: "config/initializers/cors.rb", origins: [], allows: [], commented_out: true }
          )
        end
      end

      context "with an initializer whose name matches but configures no CORS" do
        let(:cors_path) { File.join(Rails.root, "config/initializers/legacy_cors.rb") }

        before do
          FileUtils.mkdir_p(File.dirname(cors_path))
          File.write(cors_path, "Rails.application.config.x.legacy_cors_reporting = true\n")
        end

        after { FileUtils.rm_f(cors_path) }

        it "is not a CORS config" do
          expect(result[:cors_config]).to be_nil
        end
      end

      context "with an initializer that defines its own CORS middleware" do
        let(:cors_path) { File.join(Rails.root, "config/initializers/008-rack-cors.rb") }

        before do
          FileUtils.mkdir_p(File.dirname(cors_path))
          File.write(cors_path, <<~RUBY)
            class Discourse::Cors
              def call(env)
              end
            end

            Rails.configuration.middleware.insert_before ActionDispatch::Flash, Discourse::Cors
          RUBY
        end

        after { FileUtils.rm_f(cors_path) }

        it "names the file and the middleware it inserts" do
          cors = result[:cors_config]

          expect(cors[:file]).to eq("config/initializers/008-rack-cors.rb")
          expect(cors[:allows]).to eq([])
          expect(cors[:inserts]).to eq([ "Discourse::Cors" ])
        end
      end

      context "with the generated initializer left commented out" do
        let(:cors_path) { File.join(Rails.root, "config/initializers/cors.rb") }

        before do
          FileUtils.mkdir_p(File.dirname(cors_path))
          File.write(cors_path, "# Rails.application.config.middleware.insert_before 0, Rack::Cors do\n#   allow do\n#   end\n# end\n")
        end

        after { FileUtils.rm_f(cors_path) }

        it "says the file is there with nothing active in it" do
          cors = result[:cors_config]

          expect(cors[:file]).to eq("config/initializers/cors.rb")
          expect(cors[:commented_out]).to be true
        end
      end

      context "with an origins block that filters before echoing" do
        let(:cors_path) { File.join(Rails.root, "config/initializers/cors.rb") }

        before do
          FileUtils.mkdir_p(File.dirname(cors_path))
          File.write(cors_path, <<~RUBY)
            Rails.application.config.middleware.insert_before 0, Rack::Cors do
              allow do
                origins do |source, env|
                  next false unless Allowlist.allows?(env)

                  source
                end

                resource "/api/*"
              end
            end
          RUBY
        end

        after { FileUtils.rm_f(cors_path) }

        it "does not call it an echo of every origin" do
          origin = result[:cors_config][:allows].first[:origins].first

          expect(origin[:computed]).to be true
          expect(origin[:echoes_request_origin]).to be false
        end
      end

      context "with the initializer named after the gem" do
        let(:cors_path) { File.join(Rails.root, "config/initializers/rack-cors.rb") }

        before do
          FileUtils.mkdir_p(File.dirname(cors_path))
          File.write(cors_path, <<~RUBY)
            Rails.application.config.middleware.insert_after Rails::Rack::Logger, Rack::Cors do
              allow do
                origins "example.com"
                resource "/api/v3*"
              end
            end
          RUBY
        end

        after { FileUtils.rm_f(cors_path) }

        it "reads it under the name the app gives it" do
          expect(result[:cors_config][:file]).to eq("config/initializers/rack-cors.rb")
        end
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

      # One flat list read as though every origin, `*` included, reached
      # every resource, in every environment.
      context "with several allow blocks and an environment branch" do
        let(:cors_path) { File.join(Rails.root, "config/initializers/cors.rb") }

        before do
          FileUtils.mkdir_p(File.dirname(cors_path))
          File.write(cors_path, <<~RUBY)
            Rails.application.config.middleware.insert_before 0, Rack::Cors do
              allow do
                if Rails.env.production?
                  origins 'https://app.example.com'
                else
                  origins '*'
                end
                resource '*', headers: :any, methods: %i[get post]
              end

              allow do
                origins '*'
                resource '/api/v1/public/items', headers: :any, methods: %i[get]
              end
            end
          RUBY
        end

        after { FileUtils.rm_f(cors_path) }

        it "keeps each allow block's resources and its origins together" do
          allows = result[:cors_config][:allows]

          expect(allows.size).to eq(2)
          expect(allows.first[:resources]).to eq([ "*" ])
          expect(allows.first[:origins]).to contain_exactly(
            { value: "https://app.example.com", condition: "Rails.env.production?" },
            { value: "*", otherwise: true }
          )
          expect(allows.last[:resources]).to eq([ "/api/v1/public/items" ])
          expect(allows.last[:origins]).to eq([ { value: "*" } ])
        end
      end
    end

    context "with origins computed rather than listed" do
      let(:cors_path) { File.join(Rails.root, "config/initializers/cors.rb") }

      before do
        FileUtils.mkdir_p(File.dirname(cors_path))
        File.write(cors_path, <<~RUBY)
          Rails.application.config.middleware.insert_before(0, Rack::Cors) do
            allow do
              origins do |source, _env|
                source
              end

              resource "/openapi.yml"

              %w[articles comments].each do |name|
                resource "/api/\#{name}/*"
              end
            end

            allow do
              origins ENV["EXTRA_ORIGINS"].to_s.split(",")
              resource "/api/articles/*"
            end
          end
        RUBY
      end

      after { FileUtils.rm_f(cors_path) }

      it "reports the config and says the origins are computed" do
        cors = result[:cors_config]

        expect(cors[:file]).to eq("config/initializers/cors.rb")
        expect(cors[:allows].first[:resources]).to eq([ "/openapi.yml", "\"/api/\#{name}/*\"" ])
        expect(cors[:allows].first[:origins])
          .to eq([ { value: "a block", computed: true, echoes_request_origin: true } ])
        expect(cors[:allows].last[:origins])
          .to eq([ { value: "ENV[\"EXTRA_ORIGINS\"].to_s.split(\",\")", computed: true } ])
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

    # The scan reads every serializer root, so a class a pack has taken over
    # from the app is two files answering one name. The list is of classes,
    # not of files.
    it "names a class two serializer roots both hold once" do
      Dir.mktmpdir do |root|
        FileUtils.mkdir_p(File.join(root, "app/serializers"))
        FileUtils.mkdir_p(File.join(root, "packs/billing/app/serializers"))
        File.write(File.join(root, "app/serializers/invoice_serializer.rb"), "class InvoiceSerializer\nend\n")
        File.write(File.join(root, "packs/billing/app/serializers/invoice_serializer.rb"),
                   "class InvoiceSerializer\nend\n")

        static = described_class.new(RailsAiContext::StaticApp.new(root)).static_call
        expect(static[:serializers][:serializer_classes]).to eq([ "InvoiceSerializer" ])
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

    def static_serializers(files)
      Dir.mktmpdir do |root|
        files.each do |relative, content|
          FileUtils.mkdir_p(File.dirname(File.join(root, relative)))
          File.write(File.join(root, relative), content)
        end
        return described_class.new(RailsAiContext::StaticApp.new(root)).static_call[:serializers]
      end
    end

    it "reads Blueprinter blueprints, Alba resources and RABL templates as the serialization layer" do
      serializers = static_serializers(
        "app/blueprints/account_blueprint.rb" => "class AccountBlueprint < Blueprinter::Base\n  identifier :id\n  fields :email\nend\n",
        "app/resources/account_resource.rb" => "class AccountResource\n  include Alba::Resource\n  attributes :id, :email\nend\n",
        "app/resources/admin_resource.rb" => "class AdminResource < AccountResource\nend\n",
        "app/resources/plain.rb" => "class Plain\nend\n",
        "app/views/accounts/show.json.rabl" => "object @account\nattributes :id, :email\n"
      )

      expect(serializers[:serializer_classes]).to eq(%w[AccountBlueprint AccountResource AdminResource])
      expect(serializers[:rabl]).to eq(1)
    end

    it "does not count an Active Job argument serializer as a response serializer" do
      serializers = static_serializers(
        "app/serializers/money_serializer.rb" => <<~RUBY,
          class MoneySerializer < ActiveJob::Serializers::ObjectSerializer
            def serialize(money) = super("cents" => money.cents)
            def deserialize(hash) = hash["cents"]
            def klass = Integer
          end
        RUBY
        "app/serializers/post_serializer.rb" => "class PostSerializer < ActiveModel::Serializer\nend\n"
      )

      expect(serializers[:serializer_classes]).to eq(%w[PostSerializer])
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
