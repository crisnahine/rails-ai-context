# frozen_string_literal: true

require "spec_helper"
require "tmpdir"
require "fileutils"

# Ensure test app models are loaded
require_relative "../../../internal/app/models/application_record"
require_relative "../../../internal/app/models/user"
require_relative "../../../internal/app/models/post"

RSpec.describe RailsAiContext::Introspectors::ModelIntrospector do
  let(:introspector) { described_class.new(Rails.application) }

  describe "#call" do
    subject(:result) { introspector.call }

    it "discovers User and Post models" do
      expect(result).to have_key("User")
      expect(result).to have_key("Post")
    end

    it "extracts User associations" do
      assocs = result["User"][:associations]
      expect(assocs).to include(a_hash_including(name: "posts", type: "has_many"))
    end

    it "extracts Post associations" do
      assocs = result["Post"][:associations]
      expect(assocs).to include(a_hash_including(name: "user", type: "belongs_to"))
    end

    it "filters associations listed in excluded_association_names" do
      RailsAiContext.configuration.excluded_association_names += %w[comments]

      filtered = introspector.call
      user_assoc_names = filtered["User"][:associations].map { |a| a[:name] }
      expect(user_assoc_names).to include("posts")
      expect(user_assoc_names).not_to include("comments")
    ensure
      RailsAiContext.configuration = RailsAiContext::Configuration.new
    end

    it "filters excluded_association_names on the static tier too" do
      RailsAiContext.configuration.excluded_association_names += %w[comments]

      Dir.mktmpdir do |dir|
        FileUtils.mkdir_p(File.join(dir, "app", "models"))
        File.write(File.join(dir, "app", "models", "post.rb"), <<~RUBY)
          class Post < ApplicationRecord
            belongs_to :author
            has_many :comments
          end
        RUBY

        static = described_class.new(RailsAiContext::StaticApp.new(dir)).static_call
        names = static["Post"][:associations].map { |a| a[:name].to_s }
        expect(names).to include("author")
        expect(names).not_to include("comments")
      end
    ensure
      RailsAiContext.configuration = RailsAiContext::Configuration.new
    end

    it "filters excluded_association_names on both tiers of a Mongoid app" do
      RailsAiContext.configuration.excluded_association_names += %w[tickets]

      Dir.mktmpdir do |dir|
        FileUtils.mkdir_p(File.join(dir, "config"))
        FileUtils.mkdir_p(File.join(dir, "app", "models"))
        File.write(File.join(dir, "config", "mongoid.yml"), "development:\n  clients: {}\n")
        File.write(File.join(dir, "app", "models", "customer.rb"), <<~RUBY)
          class Customer
            include Mongoid::Document
            has_many :tickets
            has_many :invoices
          end
        RUBY

        introspector = described_class.new(RailsAiContext::StaticApp.new(dir))
        [ introspector.static_call, introspector.call ].each do |models|
          names = models["Customer"][:associations].map { |a| a[:name].to_s }
          expect(names).to include("invoices")
          expect(names).not_to include("tickets")
        end
      end
    ensure
      RailsAiContext.configuration = RailsAiContext::Configuration.new
    end

    it "extracts validations" do
      vals = result["User"][:validations]
      expect(vals).to include(a_hash_including(kind: "presence", attributes: [ "email" ]))
    end

    it "extracts scopes from source files" do
      user_scope_names = result["User"][:scopes].map { |s| s.is_a?(Hash) ? s[:name] : s }
      post_scope_names = result["Post"][:scopes].map { |s| s.is_a?(Hash) ? s[:name] : s }
      expect(user_scope_names).to include("active", "admins")
      expect(post_scope_names).to include("published", "recent")
    end

    it "extracts enums with values" do
      expect(result["User"][:enums]).to have_key("role")
      expect(result["User"][:enums]["role"]).to be_a(Hash)
      expect(result["User"][:enums]["role"].keys).to contain_exactly("member", "admin")
    end

    it "extracts table names" do
      expect(result["User"][:table_name]).to eq("users")
      expect(result["Post"][:table_name]).to eq("posts")
    end

    it "extracts concerns as array" do
      expect(result["User"][:concerns]).to be_an(Array)
    end

    it "excludes the debug gem's Kernel-prepended module from concerns" do
      # The `debug` gem (default in Rails 7.0+ Gemfiles) prepends this onto
      # Kernel, so every model's ancestors include it even though it's not
      # something the app itself mixed in.
      expect(RailsAiContext::ConcernMembership.payload?("DEBUGGER__::TrapInterceptor")).to be false
      expect(result["User"][:concerns]).not_to include("DEBUGGER__::TrapInterceptor")
    end

    it "extracts class_methods as array" do
      expect(result["User"][:class_methods]).to be_an(Array)
    end

    it "extracts instance_methods as array" do
      expect(result["User"][:instance_methods]).to be_an(Array)
    end
  end

  # Rails names the anonymous join class it builds for a
  # has_and_belongs_to_many through a singleton `name=`, so it answers a name
  # no constant carries: "HABTM_Tags" while it lives at "Account::HABTM_Tags".
  describe "a class that answers a name no constant carries" do
    # Autoloading a model makes Rails walk ActiveRecord::Base.descendants to
    # rebuild callbacks, so the app is loaded before the stub is in place or
    # that walk reaches the doubles.
    let(:loaded) do
      introspector.call
      ActiveRecord::Base.descendants
    end

    def add_descendant(model)
      list = loaded + [ model ]
      allow(ActiveRecord::Base).to receive(:descendants).and_return(list)
    end

    it "is not reported as a model" do
      add_descendant(double("HABTM_Tags", name: "HABTM_Tags", to_s: "Account::HABTM_Tags",
                                          abstract_class?: false))

      keys = introspector.call.keys

      expect(keys).to include("Post")
      expect(keys).not_to include("HABTM_Tags")
    end

    it "is rejected by the name it answers, not by the HABTM spelling" do
      add_descendant(double("Renamed", name: "Renamed", to_s: "Owner::Renamed",
                                       abstract_class?: false))

      expect(introspector.call.keys).not_to include("Renamed")
    end
  end

  describe "AST-based macro extraction via #call" do
    let(:fixture_model) { File.join(Rails.root, "app/models/employee.rb") }

    after { FileUtils.rm_f(fixture_model) }

    context "with all supported macros" do
      before do
        File.write(fixture_model, <<~RUBY)
          class Employee < ApplicationRecord
            has_secure_password
            encrypts :ssn, :secret_code
            normalizes :email, :name, with: ->(val) { val.strip.downcase }
            has_one_attached :avatar
            has_many_attached :documents
            has_rich_text :bio
            broadcasts_to :company
            generates_token_for :email_verification
            serialize :preferences
            store :settings, accessors: [:theme, :language]
            delegate :company_name, to: :company
            delegate_missing_to :profile
          end
        RUBY
      end

      subject(:result) do
        # Use SourceIntrospector directly on the fixture file
        source = File.read(fixture_model)
        data = RailsAiContext::Introspectors::SourceIntrospector.from_source(source)
        introspector.send(:extract_macros_from_ast, data, fixture_model)
      end

      it "detects has_secure_password" do
        expect(result[:has_secure_password]).to be true
      end

      it "detects encrypts with multiple attributes" do
        expect(result[:encrypts]).to contain_exactly("ssn", "secret_code")
      end

      it "detects normalizes with multiple attributes" do
        expect(result[:normalizes]).to contain_exactly("email", "name")
      end

      it "detects has_one_attached" do
        expect(result[:has_one_attached]).to eq([ "avatar" ])
      end

      it "detects has_many_attached" do
        expect(result[:has_many_attached]).to eq([ "documents" ])
      end

      it "detects has_rich_text" do
        expect(result[:has_rich_text]).to eq([ "bio" ])
      end

      it "detects broadcasts" do
        expect(result[:broadcasts]).to include("broadcasts_to")
      end

      it "detects generates_token_for" do
        expect(result[:generates_token_for]).to eq([ "email_verification" ])
      end

      it "detects serialize" do
        expect(result[:serialize]).to eq([ "preferences" ])
      end

      it "detects store" do
        expect(result[:store]).to eq([ "settings" ])
      end

      it "detects delegate with target" do
        expect(result[:delegations]).to be_an(Array)
        delegation = result[:delegations].find { |d| d[:to] == "company" }
        expect(delegation).not_to be_nil
        expect(delegation[:methods]).to include("company_name")
      end

      it "detects delegate_missing_to" do
        expect(result[:delegate_missing_to]).to eq("profile")
      end
    end

    context "with constants" do
      before do
        File.write(fixture_model, <<~RUBY)
          class Employee < ApplicationRecord
            STATUSES = %w[pending active suspended].freeze
            ROLES = %i[admin editor viewer]
            LEVELS = Ractor.make_shareable(%w[gold silver])
            TIERS = ::Ractor.make_shareable(%w[basic pro].freeze)
          end
        RUBY
      end

      subject(:result) do
        source = File.read(fixture_model)
        data = RailsAiContext::Introspectors::SourceIntrospector.from_source(source)
        introspector.send(:extract_macros_from_ast, data, fixture_model)
      end

      it "extracts constants with value lists" do
        expect(result[:constants]).to be_an(Array)
        statuses = result[:constants].find { |c| c[:name] == "STATUSES" }
        expect(statuses).not_to be_nil
        expect(statuses[:values]).to contain_exactly("pending", "active", "suspended")
      end

      it "reads an array Ractor.make_shareable wraps, as it returns its argument" do
        expect(result[:constants]).to include({ name: "LEVELS", values: %w[gold silver] }, { name: "TIERS", values: %w[basic pro] })
      end
    end

    context "with model gem macros" do
      before do
        File.write(fixture_model, <<~RUBY)
          class Employee < ApplicationRecord
            include AASM
            has_paper_trail
            monetize :salary_cents
            aasm do
              state :pending, initial: true
              state :active
              event :activate do
                transitions from: :pending, to: :active
              end
            end
          end
        RUBY
      end

      subject(:result) do
        data = RailsAiContext::Introspectors::SourceIntrospector.from_source(File.read(fixture_model))
        introspector.send(:extract_macros_from_ast, data, fixture_model)
      end

      it "carries each gem macro as written and the aasm states and events" do
        expect(result[:gem_macros]).to eq([ { text: "has_paper_trail" }, { text: "monetize :salary_cents", adds: %w[salary] } ])
        expect(result[:state_machines]).to eq([ {
          column: "aasm_state", initial: "pending", states: %w[pending active],
          events: [ { name: "activate", transitions: [ { from: %w[pending], to: "active" } ] } ]
        } ])
      end
    end

    context "with single-attribute macros" do
      before do
        File.write(fixture_model, <<~RUBY)
          class Employee < ApplicationRecord
            normalizes :email, with: ->(e) { e.strip }
            encrypts :ssn
          end
        RUBY
      end

      subject(:result) do
        source = File.read(fixture_model)
        data = RailsAiContext::Introspectors::SourceIntrospector.from_source(source)
        introspector.send(:extract_macros_from_ast, data, fixture_model)
      end

      it "handles single normalizes attribute" do
        expect(result[:normalizes]).to eq([ "email" ])
      end

      it "handles single encrypts attribute" do
        expect(result[:encrypts]).to eq([ "ssn" ])
      end
    end

    context "with no macros" do
      before do
        File.write(fixture_model, <<~RUBY)
          class Employee < ApplicationRecord
          end
        RUBY
      end

      subject(:result) do
        source = File.read(fixture_model)
        data = RailsAiContext::Introspectors::SourceIntrospector.from_source(source)
        introspector.send(:extract_macros_from_ast, data, fixture_model)
      end

      it "returns empty hash" do
        expect(result).to eq({})
      end
    end

    context "with options the details used to drop" do
      before do
        File.write(fixture_model, <<~RUBY)
          class User < ApplicationRecord
            has_secure_password
            has_secure_password :recovery_password, validations: false
            normalizes :phone, with: ->(p) { p&.delete("^0-9") }, apply_to_nil: true
            encrypts :phone, deterministic: true, ignore_case: true, previous: { deterministic: false }
            serialize :tags_cache, coder: JSON, type: Array
          end
        RUBY
      end

      it "carries each password attribute and every option as written" do
        data = RailsAiContext::Introspectors::SourceIntrospector.from_source(File.read(fixture_model))
        result = introspector.send(:extract_macros_from_ast, data, fixture_model).merge(introspector.send(:extract_detailed_macros_from_ast, data))

        expect(result[:secure_passwords]).to eq([ { attribute: "password", options: {} },
                                                  { attribute: "recovery_password", options: { validations: "false" } } ])
        expect(result[:normalizes_details]).to eq([ { field: "phone", transformation: "->(p) { p&.delete(\"^0-9\") }", options: { apply_to_nil: "true" } } ])
        expect(result[:encryption_details]).to eq([ { field: "phone", options: { deterministic: "true", ignore_case: "true", previous: "{ deterministic: false }" } } ])
        expect(result[:serialize_options]).to eq("tags_cache" => { coder: "JSON", type: "Array" })
      end
    end

    context "when source file does not exist" do
      subject(:result) do
        data = { associations: [], validations: [], scopes: [], enums: [], callbacks: [], macros: [], methods: [] }
        introspector.send(:extract_macros_from_ast, data, fixture_model)
      end

      it "returns empty hash" do
        expect(result).to eq({})
      end
    end
  end

  describe "AST-based detailed macro extraction" do
    let(:fixture_model) { File.join(Rails.root, "app/models/employee.rb") }

    after { FileUtils.rm_f(fixture_model) }

    context "with encryption_details" do
      before do
        File.write(fixture_model, <<~RUBY)
          class Employee < ApplicationRecord
            encrypts :ssn, deterministic: true, downcase: true
            encrypts :secret_code
          end
        RUBY
      end

      subject(:result) do
        source = File.read(fixture_model)
        data = RailsAiContext::Introspectors::SourceIntrospector.from_source(source)
        introspector.send(:extract_detailed_macros_from_ast, data)
      end

      it "extracts field name and options for encrypted attributes" do
        expect(result[:encryption_details]).to be_an(Array)
        ssn_entry = result[:encryption_details].find { |e| e[:field] == "ssn" }
        expect(ssn_entry).not_to be_nil
        expect(ssn_entry[:options]).to eq(deterministic: "true", downcase: "true")
      end

      it "extracts encrypted attributes without options" do
        secret = result[:encryption_details].find { |e| e[:field] == "secret_code" }
        expect(secret).not_to be_nil
      end
    end

    context "with normalizes_details" do
      before do
        File.write(fixture_model, <<~RUBY)
          class Employee < ApplicationRecord
            normalizes :email, with: ->(e) { e.strip.downcase }
            normalizes :phone, with: ->(p) { p.gsub(/\\D/, "") }
          end
        RUBY
      end

      subject(:result) do
        source = File.read(fixture_model)
        data = RailsAiContext::Introspectors::SourceIntrospector.from_source(source)
        introspector.send(:extract_detailed_macros_from_ast, data)
      end

      it "extracts normalizes details" do
        expect(result[:normalizes_details]).to be_an(Array)
        email_entry = result[:normalizes_details].find { |e| e[:field] == "email" }
        expect(email_entry).not_to be_nil
        expect(email_entry[:transformation]).to eq("->(e) { e.strip.downcase }")
      end
    end

    context "with token_generation" do
      before do
        File.write(fixture_model, <<~RUBY)
          class Employee < ApplicationRecord
            generates_token_for :email_verification, expires_in: 2.hours
            generates_token_for :password_reset
          end
        RUBY
      end

      subject(:result) do
        source = File.read(fixture_model)
        data = RailsAiContext::Introspectors::SourceIntrospector.from_source(source)
        introspector.send(:extract_detailed_macros_from_ast, data)
      end

      it "extracts purpose and expiry" do
        expect(result[:token_generation]).to be_an(Array)
        email_token = result[:token_generation].find { |t| t[:purpose] == "email_verification" }
        expect(email_token).not_to be_nil
        expect(email_token[:expires_in]).to eq("2.hours")
      end

      it "handles token generation without expires_in" do
        pw_token = result[:token_generation].find { |t| t[:purpose] == "password_reset" }
        expect(pw_token).not_to be_nil
        expect(pw_token).not_to have_key(:expires_in)
      end
    end

    context "when source file does not exist" do
      subject(:result) do
        data = { associations: [], validations: [], scopes: [], enums: [], callbacks: [], macros: [], methods: [] }
        introspector.send(:extract_detailed_macros_from_ast, data)
      end

      it "returns empty hash" do
        expect(result).to eq({})
      end
    end
  end

  describe "#static_call" do
    it "finds a model under another app/ root or a root config/application.rb adds, and nothing else there" do
      Dir.mktmpdir do |dir|
        files = {
          "config/application.rb" => "module X\n  class Application < Rails::Application\n    config.eager_load_paths << Rails.root.join(\"enterprise/app/models\")\n  end\nend\n",
          "app/models/application_record.rb" => "class ApplicationRecord < ActiveRecord::Base\n  primary_abstract_class\nend\n",
          "app/domain/invoice.rb" => "class Invoice < ApplicationRecord\n  self.table_name = \"notes\"\nend\n",
          "app/domain/special_invoice.rb" => "class SpecialInvoice < Invoice\nend\n",
          "app/domain/plain.rb" => "class Plain\nend\n",
          "app/domain/concerns/billable.rb" => "module Billable\nend\n",
          "app/controllers/invoices_controller.rb" => "class InvoicesController < ApplicationController\nend\n",
          "enterprise/app/models/enterprise_thing.rb" => "class EnterpriseThing < ApplicationRecord\n  self.table_name = \"teams\"\nend\n"
        }
        files.each do |name, source|
          FileUtils.mkdir_p(File.dirname(File.join(dir, name)))
          File.write(File.join(dir, name), source)
        end

        models = described_class.new(RailsAiContext::StaticApp.new(dir)).static_call

        expect(models.keys).to contain_exactly("Invoice", "SpecialInvoice", "EnterpriseThing")
        expect(models["Invoice"]).to include(file: "app/domain/invoice.rb", table_name: "notes")
        expect(models["EnterpriseThing"][:file]).to eq("enterprise/app/models/enterprise_thing.rb")
      end
    end

    it "finds a model assigned Class.new of a record base, with what its block declares" do
      Dir.mktmpdir do |dir|
        files = {
          "app/models/application_record.rb" => "class ApplicationRecord < ActiveRecord::Base\n  primary_abstract_class\nend\n",
          "app/models/note.rb" => "class Note < ApplicationRecord\nend\n",
          "app/models/admin_note.rb" => "AdminNote = Class.new(ApplicationRecord) do\n  belongs_to :note\nend\n",
          "app/models/admin/flag.rb" => "module Admin\n  Flag = Class.new(::ApplicationRecord)\nend\n",
          "app/models/plain.rb" => "Plain = Class.new\n"
        }
        files.each do |name, source|
          FileUtils.mkdir_p(File.dirname(File.join(dir, name)))
          File.write(File.join(dir, name), source)
        end

        models = described_class.new(RailsAiContext::StaticApp.new(dir)).static_call

        expect(models.keys).to contain_exactly("Note", "AdminNote", "Admin::Flag")
        expect(models["AdminNote"]).to include(table_name: "admin_notes")
        expect(models["AdminNote"][:associations].map { |a| [ a[:type], a[:name] ] }).to eq([ %w[belongs_to note] ])
        expect(models["Admin::Flag"]).to include(table_name: "flags")
      end
    end

    it "credits a nested class's settings and gem macros to the nested class, not the model around it" do
      Dir.mktmpdir do |dir|
        files = {
          "app/models/application_record.rb" => "class ApplicationRecord < ActiveRecord::Base\n  primary_abstract_class\nend\n",
          "app/models/gadget.rb" => <<~RUBY
            class Gadget < ApplicationRecord
              encrypts :serial
              def self.with_lock
                self.locking_column = :temp_lock
              end
              class Part < ApplicationRecord
                self.implicit_order_column = "made_at"
                has_paper_trail
              end
            end
          RUBY
        }
        files.each do |name, source|
          FileUtils.mkdir_p(File.dirname(File.join(dir, name)))
          File.write(File.join(dir, name), source)
        end

        gadget = described_class.new(RailsAiContext::StaticApp.new(dir)).static_call["Gadget"]

        expect(gadget[:model_settings]).to be_nil
        expect(gadget[:macros].map { |m| m[:macro] }).to eq([ :encrypts ])
      end
    end

    it "says which models Apartment keeps in the shared schema and which per tenant" do
      Dir.mktmpdir do |dir|
        files = {
          "config/initializers/apartment.rb" => "Apartment.configure do |config|\n  config.excluded_models = %w[Organization]\nend\n",
          "app/models/application_record.rb" => "class ApplicationRecord < ActiveRecord::Base\n  primary_abstract_class\nend\n",
          "app/models/organization.rb" => "class Organization < ApplicationRecord\nend\n",
          "app/models/partner.rb" => "class Partner < Organization\nend\n",
          "app/models/ticket.rb" => "class Ticket < ApplicationRecord\nend\n"
        }
        files.each do |name, source|
          FileUtils.mkdir_p(File.dirname(File.join(dir, name)))
          File.write(File.join(dir, name), source)
        end

        models = described_class.new(RailsAiContext::StaticApp.new(dir)).static_call
        shared = { gem: "apartment", scope: "shared", declared_in: "config/initializers/apartment.rb" }

        expect(models["Organization"][:tenancy]).to eq(shared)
        expect(models["Partner"][:tenancy]).to eq(shared)
        expect(models["Ticket"][:tenancy]).to eq(shared.merge(scope: "per_tenant"))
      end
    end

    it "merges an edition module GitLab's prepend_mod_with names, and a prepend written after the class" do
      Dir.mktmpdir do |dir|
        files = {
          "config/application.rb" => "module X\n  class Application < Rails::Application\n    config.autoload_paths << Rails.root.join(\"ee/app/models\")\n  end\nend\n",
          "app/models/application_record.rb" => "class ApplicationRecord < ActiveRecord::Base\n  primary_abstract_class\nend\n",
          "ee/app/models/ee/note.rb" => "module EE\n  module Note\n    extend ActiveSupport::Concern\n    prepended do\n      has_many :epics\n      validates :body, presence: true\n    end\n  end\nend\n",
          "app/models/note.rb" => "class Note < ApplicationRecord\n  validates :title, presence: true\nend\n\nNote.prepend_mod_with(\"Note\")\n",
          "app/models/concerns/flaggable.rb" => "module Flaggable\n  extend ActiveSupport::Concern\n  prepended do\n    has_many :flags\n  end\nend\n",
          "app/models/post.rb" => "class Post < ApplicationRecord\nend\nPost.prepend(Flaggable)\nPost.prepend_mod\n"
        }
        files.each do |name, source|
          FileUtils.mkdir_p(File.dirname(File.join(dir, name)))
          File.write(File.join(dir, name), source)
        end

        models = described_class.new(RailsAiContext::StaticApp.new(dir)).static_call

        expect(models["Note"][:associations].map { |a| a[:name] }).to eq([ "epics" ])
        expect(models["Note"][:validations].map { |v| [ v[:kind], v[:attributes] ] }).to include([ "presence", [ "body" ] ], [ "presence", [ "title" ] ])
        expect(models["Note"][:concerns]).to eq([ "EE::Note" ])
        expect(models["Post"][:associations].map { |a| a[:name] }).to eq([ "flags" ])
        expect(models["Post"][:concerns]).to eq([ "Flaggable" ])
        expect(models["Post"]).not_to have_key(:concerns_unread)
      end
    end

    describe "pluralize_table_names" do
      def tables_with(files)
        Dir.mktmpdir do |dir|
          files.each do |path, body|
            FileUtils.mkdir_p(File.dirname(File.join(dir, path)))
            File.write(File.join(dir, path), body)
          end
          described_class.new(RailsAiContext::StaticApp.new(dir)).static_call.transform_values { |m| m[:table_name] }
        end
      end

      it "keeps a singular table for a class that turns it off, and its STI child and nested class follow" do
        tables = tables_with(
          "app/models/application_record.rb" => "class ApplicationRecord < ActiveRecord::Base\n  primary_abstract_class\nend\n",
          "app/models/person.rb" => "class Person < ApplicationRecord\n  self.pluralize_table_names = false\nend\n",
          "app/models/admin.rb" => "class Admin < Person\nend\n",
          "app/models/person/note.rb" => "class Person::Note < ApplicationRecord\nend\n",
          "app/models/post.rb" => "class Post < ApplicationRecord\nend\n"
        )
        expect(tables).to include("Person" => "person", "Admin" => "person", "Person::Note" => "person_notes", "Post" => "posts")
      end

      it "reads the app-wide setting and a base class's, which every child inherits" do
        expect(tables_with(
          "config/application.rb" => "module X\n  class Application < Rails::Application\n    config.active_record.pluralize_table_names = false\n  end\nend\n",
          "app/models/application_record.rb" => "class ApplicationRecord < ActiveRecord::Base\n  primary_abstract_class\nend\n",
          "app/models/user.rb" => "class User < ApplicationRecord\nend\n"
        )).to include("User" => "user")

        expect(tables_with(
          "app/models/application_record.rb" => "class ApplicationRecord < ActiveRecord::Base\n  primary_abstract_class\n  self.pluralize_table_names = false\nend\n",
          "app/models/user.rb" => "class User < ApplicationRecord\nend\n"
        )).to include("User" => "user")
      end
    end

    it "reads a compact model's bare superclass from the top level, as Ruby does" do
      Dir.mktmpdir do |dir|
        FileUtils.mkdir_p(File.join(dir, "app", "models", "admin"))
        File.write(File.join(dir, "app", "models", "base.rb"), "class Base\nend\n")
        File.write(File.join(dir, "app", "models", "admin", "base.rb"),
                   "module Admin\n  class Base < ApplicationRecord\n    self.abstract_class = true\n  end\nend\n")
        File.write(File.join(dir, "app", "models", "admin", "thing.rb"), "class Admin::Thing < Base\nend\n")
        File.write(File.join(dir, "app", "models", "admin", "widget.rb"), "module Admin\n  class Widget < Base\n  end\nend\n")

        models = described_class.new(RailsAiContext::StaticApp.new(dir)).static_call

        expect(models).not_to have_key("Admin::Thing")
        expect(models).to have_key("Admin::Widget")
      end
    end

    # OpenProject mixes Acts::Journalized into ActiveRecord::Base from a
    # plugin's init.rb, and the module lives in the file that init requires.
    # Every model has the module; a model whose concern's `included do` calls
    # acts_as_journalized has what the method declares, and no other does.
    # Canvas declares DefineAttributeMethods in a 2300-line initializer full
    # of other patches; the module is its own body, not the file's.
    it "reads a base mixin declared in a longer file as its own body, and hides none of the model's" do
      Dir.mktmpdir do |dir|
        FileUtils.mkdir_p(File.join(dir, "config", "initializers"))
        FileUtils.mkdir_p(File.join(dir, "app", "models"))
        File.write(File.join(dir, "config", "initializers", "active_record.rb"), <<~RUBY)
          class ActiveRecord::Base
            delegate :distinct_on, to: :all
            has_many :everything
          end

          module DefineAttributeMethods
            def init_internals; end
          end
          ActiveRecord::Base.include(DefineAttributeMethods)

          module ActiveRecordSerializationSafety
            def serializable_hash; end
          end
          ActiveRecord::Base.prepend(ActiveRecordSerializationSafety)
        RUBY
        File.write(File.join(dir, "app", "models", "color.rb"), "class Color < ApplicationRecord\nend\n")

        color = described_class.new(RailsAiContext::StaticApp.new(dir)).static_call["Color"]

        expect(Array(color[:associations])).to be_empty
        expect(Array(color[:delegations])).to be_empty
        expect(color).not_to have_key(:concerns_hidden)
        expect(color).not_to have_key(:concerns_unread)
      end
    end

    # A mixin's attachable(name, opts) declares `has_one name` or
    # `has_many name` by `opts[:has_one]`. Each call declares one association,
    # named by its argument, of the kind its options choose.
    it "reads a called method with the call's arguments, taking the branch they decide" do
      Dir.mktmpdir do |dir|
        FileUtils.mkdir_p(File.join(dir, "app", "lib"))
        FileUtils.mkdir_p(File.join(dir, "app", "models"))
        File.write(File.join(dir, "app", "lib", "attachable.rb"), <<~RUBY)
          module Attachable
            def self.included(klass)
              klass.extend(ClassMethods)
            end

            module ClassMethods
              def attachable(name, opts = {})
                raise ArgumentError, "owned_by" unless opts.key?(:owned_by)

                if opts[:has_one]
                  has_one name, -> { where(tag: name) }, class_name: "FileUpload", as: :foreign
                else
                  has_many name, -> { where(tag: name) }, class_name: "FileUpload", as: :foreign
                end
              end

              def taggable(kind)
                if kind.admin?
                  has_many :admin_tags
                  has_one :tag_summary
                else
                  has_many :tags
                  has_many :tag_summary
                end
                has_many :flags if kind.flagged?
              end
            end
          end
        RUBY
        File.write(File.join(dir, "app", "models", "listing.rb"), <<~RUBY)
          class Listing < ApplicationRecord
            include Attachable

            attachable :cover_image, has_one: true, owned_by: nil
            attachable :photos, owned_by: :user_id
            taggable Kind.current
          end
        RUBY

        listing = described_class.new(RailsAiContext::StaticApp.new(dir)).static_call["Listing"]
        associations = listing[:associations].map { |a| [ a[:type], a[:name].to_s, a[:computed_name] ].compact }

        expect(associations).to contain_exactly(
          [ "has_one", "cover_image" ], [ "has_many", "photos" ]
        )
        # Located at the line of the mixin's file that declares it.
        expect(listing[:associations].find { |a| a[:name].to_s == "photos" }[:location]).to eq(13)
        # What only a condition the call cannot decide declares is named, not counted.
        expect(listing[:conditional_declarations].map { |c| c.slice(:declaration, :condition, :from_concern) }).to contain_exactly(
          { declaration: "has_many :admin_tags", condition: "kind.admin?", from_concern: "Attachable" },
          { declaration: "has_one :tag_summary", condition: "kind.admin?", from_concern: "Attachable" },
          { declaration: "has_many :tags", condition: "not kind.admin?", from_concern: "Attachable" },
          { declaration: "has_many :tag_summary", condition: "not kind.admin?", from_concern: "Attachable" },
          { declaration: "has_many :flags", condition: "kind.flagged?", from_concern: "Attachable" }
        )
      end
    end

    # Canvas keeps BroadcastPolicy in gems/broadcast_policy, a path gem the
    # Gemfile declares. Its source is in the repo, so it is read like the
    # app's own; a gem installed outside the repo stays unread and named.
    it "reads a base mixin from a path gem inside the repo, and names one it cannot read" do
      Dir.mktmpdir do |dir|
        gem_lib = File.join(dir, "gems", "broadcast_policy", "lib")
        FileUtils.mkdir_p(File.join(gem_lib, "broadcast_policy"))
        File.write(File.join(dir, "gems", "broadcast_policy", "broadcast_policy.gemspec"), "Gem::Specification.new\n")
        File.write(File.join(gem_lib, "broadcast_policy.rb"), "require \"broadcast_policy/class_methods\"\n")
        File.write(File.join(gem_lib, "broadcast_policy", "class_methods.rb"), <<~RUBY)
          module BroadcastPolicy
            module ClassMethods
              def has_a_broadcast_policy
                after_save :broadcast_notifications
              end
            end
          end
        RUBY
        File.write(File.join(dir, "Gemfile.lock"), <<~LOCK)
          PATH
            remote: gems
            specs:
              broadcast_policy (1.0)

          PATH
            remote: ../outside
            specs:
              outside_gem (1.0)

          GEM
            remote: https://rubygems.org/
            specs:

          DEPENDENCIES
            broadcast_policy!
        LOCK
        FileUtils.mkdir_p(File.join(dir, "config", "initializers"))
        File.write(File.join(dir, "config", "initializers", "broadcast_policy.rb"),
                   "require \"broadcast_policy\"\nActiveRecord::Base.extend BroadcastPolicy::ClassMethods\nActiveRecord::Base.include InstalledGem::Mixin\n")
        FileUtils.mkdir_p(File.join(dir, "app", "models"))
        File.write(File.join(dir, "app", "models", "submission.rb"), "class Submission < ApplicationRecord\n  has_a_broadcast_policy\nend\n")
        File.write(File.join(dir, "app", "models", "color.rb"), "class Color < ApplicationRecord\nend\n")

        result = described_class.new(RailsAiContext::StaticApp.new(dir)).static_call

        expect(result["Submission"][:callbacks]["after_save"]).to include("broadcast_notifications")
        expect(result["Color"][:callbacks].to_h).to be_empty
        expect(result["Color"][:concerns_unread]).to eq([ "InstalledGem::Mixin" ])
      end
    end

    # The other ways an app mixes a module into every model: a reopened
    # ActiveRecord::Base, a module required through __dir__, and a send
    # inside on_load. A model's own `extend` of an app module is walked too.
    it "reads the other shapes of a base mixin, and a model's own extend" do
      Dir.mktmpdir do |dir|
        FileUtils.mkdir_p(File.join(dir, "config", "initializers", "support"))
        FileUtils.mkdir_p(File.join(dir, "app", "models"))
        FileUtils.mkdir_p(File.join(dir, "app", "lib"))
        File.write(File.join(dir, "config", "initializers", "support", "stamped.rb"),
                   "module Stamped\n  def self.included(base)\n    base.has_many :stamps\n  end\nend\n")
        File.write(File.join(dir, "config", "initializers", "support", "logged.rb"),
                   "module Logged\n  def self.included(base)\n    base.has_many :logs\n  end\nend\n")
        File.write(File.join(dir, "config", "initializers", "support", "reopened.rb"),
                   "module Reopened\n  def self.included(base)\n    base.has_many :reopenings\n  end\nend\n")
        File.write(File.join(dir, "config", "initializers", "base.rb"), <<~RUBY)
          require File.join(__dir__, "support", "stamped")
          require File.expand_path("support/logged", __dir__)
          require_relative "support/reopened"

          ActiveSupport.on_load(:active_record) { send(:include, Stamped) }
          ActiveRecord::Base.include Logged

          module ActiveRecord
            class Base
              include Reopened
            end
          end
        RUBY
        File.write(File.join(dir, "app", "lib", "sluggable.rb"), <<~RUBY)
          module Sluggable
            def sluggable(column)
              has_many :slugs
            end
          end
        RUBY
        File.write(File.join(dir, "app", "models", "post.rb"), "class Post < ApplicationRecord\n  extend Sluggable\n  sluggable :title\nend\n")
        File.write(File.join(dir, "app", "models", "color.rb"), "class Color < ApplicationRecord\nend\n")

        result = described_class.new(RailsAiContext::StaticApp.new(dir)).static_call

        expect(result["Color"][:associations].map { |a| a[:name].to_s }).to contain_exactly("stamps", "logs", "reopenings")
        expect(result["Post"][:associations].map { |a| a[:name].to_s }).to contain_exactly("stamps", "logs", "reopenings", "slugs")
        expect(result["Color"]).not_to have_key(:concerns_unread)
      end
    end

    # Canvas's Submission declares `module Tardiness` in its own file and
    # includes it; Ruby finds Submission::Tardiness there, and so is it read.
    it "does not call a module the model's own file declares and includes unread" do
      Dir.mktmpdir do |dir|
        FileUtils.mkdir_p(File.join(dir, "app", "models"))
        File.write(File.join(dir, "app", "models", "submission.rb"), <<~RUBY)
          class Submission < ApplicationRecord
            module Tardiness
              def late?; end
            end

            include Tardiness
            include Missing
          end
        RUBY

        submission = described_class.new(RailsAiContext::StaticApp.new(dir)).static_call["Submission"]

        expect(submission[:concerns_unread]).to eq([ "Missing" ])
      end
    end

    # OpenProject's WorkPackage gets journals from acts_as_journalized, which
    # a concern's included block calls; WorkPackage::InexistentWorkPackage
    # inherits the association, so it counts as calling what its parent calls.
    it "gives a subclass what its parent's concerns call into, as well as the parent" do
      Dir.mktmpdir do |dir|
        FileUtils.mkdir_p(File.join(dir, "config", "initializers"))
        FileUtils.mkdir_p(File.join(dir, "app", "models", "work_package"))
        File.write(File.join(dir, "config", "initializers", "journalized.rb"), <<~RUBY)
          module Acts
            module Journalized
              def self.included(base)
                base.extend ClassMethods
              end

              module ClassMethods
                def acts_as_journalized
                  has_many :journals
                end
              end
            end
          end
          ActiveRecord::Base.include(Acts::Journalized)
        RUBY
        File.write(File.join(dir, "app", "models", "work_package", "journalized.rb"), <<~RUBY)
          module WorkPackage::Journalized
            extend ActiveSupport::Concern

            included do
              acts_as_journalized
            end
          end
        RUBY
        File.write(File.join(dir, "app", "models", "work_package.rb"),
                   "class WorkPackage < ApplicationRecord\n  include WorkPackage::Journalized\n  has_many :relations\nend\n")
        File.write(File.join(dir, "app", "models", "work_package", "inexistent_work_package.rb"),
                   "class WorkPackage::InexistentWorkPackage < WorkPackage\n  has_one :ghost\nend\n")

        result = described_class.new(RailsAiContext::StaticApp.new(dir)).static_call
        names = ->(model) { result[model][:associations].map { |a| a[:name].to_s } }

        expect(names.call("WorkPackage")).to contain_exactly("relations", "journals")
        expect(names.call("WorkPackage::InexistentWorkPackage")).to contain_exactly("relations", "journals", "ghost")
      end
    end

    # Consul's Proposal calls validates_translation, which validates the model
    # and, inside translation_class.instance_eval, the translation class.
    it "keeps what a called method declares on another receiver out of the model, and names it" do
      Dir.mktmpdir do |dir|
        FileUtils.mkdir_p(File.join(dir, "app", "models", "concerns"))
        File.write(File.join(dir, "app", "models", "concerns", "globalizable.rb"), <<~RUBY)
          module Globalizable
            extend ActiveSupport::Concern

            class_methods do
              def validates_translation(method, options = {})
                validates(method, options)
                translation_class.instance_eval { validates method, options }
              end
            end
          end
        RUBY
        File.write(File.join(dir, "app", "models", "proposal.rb"), <<~RUBY)
          class Proposal < ApplicationRecord
            include Globalizable

            validates_translation :title, presence: true
          end
        RUBY

        proposal = described_class.new(RailsAiContext::StaticApp.new(dir)).static_call["Proposal"]

        expect(proposal[:validations].size).to eq(1)
        expect(proposal[:foreign_declarations]).to eq(
          [ { declaration: "validates :title, presence: true", receiver: "translation_class", from_concern: "Globalizable" } ]
        )
      end
    end

    it "reads a module the app includes into ActiveRecord::Base as every model's mixin" do
      Dir.mktmpdir do |dir|
        plugin = File.join(dir, "lib_static", "plugins", "acts_as_journalized")
        FileUtils.mkdir_p(File.join(plugin, "lib"))
        FileUtils.mkdir_p(File.join(dir, "config"))
        File.write(File.join(dir, "config", "application.rb"),
                   "module App\n  class Application < Rails::Application\n    config.autoload_once_paths << Rails.root.join(\"lib_static\").to_s\n  end\nend\n")
        File.write(File.join(plugin, "init.rb"), "require File.dirname(__FILE__) + \"/lib/acts_as_journalized\"\nActiveRecord::Base.include(Acts::Journalized)\n")
        File.write(File.join(plugin, "lib", "acts_as_journalized.rb"), <<~RUBY)
          module Acts
            module Journalized
              def self.included(base)
                base.extend ClassMethods
              end

              module ClassMethods
                def acts_as_journalized
                  has_many :journals
                end
              end
            end
          end
        RUBY
        FileUtils.mkdir_p(File.join(dir, "config", "initializers"))
        File.write(File.join(dir, "config", "initializers", "sanitize.rb"), <<~RUBY)
          module Sanitized
            def self.included(base); end

            def sanitize_all; end
          end
          ActiveSupport.on_load(:active_record) { include Sanitized }
          ActiveRecord::Base.include GemSupplied::Module
        RUBY
        FileUtils.mkdir_p(File.join(dir, "app", "models", "work_package"))
        File.write(File.join(dir, "app", "models", "work_package", "journalized.rb"), <<~RUBY)
          module WorkPackage::Journalized
            extend ActiveSupport::Concern

            included do
              acts_as_journalized
            end
          end
        RUBY
        File.write(File.join(dir, "app", "models", "work_package.rb"), "class WorkPackage < ApplicationRecord\n  include WorkPackage::Journalized\nend\n")
        File.write(File.join(dir, "app", "models", "color.rb"), "class Color < ApplicationRecord\nend\n")

        result = described_class.new(RailsAiContext::StaticApp.new(dir)).static_call

        expect(Array(result["WorkPackage"][:associations]).map { |a| a[:name].to_s }).to include("journals")
        expect(Array(result["Color"][:associations]).map { |a| a[:name].to_s }).not_to include("journals")
        expect(result["Color"][:concerns_unread]).to include("GemSupplied::Module")
        expect(result["Color"][:concerns_unread]).not_to include("Acts::Journalized", "Sanitized")
      end
    end

    # Huginn's ImapFolderAgent was credited with Scrubbed, which only its
    # nested Message class includes.
    it "names as a model's concerns only what the model's own body includes" do
      Dir.mktmpdir do |dir|
        FileUtils.mkdir_p(File.join(dir, "app", "models", "concerns"))
        File.write(File.join(dir, "app", "models", "concerns", "scrubbed.rb"), "module Scrubbed\n  has_many :scrubs\nend\n")
        File.write(File.join(dir, "app", "models", "concerns", "watched.rb"), "module Watched\nend\n")
        File.write(File.join(dir, "app", "models", "imap_folder_agent.rb"), <<~RUBY)
          class ImapFolderAgent < ApplicationRecord
            include Watched

            class Message
              include Scrubbed
            end
          end
        RUBY

        agent = described_class.new(RailsAiContext::StaticApp.new(dir)).static_call["ImapFolderAgent"]

        expect(agent[:concerns]).to eq([ "Watched" ])
        expect(Array(agent[:associations]).map { |a| a[:name].to_s }).not_to include("scrubs")
      end
    end

    # OpenProject's ApplicationRecord includes Acts::Watchable, whose
    # associations sit inside `def acts_as_watchable ... class_eval do`. A
    # model that calls it has them, whether it calls it itself or its base
    # does; every other model of the app does not.
    # OpenProject's User includes Users::Avatars, whose `included do` calls
    # an acts_as_* method a mixin of ApplicationRecord defines: the call runs
    # in User, so User has what the method declares.
    it "gives a base mixin's in-method macros to a model whose concern's included block calls the method" do
      Dir.mktmpdir do |dir|
        FileUtils.mkdir_p(File.join(dir, "app", "models", "concerns"))
        File.write(File.join(dir, "app", "models", "concerns", "watchable.rb"), <<~RUBY)
          module Watchable
            def self.included(base)
              base.extend ClassMethods
            end

            module ClassMethods
              def acts_as_watchable
                has_many :watchers
              end
            end
          end
        RUBY
        File.write(File.join(dir, "app", "models", "concerns", "avatars.rb"), <<~RUBY)
          module Avatars
            extend ActiveSupport::Concern

            included do
              acts_as_watchable
            end
          end
        RUBY
        File.write(File.join(dir, "app", "models", "application_record.rb"), <<~RUBY)
          class ApplicationRecord < ActiveRecord::Base
            primary_abstract_class
            include Watchable
          end
        RUBY
        File.write(File.join(dir, "app", "models", "user.rb"), "class User < ApplicationRecord\n  include Avatars\nend\n")
        File.write(File.join(dir, "app", "models", "color.rb"), "class Color < ApplicationRecord\nend\n")

        result = described_class.new(RailsAiContext::StaticApp.new(dir)).static_call

        expect(Array(result["User"][:associations]).map { |a| a[:name].to_s }).to include("watchers")
        expect(Array(result["Color"][:associations]).map { |a| a[:name].to_s }).not_to include("watchers")
      end
    end

    it "gives a mixin's in-method macros to the models that call the method, and to no others" do
      Dir.mktmpdir do |dir|
        FileUtils.mkdir_p(File.join(dir, "app", "models", "concerns"))
        File.write(File.join(dir, "app", "models", "concerns", "watchable.rb"), <<~RUBY)
          module Watchable
            def self.included(base)
              base.extend ClassMethods
            end

            module ClassMethods
              def acts_as_watchable
                class_eval do
                  has_many :watchers
                end
              end
            end
          end
        RUBY
        File.write(File.join(dir, "app", "models", "application_record.rb"), <<~RUBY)
          class ApplicationRecord < ActiveRecord::Base
            primary_abstract_class
            include Watchable
          end
        RUBY
        File.write(File.join(dir, "app", "models", "work_package.rb"), <<~RUBY)
          class WorkPackage < ApplicationRecord
            include Watchable
            acts_as_watchable
          end
        RUBY
        File.write(File.join(dir, "app", "models", "color.rb"), <<~RUBY)
          class Color < ApplicationRecord
            include Watchable
          end
        RUBY

        result = described_class.new(RailsAiContext::StaticApp.new(dir)).static_call

        expect(result["WorkPackage"][:associations].map { |a| a[:name].to_s }).to include("watchers")
        expect(Array(result["Color"][:associations]).map { |a| a[:name].to_s }).not_to include("watchers")
      end
    end

    # A leading `::` is top level to the class resolver, so both tiers keep
    # it; the pages that print the name drop it.
    it "records a class_name written with a leading :: as written" do
      Dir.mktmpdir do |dir|
        FileUtils.mkdir_p(File.join(dir, "app", "models"))
        File.write(File.join(dir, "app", "models", "anonymous_user.rb"), <<~RUBY)
          class AnonymousUser < ApplicationRecord
            has_one :api_token, class_name: "::Token::API"
          end
        RUBY

        result = described_class.new(RailsAiContext::StaticApp.new(dir)).static_call

        expect(result["AnonymousUser"][:associations].first[:class_name]).to eq("::Token::API")
      end
    end

    it "keeps a composite foreign key as a column list, and marks one a constant names" do
      Dir.mktmpdir do |dir|
        FileUtils.mkdir_p(File.join(dir, "app", "models"))
        File.write(File.join(dir, "app", "models", "line.rb"), <<~RUBY)
          class Line < ApplicationRecord
            belongs_to :order, foreign_key: [:shop_id, :order_id]
            belongs_to :author, foreign_key: AUTHOR_KEY
            belongs_to :account, foreign_key: :account_ref
          end
        RUBY

        by_name = described_class.new(RailsAiContext::StaticApp.new(dir)).static_call["Line"][:associations].to_h { |a| [ a[:name], a ] }

        expect(by_name["order"][:foreign_key]).to eq(%w[shop_id order_id])
        expect(by_name["author"][:computed_foreign_key]).to be(true)
        expect(by_name["account"]).to include(foreign_key: "account_ref")
        expect(by_name["account"]).not_to have_key(:computed_foreign_key)
      end
    end

    it "keeps a reflected composite foreign key as a column list" do
      assoc = double(name: :order, macro: :belongs_to, class_name: "Order",
                     foreign_key: %i[shop_id order_id], options: { foreign_key: %i[shop_id order_id] })

      detail = described_class.new(RailsAiContext::StaticApp.new(Dir.pwd)).send(:association_detail, assoc)

      expect(detail[:foreign_key]).to eq(%w[shop_id order_id])
    end

    it "records a reflected class_name written with a leading :: as written" do
      assoc = double(name: :api_token, macro: :has_one, class_name: "::Token::API",
                     foreign_key: "user_id", options: { class_name: "::Token::API" })

      detail = described_class.new(RailsAiContext::StaticApp.new(Dir.pwd)).send(:association_detail, assoc)

      expect(detail[:class_name]).to eq("::Token::API")
    end

    # consul keeps app/models/custom/setting.rb, which reopens Setting to add
    # methods. Both files declare one class, and the reopen carried no
    # superclass, so whichever the walk saw first decided whether the app had
    # the model at all.
    it "reads the model off the file that defines it, not the one reopening it" do
      Dir.mktmpdir do |dir|
        FileUtils.mkdir_p(File.join(dir, "app", "models", "custom"))
        File.write(File.join(dir, "app", "models", "setting.rb"), <<~RUBY)
          class Setting < ApplicationRecord
            belongs_to :owner
          end
        RUBY
        File.write(File.join(dir, "app", "models", "custom", "setting.rb"), <<~RUBY)
          class Setting
            def prefix; end
          end
        RUBY

        result = described_class.new(RailsAiContext::StaticApp.new(dir)).static_call

        expect(result.keys).to eq([ "Setting" ])
        expect(result["Setting"][:associations].map { |a| a[:name] }).to eq([ "owner" ])
      end
    end

    # A plugin model sits at an un-namespaced path and declares a namespaced
    # constant. Keyed under the path it named no superclass, so the walk read
    # it as a PORO and left the model out of the section entirely.
    it "names a model the way its own class does when the path carries no namespace" do
      Dir.mktmpdir do |dir|
        plugin = File.join(dir, "plugins", "discourse-github", "app", "models")
        FileUtils.mkdir_p(plugin)
        File.write(File.join(dir, "plugins", "discourse-github", "plugin.rb"), "# name: discourse-github\n")
        RailsAiContext::PathResolver.clear_code_roots
        FileUtils.mkdir_p(File.join(dir, "app", "models"))
        File.write(File.join(dir, "app", "models", "post.rb"), "class Post < ApplicationRecord\nend\n")
        File.write(File.join(plugin, "github_commit.rb"), <<~RUBY)
          class DiscourseGithubPlugin::GithubCommit < ActiveRecord::Base
            belongs_to :user
          end
        RUBY

        result = described_class.new(RailsAiContext::StaticApp.new(dir)).static_call

        expect(result.keys).to include("DiscourseGithubPlugin::GithubCommit")
        expect(result).not_to have_key("GithubCommit")
        expect(result["DiscourseGithubPlugin::GithubCommit"][:associations].map { |a| a[:name] }).to eq([ "user" ])
      end
    end

    # A concern the walk cannot read used to raise out of the section, so one
    # unreadable file answered `error` for every model in the app.
    it "keeps the other models when a concern cannot be read" do
      Dir.mktmpdir do |dir|
        FileUtils.mkdir_p(File.join(dir, "app", "models", "concerns"))
        File.write(File.join(dir, "app", "models", "post.rb"), <<~RUBY)
          class Post < ApplicationRecord
            include Publishable
            belongs_to :author
          end
        RUBY
        File.write(File.join(dir, "app", "models", "tag.rb"), "class Tag < ApplicationRecord\nend\n")
        FileUtils.mkdir_p(File.join(dir, "app", "models", "concerns", "publishable.rb"))

        result = described_class.new(RailsAiContext::StaticApp.new(dir)).static_call

        expect(result.keys).to contain_exactly("Post", "Tag")
        expect(result["Post"][:associations].map { |a| a[:name] }).to eq([ "author" ])
        expect(result["Post"][:concerns_unread]).to eq([ "Publishable" ])
        expect(result["Tag"]).not_to have_key(:error)
      end
    end

    # The booted tier answers `{ error: }` for the one model that raised and
    # keeps the rest; the static tier lost the whole section.
    it "costs one model, not the section, when reading its details raises" do
      Dir.mktmpdir do |dir|
        FileUtils.mkdir_p(File.join(dir, "app", "models"))
        File.write(File.join(dir, "app", "models", "post.rb"), "class Post < ApplicationRecord\nend\n")
        File.write(File.join(dir, "app", "models", "tag.rb"), "class Tag < ApplicationRecord\nend\n")
        # The walk is fed the source, not the path, so the one file is named
        # by what it declares.
        allow(RailsAiContext::Introspectors::SourceIntrospector).to receive(:walk_source).and_call_original
        allow(RailsAiContext::Introspectors::SourceIntrospector).to receive(:walk_source)
          .with(a_string_including("class Post")).and_raise(Errno::EACCES, "post.rb")

        result = described_class.new(RailsAiContext::StaticApp.new(dir)).static_call

        expect(result["Post"][:error]).to include("Permission denied")
        # What the unreadable branch keeps: both are known here too, and
        # without them a consumer derives app/models/<name>.rb, which the
        # walk stopped doing two commits ago.
        expect(result["Post"][:file]).to eq("app/models/post.rb")
        expect(result["Post"][:table_name]).to eq("posts")
        expect(result["Tag"][:confidence]).to eq(RailsAiContext::Confidence::STATIC)
      end
    end

    # The static builder passed the listener's raw records through where the
    # booted one merges the attribute-macro mappers, so every mapped key was
    # nil and five consumers rendered nothing.
    it "maps attribute macros, enums and custom validates the same way the booted tier does" do
      Dir.mktmpdir do |dir|
        FileUtils.mkdir_p(File.join(dir, "app", "models"))
        File.write(File.join(dir, "app", "models", "keypair.rb"), <<~RUBY)
          class Keypair < ApplicationRecord
            ROLES = %w[owner guest].freeze

            enum :kind, { rsa: 0, ed25519: 1 }
            encrypts :private_key, deterministic: true
            normalizes :email, with: ->(e) { e.strip }
            serialize :prefs
            store :settings
            has_one_attached :avatar
            has_secure_password
            generates_token_for :password_reset, expires_in: 2.hours
            delegate :name, to: :account
            validate :key_is_sane
          end
        RUBY

        data = described_class.new(RailsAiContext::StaticApp.new(dir)).static_call["Keypair"]

        expect(data[:encrypts]).to eq([ "private_key" ])
        expect(data[:normalizes]).to eq([ "email" ])
        expect(data[:serialize]).to eq([ "prefs" ])
        expect(data[:store]).to eq([ "settings" ])
        expect(data[:has_one_attached]).to eq([ "avatar" ])
        expect(data[:has_secure_password]).to be(true)
        expect(data[:generates_token_for]).to eq([ "password_reset" ])
        expect(data[:delegations]).to eq([ { methods: [ "name" ], to: "account" } ])
        expect(data[:constants]).to include(a_hash_including(name: "ROLES"))
        expect(data[:encryption_details]).to eq([ { field: "private_key", options: { deterministic: "true" } } ])
        expect(data[:token_generation]).to include(a_hash_including(purpose: "password_reset"))
        expect(data[:custom_validates]).to eq([ "key_is_sane" ])
        expect(data[:enums]).to eq({ "kind" => { "rsa" => 0, "ed25519" => 1 } })
      end
    end

    # The skip was `relative.start_with?("concerns/")`, which only sees the
    # top-level directory Rails autoloads. A nested one - OpenProject has
    # app/models/queries/operators/concerns - walked straight past it, and four
    # mixins were reported as models of the app.
    it "does not report a module in a nested concerns directory as a model" do
      Dir.mktmpdir do |dir|
        FileUtils.mkdir_p(File.join(dir, "app", "models", "queries", "operators", "concerns"))
        File.write(File.join(dir, "app", "models", "widget.rb"), <<~RUBY)
          class Widget < ApplicationRecord
          end
        RUBY
        File.write(File.join(dir, "app", "models", "queries", "operators", "concerns", "contains.rb"), <<~RUBY)
          module Queries
            module Operators
              module Concerns
                module Contains
                  def contains?(x) = true
                end
              end
            end
          end
        RUBY

        result = described_class.new(RailsAiContext::StaticApp.new(dir)).static_call

        expect(result.keys).to contain_exactly("Widget")
      end
    end

    it "discovers and parses models from source without constantizing" do
      Dir.mktmpdir do |dir|
        FileUtils.mkdir_p(File.join(dir, "app", "models", "concerns"))
        FileUtils.mkdir_p(File.join(dir, "app", "models", "admin"))
        File.write(File.join(dir, "app", "models", "widget.rb"), <<~RUBY)
          class Widget < ApplicationRecord
            belongs_to :factory
            has_many :parts
            validates :name, presence: true
            scope :active, -> { where(active: true) }
          end
        RUBY
        File.write(File.join(dir, "app", "models", "admin", "report.rb"), <<~RUBY)
          class Admin::Report < ApplicationRecord
          end
        RUBY
        File.write(File.join(dir, "app", "models", "application_record.rb"), <<~RUBY)
          class ApplicationRecord < ActiveRecord::Base
            primary_abstract_class
          end
        RUBY
        File.write(File.join(dir, "app", "models", "concerns", "searchable.rb"), <<~RUBY)
          module Searchable
          end
        RUBY

        result = described_class.new(RailsAiContext::StaticApp.new(dir)).static_call

        expect(result.keys).to contain_exactly("Widget", "Admin::Report")
        widget = result["Widget"]
        expect(widget[:confidence]).to eq("[STATIC]")
        expect(widget[:table_name]).to eq("widgets")
        expect(widget[:associations].map { |a| a[:name] }).to contain_exactly("factory", "parts")
        expect(widget[:validations]).not_to be_empty
        expect(result["Admin::Report"][:table_name]).to eq("reports")
      end
    end

    # An STI child inherits its base's macros the way it inherits its table,
    # so a child that declares nothing answered "0 assoc, 0 val" in the schema
    # heading while the booted tier read its parent's.
    it "gives an STI child the macros its base declares" do
      Dir.mktmpdir do |dir|
        FileUtils.mkdir_p(File.join(dir, "app", "models"))
        File.write(File.join(dir, "app", "models", "post.rb"), <<~RUBY)
          class Post < ApplicationRecord
            has_many :comments
            validates :title, presence: true
            scope :published, -> { where(published: true) }
            before_save :normalize_title
            encrypts :secret
          end
        RUBY
        File.write(File.join(dir, "app", "models", "article.rb"), "class Article < Post\nend\n")

        article = described_class.new(RailsAiContext::StaticApp.new(dir)).static_call["Article"]

        expect(article[:table_name]).to eq("posts")
        expect(article[:associations].map { |a| a[:name] }).to contain_exactly("comments")
        expect(article[:validations].map { |v| v[:kind] }).to contain_exactly("presence")
        expect(article[:scopes].map { |s| s[:name] }).to contain_exactly("published")
        expect(article[:callbacks]).to include("before_save")
        expect(article[:encrypts]).to contain_exactly("secret")
      end
    end

    it "keeps a class's own declaration when its STI base declares the same one" do
      Dir.mktmpdir do |dir|
        FileUtils.mkdir_p(File.join(dir, "app", "models"))
        File.write(File.join(dir, "app", "models", "post.rb"), <<~RUBY)
          class Post < ApplicationRecord
            has_many :comments, dependent: :destroy
          end
        RUBY
        File.write(File.join(dir, "app", "models", "article.rb"), <<~RUBY)
          class Article < Post
            has_many :comments, dependent: :nullify
          end
        RUBY

        article = described_class.new(RailsAiContext::StaticApp.new(dir)).static_call["Article"]

        comments = article[:associations].select { |a| a[:name] == "comments" }
        expect(comments.size).to eq(1)
        expect(comments.first[:options][:dependent]).to eq(:nullify)
      end
    end

    # `dependent: nil` is a real declaration, and lifting it as "" rendered
    # `.dependent(:)` into the scaffold the user is told to paste.
    it "does not lift an association option that is written as nil" do
      Dir.mktmpdir do |dir|
        FileUtils.mkdir_p(File.join(dir, "app", "models"))
        File.write(File.join(dir, "app", "models", "status.rb"), <<~RUBY)
          class Status < ApplicationRecord
            has_many :replies, class_name: "Status", foreign_key: "in_reply_to_id", dependent: nil
            has_many :favourites, dependent: :destroy
            belongs_to :account, optional: false
            belongs_to :subject, polymorphic: false
          end
        RUBY

        associations = described_class.new(RailsAiContext::StaticApp.new(dir)).static_call["Status"][:associations]
        by_name = associations.to_h { |a| [ a[:name], a ] }

        expect(by_name["replies"]).not_to have_key(:dependent)
        expect(by_name["replies"][:class_name]).to eq("Status")
        expect(by_name["favourites"][:dependent]).to eq("destroy")
        expect(by_name["account"][:optional]).to be(false)
        expect(by_name["subject"][:polymorphic]).to be(false)
      end
    end

    # validate finds an unindexed key through this field, so a static record needs it too.
    it "gives a belongs_to the key reflection would, declared or not" do
      Dir.mktmpdir do |dir|
        FileUtils.mkdir_p(File.join(dir, "app", "models"))
        File.write(File.join(dir, "app", "models", "volume.rb"), <<~RUBY)
          class Volume < ApplicationRecord
            belongs_to :publisher
            belongs_to :writer, class_name: "User", foreign_key: :author_id
            has_many :chapters
          end
        RUBY

        associations = described_class.new(RailsAiContext::StaticApp.new(dir)).static_call["Volume"][:associations]
        by_name = associations.to_h { |a| [ a[:name], a ] }

        expect(by_name["publisher"][:foreign_key]).to eq("publisher_id")
        expect(by_name["writer"][:foreign_key]).to eq("author_id")
        expect(by_name["chapters"]).not_to have_key(:foreign_key)
      end
    end

    # An error entry carries no path, and File.basename("", ".rb").pluralize
    # is "", which is truthy and so was accepted as the child's table. No
    # walk reaches this today, because model_class? already rejects a child
    # whose chain hits an error entry, so the resolution is pinned directly.
    it "does not resolve a table through a candidate that carries no path" do
      Dir.mktmpdir do |dir|
        introspector = described_class.new(RailsAiContext::StaticApp.new(dir))
        candidates = {
          "Post" => { error: "boom" },
          "Draft" => { path: File.join(dir, "app", "models", "draft.rb"), superclass: "Post" }
        }

        expect(introspector.send(:resolve_table_name, "Draft", candidates)).to eq("drafts")
      end
    end

    it "reports a custom validate once, under custom_validates" do
      Dir.mktmpdir do |dir|
        FileUtils.mkdir_p(File.join(dir, "app", "models"))
        File.write(File.join(dir, "app", "models", "post.rb"), <<~RUBY)
          class Post < ApplicationRecord
            validate :body_is_sane
          end
        RUBY

        post = described_class.new(RailsAiContext::StaticApp.new(dir)).static_call["Post"]

        expect(post[:custom_validates]).to contain_exactly("body_is_sane")
        expect(post[:validations].map { |v| v[:kind] }).not_to include("custom")
      end
    end

    it "reports the modules a model includes or prepends, and not what it extends" do
      Dir.mktmpdir do |dir|
        FileUtils.mkdir_p(File.join(dir, "app", "models", "concerns"))
        File.write(File.join(dir, "app", "models", "post.rb"), <<~RUBY)
          class Post < ApplicationRecord
            include Publishable
            prepend Auditable
            extend Searchable
            has_many :comments
          end
        RUBY

        result = described_class.new(RailsAiContext::StaticApp.new(dir)).static_call

        expect(result["Post"][:concerns]).to contain_exactly("Publishable", "Auditable")
      end
    end

    it "leaves framework modules out of the concerns it reports" do
      Dir.mktmpdir do |dir|
        FileUtils.mkdir_p(File.join(dir, "app", "models"))
        File.write(File.join(dir, "app", "models", "post.rb"), <<~RUBY)
          class Post < ApplicationRecord
            include ActiveModel::Validations
          end
        RUBY

        result = described_class.new(RailsAiContext::StaticApp.new(dir)).static_call

        expect(result["Post"][:concerns]).to be_empty
      end
    end

    it "isolates a single unreadable model to its own entry" do
      Dir.mktmpdir do |dir|
        FileUtils.mkdir_p(File.join(dir, "app", "models"))
        File.write(File.join(dir, "app", "models", "good.rb"), "class Good < ApplicationRecord\nend\n")
        File.write(File.join(dir, "app", "models", "huge.rb"), "class Huge < ApplicationRecord\nend\n")
        allow(File).to receive(:size).and_call_original
        allow(File).to receive(:size).with(a_string_ending_with("huge.rb")).and_return(10_000_000)

        result = described_class.new(RailsAiContext::StaticApp.new(dir)).static_call
        expect(result.keys).to contain_exactly("Good", "Huge")
        expect(result["Huge"][:error]).to include("too large")
        expect(result["Good"]).to have_key(:associations)
      end
    end

    # app/models holds POROs too - a form object, a service, a generated data
    # class. A file the walk could not read might be one of those, so the
    # entry says what it knows (the file, and why it is empty) and claims no
    # table. A base something inherits from is different: the inheritance is
    # what says it is a model, and its children share the table.
    # Every error branch names the file it is about: a consumer with none
    # derives app/models/<name>.rb, which is a path a pack model does not have.
    it "names the file on the branch a failing scan produces" do
      Dir.mktmpdir do |dir|
        FileUtils.mkdir_p(File.join(dir, "app", "models"))
        File.write(File.join(dir, "app", "models", "post.rb"), "class Post < ApplicationRecord\nend\n")
        allow(File).to receive(:size).and_call_original
        allow(File).to receive(:size).with(a_string_ending_with("post.rb")).and_raise(Errno::ENOENT, "post.rb")

        entry = described_class.new(RailsAiContext::StaticApp.new(dir)).static_call["Post"]

        expect(entry[:error]).to include("No such file")
        expect(entry[:file]).to eq("app/models/post.rb")
      end
    end

    it "claims no table for an unreadable file nothing inherits from" do
      Dir.mktmpdir do |dir|
        FileUtils.mkdir_p(File.join(dir, "app", "models"))
        File.write(File.join(dir, "app", "models", "good.rb"), "class Good < ApplicationRecord\nend\n")
        File.write(File.join(dir, "app", "models", "big_report.rb"), "class BigReport\nend\n")
        allow(File).to receive(:size).and_call_original
        allow(File).to receive(:size).with(a_string_ending_with("big_report.rb")).and_return(10_000_000)

        result = described_class.new(RailsAiContext::StaticApp.new(dir)).static_call

        expect(result["BigReport"][:error]).to include("too large")
        expect(result["BigReport"][:file]).to eq("app/models/big_report.rb")
        expect(result["BigReport"]).not_to have_key(:table_name)
        expect(result["Good"][:table_name]).to eq("goods")
      end
    end

    # A base nobody can read is the only route its children have to
    # ApplicationRecord, so dropping it drops them, and an app whose every
    # model descends from one answers that it has no models at all.
    context "when an STI base cannot be read" do
      def sti_app(dir)
        FileUtils.mkdir_p(File.join(dir, "app", "models"))
        File.write(File.join(dir, "app", "models", "vehicle.rb"),
                   "class Vehicle < ApplicationRecord\n  validates :name, presence: true\nend\n")
        File.write(File.join(dir, "app", "models", "car.rb"), "class Car < Vehicle\nend\n")
        File.write(File.join(dir, "app", "models", "truck.rb"), "class Truck < Vehicle\nend\n")
        allow(RailsAiContext::SafeFile).to receive(:read).and_call_original
        allow(RailsAiContext::SafeFile).to receive(:read)
          .with(a_string_ending_with("vehicle.rb"), any_args).and_return(nil)
        described_class.new(RailsAiContext::StaticApp.new(dir)).static_call
      end

      it "keeps the children of the base it cannot read" do
        Dir.mktmpdir { |dir| expect(sti_app(dir).keys).to include("Car", "Truck") }
      end

      it "names the base with the reason its declarations are missing" do
        Dir.mktmpdir do |dir|
          expect(sti_app(dir)["Vehicle"][:error]).to include("unreadable")
        end
      end

      it "still reads the children's table off the base's file name" do
        Dir.mktmpdir { |dir| expect(sti_app(dir)["Car"][:table_name]).to eq("vehicles") }
      end
    end

    it "records a stat failure as that model's error entry without aborting the pass" do
      Dir.mktmpdir do |dir|
        FileUtils.mkdir_p(File.join(dir, "app", "models"))
        File.write(File.join(dir, "app", "models", "good.rb"), "class Good < ApplicationRecord\nend\n")
        File.write(File.join(dir, "app", "models", "bad.rb"), "class Bad < ApplicationRecord\nend\n")
        allow(File).to receive(:size).and_call_original
        allow(File).to receive(:size).with(a_string_ending_with("bad.rb")).and_raise(Errno::EACCES)

        result = described_class.new(RailsAiContext::StaticApp.new(dir)).static_call
        expect(result["Bad"]).to include(error: a_string_including("Permission denied"))
        expect(result["Good"]).to have_key(:associations)
      end
    end

    it "discovers models in packs and engines directories" do
      Dir.mktmpdir do |dir|
        FileUtils.mkdir_p(File.join(dir, "app", "models"))
        FileUtils.mkdir_p(File.join(dir, "packs", "billing", "app", "models"))
        FileUtils.mkdir_p(File.join(dir, "engines", "store", "app", "models", "store"))
        File.write(File.join(dir, "app", "models", "user.rb"),
                   "class User < ApplicationRecord\nend\n")
        File.write(File.join(dir, "packs", "billing", "app", "models", "invoice.rb"),
                   "class Invoice < ApplicationRecord\n  belongs_to :user\nend\n")
        File.write(File.join(dir, "engines", "store", "app", "models", "store", "order.rb"),
                   "class Store::Order < ApplicationRecord\nend\n")

        result = described_class.new(RailsAiContext::StaticApp.new(dir)).static_call

        expect(result.keys).to contain_exactly("User", "Invoice", "Store::Order")
        expect(result["Invoice"][:associations].map { |a| a[:name] }).to eq([ "user" ])
        expect(result["Store::Order"][:table_name]).to eq("orders")
      end
    end

    it "keeps the first definition when the same class name appears in two dirs" do
      Dir.mktmpdir do |dir|
        FileUtils.mkdir_p(File.join(dir, "app", "models"))
        FileUtils.mkdir_p(File.join(dir, "packs", "billing", "app", "models"))
        File.write(File.join(dir, "app", "models", "user.rb"),
                   "class User < ApplicationRecord\n  has_many :posts\nend\n")
        File.write(File.join(dir, "packs", "billing", "app", "models", "user.rb"),
                   "class User < ApplicationRecord\nend\n")

        result = described_class.new(RailsAiContext::StaticApp.new(dir)).static_call
        expect(result["User"][:associations]).not_to be_empty
      end
    end

    it "counts only classes descending from a model base, STI included" do
      Dir.mktmpdir do |dir|
        FileUtils.mkdir_p(File.join(dir, "app", "models", "admin"))
        FileUtils.mkdir_p(File.join(dir, "app", "models", "form"))
        FileUtils.mkdir_p(File.join(dir, "app", "models", "trends"))
        File.write(File.join(dir, "app", "models", "post.rb"),
                   "class Post < ApplicationRecord\nend\n")
        File.write(File.join(dir, "app", "models", "admin", "report.rb"),
                   "class Admin::Report < Post\nend\n")
        File.write(File.join(dir, "app", "models", "form", "batch.rb"),
                   "class Form::Batch\n  include ActiveModel::Model\nend\n")
        File.write(File.join(dir, "app", "models", "admin.rb"),
                   "module Admin\nend\n")
        File.write(File.join(dir, "app", "models", "trends", "statuses.rb"),
                   "class Trends::Statuses\n  def call = nil\nend\n")

        result = described_class.new(RailsAiContext::StaticApp.new(dir)).static_call

        expect(result.keys).to contain_exactly("Post", "Admin::Report")
      end
    end
  end

  describe "file reads" do
    def read_count_for(dir, basename)
      reads = 0
      allow(File).to receive(:read).and_wrap_original do |original, *args, **kwargs|
        reads += 1 if args.first.to_s.end_with?("/#{basename}")
        original.call(*args, **kwargs)
      end

      described_class.new(RailsAiContext::StaticApp.new(dir)).static_call
      reads
    end

    it "reads a model file once per static run" do
      Dir.mktmpdir do |dir|
        FileUtils.mkdir_p(File.join(dir, "app", "models"))
        File.write(File.join(dir, "app", "models", "post.rb"), <<~RUBY)
          class Post < ApplicationRecord
            has_many :comments
            scope :recent, -> { order(created_at: :desc) }
          end
        RUBY

        expect(read_count_for(dir, "post.rb")).to eq(1)
      end
    end

    it "reads an STI base once, though its children walk it too" do
      Dir.mktmpdir do |dir|
        FileUtils.mkdir_p(File.join(dir, "app", "models"))
        File.write(File.join(dir, "app", "models", "vehicle.rb"), "class Vehicle < ApplicationRecord\n  has_many :trips\nend\n")
        File.write(File.join(dir, "app", "models", "car.rb"), "class Car < Vehicle\nend\n")
        File.write(File.join(dir, "app", "models", "truck.rb"), "class Truck < Vehicle\nend\n")

        expect(read_count_for(dir, "vehicle.rb")).to eq(1)
      end
    end
  end

  describe "Mongoid apps" do
    it "extracts fields and embeds statically in both tiers" do
      Dir.mktmpdir do |dir|
        FileUtils.mkdir_p(File.join(dir, "config"))
        FileUtils.mkdir_p(File.join(dir, "app", "models"))
        File.write(File.join(dir, "config", "mongoid.yml"), "development:\n  clients: {}\n")
        File.write(File.join(dir, "app", "models", "customer.rb"), <<~RUBY)
          class Customer
            include Mongoid::Document
            field :name, type: String
            embeds_many :orders
            has_many :tickets
          end
        RUBY

        introspector = described_class.new(RailsAiContext::StaticApp.new(dir))
        [ introspector.static_call, introspector.call ].each do |result|
          customer = result["Customer"]
          expect(customer[:mongoid]).to be(true)
          expect(customer[:fields]).to include(name: :name, type: "String")
          expect(customer[:embeds]).to include(type: :embeds_many, name: :orders)
          expect(customer[:associations].map { |a| a[:name] }).to include("tickets")
          expect(customer).not_to have_key(:table_name)
        end
      end
    end

    it "lists each declared index as written in both tiers" do
      Dir.mktmpdir do |dir|
        FileUtils.mkdir_p(File.join(dir, "config"))
        FileUtils.mkdir_p(File.join(dir, "app", "models"))
        File.write(File.join(dir, "config", "mongoid.yml"), "development:\n  clients: {}\n")
        File.write(File.join(dir, "app", "models", "author.rb"), <<~RUBY)
          class Author
            include Mongoid::Document
            field :email, type: String
            index({ email: 1 }, { unique: true })
            index({ account_id: 1, created_at: -1 }, # newest first
                  background: true)
          end
        RUBY

        introspector = described_class.new(RailsAiContext::StaticApp.new(dir))
        [ introspector.static_call, introspector.call ].each do |result|
          expect(result["Author"][:indexes]).to eq([
            "index({ email: 1 }, { unique: true })",
            "index({ account_id: 1, created_at: -1 }, background: true)"
          ])
        end
      end
    end

    it "lists the fields and indexes an included concern declares, in both tiers" do
      Dir.mktmpdir do |dir|
        FileUtils.mkdir_p(File.join(dir, "config"))
        FileUtils.mkdir_p(File.join(dir, "app", "models", "concerns"))
        File.write(File.join(dir, "config", "mongoid.yml"), "development:\n  clients: {}\n")
        File.write(File.join(dir, "app", "models", "concerns", "taggable.rb"), <<~RUBY)
          module Taggable
            extend ActiveSupport::Concern
            included do
              field :tags, type: Array
              index tags: 1
            end
          end
        RUBY
        File.write(File.join(dir, "app", "models", "book.rb"), <<~RUBY)
          class Book
            include Mongoid::Document
            include Taggable
            field :title, type: String
            index title: 1
          end
        RUBY

        introspector = described_class.new(RailsAiContext::StaticApp.new(dir))
        [ introspector.static_call, introspector.call ].each do |result|
          expect(result["Book"][:fields].map { |f| f[:name] }).to eq(%i[tags title])
          expect(result["Book"][:indexes]).to eq([ "index tags: 1", "index title: 1" ])
        end
      end
    end

    it "keeps only the later declaration of a callback declared twice" do
      Dir.mktmpdir do |dir|
        FileUtils.mkdir_p(File.join(dir, "config"))
        FileUtils.mkdir_p(File.join(dir, "app", "models"))
        File.write(File.join(dir, "config", "mongoid.yml"), "development:\n  clients: {}\n")
        File.write(File.join(dir, "app", "models", "customer.rb"), <<~RUBY)
          class Customer
            include Mongoid::Document
            before_save :sync, if: :a?
            before_save :stamp
            before_save :sync
          end
        RUBY

        customer = described_class.new(RailsAiContext::StaticApp.new(dir)).static_call["Customer"]
        expect(customer.values_at(:callbacks, :callback_conditions)).to eq([ { "before_save" => %w[stamp sync] }, {} ])
      end
    end

    # ActiveModel runs before_save :z, :x, :y here and after_save :a, :b;
    # Mongoid's after_commit, set without prepend, runs :c2, :c1.
    it "lists a document's callbacks in run order, prepend: true first" do
      Dir.mktmpdir do |dir|
        FileUtils.mkdir_p(File.join(dir, "config"))
        FileUtils.mkdir_p(File.join(dir, "app", "models"))
        File.write(File.join(dir, "config", "mongoid.yml"), "development:\n  clients: {}\n")
        File.write(File.join(dir, "app", "models", "customer.rb"), <<~RUBY)
          class Customer
            include Mongoid::Document
            before_save :x, prepend: true
            before_save :y
            before_save :z, prepend: true
            after_save :a
            after_save :b
            after_commit :c1
            after_commit :c2
          end
        RUBY

        customer = described_class.new(RailsAiContext::StaticApp.new(dir)).static_call["Customer"]
        expect(customer[:callbacks]).to eq("before_save" => %w[z x y], "after_save" => %w[a b], "after_commit" => %w[c2 c1])
      end
    end

    # ActiveModel runs before_save :first, :track, :last: a callback in a class method counts
    # where the method is called, one in an instance method or a nested class nowhere.
    it "places a document's callback in a class method at its call" do
      Dir.mktmpdir do |dir|
        FileUtils.mkdir_p(File.join(dir, "config"))
        FileUtils.mkdir_p(File.join(dir, "app", "models"))
        File.write(File.join(dir, "config", "mongoid.yml"), "development:\n  clients: {}\n")
        File.write(File.join(dir, "app", "models", "customer.rb"), <<~RUBY)
          class Customer
            include Mongoid::Document
            class Inner
              before_save :inner
            end
            def self.loud!
              before_save :track
            end
            def setup
              before_save :inst
            end
            before_save :first
            loud!
            before_save :last
          end
        RUBY

        customer = described_class.new(RailsAiContext::StaticApp.new(dir)).static_call["Customer"]
        expect(customer[:callbacks]).to eq("before_save" => %w[first track last])
      end
    end

    it "names the collection Mongoid derives when store_in names none" do
      Dir.mktmpdir do |dir|
        FileUtils.mkdir_p(File.join(dir, "config"))
        FileUtils.mkdir_p(File.join(dir, "app", "models", "admin"))
        File.write(File.join(dir, "config", "mongoid.yml"), "development:\n  clients: {}\n")
        File.write(File.join(dir, "app", "models", "admin", "shelf.rb"), "module Admin\n  class Shelf\n    include Mongoid::Document\n  end\nend\n")

        expect(described_class.new(RailsAiContext::StaticApp.new(dir)).static_call["Admin::Shelf"][:collection]).to eq("admin_shelves")
      end
    end

    it "reads every embed kind and the store_in collection" do
      Dir.mktmpdir do |dir|
        FileUtils.mkdir_p(File.join(dir, "config"))
        FileUtils.mkdir_p(File.join(dir, "app", "models"))
        File.write(File.join(dir, "config", "mongoid.yml"), "development:\n  clients: {}\n")
        File.write(File.join(dir, "app", "models", "order.rb"), <<~RUBY)
          class Order
            include Mongoid::Document
            store_in collection: "legacy_orders"
            field :total, type: BigDecimal
            field :tags
            field :age, type: Integer, default: 0
            field :labels, type: Array, default: []
            embeds_many :line_items
            embeds_one :address
            embedded_in :customer
          end
        RUBY

        order = described_class.new(RailsAiContext::StaticApp.new(dir)).static_call["Order"]

        expect(order[:collection]).to eq("legacy_orders")
        expect(order[:fields]).to eq([ { name: :total, type: "BigDecimal" }, { name: :tags },
                                       { name: :age, type: "Integer", default: "0" }, { name: :labels, type: "Array", default: "[]" } ])
        expect(order[:embeds]).to eq([
          { type: :embeds_many, name: :line_items },
          { type: :embeds_one, name: :address },
          { type: :embedded_in, name: :customer }
        ])
      end
    end
  end

  # Errbit: App embeds five relations and has_many one, and was listed with
  # one association; ErrorReport, a plain class under app/models, was a model.
  describe "Mongoid apps, what counts" do
    it "counts embeds as associations and lists only documents and their subclasses" do
      Dir.mktmpdir do |dir|
        FileUtils.mkdir_p(File.join(dir, "config"))
        FileUtils.mkdir_p(File.join(dir, "app", "models"))
        File.write(File.join(dir, "config", "mongoid.yml"), "development:\n  clients: {}\n")
        File.write(File.join(dir, "app", "models", "app.rb"), <<~RUBY)
          class App
            include Mongoid::Document
            embeds_many :watchers
            embeds_one :issue_tracker, class_name: "Tracker"
            has_many :problems
          end
        RUBY
        File.write(File.join(dir, "app", "models", "special_app.rb"), "class SpecialApp < App\nend\n")
        File.write(File.join(dir, "app", "models", "error_report.rb"), "class ErrorReport\n  def initialize(x); end\nend\n")

        result = described_class.new(RailsAiContext::StaticApp.new(dir)).static_call

        associations = result["App"][:associations]
        expect(associations.map { |a| [ a[:name], a[:type] ] }).to contain_exactly(
          %w[problems has_many], %w[watchers embeds_many], %w[issue_tracker embeds_one]
        )
        expect(associations.find { |a| a[:name] == "issue_tracker" }[:class_name]).to eq("Tracker")
        expect(result.keys).to contain_exactly("App", "SpecialApp")
      end
    end
  end

  describe "hybrid AR + Mongoid apps" do
    it "static_call gives AR-style table details for AR models and Mongoid details for Mongoid documents" do
      Dir.mktmpdir do |dir|
        FileUtils.mkdir_p(File.join(dir, "config"))
        FileUtils.mkdir_p(File.join(dir, "app", "models"))
        File.write(File.join(dir, "config", "mongoid.yml"), "development:\n  clients: {}\n")
        File.write(File.join(dir, "app", "models", "widget.rb"), <<~RUBY)
          class Widget < ApplicationRecord
            belongs_to :factory
          end
        RUBY
        File.write(File.join(dir, "app", "models", "customer.rb"), <<~RUBY)
          class Customer
            include Mongoid::Document
            field :name, type: String
          end
        RUBY

        result = described_class.new(RailsAiContext::StaticApp.new(dir)).static_call

        widget = result["Widget"]
        expect(widget[:table_name]).to eq("widgets")
        expect(widget[:associations].map { |a| a[:name] }).to contain_exactly("factory")
        expect(widget).not_to have_key(:mongoid)

        customer = result["Customer"]
        expect(customer[:mongoid]).to be(true)
        expect(customer[:fields]).to include(name: :name, type: "String")
        expect(customer).not_to have_key(:table_name)
      end
    end

    it "#call keeps AR-reflected entries (with real table_name) instead of discarding them when AppKind.mongoid? is true" do
      allow(RailsAiContext::AppKind).to receive(:mongoid?).and_return(true)

      result = introspector.call

      expect(result["User"][:table_name]).to eq("users")
      expect(result["User"][:associations]).not_to be_empty
    end
  end
  # `validates_with` registers an ActiveModel::Validator, which has no
  # #attributes - only EachValidator does. One of them anywhere on a model
  # replaced the entire response with "Error inspecting X".
  describe "a model using validates_with" do
    before do
      stub_const("QaShapeValidator", Class.new(ActiveModel::Validator) do
        def validate(record); end
      end)
      Comment.validates_with QaShapeValidator
    end

    after { Comment.clear_validators! }

    it "still returns the model instead of one error line" do
      result = described_class.new(Rails.application).call
      expect(result["Comment"]).to be_a(Hash)
      expect(result["Comment"][:error]).to be_nil
    end

    # The booted tier reads validations off the source now, and reflection
    # is the fallback for a file it cannot read - where a bare Validator must
    # still not raise.
    it "reports the validator with no attributes rather than raising, from reflection" do
      validations = described_class.new(Rails.application).send(:extract_validations, Comment)
      kinds = validations.map { |v| v[:kind] }
      expect(kinds).to include(a_string_matching(/qa_shape|QaShape/i))
    end
  end
  # The two tiers used to hand back different types for one key: a Hash from
  # the booted path, a flat Array from the listener. Every consumer filters on
  # `is_a?(Hash)`, so static-tier callbacks vanished and a Hash lookup against
  # the Array raised TypeError.
  describe "#static_call callbacks shape" do
    it "groups callbacks by type, like the booted tier" do
      Dir.mktmpdir do |dir|
        FileUtils.mkdir_p(File.join(dir, "app", "models"))
        File.write(File.join(dir, "app", "models", "post.rb"), <<~RUBY)
          class Post < ApplicationRecord
            before_validation :normalize_title
            after_create_commit :notify_subscribers
          end
        RUBY

        result = described_class.new(RailsAiContext::StaticApp.new(dir)).static_call
        callbacks = result["Post"][:callbacks]

        expect(callbacks).to be_a(Hash)
        expect(callbacks["before_validation"]).to include("normalize_title")
        expect(callbacks["after_create_commit"]).to include("notify_subscribers")
      end
    end
  end
  # `concerns/` under app/models is the Zeitwerk root for mixins, and an app
  # may also nest one anywhere - OpenProject has app/models/queries/operators/
  # concerns. But a nested concerns/ is an ordinary namespace, so a class
  # declared there is a model like any other and dropping it by directory name
  # loses it.
  describe "models under a concerns directory" do
    def models_in(files)
      Dir.mktmpdir do |dir|
        files.each do |relative, body|
          full = File.join(dir, "app", "models", relative)
          FileUtils.mkdir_p(File.dirname(full))
          File.write(full, body)
        end
        return described_class.new(RailsAiContext::StaticApp.new(dir)).static_call.keys
      end
    end

    it "keeps a class declared in a nested concerns namespace" do
      expect(models_in(
        "billing/concerns/plan.rb" => "module Billing\n  module Concerns\n    class Plan < ApplicationRecord\n    end\n  end\nend\n"
      )).to include("Billing::Concerns::Plan")
    end

    it "drops a mixin in a nested concerns namespace" do
      expect(models_in(
        "queries/operators/concerns/dateish.rb" => "module Queries\n  module Operators\n    module Concerns\n      module Dateish\n      end\n    end\n  end\nend\n"
      )).to be_empty
    end

    # The autoload root does not namespace its files, so the path is not their
    # name; keeping one would report a constant the app does not have.
    it "drops everything under the top-level concerns root" do
      expect(models_in(
        "concerns/trashable.rb" => "module Trashable\nend\n",
        "concerns/oddity.rb" => "class Oddity < ApplicationRecord\nend\n"
      )).to be_empty
    end
  end
  # Rails derives the table from the class name through its own inflector, so
  # OAuthClientConfig is `oauth_client_configs`. The static tier has no
  # inflector, and `"OAuthClientConfig".underscore` is `o_auth_client_config` -
  # a table no app has. The file's own name is the reliable source: Zeitwerk
  # resolved the constant from it, so it already carries the inflection.
  describe "the table a model reads" do
    def write_models(dir, files)
      files.each do |relative, source|
        path = File.join(dir, "app", "models", relative)
        FileUtils.mkdir_p(File.dirname(path))
        File.write(path, source)
      end
    end

    it "reads it from the file, not from the inflected name" do
      Dir.mktmpdir do |dir|
        FileUtils.mkdir_p(File.join(dir, "app", "models"))
        File.write(File.join(dir, "app", "models", "oauth_client_config.rb"),
                   "class OAuthClientConfig < ApplicationRecord\nend\n")

        result = described_class.new(RailsAiContext::StaticApp.new(dir)).static_call

        expect(result["OAuthClientConfig"][:table_name]).to eq("oauth_client_configs")
      end
    end

    # A namespaced model's table is the demodulized name, the way Rails does it
    # without an explicit table_name_prefix.
    it "uses the basename for a namespaced model" do
      Dir.mktmpdir do |dir|
        FileUtils.mkdir_p(File.join(dir, "app", "models", "billing"))
        File.write(File.join(dir, "app", "models", "billing", "invoice.rb"),
                   "module Billing\n  class Invoice < ApplicationRecord\n  end\nend\n")

        result = described_class.new(RailsAiContext::StaticApp.new(dir)).static_call

        expect(result["Billing::Invoice"][:table_name]).to eq("invoices")
      end
    end

    it "reads an STI base's table interpolating the configured prefix and suffix" do
      Dir.mktmpdir do |dir|
        write_models(dir,
          "principal.rb" => "class Principal < ApplicationRecord\n  self.table_name = \"\#{table_name_prefix}users\#{table_name_suffix}\"\nend\n",
          "group.rb" => "class Group < Principal\nend\n")
        RailsAiContext::Introspectors::TableName.clear_namespace_prefixes

        result = described_class.new(RailsAiContext::StaticApp.new(dir)).static_call

        expect(result.slice("Principal", "Group").transform_values { |m| m[:table_name] })
          .to eq("Principal" => "users", "Group" => "users")
      end
    end

    # compute_table_name (7.0 and 8.1): a class nested in a concrete model takes
    # the parent's singular table as a prefix, so Project::Phase is project_phases.
    it "prefixes a class nested in a model with the model's singular table" do
      Dir.mktmpdir do |dir|
        write_models(dir,
          "project.rb" => "class Project < ApplicationRecord\nend\n",
          "project/phase.rb" => "class Project::Phase < ApplicationRecord\nend\n",
          "base.rb" => "class Base < ApplicationRecord\n  self.abstract_class = true\nend\n",
          "base/note.rb" => "class Base::Note < ApplicationRecord\nend\n")

        result = described_class.new(RailsAiContext::StaticApp.new(dir)).static_call

        expect(result["Project::Phase"][:table_name]).to eq("project_phases")
        expect(result["Base::Note"][:table_name]).to eq("notes")
      end
    end

    it "reads a habtm join_table built from the affixes as the table it names" do
      Dir.mktmpdir do |dir|
        write_models(dir, "custom_field.rb" => <<~RUBY)
          class CustomField < ApplicationRecord
            has_and_belongs_to_many :projects, join_table: "\#{table_name_prefix}custom_fields_projects\#{table_name_suffix}"
          end
        RUBY
        RailsAiContext::Introspectors::TableName.clear_namespace_prefixes

        result = described_class.new(RailsAiContext::StaticApp.new(dir)).static_call

        expect(result["CustomField"][:associations].first[:options][:join_table]).to eq("custom_fields_projects")
      end
    end

    # full_table_name_prefix falls back to the class attribute, which Rails
    # sets from config.active_record.table_name_prefix.
    it "wraps a derived table in the app's configured prefix and suffix" do
      Dir.mktmpdir do |dir|
        write_models(dir,
          "project.rb" => "class Project < ApplicationRecord\nend\n",
          "admin.rb" => "module Admin\n  def self.table_name_prefix\n    'admin_'\n  end\nend\n",
          "admin/log.rb" => "module Admin\n  class Log < ApplicationRecord\n  end\nend\n")
        FileUtils.mkdir_p(File.join(dir, "config"))
        File.write(File.join(dir, "config/application.rb"),
                   "module Op\n  class Application < Rails::Application\n    config.active_record.table_name_prefix = \"op_\"\n" \
                   "    config.active_record.table_name_suffix = \"_v2\"\n  end\nend\n")
        RailsAiContext::Introspectors::TableName.clear_namespace_prefixes

        result = described_class.new(RailsAiContext::StaticApp.new(dir)).static_call

        expect(result["Project"][:table_name]).to eq("op_projects_v2")
        expect(result["Admin::Log"][:table_name]).to eq("admin_logs_v2")
      end
    end

    it "prepends the table_name_prefix the enclosing module declares" do
      Dir.mktmpdir do |dir|
        write_models(dir,
          "admin.rb" => "module Admin\n  def self.table_name_prefix\n    'admin_'\n  end\nend\n",
          "admin/action_log.rb" => "module Admin\n  class ActionLog < ApplicationRecord\n  end\nend\n")

        result = described_class.new(RailsAiContext::StaticApp.new(dir)).static_call

        expect(result["Admin::ActionLog"][:table_name]).to eq("admin_action_logs")
      end
    end

    # Rails' isolate_namespace defines table_name_prefix on the namespace as
    # "#{underscore(mod.name).tr('/', '_')}_", and nothing in the model file
    # says so.
    it "reads the prefix an in-repo engine isolates its namespace with" do
      Dir.mktmpdir do |dir|
        FileUtils.mkdir_p(File.join(dir, "plugins", "rss", "app", "models", "discourse_rss_polling"))
        FileUtils.mkdir_p(File.join(dir, "plugins", "rss", "lib", "discourse_rss_polling"))
        FileUtils.touch(File.join(dir, "plugins", "rss", "plugin.rb"))
        File.write(File.join(dir, "plugins", "rss", "app", "models", "discourse_rss_polling", "rss_feed.rb"),
                   "module DiscourseRssPolling\n  class RssFeed < ActiveRecord::Base\n  end\nend\n")
        File.write(File.join(dir, "plugins", "rss", "lib", "discourse_rss_polling", "engine.rb"),
                   "module DiscourseRssPolling\n  class Engine < ::Rails::Engine\n    isolate_namespace DiscourseRssPolling\n  end\nend\n")

        result = described_class.new(RailsAiContext::StaticApp.new(dir)).static_call

        expect(result["DiscourseRssPolling::RssFeed"][:table_name]).to eq("discourse_rss_polling_rss_feeds")
      end
    end

    it "lets an explicit table_name beat the isolated namespace's prefix" do
      Dir.mktmpdir do |dir|
        FileUtils.mkdir_p(File.join(dir, "plugins", "chat", "app", "models", "chat"))
        FileUtils.mkdir_p(File.join(dir, "plugins", "chat", "lib", "chat"))
        FileUtils.touch(File.join(dir, "plugins", "chat", "plugin.rb"))
        File.write(File.join(dir, "plugins", "chat", "app", "models", "chat", "message.rb"),
                   "module Chat\n  class Message < ActiveRecord::Base\n    self.table_name = \"chat_messages\"\n  end\nend\n")
        File.write(File.join(dir, "plugins", "chat", "lib", "chat", "engine.rb"),
                   "module Chat\n  class Engine < ::Rails::Engine\n    isolate_namespace Chat\n  end\nend\n")

        result = described_class.new(RailsAiContext::StaticApp.new(dir)).static_call

        expect(result["Chat::Message"][:table_name]).to eq("chat_messages")
      end
    end

    # The engine defines its prefix only `unless mod.respond_to?`, so a module
    # that declares one keeps it.
    it "lets a module's own declared prefix beat the isolated namespace's" do
      Dir.mktmpdir do |dir|
        FileUtils.mkdir_p(File.join(dir, "plugins", "rss", "app", "models", "feeds"))
        FileUtils.mkdir_p(File.join(dir, "plugins", "rss", "lib", "feeds"))
        FileUtils.touch(File.join(dir, "plugins", "rss", "plugin.rb"))
        File.write(File.join(dir, "plugins", "rss", "app", "models", "feeds.rb"),
                   "module Feeds\n  def self.table_name_prefix\n    'legacy_'\n  end\nend\n")
        File.write(File.join(dir, "plugins", "rss", "app", "models", "feeds", "entry.rb"),
                   "module Feeds\n  class Entry < ActiveRecord::Base\n  end\nend\n")
        File.write(File.join(dir, "plugins", "rss", "lib", "feeds", "engine.rb"),
                   "module Feeds\n  class Engine < ::Rails::Engine\n    isolate_namespace Feeds\n  end\nend\n")

        result = described_class.new(RailsAiContext::StaticApp.new(dir)).static_call

        expect(result["Feeds::Entry"][:table_name]).to eq("legacy_entries")
      end
    end

    # Nothing isolates DiscourseGithubPlugin, so its models keep the plain
    # demodulized table - a prefix invented here would be a wrong answer where
    # today's is right.
    it "leaves a namespace no engine isolates alone" do
      Dir.mktmpdir do |dir|
        FileUtils.mkdir_p(File.join(dir, "plugins", "gh", "app", "models", "discourse_github_plugin"))
        FileUtils.touch(File.join(dir, "plugins", "gh", "plugin.rb"))
        File.write(File.join(dir, "plugins", "gh", "app", "models", "discourse_github_plugin", "github_commit.rb"),
                   "module DiscourseGithubPlugin\n  class GithubCommit < ActiveRecord::Base\n  end\nend\n")

        result = described_class.new(RailsAiContext::StaticApp.new(dir)).static_call

        expect(result["DiscourseGithubPlugin::GithubCommit"][:table_name]).to eq("github_commits")
      end
    end

    it "appends the table_name_suffix the enclosing module declares" do
      Dir.mktmpdir do |dir|
        write_models(dir,
          "legacy.rb" => "module Legacy\n  self.table_name_suffix = '_v1'\nend\n",
          "legacy/invoice.rb" => "module Legacy\n  class Invoice < ApplicationRecord\n  end\nend\n")

        result = described_class.new(RailsAiContext::StaticApp.new(dir)).static_call

        expect(result["Legacy::Invoice"][:table_name]).to eq("invoices_v1")
      end
    end

    it "reads an explicit assignment the model makes" do
      Dir.mktmpdir do |dir|
        write_models(dir,
          "follow_recommendation.rb" =>
            "class FollowRecommendation < ApplicationRecord\n  self.table_name = :global_follow_recommendations\nend\n")

        result = described_class.new(RailsAiContext::StaticApp.new(dir)).static_call

        expect(result["FollowRecommendation"][:table_name]).to eq("global_follow_recommendations")
      end
    end

    # An STI child has no table of its own; it reads its parent's.
    it "takes the table of the model it inherits from" do
      Dir.mktmpdir do |dir|
        write_models(dir,
          "post.rb" => "class Post < ApplicationRecord\nend\n",
          "article.rb" => "class Article < Post\nend\n")

        result = described_class.new(RailsAiContext::StaticApp.new(dir)).static_call

        expect(result["Article"][:table_name]).to eq("posts")
      end
    end

    it "keeps its own table under an abstract base" do
      Dir.mktmpdir do |dir|
        write_models(dir,
          "analytics/record.rb" =>
            "module Analytics\n  class Record < ApplicationRecord\n    self.abstract_class = true\n  end\nend\n",
          "analytics/visit.rb" => "module Analytics\n  class Visit < Analytics::Record\n  end\nend\n")

        result = described_class.new(RailsAiContext::StaticApp.new(dir)).static_call

        expect(result["Analytics::Visit"][:table_name]).to eq("visits")
      end
    end

    # The two tiers must answer the same table for the same file. The static
    # fixture's tagging.rb and the booted dummy app's are the same source.
    it "matches the booted tier on the same model's explicit assignment" do
      root = File.expand_path("../../../fixtures/static_app", __dir__)

      static = described_class.new(RailsAiContext::StaticApp.new(root)).static_call
      booted = described_class.new(Rails.application).call

      expect(static["Tagging"][:table_name]).to eq("comments")
      expect(static["Tagging"][:table_name]).to eq(booted["Tagging"][:table_name])
    end
  end

  # The booted tier rejects `abstract_class?`, so a namespaced base class is
  # not a model there. GitLab has three - Ci::ApplicationRecord,
  # PackageMetadata::ApplicationRecord, SecApplicationRecord - and the static
  # tier counted all three, giving the same app two different model counts.
  describe "an abstract base class" do
    it "is not a model in the static tier either" do
      Dir.mktmpdir do |dir|
        FileUtils.mkdir_p(File.join(dir, "app", "models", "ci"))
        File.write(File.join(dir, "app", "models", "ci", "application_record.rb"), <<~RUBY)
          module Ci
            class ApplicationRecord < ::ApplicationRecord
              self.abstract_class = true
            end
          end
        RUBY
        File.write(File.join(dir, "app", "models", "widget.rb"), "class Widget < ApplicationRecord\nend\n")

        result = described_class.new(RailsAiContext::StaticApp.new(dir)).static_call

        expect(result.keys).to contain_exactly("Widget")
      end
    end

    # The multi-database guide's own shape: a per-connection abstract base in
    # its own file, with the connection's models under it. Dropping the base
    # from the walk loses every model on that connection.
    it "still reaches a model whose base is an abstract class in another file" do
      Dir.mktmpdir do |dir|
        FileUtils.mkdir_p(File.join(dir, "app", "models", "analytics"))
        File.write(File.join(dir, "app", "models", "application_record.rb"), <<~RUBY)
          class ApplicationRecord < ActiveRecord::Base
            primary_abstract_class
          end
        RUBY
        File.write(File.join(dir, "app", "models", "analytics", "record.rb"), <<~RUBY)
          module Analytics
            class Record < ApplicationRecord
              self.abstract_class = true
            end
          end
        RUBY
        File.write(File.join(dir, "app", "models", "analytics", "event.rb"), <<~RUBY)
          module Analytics
            class Event < Record
            end
          end
        RUBY

        result = described_class.new(RailsAiContext::StaticApp.new(dir)).static_call

        expect(result.keys).to contain_exactly("Analytics::Event")
      end
    end
  end

  # Zeitwerk never loads a file with a syntax error, so reflection never sees
  # the class and the answer was that the model does not exist - while its
  # table was listed as having no model at all.
  describe "a model file the app cannot load" do
    let(:broken) { Rails.root.join("app", "models", "broken_widget.rb") }

    around do |example|
      File.write(broken, "class BrokenWidget < ApplicationRecord\n  def x\n    if true\nend\n")
      example.run
    ensure
      FileUtils.rm_f(broken)
    end

    it "is named with the error rather than left out of the booted answer" do
      result = described_class.new(Rails.application).call

      expect(result).to have_key("BrokenWidget")
      expect(result["BrokenWidget"][:error]).to be_a(String)
      expect(result["BrokenWidget"][:file]).to eq("app/models/broken_widget.rb")
    end

    it "still names the table it maps to, so the table is not read as orphaned" do
      result = described_class.new(Rails.application).call

      expect(result["BrokenWidget"][:table_name]).to eq("broken_widgets")
    end

    it "states the error without the machine path of the app" do
      allow(ActiveSupport::Inflector).to receive(:constantize).and_call_original
      allow(ActiveSupport::Inflector).to receive(:constantize).with("BrokenWidget")
        .and_raise(SyntaxError, "#{File.realpath(broken)}:4: syntax errors found")

      error = RailsAiContext::Introspector.new(Rails.application).call.dig(:models, "BrokenWidget", :error)

      expect(error).not_to include(Rails.root.to_s)
      expect(error).not_to include(File.realpath(Rails.root.to_s))
      expect(error).to include("app/models/broken_widget.rb")
    end
  end

  # A root outside app/models holds generators and gem subclasses too; one of
  # them that will not load is not a model, and static leaves it out.
  describe "a class outside the model directories that cannot load" do
    let(:domain) { Rails.root.join("app", "zz_domain") }

    around do |example|
      FileUtils.mkdir_p(domain)
      File.write(domain.join("zz_widget_generator.rb"), "class ZzWidgetGenerator < Rails::Generators::NamedBase\nend\n")
      File.write(domain.join("zz_unknown_base.rb"), "class ZzUnknownBase < SomeGem::Base\nend\n")
      File.write(domain.join("zz_lost_record.rb"), "class ZzLostRecord < ApplicationRecord\nend\n")
      example.run
    ensure
      FileUtils.rm_rf(domain)
    end

    it "is left out of the booted answer unless its chain reaches a model base, as in static" do
      allow(RailsAiContext::PathResolver).to receive(:extra_model_roots).and_return([ domain.to_s ])

      booted = described_class.new(Rails.application).call
      static = described_class.new(RailsAiContext::StaticApp.new(Rails.root.to_s)).static_call

      expect(booted.keys).not_to include("ZzWidgetGenerator", "ZzUnknownBase")
      expect(static.keys).not_to include("ZzWidgetGenerator", "ZzUnknownBase")
      expect(booted["ZzLostRecord"]).to include(file: "app/zz_domain/zz_lost_record.rb")
      expect(booted["ZzLostRecord"][:error]).to be_a(String)
      expect(static.keys).to include("ZzLostRecord")
    end

    it "keeps one in the booted tier whose superclass is a record base loaded from outside the scanned roots" do
      allow(RailsAiContext::PathResolver).to receive(:extra_model_roots).and_return([ domain.to_s ])
      stub_const("ZzVendorish::Model", Class.new(ActiveRecord::Base) { self.abstract_class = true })
      stub_const("ZzShop::Model", Class.new(ActiveRecord::Base) { self.abstract_class = true })
      FileUtils.mkdir_p(domain.join("zz_shop"))
      File.write(domain.join("zz_vendor_widget.rb"), "class ZzVendorWidget < ZzVendorish::Model\nend\n")
      File.write(domain.join("zz_shop", "zz_shop_item.rb"), "module ZzShop\n  class ZzShopItem < Model\n  end\nend\n")
      Object.autoload(:ZzVendorWidget, domain.join("zz_vendor_widget.rb").to_s)
      ZzShop.autoload(:ZzShopItem, domain.join("zz_shop", "zz_shop_item.rb").to_s)

      booted = described_class.new(Rails.application).call

      expect(booted.keys).to include("ZzVendorWidget", "ZzShop::ZzShopItem")
      expect(booted.keys).not_to include("ZzUnknownBase", "ZzWidgetGenerator")
    ensure
      # Abstract, so the loaded classes left in ActiveRecord::Base.descendants list nowhere else.
      [ [ Object, :ZzVendorWidget ], [ ZzShop, :ZzShopItem ] ].each do |owner, name|
        next unless owner.const_defined?(name, false)

        owner.const_get(name, false).abstract_class = true if owner.autoload?(name).nil?
        owner.send(:remove_const, name)
      end
    end
  end

  # Rebuilding app/models/<underscored>.rb from the name is wrong for a model
  # in a pack or an engine, and wrong wherever the app registers an inflection,
  # so the file travels with the model the way it does with a controller.
  describe "the file a model was read from" do
    # The booted tier answers from the constant, so it must not fall back to
    # rebuilding the path from the name either.
    it "carries it in the booted tier" do
      expect(described_class.new(Rails.application).call["Post"][:file]).to eq("app/models/post.rb")
    end

    it "carries it for a model outside app/models" do
      Dir.mktmpdir do |dir|
        path = File.join(dir, "packs", "billing", "app", "models", "invoice.rb")
        FileUtils.mkdir_p(File.dirname(path))
        File.write(path, "class Invoice < ApplicationRecord\nend\n")

        result = described_class.new(RailsAiContext::StaticApp.new(dir)).static_call

        expect(result["Invoice"][:file]).to eq("packs/billing/app/models/invoice.rb")
      end
    end

    it "names a model by the constant its source declares" do
      Dir.mktmpdir do |dir|
        path = File.join(dir, "app", "models", "activitypub", "activity.rb")
        FileUtils.mkdir_p(File.dirname(path))
        File.write(path, "module ActivityPub\n  class Activity < ApplicationRecord\n  end\nend\n")

        result = described_class.new(RailsAiContext::StaticApp.new(dir)).static_call

        expect(result.keys).to include("ActivityPub::Activity")
        expect(result["ActivityPub::Activity"][:file]).to eq("app/models/activitypub/activity.rb")
      end
    end
  end

  describe "#static_call containment" do
    it "refuses a symlink that leaves the models directory" do
      Dir.mktmpdir do |dir|
        Dir.mktmpdir do |elsewhere|
          FileUtils.mkdir_p(File.join(dir, "app", "models"))
          File.write(File.join(dir, "app", "models", "good.rb"), "class Good < ApplicationRecord\nend\n")
          File.write(File.join(elsewhere, "secret.rb"), "class Secret < ApplicationRecord\nend\n")
          File.symlink(File.join(elsewhere, "secret.rb"), File.join(dir, "app", "models", "secret.rb"))

          result = described_class.new(RailsAiContext::StaticApp.new(dir)).static_call
          expect(result.keys).to contain_exactly("Good")
        end
      end
    end
  end

  # Both tiers read the callbacks off the model's own source. The booted tier
  # used to answer off Rails' event chains, which carry the framework's own
  # registrations and drop every block callback.
  # Reflection dropped every `if:` (a Proc has no text) and rendered
  # `validates_with RecordValidator` as a kind with no subject,
  # while the walk dropped `validates_with` and `validates_date` entirely.
  # Discourse's Chat::NullUser < User: a subclass of a concrete model, with
  # no type column, so no STI entry either.
  describe "a booted model's concerns" do
    it "are resolved once for both the list and its sources" do
      Dir.mktmpdir do |dir|
        FileUtils.mkdir_p(File.join(dir, "app", "models"))
        File.write(File.join(dir, "app", "models", "user.rb"), "class User < ApplicationRecord\nend\n")
        model = Class.new(ApplicationRecord) { self.table_name = "users" }
        model.define_singleton_method(:name) { "User" }
        introspector = described_class.new(RailsAiContext::StaticApp.new(dir))
        expect(introspector).to receive(:booted_concerns).once.and_call_original

        introspector.send(:extract_model_details, model)
      end
    end
  end

  describe "the parent model a subclass names" do
    it "is the concrete parent in both tiers, and absent under an abstract base" do
      Dir.mktmpdir do |dir|
        FileUtils.mkdir_p(File.join(dir, "app", "models", "chat"))
        File.write(File.join(dir, "app", "models", "user.rb"), "class User < ApplicationRecord\nend\n")
        File.write(File.join(dir, "app", "models", "chat", "null_user.rb"), "module Chat\n  class NullUser < User\n  end\nend\n")
        parent = Class.new(ApplicationRecord) { self.table_name = "users" }
        parent.define_singleton_method(:name) { "User" }
        child = Class.new(parent)
        child.define_singleton_method(:name) { "Chat::NullUser" }
        introspector = described_class.new(RailsAiContext::StaticApp.new(dir))
        static = introspector.static_call

        expect(introspector.send(:extract_model_details, child)[:parent_model]).to eq("User")
        expect(introspector.send(:extract_model_details, parent)).not_to have_key(:parent_model)
        expect(static["Chat::NullUser"][:parent_model]).to eq("User")
        expect(static["User"]).not_to have_key(:parent_model)
      end
    end
  end

  # Discourse's Topic writes `after_create do` and includes
  # RateLimiter::OnCreateRecord, whose `included do` writes one too.
  describe "a block callback in the model and in a concern" do
    it "keeps both, each credited to its own source" do
      Dir.mktmpdir do |dir|
        FileUtils.mkdir_p(File.join(dir, "app", "models", "concerns"))
        File.write(File.join(dir, "app", "models", "concerns", "limited.rb"), <<~RUBY)
          module Limited
            extend ActiveSupport::Concern

            included do
              after_create do
                limit!
              end
            end
          end
        RUBY
        File.write(File.join(dir, "app", "models", "topic.rb"),
                   "class Topic < ApplicationRecord\n  include Limited\n\n  after_create do\n    log!\n  end\nend\n")

        topic = described_class.new(RailsAiContext::StaticApp.new(dir)).static_call["Topic"]

        expect(topic[:callbacks]["after_create"]).to eq([ "[inline_block]", "[inline_block]" ])
        expect(topic[:concern_callbacks].map { |c| c[:from_concern] }).to eq([ "Limited" ])
        expect(topic[:concern_callbacks].flat_map(&:keys)).not_to include(:owner, :rank, :chain_at)
      end
    end
  end

  # Rails adds a presence validator for a required belongs_to; no line of the
  # model declares it, and the booted tier had dropped it.
  describe "the implicit presence of a required belongs_to" do
    def write_app(dir, application: "config.load_defaults 7.1")
      FileUtils.mkdir_p(File.join(dir, "app", "models"))
      FileUtils.mkdir_p(File.join(dir, "config"))
      File.write(File.join(dir, "config", "application.rb"),
                 "module Demo\n  class Application < Rails::Application\n    #{application}\n  end\nend\n")
      File.write(File.join(dir, "app", "models", "comment.rb"), <<~RUBY)
        class Comment < ApplicationRecord
          belongs_to :post
          belongs_to :user, optional: true
          belongs_to :editor, required: false
          validates :body, presence: true
        end
      RUBY
    end

    def implicit(validations)
      validations.select { |v| v[:implicit] }.map { |v| v[:attributes] }
    end

    it "lists it in both tiers, marked, ahead of the declared ones" do
      Dir.mktmpdir do |dir|
        write_app(dir)
        model = Class.new(ApplicationRecord) do
          self.table_name = "comments"
          self.belongs_to_required_by_default = true
          belongs_to :post
          belongs_to :user, optional: true
          belongs_to :editor, required: false, class_name: "User"
          validates :body, presence: true
        end
        model.define_singleton_method(:name) { "Comment" }
        introspector = described_class.new(RailsAiContext::StaticApp.new(dir))

        booted = introspector.send(:extract_model_details, model)[:validations]
        static = introspector.static_call["Comment"][:validations]

        strip = ->(list) { list.map { |v| v.slice(:kind, :attributes, :options, :implicit) } }
        expect(strip.call(booted)).to eq(strip.call(static))
        expect(implicit(booted)).to eq([ %w[post] ])
        expect(booted.map { |v| v[:attributes] }).to eq([ %w[post], %w[body] ])
      end
    end

    it "is off statically when the app turns the default off or predates it" do
      [ "config.load_defaults 7.1\n    config.active_record.belongs_to_required_by_default = false",
        "config.load_defaults 4.2", "" ].each do |application|
        Dir.mktmpdir do |dir|
          write_app(dir, application: application)

          static = described_class.new(RailsAiContext::StaticApp.new(dir)).static_call["Comment"][:validations]

          expect(implicit(static)).to eq([]), application
        end
      end
    end

    # `optional: !Rails.env.test?` is decided when the class loads; statically
    # the presence holds only when that expression is false.
    it "leaves out an excluded association in both tiers" do
      Dir.mktmpdir do |dir|
        write_app(dir)
        allow(RailsAiContext.configuration).to receive(:excluded_association_names).and_return(%w[post])

        static = described_class.new(RailsAiContext::StaticApp.new(dir)).static_call["Comment"][:validations]

        expect(implicit(static)).to eq([])
      end
    end

    # OFN's Subscription writes `self.belongs_to_required_by_default = false`.
    it "follows a class's own setting, and its parent's in a subclass" do
      Dir.mktmpdir do |dir|
        write_app(dir)
        File.write(File.join(dir, "app", "models", "comment.rb"),
                   "class Comment < ApplicationRecord\n  self.belongs_to_required_by_default = false\n  belongs_to :post\nend\n")
        File.write(File.join(dir, "app", "models", "reply.rb"), "class Reply < Comment\n  belongs_to :author\nend\n")

        models = described_class.new(RailsAiContext::StaticApp.new(dir)).static_call

        expect(implicit(models["Comment"][:validations])).to eq([])
        expect(implicit(models["Reply"][:validations])).to eq([])
      end
    end

    # Rails turns `required:` into `optional: !required`, over any optional:,
    # so `required: nil` is optional; `optional: nil` falls back to the default.
    it "reads required: nil as optional and lets required: decide over optional:" do
      Dir.mktmpdir do |dir|
        write_app(dir)
        File.write(File.join(dir, "app", "models", "comment.rb"), <<~RUBY)
          class Comment < ApplicationRecord
            belongs_to :post, required: nil
            belongs_to :user, optional: nil
            belongs_to :editor, optional: true, required: true
          end
        RUBY
        model = Class.new(ApplicationRecord) do
          self.table_name = "comments"
          self.belongs_to_required_by_default = true
          belongs_to :post, required: nil
          belongs_to :user, optional: nil
          belongs_to :editor, optional: true, required: true, class_name: "User"
        end
        model.define_singleton_method(:name) { "Comment" }
        introspector = described_class.new(RailsAiContext::StaticApp.new(dir))

        static = introspector.static_call["Comment"][:validations]
        booted = introspector.send(:extract_model_details, model)[:validations]

        expect(implicit(static)).to eq([ %w[user], %w[editor] ])
        expect(implicit(booted)).to eq(implicit(static))
      end
    end

    it "is conditional on an optional: the source cannot evaluate" do
      Dir.mktmpdir do |dir|
        write_app(dir)
        File.write(File.join(dir, "app", "models", "comment.rb"),
                   "class Comment < ApplicationRecord\n  belongs_to :maybe, optional: !Rails.env.test?\nend\n")

        static = described_class.new(RailsAiContext::StaticApp.new(dir)).static_call["Comment"][:validations]

        expect(static).to eq([ { kind: "presence", attributes: [ "maybe" ], options: {}, implicit: true,
                                 implicit_if: "optional: !Rails.env.test? is false" } ])
      end
    end

    it "reads the setting from any initializer, on any receiver, and skips comments" do
      Dir.mktmpdir do |dir|
        write_app(dir, application: "config.load_defaults 7.1\n    # config.active_record.belongs_to_required_by_default = true")
        FileUtils.mkdir_p(File.join(dir, "config", "initializers"))
        File.write(File.join(dir, "config", "initializers", "active_record.rb"),
                   "ActiveRecord::Base.belongs_to_required_by_default = true\n")
        File.write(File.join(dir, "config", "initializers", "zz_late.rb"),
                   "Rails.application.config.active_record.belongs_to_required_by_default = false\n")

        static = described_class.new(RailsAiContext::StaticApp.new(dir)).static_call["Comment"][:validations]

        expect(implicit(static)).to eq([])
      end
    end

    # load_defaults assigns the setting where it runs; a later line wins either way.
    it "takes the setting from the last line that sets it, initializers after application.rb" do
      {
        [ "config.active_record.belongs_to_required_by_default = false\n    config.load_defaults 7.1", nil ] => [ %w[post] ],
        [ "config.active_record.belongs_to_required_by_default = false\n    config.load_defaults 4.2", nil ] => [],
        [ "config.load_defaults 7.1",
          "Rails.application.config.active_record.belongs_to_required_by_default = false" ] => []
      }.each do |(application, initializer), expected|
        Dir.mktmpdir do |dir|
          write_app(dir, application: application)
          if initializer
            FileUtils.mkdir_p(File.join(dir, "config", "initializers"))
            File.write(File.join(dir, "config", "initializers", "defaults.rb"), "#{initializer}\n")
          end

          static = described_class.new(RailsAiContext::StaticApp.new(dir)).static_call["Comment"][:validations]

          expect(implicit(static)).to eq(expected), application
        end
      end
    end

    # The value is decided when the app boots, so statically the presence
    # holds only when that expression is true.
    it "is conditional on a setting the source cannot evaluate, app-wide or in the class" do
      {
        "config.load_defaults 7.1\n    config.active_record.belongs_to_required_by_default = ENV.fetch(\"R\", \"1\") == \"1\"" =>
          [ nil, "belongs_to_required_by_default = ENV.fetch(\"R\", \"1\") == \"1\" is true" ],
        "config.load_defaults 7.1" => [ "self.belongs_to_required_by_default = strict?",
                                        "belongs_to_required_by_default = strict? is true" ]
      }.each do |application, (class_line, condition)|
        Dir.mktmpdir do |dir|
          write_app(dir, application: application)
          File.write(File.join(dir, "app", "models", "comment.rb"),
                     "class Comment < ApplicationRecord\n  #{class_line}\n  belongs_to :post\n  belongs_to :user, optional: true\nend\n")

          static = described_class.new(RailsAiContext::StaticApp.new(dir)).static_call["Comment"][:validations]

          expect(static).to eq([ { kind: "presence", attributes: [ "post" ], options: {}, implicit: true,
                                   implicit_if: condition } ]), application
        end
      end
    end

    # Rails tests the setting for truth, so a literal nil turns it off.
    it "is off for a literal nil, app-wide or in the class" do
      {
        "config.load_defaults 7.1\n    config.active_record.belongs_to_required_by_default = nil" => "",
        "config.load_defaults 7.1" => "self.belongs_to_required_by_default = nil"
      }.each do |application, class_line|
        Dir.mktmpdir do |dir|
          write_app(dir, application: application)
          File.write(File.join(dir, "app", "models", "comment.rb"),
                     "class Comment < ApplicationRecord\n  #{class_line}\n  belongs_to :post\nend\n")

          static = described_class.new(RailsAiContext::StaticApp.new(dir)).static_call["Comment"][:validations]

          expect(static).to eq([]), application
        end
      end
    end

    it "is on for load_defaults written as the running version" do
      Dir.mktmpdir do |dir|
        write_app(dir, application: "config.load_defaults Rails::VERSION::STRING.to_f")

        static = described_class.new(RailsAiContext::StaticApp.new(dir)).static_call["Comment"][:validations]

        expect(implicit(static)).to eq([ %w[post] ])
      end
    end

    it "is on when a new_framework_defaults file turns it on" do
      Dir.mktmpdir do |dir|
        write_app(dir, application: "")
        FileUtils.mkdir_p(File.join(dir, "config", "initializers"))
        File.write(File.join(dir, "config", "initializers", "new_framework_defaults.rb"),
                   "Rails.application.config.active_record.belongs_to_required_by_default = true\n")

        static = described_class.new(RailsAiContext::StaticApp.new(dir)).static_call["Comment"][:validations]

        expect(implicit(static)).to eq([ %w[post] ])
      end
    end
  end

  # A User with has_secure_password; Devise :validatable and gem modules
  # add validators no app line declares, and reflection is where they live.
  describe "validations no app line declares" do
    def lock_rails(dir, version)
      File.write(File.join(dir, "Gemfile"), "gem \"rails\"\n")
      File.write(File.join(dir, "Gemfile.lock"),
                 "GEM\n  remote: https://rubygems.org/\n  specs:\n    rails (#{version})\n\nDEPENDENCIES\n  rails\n")
    end

    def secure_password_validations(dir)
      FileUtils.mkdir_p(File.join(dir, "app", "models"))
      File.write(File.join(dir, "app", "models", "account.rb"), "class Account < ApplicationRecord\n  has_secure_password\nend\n")
      described_class.new(RailsAiContext::StaticApp.new(dir)).static_call["Account"][:validations]
        .map { |v| [ v[:kind], v[:options], v[:added_by] ] }
    end

    it "reads has_secure_password as the app's locked Rails registers it" do
      Dir.mktmpdir do |dir|
        lock_rails(dir, "7.0.8")
        expect(secure_password_validations(dir)).to eq([ [ "length", { maximum: 72 }, "has_secure_password" ],
                                                         [ "confirmation", {}, "has_secure_password" ] ])
      end
      Dir.mktmpdir do |dir|
        lock_rails(dir, "7.1.3")
        expect(secure_password_validations(dir)).to eq([ [ "confirmation", {}, "has_secure_password" ] ])
      end
    end

    it "says which Rails it assumes when no lockfile names one" do
      Dir.mktmpdir do |dir|
        expect(secure_password_validations(dir)).to eq([
          [ "confirmation", {}, "has_secure_password, assuming Rails 7.1+ as Gemfile.lock names no Rails version" ]
        ])
      end
    end

    it "keeps reflection's, and the static tier reads the ones a known macro adds" do
      Dir.mktmpdir do |dir|
        lock_rails(dir, "7.2.2")
        FileUtils.mkdir_p(File.join(dir, "app", "models"))
        File.write(File.join(dir, "app", "models", "account.rb"), <<~RUBY)
          class Account < ApplicationRecord
            has_secure_password
            validates :title, presence: true
          end
        RUBY
        gem_module = Module.new do
          extend ActiveSupport::Concern
          included { validates :body, length: { maximum: 10 } }
        end
        model = Class.new(ApplicationRecord) do
          self.table_name = "posts"
          # What has_secure_password registers; bcrypt is not in this bundle.
          validates_confirmation_of :password, allow_nil: true
          validates :title, presence: true
          include gem_module
        end
        model.define_singleton_method(:name) { "Account" }
        introspector = described_class.new(RailsAiContext::StaticApp.new(dir))

        booted = introspector.send(:extract_model_details, model)[:validations]
        static = introspector.static_call["Account"][:validations]

        shape = ->(list) { list.map { |v| [ v[:kind], v[:attributes], v[:added_by], v[:reflection_only] ] } }
        expect(shape.call(booted)).to eq([
          [ "presence", %w[title], nil, nil ],
          [ "confirmation", %w[password], "has_secure_password", nil ],
          [ "length", %w[body], nil, true ]
        ])
        expect(shape.call(static)).to eq(shape.call(booted).first(2))
        expect(booted[1][:options]).to include(allow_nil: true)
      end
    end

    # `LIMITS.each { |field, limit| validates field, length: ... }` declares a computed attribute.
    it "names a computed attribute statically and the ones it ran for when booted" do
      Dir.mktmpdir do |dir|
        FileUtils.mkdir_p(File.join(dir, "app", "models"))
        File.write(File.join(dir, "app", "models", "form.rb"), <<~RUBY)
          class Form < ApplicationRecord
            LIMITS = { title: 5, body: 9 }.freeze
            LIMITS.each { |field, limit| validates field, length: { maximum: limit } }
          end
        RUBY
        model = Class.new(ApplicationRecord) do
          self.table_name = "posts"
          { title: 5, body: 9 }.each { |field, limit| validates field, length: { maximum: limit } }
        end
        model.define_singleton_method(:name) { "Form" }
        introspector = described_class.new(RailsAiContext::StaticApp.new(dir))

        booted = introspector.send(:extract_model_details, model)[:validations]
        static = introspector.static_call["Form"][:validations]

        expect(static.map { |v| [ v[:kind], v[:attributes], v[:computed_attributes] ] }).to eq([ [ "length", [], %w[field] ] ])
        expect(booted.map { |v| [ v[:attributes], v[:computed_attributes], v[:reflection_only] ] })
          .to eq([ [ %w[title], %w[field], nil ], [ %w[body], %w[field], nil ] ])
      end
    end

    it "leaves a known macro's validator of the loop's kind under its own label" do
      Dir.mktmpdir do |dir|
        FileUtils.mkdir_p(File.join(dir, "app", "models"))
        File.write(File.join(dir, "app", "models", "form.rb"), <<~RUBY)
          class Form < ApplicationRecord
            devise :database_authenticatable, :validatable
            { title: 5 }.each { |field, limit| validates field, length: { maximum: limit } }
          end
        RUBY
        model = Class.new(ApplicationRecord) do
          self.table_name = "posts"
          # What devise :validatable registers for the password length.
          validates_length_of :password, within: 6..128, allow_blank: true
          { title: 5 }.each { |field, limit| validates field, length: { maximum: limit } }
        end
        model.define_singleton_method(:name) { "Form" }

        booted = described_class.new(RailsAiContext::StaticApp.new(dir)).send(:extract_model_details, model)[:validations]
        lengths = booted.select { |v| v[:kind] == "length" }

        expect(lengths.map { |v| [ v[:attributes], v[:computed_attributes], v[:added_by] ] })
          .to contain_exactly([ %w[title], %w[field], nil ], [ %w[password], nil, "devise :validatable" ])
      end
    end

    it "reads devise :validatable statically" do
      Dir.mktmpdir do |dir|
        FileUtils.mkdir_p(File.join(dir, "app", "models"))
        File.write(File.join(dir, "app", "models", "member.rb"),
                   "class Member < ApplicationRecord\n  devise :database_authenticatable, :validatable\nend\n")

        static = described_class.new(RailsAiContext::StaticApp.new(dir)).static_call["Member"][:validations]

        expect(static.map { |v| [ v[:kind], v[:attributes].first ] }).to eq(
          [ %w[presence email], %w[uniqueness email], %w[format email],
            %w[presence password], %w[confirmation password], %w[length password] ]
        )
        expect(static.map { |v| v[:added_by] }.uniq).to eq([ "devise :validatable" ])
      end
    end
  end

  # A booted count carried PaperTrail::Version, which static never sees.
  # A gem that puts a module into every model (an APM agent's base
  # extensions) is no concern of the model; one a gem macro includes into
  # this model alone is, and says where it came from.
  describe "the concerns a booted model lists" do
    it "keeps per-model modules, drops every-model ones, and agrees with static on Devise" do
      Dir.mktmpdir do |dir|
        FileUtils.mkdir_p(File.join(dir, "app", "models"))
        File.write(File.join(dir, "app", "models", "account.rb"),
                   "class Account < ApplicationRecord\n  include Trackable\n  devise :lockable\n  acts_as_widget\nend\n")
        every_model = Module.new
        stub_const("ApmAgent::BaseExtensions", every_model)
        stub_const("Devise::Models::Authenticatable", Module.new)
        stub_const("Devise::Models::Lockable", Module.new)
        stub_const("WidgetGem::Widget", Module.new)
        stub_const("Trackable", Module.new)
        model = Class.new(ApplicationRecord) do
          self.table_name = "posts"
          include every_model
          include Trackable
          include Devise::Models::Authenticatable
          include Devise::Models::Lockable
          include WidgetGem::Widget
        end
        model.define_singleton_method(:name) { "Account" }
        # Devise's modules are hidden by default; this app shows them.
        allow(RailsAiContext.configuration).to receive(:excluded_concerns).and_return([])
        introspector = described_class.new(RailsAiContext::StaticApp.new(dir))
        allow(introspector).to receive(:every_model_modules).and_return([ every_model, *ActiveRecord::Base.ancestors ])

        booted = introspector.send(:extract_model_details, model)
        static = introspector.static_call["Account"]

        expect(booted[:concerns]).not_to include("ApmAgent::BaseExtensions")
        expect(booted[:concerns]).to include("Trackable", "Devise::Models::Lockable", "WidgetGem::Widget")
        expect(booted[:concern_sources]).to eq("Devise::Models::Authenticatable" => "devise", "Devise::Models::Lockable" => "devise",
                                               "WidgetGem::Widget" => "a gem macro (booted only)")
        expect(static[:concerns]).to contain_exactly("Trackable", "Devise::Models::Authenticatable", "Devise::Models::Lockable")
        expect(static[:concern_sources]).to eq("Devise::Models::Authenticatable" => "devise", "Devise::Models::Lockable" => "devise")
      end
    end
  end

  describe "a concern the model builds with concerning" do
    it "is listed by both tiers as the model's own, not a gem's" do
      Dir.mktmpdir do |dir|
        FileUtils.mkdir_p(File.join(dir, "app", "models"))
        File.write(File.join(dir, "app", "models", "widget_log.rb"),
                   "class WidgetLog < ApplicationRecord\n  concerning :Exporting do\n    def export; end\n  end\nend\n")
        model = Class.new(ApplicationRecord) { self.table_name = "posts" }
        model.define_singleton_method(:name) { "WidgetLog" }
        model.const_set(:Exporting, Module.new)
        model.include(model::Exporting)
        stub_const("WidgetLog", model)
        introspector = described_class.new(RailsAiContext::StaticApp.new(dir))

        booted = introspector.send(:extract_model_details, model)
        static = introspector.static_call["WidgetLog"]

        expect(booted[:concerns]).to include("WidgetLog::Exporting")
        expect(booted[:concern_sources].to_h).not_to have_key("WidgetLog::Exporting")
        expect(static[:concerns]).to eq([ "WidgetLog::Exporting" ])
        expect(static[:concern_sources]).to be_nil
      end
    end
  end

  # Kaminari includes its extension into the app's abstract base from an
  # inherited hook, so every model has it and no file of the app says so.
  describe "what a gem puts into the app's abstract base" do
    it "is neither a concern nor a class method of the model" do
      Dir.mktmpdir do |dir|
        FileUtils.mkdir_p(File.join(dir, "app", "models"))
        File.write(File.join(dir, "app", "models", "category.rb"), "class Category < AppBase\n  acts_as_widget\nend\n")
        stub_const("PagerGem::ModelExtension", Module.new)
        stub_const("WidgetGem::Widget", Module.new)
        base = Class.new(ActiveRecord::Base) { self.abstract_class = true }
        stub_const("AppBase", base)
        base.include(PagerGem::ModelExtension)
        base.define_singleton_method(:page) { |*| all }
        model = Class.new(base) do
          self.table_name = "posts"
          include WidgetGem::Widget
        end
        model.define_singleton_method(:name) { "Category" }
        model.define_singleton_method(:featured) { all }
        introspector = described_class.new(RailsAiContext::StaticApp.new(dir))

        booted = introspector.send(:extract_model_details, model)

        expect(booted[:concerns]).to eq([ "WidgetGem::Widget" ])
        expect(booted[:class_methods]).to include("featured")
        expect(booted[:class_methods]).not_to include("page")
      end
    end
  end

  # Kaminari's hook includes into every direct ActiveRecord::Base child, so a
  # model with no abstract base of its own gets what the app's base gets.
  describe "what a gem puts into a model that is a direct ActiveRecord::Base child" do
    it "is neither a concern nor a class method of the model" do
      Dir.mktmpdir do |dir|
        FileUtils.mkdir_p(File.join(dir, "app", "models"))
        File.write(File.join(dir, "app", "models", "legacy.rb"), "class Legacy < ActiveRecord::Base\nend\n")
        stub_const("PagerGem::ModelExtension", Module.new)
        base = Class.new(ActiveRecord::Base) { self.abstract_class = true }
        stub_const("AppBase", base)
        model = Class.new(ActiveRecord::Base) { self.table_name = "posts" }
        model.define_singleton_method(:name) { "Legacy" }
        [ base, model ].each do |klass|
          klass.include(PagerGem::ModelExtension)
          klass.define_singleton_method(:page) { |*| all }
        end
        introspector = described_class.new(RailsAiContext::StaticApp.new(dir))

        booted = introspector.send(:extract_model_details, model)

        expect(booted[:concerns]).to eq([])
        expect(booted[:class_methods]).not_to include("page")
      end
    end
  end

  describe "a model that sets its own primary key" do
    it "records the key the model sets, and its STI child's, on both tiers" do
      Dir.mktmpdir do |dir|
        FileUtils.mkdir_p(File.join(dir, "app", "models"))
        File.write(File.join(dir, "app", "models", "legacy_widget.rb"), "class LegacyWidget < ApplicationRecord\n  self.primary_key = :label\nend\n")
        File.write(File.join(dir, "app", "models", "special_widget.rb"), "class SpecialWidget < LegacyWidget\nend\n")
        File.write(File.join(dir, "app", "models", "plain.rb"), "class Plain < ApplicationRecord\nend\n")
        model = Class.new(ApplicationRecord) do
          self.table_name = "posts"
          self.primary_key = "label"
        end
        model.define_singleton_method(:name) { "LegacyWidget" }
        introspector = described_class.new(RailsAiContext::StaticApp.new(dir))

        static = introspector.static_call

        expect(introspector.send(:extract_model_details, model)[:primary_key]).to eq("label")
        expect(static["LegacyWidget"][:primary_key]).to eq("label")
        expect(static["SpecialWidget"][:primary_key]).to eq("label")
        expect(static["Plain"]).not_to have_key(:primary_key)
      end
    end
  end

  describe "the primary key of a booted model with no connection" do
    it "never asks the database, and still reads a key the source assigns" do
      Dir.mktmpdir do |dir|
        FileUtils.mkdir_p(File.join(dir, "app", "models"))
        File.write(File.join(dir, "app", "models", "legacy_widget.rb"), "class LegacyWidget < ApplicationRecord\n  self.primary_key = :label\nend\n")
        introspector = described_class.new(RailsAiContext::StaticApp.new(dir))
        introspector.static_call
        models = %w[LegacyWidget Plain].map do |name|
          Class.new(ApplicationRecord) { self.table_name = "posts" }.tap do |model|
            model.define_singleton_method(:name) { name }
            allow(model).to receive(:connected?).and_return(false)
            expect(model).not_to receive(:primary_key)
          end
        end

        expect(models.map { |model| introspector.send(:model_primary_key, model) }).to eq([ "label", nil ])
      end
    end
  end

  describe "a custom validate method with a condition" do
    it "keeps the condition in both tiers" do
      Dir.mktmpdir do |dir|
        FileUtils.mkdir_p(File.join(dir, "app", "models"))
        File.write(File.join(dir, "app", "models", "form.rb"),
                   "class Form < ApplicationRecord\n  validate :uses_left, on: :create\n  validate :selectable, if: :changed?\n  validate :always\nend\n")
        model = Class.new(ApplicationRecord) { self.table_name = "posts" }
        model.define_singleton_method(:name) { "Form" }
        introspector = described_class.new(RailsAiContext::StaticApp.new(dir))

        expected = { "uses_left" => { on: :create }, "selectable" => { if: :changed? } }
        expect(introspector.static_call["Form"][:custom_validate_conditions]).to eq(expected)
        expect(introspector.send(:extract_model_details, model)[:custom_validate_conditions]).to eq(expected)
      end
    end
  end

  describe "a model a gem defines" do
    it "is the gem's, while a gem the app sits inside is the app's" do
      Dir.mktmpdir do |dir|
        File.write(File.join(dir, "gem_version_record.rb"), "class GemVersionRecord < ActiveRecord::Base\nend\n")
        load File.join(dir, "gem_version_record.rb")
        introspector = described_class.new(Rails.application)

        allow(Gem).to receive(:loaded_specs).and_return("paper_trail" => double(full_gem_path: dir))
        expect(introspector.send(:gem_defined?, GemVersionRecord)).to be(true)
        expect(introspector.send(:gem_defined?, Post)).to be(false)

        allow(Gem).to receive(:loaded_specs).and_return("self" => double(full_gem_path: File.dirname(Rails.root.to_s)))
        expect(introspector.send(:gem_defined?, Post)).to be(false)
      ensure
        Object.send(:remove_const, :GemVersionRecord) if Object.const_defined?(:GemVersionRecord, false)
      end
    end
  end

  describe "a gem installed under the app root" do
    it "is the gem's in a vendored bundle, and the app's as an in-repo path gem" do
      Dir.mktmpdir do |root|
        gem_dir = File.join(root, "vendor", "bundle", "ruby", "3.4.0", "gems", "audit_trail-1.0.0")
        FileUtils.mkdir_p(gem_dir)
        File.write(File.join(gem_dir, "gem_version_record.rb"), "class GemVersionRecord < ActiveRecord::Base\nend\n")
        load File.join(gem_dir, "gem_version_record.rb")
        introspector = described_class.new(RailsAiContext::StaticApp.new(root))

        vendored = double(full_gem_path: gem_dir, source: Bundler::Source::Rubygems.allocate)
        allow(Gem).to receive(:loaded_specs).and_return("audit_trail" => vendored)
        expect(introspector.send(:gem_defined?, GemVersionRecord)).to be(true)

        in_repo = double(full_gem_path: gem_dir, source: Bundler::Source::Path.allocate)
        allow(Gem).to receive(:loaded_specs).and_return("audit_trail" => in_repo)
        expect(introspector.send(:gem_defined?, GemVersionRecord)).to be(false)
      ensure
        Object.send(:remove_const, :GemVersionRecord) if Object.const_defined?(:GemVersionRecord, false)
      end
    end
  end

  describe "validations in both tiers" do
    let(:source) do
      <<~RUBY
        class Document < ApplicationRecord
          validates :first_name, presence: true, if: ->(d) { d.approved? }
          validates_date :date_of_birth, presence: true, if: ->(d) { d.approved? }
          validates_with RecordValidator
        end
      RUBY
    end

    def write_document(dir)
      FileUtils.mkdir_p(File.join(dir, "app", "models"))
      File.write(File.join(dir, "app", "models", "document.rb"), source)
    end

    it "lists the same validations, conditions included, in both tiers" do
      Dir.mktmpdir do |dir|
        write_document(dir)
        model = Class.new(ApplicationRecord) do
          self.table_name = "posts"
          validates :first_name, presence: true, if: ->(d) { d.approved? }
        end
        model.define_singleton_method(:name) { "Document" }
        introspector = described_class.new(RailsAiContext::StaticApp.new(dir))

        booted = introspector.send(:extract_model_details, model)[:validations]
        static = introspector.static_call["Document"][:validations]

        strip = ->(list) { list.map { |v| v.slice(:kind, :attributes, :validator, :options) } }
        expect(strip.call(booted)).to eq(strip.call(static))
        expect(booted.map { |v| v[:kind] }).to eq(%w[presence validates_date validates_with])
        expect(booted.first[:options]).to include(if: "->(d) { d.approved? }")
      end
    end

    # A model whose file cannot be read still answers from reflection rather
    # than claiming it validates nothing.
    it "falls back to reflection when the model's source cannot be read" do
      Dir.mktmpdir do |dir|
        model = Class.new(ApplicationRecord) do
          self.table_name = "posts"
          validates :title, presence: true
        end
        model.define_singleton_method(:name) { "Unfiled" }

        booted = described_class.new(RailsAiContext::StaticApp.new(dir)).send(:extract_model_details, model)[:validations]

        expect(booted.map { |v| [ v[:kind], v[:attributes] ] }).to include([ "presence", [ "title" ] ])
      end
    end
  end

  describe "callbacks in both tiers" do
    def write_model(dir, class_name, source)
      path = File.join(dir, "app", "models", "#{class_name.underscore}.rb")
      FileUtils.mkdir_p(File.dirname(path))
      File.write(path, source)
      path
    end

    def booted_callbacks(dir, class_name)
      model = Class.new(ApplicationRecord) { self.table_name = "posts" }
      model.define_singleton_method(:name) { class_name }
      described_class.new(RailsAiContext::StaticApp.new(dir)).send(:extract_model_details, model)[:callbacks]
    end

    def static_callbacks(dir, class_name)
      described_class.new(RailsAiContext::StaticApp.new(dir)).static_call[class_name][:callbacks]
    end

    # Rails keeps one entry per kind and method: the later declaration removes
    # the earlier one and runs at its own position, under its own condition.
    it "keeps only the later declaration of a method declared twice for one kind" do
      Dir.mktmpdir do |dir|
        write_model(dir, "Order", <<~RUBY)
          class Order < ApplicationRecord
            before_save :sync, if: :a?
            before_save :stamp
            before_save :sync, unless: -> { b? }
            after_save :sync
            after_create_commit :notify
            after_update_commit :notify
          end
        RUBY

        details = described_class.new(RailsAiContext::StaticApp.new(dir)).static_call["Order"]

        expect(details[:callbacks]).to eq(
          "before_save" => %w[stamp sync], "after_save" => %w[sync], "after_update_commit" => %w[notify]
        )
        expect(details[:callback_conditions]).to eq("before_save" => [ nil, { unless: "-> { b? }" } ])
        expect(booted_callbacks(dir, "Order")).to eq(details[:callbacks])
      end
    end

    # A redeclaration in a method body nothing calls never runs, so the
    # declaration it would have replaced stays.
    it "keeps a callback that an uncalled concern method redeclares" do
      Dir.mktmpdir do |dir|
        write_model(dir, "Concerns::Tracked", <<~RUBY)
          module Tracked
            extend ActiveSupport::Concern
            included do
              before_save :track
            end
            class_methods do
              def tracked_loudly
                before_save :track, if: :loud?
              end
            end
          end
        RUBY
        write_model(dir, "Note", "class Note < ApplicationRecord\n  include Tracked\nend\n")

        details = described_class.new(RailsAiContext::StaticApp.new(dir)).static_call["Note"]

        expect(details.values_at(:callbacks, :callback_conditions)).to eq([ { "before_save" => %w[track] }, {} ])
        expect(booted_callbacks(dir, "Note")).to eq(details[:callbacks])
      end
    end

    # The model's own class method declares its callback where the class
    # calls it, and not at all when nothing does.
    it "applies a callback in the model's own class method only where it is called" do
      Dir.mktmpdir do |dir|
        write_model(dir, "Quiet", <<~RUBY)
          class Quiet < ApplicationRecord
            before_save :track
            def self.loud!
              before_save :track, if: :loud?
            end
          end
        RUBY
        write_model(dir, "Loud", <<~RUBY)
          class Loud < ApplicationRecord
            def self.loud!
              before_save :track, if: :loud?
            end
            before_save :first
            loud!
            before_save :last
          end
        RUBY

        static = described_class.new(RailsAiContext::StaticApp.new(dir)).static_call

        expect(static["Quiet"].values_at(:callbacks, :callback_conditions))
          .to eq([ { "before_save" => %w[track] }, {} ])
        expect(static["Loud"].values_at(:callbacks, :callback_conditions))
          .to eq([ { "before_save" => %w[first track last] }, { "before_save" => [ nil, { if: :loud? }, nil ] } ])
        expect(booted_callbacks(dir, "Quiet")).to eq(static["Quiet"][:callbacks])
        expect(booted_callbacks(dir, "Loud")).to eq(static["Loud"][:callbacks])
      end
    end

    # Runtime: each of these runs before_save :first, :track, :last; Cycle runs :first, :x.
    it "follows a call with self as receiver and a call made from another of the class's methods" do
      Dir.mktmpdir do |dir|
        write_model(dir, "Selfcall", <<~RUBY)
          class Selfcall < ApplicationRecord
            def self.loud!
              before_save :track
            end
            before_save :first
            self.loud!
            before_save :last
          end
        RUBY
        write_model(dir, "Indirect", <<~RUBY)
          class Indirect < ApplicationRecord
            def self.setup
              loud!
            end
            def self.loud!
              before_save :track
            end
            before_save :first
            setup
            before_save :last
          end
        RUBY
        write_model(dir, "Viaself", <<~RUBY)
          class Viaself < ApplicationRecord
            class << self
              def setup
                self.loud!
              end
              def loud!
                before_save :track
              end
            end
            before_save :first
            setup
            before_save :last
          end
        RUBY
        write_model(dir, "Cycle", <<~RUBY)
          class Cycle < ApplicationRecord
            def self.a(go = true)
              b if go
            end
            def self.b
              a(false)
              before_save :x
            end
            before_save :first
            a
          end
        RUBY

        static = described_class.new(RailsAiContext::StaticApp.new(dir)).static_call

        %w[Selfcall Indirect Viaself].each do |name|
          expect(static[name][:callbacks]).to eq("before_save" => %w[first track last])
          expect(booted_callbacks(dir, name)).to eq(static[name][:callbacks])
        end
        expect(static["Cycle"][:callbacks]).to eq("before_save" => %w[first x])
      end
    end

    # Runtime: Gb runs :g_only, :b and Gc :g_only, :b, :d.
    it "keeps the callbacks of a module nested in the model's file that the model includes" do
      Dir.mktmpdir do |dir|
        write_model(dir, "Gb", <<~RUBY)
          class Gb < ApplicationRecord
            module Gst
              extend ActiveSupport::Concern
              class_methods do
                def gstamp
                  before_save :g_only
                end
              end
              included do
                gstamp
              end
            end
            include Gst
            before_save :b
          end
        RUBY
        write_model(dir, "Gc", "class Gc < Gb\n  include Gb::Gst\n  before_save :d\nend\n")

        static = described_class.new(RailsAiContext::StaticApp.new(dir)).static_call

        expect(static["Gb"][:callbacks]).to eq("before_save" => %w[g_only b])
        expect(static["Gc"][:callbacks]).to eq("before_save" => %w[g_only b d])
        expect(booted_callbacks(dir, "Gb")).to eq(static["Gb"][:callbacks])
      end
    end

    # Runtime: Gd runs :a, :b, :g; Ge :a, :b, :g, :c; Gn :a, :u; Gx only :b.
    it "places a nested module's callbacks where the model includes it, and none through extend" do
      Dir.mktmpdir do |dir|
        concern = ->(body) { "  module Gst\n    extend ActiveSupport::Concern\n#{body}  end\n" }
        block = "    included do\n      before_save :g\n    end\n"
        write_model(dir, "Gd", "class Gd < ApplicationRecord\n  before_save :a\n#{concern.call(block)}  before_save :b\n  include Gst\nend\n")
        write_model(dir, "Ge", <<~RUBY)
          class Ge < ApplicationRecord
            before_save :a
            module Gst
              extend ActiveSupport::Concern
              class_methods do
                def gstamp
                  before_save :g
                end
              end
              included do
                gstamp
              end
            end
            before_save :b
            include Gst
            before_save :c
          end
        RUBY
        write_model(dir, "Gn", <<~RUBY)
          class Gn < ApplicationRecord
            module Unused
              extend ActiveSupport::Concern
              included do
                before_save :never
              end
            end
            module Used
              extend ActiveSupport::Concern
              included do
                before_save :u
              end
            end
            before_save :a
            include Used
          end
        RUBY
        write_model(dir, "Gx", "class Gx < ApplicationRecord\n#{concern.call(block)}  extend Gst\n  before_save :b\nend\n")

        static = described_class.new(RailsAiContext::StaticApp.new(dir)).static_call

        expected = { "Gd" => %w[a b g], "Ge" => %w[a b g c], "Gn" => %w[a u], "Gx" => %w[b] }
        expect(expected.keys.to_h { |name| [ name, static[name][:callbacks]["before_save"] ] }).to eq(expected)
        expected.each_key { |name| expect(booted_callbacks(dir, name)).to eq(static[name][:callbacks]) }
      end
    end

    # Ruby runs the nearest class method for a call: the class's own, then its
    # concerns', then a base's; never an instance method, a nested class's, or an
    # override a base's own code cannot see. Runtime: Nest :first; Inst :first,
    # :track, :last; Ochild :first, :child_v; Tchild2 :s, :tb, :c; Uchild :ub,
    # :first, :track, :last; OwnWins :first, :own.
    it "credits a call only to the class method Ruby runs for it" do
      Dir.mktmpdir do |dir|
        write_model(dir, "Concerns::Stampy", <<~RUBY)
          module Stampy
            extend ActiveSupport::Concern
            class_methods do
              def stamp
                before_save :s
              end
            end
          end
        RUBY
        write_model(dir, "Concerns::Hooky2", "module Hooky2\n  extend ActiveSupport::Concern\n  included do\n    loud!\n    stamp\n  end\nend\n")
        write_model(dir, "Nest", <<~RUBY)
          class Nest < ApplicationRecord
            class Inner
              def self.setup
                stamp
              end
            end
            include Stampy
            def self.setup
            end
            before_save :first
            setup
          end
        RUBY
        write_model(dir, "Inst", <<~RUBY)
          class Inst < ApplicationRecord
            def loud!
              before_save :inst
            end
            def self.loud!
              before_save :track
            end
            before_save :first
            loud!
            before_save :last
          end
        RUBY
        write_model(dir, "Obase", "class Obase < ApplicationRecord\n  def self.setup\n    before_save :base_v\n  end\nend\n")
        write_model(dir, "Ochild", <<~RUBY)
          class Ochild < Obase
            def self.setup
              before_save :child_v
            end
            before_save :first
            setup
          end
        RUBY
        write_model(dir, "Tbase2", <<~RUBY)
          class Tbase2 < ApplicationRecord
            include Stampy
            def self.loud!
            end
            include Hooky2
            before_save :tb
          end
        RUBY
        write_model(dir, "Tchild2", <<~RUBY)
          class Tchild2 < Tbase2
            include Stampy
            def self.loud!
              before_save :track
            end
            before_save :c
          end
        RUBY

        write_model(dir, "Concerns::Hooky", "module Hooky\n  extend ActiveSupport::Concern\n  included do\n    loud!\n  end\nend\n")
        write_model(dir, "Ubase", "class Ubase < ApplicationRecord\n  def self.loud!\n    before_save :track\n  end\n  before_save :ub\nend\n")
        write_model(dir, "Uchild", "class Uchild < Ubase\n  before_save :first\n  include Hooky\n  before_save :last\nend\n")
        write_model(dir, "OwnWins", <<~RUBY)
          class OwnWins < ApplicationRecord
            include Stampy
            def self.stamp
              before_save :own
            end
            before_save :first
            stamp
          end
        RUBY

        static = described_class.new(RailsAiContext::StaticApp.new(dir)).static_call

        expect(static["Uchild"][:callbacks]).to eq("before_save" => %w[ub first track last])
        expect(static["OwnWins"][:callbacks]).to eq("before_save" => %w[first own])
        expect(static["Nest"][:callbacks]).to eq("before_save" => %w[first])
        expect(static["Inst"][:callbacks]).to eq("before_save" => %w[first track last])
        expect(static["Ochild"][:callbacks]).to eq("before_save" => %w[first child_v])
        expect(static["Tchild2"][:callbacks]).to eq("before_save" => %w[s tb c])
        %w[Nest Inst OwnWins].each { |name| expect(booted_callbacks(dir, name)).to eq(static[name][:callbacks]) }
      end
    end

    describe "a class-body call resolved the way Ruby resolves it" do
      def stampy(dir)
        write_model(dir, "Concerns::Stampy", <<~RUBY)
          module Stampy
            extend ActiveSupport::Concern
            class_methods do
              def stamp
                before_save :s
              end
            end
          end
        RUBY
      end

      def static_save(dir, kind = "before_save")
        described_class.new(RailsAiContext::StaticApp.new(dir)).static_call.transform_values { |m| m.dig(:callbacks, kind) }
      end

      # Runtime: SuperOver :first, :s, :own; Qchild :b1, :c1; Rchild :s, :c; SupChild :gb, :sc;
      # TwoSuper :first, :pre, :s, :s2; RelaySuper :a, :s, :own, :b.
      it "runs what a super in the reached method reaches, at the super" do
        Dir.mktmpdir do |dir|
          stampy(dir)
          write_model(dir, "Concerns::StampSup", "module StampSup\n  extend ActiveSupport::Concern\n  class_methods do\n    def stamp\n      before_save :pre\n      super\n      before_save :s2\n    end\n  end\nend\n")
          write_model(dir, "SuperOver", "class SuperOver < ApplicationRecord\n  include Stampy\n  def self.stamp\n    super\n    before_save :own\n  end\n  before_save :first\n  stamp\nend\n")
          write_model(dir, "Qbase", "class Qbase < ApplicationRecord\n  def self.stamp\n    before_save :b1\n  end\nend\n")
          write_model(dir, "Qchild", "class Qchild < Qbase\n  def self.stamp\n    super\n    before_save :c1\n  end\n  stamp\nend\n")
          write_model(dir, "Rbase", "class Rbase < ApplicationRecord\n  include Stampy\nend\n")
          write_model(dir, "Rchild", "class Rchild < Rbase\n  def self.stamp\n    super\n    before_save :c\n  end\n  stamp\nend\n")
          write_model(dir, "Gbase", "class Gbase < ApplicationRecord\n  def self.setup\n    before_save :gb\n  end\nend\n")
          write_model(dir, "SupChild", "class SupChild < Gbase\n  def self.setup\n    super\n    before_save :sc\n  end\n  setup\nend\n")
          write_model(dir, "TwoSuper", "class TwoSuper < ApplicationRecord\n  include Stampy\n  include StampSup\n  before_save :first\n  stamp\nend\n")
          write_model(dir, "RelaySuper", <<~RUBY)
            class RelaySuper < ApplicationRecord
              include Stampy
              def self.setup
                before_save :a
                stamp
                before_save :b
              end
              def self.stamp
                super
                before_save :own
              end
              setup
            end
          RUBY

          static = static_save(dir)

          expect(static.slice("SuperOver", "Qchild", "Rchild", "SupChild", "TwoSuper", "RelaySuper")).to eq(
            "SuperOver" => %w[first s own], "Qchild" => %w[b1 c1], "Rchild" => %w[s c], "SupChild" => %w[gb sc],
            "TwoSuper" => %w[first pre s s2], "RelaySuper" => %w[a s own b]
          )
          %w[SuperOver TwoSuper RelaySuper].each { |name| expect(booted_callbacks(dir, name)).to eq("before_save" => static[name]) }
        end
      end

      # Runtime: TwoConc :first, :s2; Xchild :first, :s; Zchild :first, :sc; Kchild :b, :c; ReincChild :pre, :s, :s2;
      # LateDef :first, :s, :own; PreOver :first, :p; ViaUnreached :first, :own_setup, :s; ViaTime and PlainCmM :first, :s.
      it "runs the nearest definition: own, then concerns latest first, then a base's, as of the call" do
        Dir.mktmpdir do |dir|
          stampy(dir)
          write_model(dir, "Concerns::Stampy2", "module Stampy2\n  extend ActiveSupport::Concern\n  class_methods do\n    def stamp\n      before_save :s2\n    end\n  end\nend\n")
          write_model(dir, "Concerns::StampSup", "module StampSup\n  extend ActiveSupport::Concern\n  class_methods do\n    def stamp\n      before_save :pre\n      super\n      before_save :s2\n    end\n  end\nend\n")
          write_model(dir, "Concerns::PreStamp", "module PreStamp\n  extend ActiveSupport::Concern\n  class_methods do\n    def stamp\n      before_save :p\n    end\n  end\nend\n")
          write_model(dir, "Concerns::Setty", "module Setty\n  extend ActiveSupport::Concern\n  class_methods do\n    def setup\n      before_save :sb\n    end\n  end\nend\n")
          write_model(dir, "Concerns::Setty2", "module Setty2\n  extend ActiveSupport::Concern\n  class_methods do\n    def setup\n      before_save :sc\n    end\n  end\nend\n")
          write_model(dir, "TwoConc", "class TwoConc < ApplicationRecord\n  include Stampy\n  include Stampy2\n  before_save :first\n  stamp\nend\n")
          write_model(dir, "Xbase", "class Xbase < ApplicationRecord\n  def self.stamp\n    before_save :xb\n  end\nend\n")
          write_model(dir, "Xchild", "class Xchild < Xbase\n  include Stampy\n  before_save :first\n  stamp\nend\n")
          write_model(dir, "Zbase", "class Zbase < ApplicationRecord\n  include Setty\nend\n")
          write_model(dir, "Zchild", "class Zchild < Zbase\n  include Setty2\n  before_save :first\n  setup\nend\n")
          write_model(dir, "Kbase", "class Kbase < ApplicationRecord\n  def self.stamp\n    before_save :b\n  end\n  stamp\nend\n")
          write_model(dir, "Kchild", "class Kchild < Kbase\n  include Stampy\n  before_save :c\nend\n")
          write_model(dir, "ReincBase", "class ReincBase < ApplicationRecord\n  include Stampy\nend\n")
          write_model(dir, "ReincChild", "class ReincChild < ReincBase\n  include StampSup\n  include Stampy\n  stamp\nend\n")
          write_model(dir, "LateDef", "class LateDef < ApplicationRecord\n  include Stampy\n  before_save :first\n  stamp\n  def self.stamp\n    before_save :own\n  end\n  stamp\nend\n")
          write_model(dir, "PreOver", "class PreOver < ApplicationRecord\n  def self.stamp\n    before_save :own\n  end\n  prepend PreStamp\n  before_save :first\n  stamp\nend\n")
          write_model(dir, "Concerns::HelperC", "module HelperC\n  extend ActiveSupport::Concern\n  class_methods do\n    def stamp\n      before_save :hs\n    end\n  end\nend\n")
          write_model(dir, "Concerns::SetupC", "module SetupC\n  extend ActiveSupport::Concern\n  class_methods do\n    def setup\n      include HelperC\n    end\n  end\nend\n")
          write_model(dir, "Concerns::PlainCm", "module PlainCm\n  module ClassMethods\n    def stamp\n      before_save :pc\n    end\n  end\nend\n")
          write_model(dir, "ViaUnreached", "class ViaUnreached < ApplicationRecord\n  include Stampy\n  include SetupC\n  def self.setup\n    before_save :own_setup\n  end\n  before_save :first\n  setup\n  stamp\nend\n")
          write_model(dir, "ViaTime", "class ViaTime < ApplicationRecord\n  include Stampy\n  include SetupC\n  before_save :first\n  stamp\n  setup\nend\n")
          write_model(dir, "PlainCmM", "class PlainCmM < ApplicationRecord\n  include Stampy\n  include PlainCm\n  before_save :first\n  stamp\nend\n")

          static = static_save(dir)

          expect(static.slice("TwoConc", "Xchild", "Zchild", "Kchild", "ReincChild", "LateDef", "PreOver", "ViaUnreached", "ViaTime", "PlainCmM")).to eq(
            "TwoConc" => %w[first s2], "Xchild" => %w[first s], "Zchild" => %w[first sc], "Kchild" => %w[b c],
            "ReincChild" => %w[pre s s2], "LateDef" => %w[first s own], "PreOver" => %w[first p],
            "ViaUnreached" => %w[first own_setup s], "ViaTime" => %w[first s], "PlainCmM" => %w[first s]
          )
          %w[TwoConc LateDef PreOver].each { |name| expect(booted_callbacks(dir, name)).to eq("before_save" => static[name]) }
        end
      end

      # Runtime: AliasSing :first, :x; ExtNested :first, :t; ExtNested2 :first, :e; ExtChild :c, :t; AliasChain :first, :s, :w.
      it "reads an alias in class << self and a module the class extends, nested in its file or not" do
        Dir.mktmpdir do |dir|
          write_model(dir, "Concerns::TrExt", "module TrExt\n  def track_it\n    before_save :t\n  end\nend\n")
          write_model(dir, "AliasSing", "class AliasSing < ApplicationRecord\n  class << self\n    def loud!\n      before_save :x\n    end\n    alias_method :loud2, :loud!\n  end\n  before_save :first\n  loud2\nend\n")
          write_model(dir, "ExtNested", "class ExtNested < ApplicationRecord\n  module Tr\n    def track_it\n      before_save :t\n    end\n  end\n  extend Tr\n  before_save :first\n  track_it\nend\n")
          write_model(dir, "ExtNested2", "class ExtNested2 < ApplicationRecord\n  module Tr\n    def self.extended(base)\n      base.before_save :e\n    end\n  end\n  before_save :first\n  extend Tr\nend\n")
          write_model(dir, "ExtBase", "class ExtBase < ApplicationRecord\n  extend TrExt\n  track_it\nend\n")
          write_model(dir, "ExtChild", "class ExtChild < ExtBase\n  before_save :c\n  track_it\nend\n")
          stampy(dir)
          write_model(dir, "AliasChain", "class AliasChain < ApplicationRecord\n  include Stampy\n  class << self\n    alias_method :stamp_without, :stamp\n    def stamp\n      stamp_without\n      before_save :w\n    end\n  end\n  before_save :first\n  stamp\nend\n")

          static = static_save(dir)

          expect(static.slice("AliasSing", "ExtNested", "ExtNested2", "ExtChild", "AliasChain")).to eq(
            "AliasSing" => %w[first x], "ExtNested" => %w[first t], "ExtNested2" => %w[first e], "ExtChild" => %w[c t],
            "AliasChain" => %w[first s w]
          )
          %w[AliasSing ExtNested ExtNested2].each { |name| expect(booted_callbacks(dir, name)).to eq("before_save" => static[name]) }
        end
      end

      # Runtime: T3child and T4child :bl, :tb, :c (Hooky's block ran once, in T3base);
      # HkC :hb, :hc (a plain hook runs again, resolved for the child); TwinBlock destroys block, block, :mid, block;
      # TwSetup, VtChild and VlChild :tb, :first; TwBlk and VbChild block, :first (the first include runs the block).
      it "runs a Concern's block once in the first class including it, and a plain hook on every include" do
        Dir.mktmpdir do |dir|
          write_model(dir, "Concerns::Hooky", "module Hooky\n  extend ActiveSupport::Concern\n  included do\n    loud!\n  end\nend\n")
          write_model(dir, "Concerns::Hk", "module Hk\n  def self.included(base)\n    base.loud!\n  end\nend\n")
          write_model(dir, "T3base", "class T3base < ApplicationRecord\n  def self.loud!\n    before_save :bl\n  end\n  include Hooky\n  before_save :tb\nend\n")
          write_model(dir, "T3child", "class T3child < T3base\n  def self.loud!\n    before_save :track\n  end\n  include Hooky\n  before_save :c\nend\n")
          write_model(dir, "T4child", "class T4child < T3base\n  include Hooky\n  def self.loud!\n    before_save :track\n  end\n  before_save :c\nend\n")
          write_model(dir, "HkB", "class HkB < ApplicationRecord\n  def self.loud!\n    before_save :hb\n  end\n  include Hk\nend\n")
          write_model(dir, "HkC", "class HkC < HkB\n  def self.loud!\n    before_save :hc\n  end\n  include Hk\nend\n")

          write_model(dir, "Concerns::Virt", "module Virt\n  extend ActiveSupport::Concern\n  class_methods do\n    def virt(name)\n      before_destroy { name }\n    end\n  end\nend\n")
          write_model(dir, "Concerns::Twin", "module Twin\n  extend ActiveSupport::Concern\n  included do\n    include Virt\n    virt :a\n    virt :b\n  end\nend\n")
          write_model(dir, "TwinBlock", "class TwinBlock < ApplicationRecord\n  include Twin\n  before_destroy :mid\n  virt :c\nend\n")

          static = static_save(dir)

          write_model(dir, "Concerns::Tb", "module Tb\n  extend ActiveSupport::Concern\n  included do\n    before_save :tb\n  end\nend\n")
          write_model(dir, "Concerns::Tblk", "module Tblk\n  extend ActiveSupport::Concern\n  included do\n    before_save { }\n  end\nend\n")
          write_model(dir, "TwSetup", "class TwSetup < ApplicationRecord\n  def self.setup\n    include Tb\n  end\n  setup\n  before_save :first\n  setup\nend\n")
          write_model(dir, "TwBlk", "class TwBlk < ApplicationRecord\n  def self.setup\n    include Tblk\n  end\n  setup\n  before_save :first\n  setup\nend\n")
          write_model(dir, "VtBase", "class VtBase < ApplicationRecord\n  def self.setup\n    include Tb\n  end\nend\n")
          write_model(dir, "VtChild", "class VtChild < VtBase\n  include Tb\n  before_save :first\n  setup\nend\n")
          write_model(dir, "VlChild", "class VlChild < VtBase\n  setup\n  before_save :first\n  include Tb\nend\n")
          write_model(dir, "VbBase", "class VbBase < ApplicationRecord\n  def self.setup\n    include Tblk\n  end\nend\n")
          write_model(dir, "VbChild", "class VbChild < VbBase\n  include Tblk\n  before_save :first\n  setup\nend\n")
          static = static_save(dir)

          expect(static.slice("T3child", "T4child", "HkC")).to eq("T3child" => %w[bl tb c], "T4child" => %w[bl tb c], "HkC" => %w[hb hc])
          expect(static.slice("TwSetup", "VtChild", "VlChild", "TwBlk", "VbChild")).to eq(
            "TwSetup" => %w[tb first], "VtChild" => %w[tb first], "VlChild" => %w[tb first],
            "TwBlk" => %w[[inline_block] first], "VbChild" => %w[[inline_block] first]
          )
          expect(static_save(dir, "before_destroy")["TwinBlock"]).to eq(%w[[inline_block] [inline_block] mid [inline_block]])
          expect(booted_callbacks(dir, "TwinBlock")).to eq("before_destroy" => %w[[inline_block] [inline_block] mid [inline_block]])
        end
      end

      # Runtime: PrepCm :first, :p; IncCm :first, :i; ExtBlk :first, :e4; ExtBlk2 :first, :own; SelfExtM :first, :se;
      # PlainHook :first, :ph.
      it "reads the class methods a hook or an included block adds, from where it runs" do
        Dir.mktmpdir do |dir|
          stampy(dir)
          write_model(dir, "Concerns::Pcm", "module Pcm\n  def self.prepended(base)\n    class << base\n      def stamp\n        before_save :p\n      end\n    end\n  end\nend\n")
          write_model(dir, "Concerns::Icm", "module Icm\n  def self.included(base)\n    class << base\n      def stamp\n        before_save :i\n      end\n    end\n  end\nend\n")
          write_model(dir, "Concerns::Ext4", "module Ext4\n  def stamp\n    before_save :e4\n  end\nend\n")
          write_model(dir, "Concerns::Inc4", "module Inc4\n  extend ActiveSupport::Concern\n  included do\n    extend Ext4\n    stamp\n  end\nend\n")
          write_model(dir, "Concerns::SelfExt", "module SelfExt\n  def self.included(base)\n    base.extend(self)\n  end\n\n  def stamp\n    before_save :se\n  end\nend\n")
          write_model(dir, "Concerns::PlainHk", "module PlainHk\n  def self.included(base)\n    base.extend ClassMethods\n  end\n\n  module ClassMethods\n    def stamp\n      before_save :ph\n    end\n  end\nend\n")
          write_model(dir, "PrepCm", "class PrepCm < ApplicationRecord\n  def self.stamp\n    before_save :own\n  end\n  prepend Pcm\n  before_save :first\n  stamp\nend\n")
          write_model(dir, "IncCm", "class IncCm < ApplicationRecord\n  def self.stamp\n    before_save :own\n  end\n  include Icm\n  before_save :first\n  stamp\nend\n")
          write_model(dir, "ExtBlk", "class ExtBlk < ApplicationRecord\n  before_save :first\n  include Inc4\nend\n")
          write_model(dir, "ExtBlk2", "class ExtBlk2 < ApplicationRecord\n  def self.stamp\n    before_save :own\n  end\n  before_save :first\n  include Inc4\nend\n")
          write_model(dir, "SelfExtM", "class SelfExtM < ApplicationRecord\n  include Stampy\n  include SelfExt\n  before_save :first\n  stamp\nend\n")
          write_model(dir, "PlainHook", "class PlainHook < ApplicationRecord\n  include Stampy\n  include PlainHk\n  before_save :first\n  stamp\nend\n")

          expect(static_save(dir).slice("PrepCm", "IncCm", "ExtBlk", "ExtBlk2", "SelfExtM", "PlainHook")).to eq(
            "PrepCm" => %w[first p], "IncCm" => %w[first i], "ExtBlk" => %w[first e4], "ExtBlk2" => %w[first own],
            "SelfExtM" => %w[first se], "PlainHook" => %w[first ph]
          )
        end
      end

      # Runtime: IsdM :first, :isd; IsdChild :first, :isd; IcsM :first, :ics; CevM :first, :ce; IsdLateM :s, :first, :il.
      it "reads the class methods an included block or a hook's class_eval defines, from their line in that run" do
        Dir.mktmpdir do |dir|
          stampy(dir)
          write_model(dir, "Concerns::Isd", "module Isd\n  extend ActiveSupport::Concern\n  included do\n    def self.stamp\n      before_save :isd\n    end\n  end\nend\n")
          write_model(dir, "Concerns::Ics", "module Ics\n  extend ActiveSupport::Concern\n  included do\n    class << self\n      def stamp\n        before_save :ics\n      end\n    end\n  end\nend\n")
          write_model(dir, "Concerns::Cev", "module Cev\n  def self.included(base)\n    base.class_eval do\n      def self.stamp\n        before_save :ce\n      end\n    end\n  end\nend\n")
          write_model(dir, "Concerns::IsdLate", "module IsdLate\n  extend ActiveSupport::Concern\n  included do\n    stamp\n    def self.stamp\n      before_save :il\n    end\n    stamp\n  end\nend\n")
          write_model(dir, "IsdM", "class IsdM < ApplicationRecord\n  include Isd\n  before_save :first\n  stamp\nend\n")
          write_model(dir, "IsdBase", "class IsdBase < ApplicationRecord\n  include Isd\nend\n")
          write_model(dir, "IsdChild", "class IsdChild < IsdBase\n  before_save :first\n  stamp\nend\n")
          write_model(dir, "IcsM", "class IcsM < ApplicationRecord\n  include Ics\n  before_save :first\n  stamp\nend\n")
          write_model(dir, "CevM", "class CevM < ApplicationRecord\n  include Cev\n  before_save :first\n  stamp\nend\n")
          write_model(dir, "IsdLateM", "class IsdLateM < ApplicationRecord\n  include Stampy\n  include IsdLate\n  before_save :first\n  stamp\nend\n")

          static = static_save(dir)
          expect(static.slice("IsdM", "IsdChild", "IcsM", "CevM", "IsdLateM")).to eq(
            "IsdM" => %w[first isd], "IsdChild" => %w[first isd], "IcsM" => %w[first ics], "CevM" => %w[first ce], "IsdLateM" => %w[s first il]
          )
          %w[IsdM CevM].each { |name| expect(booted_callbacks(dir, name)).to eq("before_save" => static[name]) }
        end
      end

      # Runtime: ActsM :first, :aa, :sm; ActsYM :first, :yh; ActsZM :first, :s, :x.
      it "follows an extend in a module's class method from its call, and runs the extended module's hook there" do
        Dir.mktmpdir do |dir|
          stampy(dir)
          write_model(dir, "Concerns::ActsX", "module ActsX\n  def self.included(base)\n    base.extend ClassMethods\n  end\n\n  module ClassMethods\n    def acts_as_x\n      before_save :aa\n      extend SingletonMethods\n    end\n  end\n\n  module SingletonMethods\n    def stamp\n      before_save :sm\n    end\n  end\nend\n")
          write_model(dir, "Concerns::Yh", "module Yh\n  def self.extended(base)\n    base.before_save :yh\n  end\nend\n")
          write_model(dir, "Concerns::ActsY", "module ActsY\n  def self.included(base)\n    base.extend ClassMethods\n  end\n\n  module ClassMethods\n    def acts_as_y\n      extend Yh\n    end\n  end\nend\n")
          write_model(dir, "Concerns::X4", "module X4\n  def stamp\n    before_save :x\n  end\nend\n")
          write_model(dir, "Concerns::ActsZ", "module ActsZ\n  extend ActiveSupport::Concern\n  class_methods do\n    def acts_as_z\n      extend X4\n    end\n  end\nend\n")
          write_model(dir, "ActsM", "class ActsM < ApplicationRecord\n  include ActsX\n  before_save :first\n  acts_as_x\n  stamp\nend\n")
          write_model(dir, "ActsYM", "class ActsYM < ApplicationRecord\n  include ActsY\n  before_save :first\n  acts_as_y\nend\n")
          write_model(dir, "ActsZM", "class ActsZM < ApplicationRecord\n  include Stampy\n  include ActsZ\n  before_save :first\n  stamp\n  acts_as_z\n  stamp\nend\n")

          static = static_save(dir)
          expect(static.slice("ActsM", "ActsYM", "ActsZM")).to eq("ActsM" => %w[first aa sm], "ActsYM" => %w[first yh], "ActsZM" => %w[first s x])
          %w[ActsM ActsYM].each { |name| expect(booted_callbacks(dir, name)).to eq("before_save" => static[name]) }
        end
      end

      # Runtime: OrderM :s; Order2M :x.
      it "adds a module a Concern's block extends from its line in the block" do
        Dir.mktmpdir do |dir|
          stampy(dir)
          write_model(dir, "Concerns::X4", "module X4\n  def stamp\n    before_save :x\n  end\nend\n")
          write_model(dir, "Concerns::BlkExt", "module BlkExt\n  extend ActiveSupport::Concern\n  included do\n    stamp\n    extend X4\n  end\nend\n")
          write_model(dir, "Concerns::BlkExt2", "module BlkExt2\n  extend ActiveSupport::Concern\n  included do\n    extend X4\n    stamp\n  end\nend\n")
          write_model(dir, "OrderM", "class OrderM < ApplicationRecord\n  include Stampy\n  include BlkExt\nend\n")
          write_model(dir, "Order2M", "class Order2M < ApplicationRecord\n  include Stampy\n  include BlkExt2\nend\n")

          static = static_save(dir)
          expect(static.slice("OrderM", "Order2M")).to eq("OrderM" => %w[s], "Order2M" => %w[x])
          expect(booted_callbacks(dir, "OrderM")).to eq("before_save" => static["OrderM"])
        end
      end

      # Runtime: SciM :first, :sci; SpcM :first, :spc; PeM :first, :own; SciSendM :first, :ss; PreExtM :first, :ph.
      it "reads a hook's singleton_class include and prepend, and ranks what a prepend hook extends behind the class's own" do
        Dir.mktmpdir do |dir|
          stampy(dir)
          write_model(dir, "Concerns::Sci", "module Sci\n  module ClassMethods\n    def stamp\n      before_save :sci\n    end\n  end\n\n  def self.included(klass)\n    klass.singleton_class.include(ClassMethods)\n  end\nend\n")
          write_model(dir, "Concerns::SciSend", "module SciSend\n  def self.included(klass)\n    klass.singleton_class.send(:include, Cm)\n  end\n\n  module Cm\n    def stamp\n      before_save :ss\n    end\n  end\nend\n")
          write_model(dir, "Concerns::Spc", "module Spc\n  def self.prepended(base)\n    base.singleton_class.prepend ClassMethods\n  end\n\n  module ClassMethods\n    def stamp\n      before_save :spc\n    end\n  end\nend\n")
          write_model(dir, "Concerns::Pe", "module Pe\n  def self.prepended(base)\n    base.extend ClassMethods\n  end\n\n  module ClassMethods\n    def stamp\n      before_save :pe\n    end\n  end\nend\n")
          write_model(dir, "Concerns::HookExt", "module HookExt\n  def self.included(base)\n    base.extend Cm\n  end\n\n  module Cm\n    def stamp\n      before_save :he\n    end\n  end\nend\n")
          write_model(dir, "Concerns::PreHook", "module PreHook\n  def self.prepended(base)\n    base.extend Cm\n  end\n\n  module Cm\n    def stamp\n      before_save :ph\n    end\n  end\nend\n")
          write_model(dir, "SciM", "class SciM < ApplicationRecord\n  include Stampy\n  include Sci\n  before_save :first\n  stamp\nend\n")
          write_model(dir, "SciSendM", "class SciSendM < ApplicationRecord\n  include Stampy\n  include SciSend\n  before_save :first\n  stamp\nend\n")
          own = "  def self.stamp\n    before_save :own\n  end\n"
          write_model(dir, "SpcM", "class SpcM < ApplicationRecord\n#{own}  prepend Spc\n  before_save :first\n  stamp\nend\n")
          write_model(dir, "PeM", "class PeM < ApplicationRecord\n#{own}  prepend Pe\n  before_save :first\n  stamp\nend\n")
          write_model(dir, "PreExtM", "class PreExtM < ApplicationRecord\n  include HookExt\n  prepend PreHook\n  before_save :first\n  stamp\nend\n")

          expect(static_save(dir).slice("SciM", "SciSendM", "SpcM", "PeM", "PreExtM")).to eq(
            "SciM" => %w[first sci], "SciSendM" => %w[first ss], "SpcM" => %w[first spc], "PeM" => %w[first own], "PreExtM" => %w[first ph]
          )
        end
      end

      # Runtime: ScBody, SelfSc, SendSc and BlkScM :sc; ScPre :first, :scp.
      it "reads singleton_class include and prepend in the class body and in an included block, from their line" do
        Dir.mktmpdir do |dir|
          stampy(dir)
          write_model(dir, "Concerns::ScMod", "module ScMod\n  def stamp\n    before_save :sc\n  end\nend\n")
          write_model(dir, "Concerns::ScPreMod", "module ScPreMod\n  def stamp\n    before_save :scp\n  end\nend\n")
          write_model(dir, "Concerns::BlkSc", "module BlkSc\n  extend ActiveSupport::Concern\n  included do\n    singleton_class.include ScMod\n    stamp\n  end\nend\n")
          write_model(dir, "ScBody", "class ScBody < ApplicationRecord\n  include Stampy\n  singleton_class.include ScMod\n  stamp\nend\n")
          write_model(dir, "SelfSc", "class SelfSc < ApplicationRecord\n  include Stampy\n  self.singleton_class.include ScMod\n  stamp\nend\n")
          write_model(dir, "SendSc", "class SendSc < ApplicationRecord\n  include Stampy\n  singleton_class.send(:include, ScMod)\n  stamp\nend\n")
          write_model(dir, "BlkScM", "class BlkScM < ApplicationRecord\n  include Stampy\n  include BlkSc\nend\n")
          write_model(dir, "ScPre", "class ScPre < ApplicationRecord\n  def self.stamp\n    before_save :own\n  end\n  singleton_class.prepend ScPreMod\n  before_save :first\n  stamp\nend\n")

          static = static_save(dir)
          expect(static.slice("ScBody", "SelfSc", "SendSc", "BlkScM", "ScPre")).to eq(
            "ScBody" => %w[sc], "SelfSc" => %w[sc], "SendSc" => %w[sc], "BlkScM" => %w[sc], "ScPre" => %w[first scp]
          )
          %w[ScBody BlkScM ScPre].each { |name| expect(booted_callbacks(dir, name)).to eq("before_save" => static[name]) }
        end
      end

      # Runtime: HkExtM, HkScM, HkSendM :first, :i; HkPreM :first, :p, :own; HkModScM :first, :s; HkLateM :first, :s, :i.
      it "follows a module from its own file that a plain hook extends the class with, at each include" do
        Dir.mktmpdir do |dir|
          stampy(dir)
          write_model(dir, "Concerns::HkInc", "module HkInc\n  def stamp\n    before_save :i\n  end\nend\n")
          write_model(dir, "Concerns::HkPre", "module HkPre\n  def stamp\n    before_save :p\n    super\n  end\nend\n")
          { "HkExt" => "base.extend HkInc", "HkSc" => "base.singleton_class.include HkInc", "HkSend" => "base.send(:extend, HkInc)",
            "HkPreHook" => "base.singleton_class.prepend HkPre", "HkModSc" => "singleton_class.include HkInc" }.each do |name, line|
            write_model(dir, "Concerns::#{name}", "module #{name}\n  def self.included(base)\n    #{line}\n  end\nend\n")
          end
          %w[HkExt HkSc HkSend HkModSc].each do |hook|
            write_model(dir, "#{hook}M", "class #{hook}M < ApplicationRecord\n  include Stampy\n  include #{hook}\n  before_save :first\n  stamp\nend\n")
          end
          write_model(dir, "HkPreM", "class HkPreM < ApplicationRecord\n  def self.stamp\n    before_save :own\n  end\n  include HkPreHook\n  before_save :first\n  stamp\nend\n")
          write_model(dir, "HkLateM", "class HkLateM < ApplicationRecord\n  include Stampy\n  before_save :first\n  stamp\n  include HkExt\n  stamp\nend\n")

          static = static_save(dir)
          expect(static.slice("HkExtM", "HkScM", "HkSendM", "HkPreM", "HkModScM", "HkLateM")).to eq(
            "HkExtM" => %w[first i], "HkScM" => %w[first i], "HkSendM" => %w[first i], "HkPreM" => %w[first p own],
            "HkModScM" => %w[first s], "HkLateM" => %w[first s i]
          )
          %w[HkExtM HkPreM HkLateM].each { |name| expect(booted_callbacks(dir, name)).to eq("before_save" => static[name]) }
        end
      end

      # Runtime: TwoFarM :first, :a, :b; TwoFarEvalM :first, :a, :c. CanvasLikeM raises (Subm::ClassMethods is
      # undefined); without Subm it lists :first, :g, which an unresolved name must not take away.
      it "keeps apart two concerns' modules of one name, each resolved in its own concern" do
        Dir.mktmpdir do |dir|
          %w[a b c].each do |key|
            write_model(dir, "Concerns::H#{key}::ClassMethods", "module H#{key}\n  module ClassMethods\n    def stamp_#{key}\n      before_save :#{key}\n    end\n  end\nend\n")
          end
          %w[Ha Hb Subm].each { |name| write_model(dir, "Concerns::#{name}", "module #{name}\n  def self.included(base)\n    base.extend ClassMethods\n  end\nend\n") }
          write_model(dir, "Concerns::Hc", "module Hc\n  def self.included(base)\n    base.class_eval do\n      extend ClassMethods\n    end\n  end\nend\n")
          write_model(dir, "Concerns::Smart", "module Smart\n  def self.included(klass)\n    klass.class_eval do\n      extend ClassMethods\n    end\n  end\n\n" \
                                              "  module ClassMethods\n    def use_ss\n      before_save :g\n    end\n  end\nend\n")
          write_model(dir, "TwoFarM", "class TwoFarM < ApplicationRecord\n  include Ha\n  include Hb\n  before_save :first\n  stamp_a\n  stamp_b\nend\n")
          write_model(dir, "TwoFarEvalM", "class TwoFarEvalM < ApplicationRecord\n  include Ha\n  include Hc\n  before_save :first\n  stamp_a\n  stamp_c\nend\n")
          write_model(dir, "CanvasLikeM", "class CanvasLikeM < ApplicationRecord\n  include Subm\n  include Smart\n  before_save :first\n  use_ss\nend\n")

          expect(static_save(dir).slice("TwoFarM", "TwoFarEvalM", "CanvasLikeM")).to eq(
            "TwoFarM" => %w[first a b], "TwoFarEvalM" => %w[first a c], "CanvasLikeM" => %w[first g]
          )
        end
      end

      # Runtime: HTwoM :first, :n; HInstM :first, :n.
      it "places the modules one hook extends with by line, in instance_eval too" do
        Dir.mktmpdir do |dir|
          stampy(dir)
          write_model(dir, "Concerns::ZInc", "module ZInc\n  def stamp\n    before_save :i\n  end\nend\n")
          nested = "\n  module ClassMethods\n    def stamp\n      before_save :n\n    end\n  end\nend\n"
          write_model(dir, "Concerns::HTwo", "module HTwo\n  def self.included(base)\n    base.extend ZInc\n    base.extend ClassMethods\n  end\n#{nested}")
          write_model(dir, "Concerns::HInst", "module HInst\n  def self.included(base)\n    base.instance_eval do\n      extend ClassMethods\n    end\n  end\n#{nested}")
          write_model(dir, "HTwoM", "class HTwoM < ApplicationRecord\n  include HTwo\n  before_save :first\n  stamp\nend\n")
          write_model(dir, "HInstM", "class HInstM < ApplicationRecord\n  include Stampy\n  include HInst\n  before_save :first\n  stamp\nend\n")

          expect(static_save(dir).slice("HTwoM", "HInstM")).to eq("HTwoM" => %w[first n], "HInstM" => %w[first n])
        end
      end

      # Runtime: TieRedefM :first, :b; TwoArgM :first, :a; TwoArgRevM :first, :b.
      it "runs the later of two defs of one name in a module a hook extends with, and the earlier argument's" do
        Dir.mktmpdir do |dir|
          stampy(dir)
          twice = "  module ClassMethods\n    def stamp\n      before_save :a\n    end\n\n    def stamp\n      before_save :b\n    end\n  end\nend\n"
          write_model(dir, "Concerns::TRedef", "module TRedef\n  def self.included(base)\n    base.extend ClassMethods\n  end\n#{twice}")
          two = "  module CmA\n    def stamp\n      before_save :a\n    end\n  end\n\n  module CmB\n    def stamp\n      before_save :b\n    end\n  end\nend\n"
          write_model(dir, "Concerns::TTwoArg", "module TTwoArg\n  def self.included(base)\n    base.extend CmA, CmB\n  end\n#{two}")
          write_model(dir, "Concerns::TTwoArgRev", "module TTwoArgRev\n  def self.included(base)\n    base.extend CmB, CmA\n  end\n#{two}")
          { "TieRedefM" => "TRedef", "TwoArgM" => "TTwoArg", "TwoArgRevM" => "TTwoArgRev" }.each do |name, mod|
            write_model(dir, name, "class #{name} < ApplicationRecord\n  include Stampy\n  include #{mod}\n  before_save :first\n  stamp\nend\n")
          end

          expect(static_save(dir).slice("TieRedefM", "TwoArgM", "TwoArgRevM")).to eq("TieRedefM" => %w[first b], "TwoArgM" => %w[first a], "TwoArgRevM" => %w[first b])
        end
      end

      # Runtime: QExtM, QActsM, QOuterM :first, :s; QExt2M :first, :t.
      it "runs a module's extended hook, and the hooks of a module a hook includes" do
        Dir.mktmpdir do |dir|
          write_model(dir, "Concerns::QCm", "module QCm\n  def stamp\n    before_save :s\n  end\nend\n")
          write_model(dir, "Concerns::QHook", "module QHook\n  def self.included(base)\n    base.extend QCm\n  end\nend\n")
          write_model(dir, "Concerns::QHookExt", "module QHookExt\n  def self.extended(base)\n    base.extend QCm\n  end\nend\n")
          write_model(dir, "Concerns::QHookExt2", "module QHookExt2\n  def self.extended(base)\n    base.extend QCm2\n  end\n" \
                                                  "  module QCm2\n    def stamp\n      before_save :t\n    end\n  end\nend\n")
          write_model(dir, "Concerns::QOuter", "module QOuter\n  def self.included(base)\n    base.include QHook\n  end\nend\n")
          write_model(dir, "Concerns::QActs", "module QActs\n  def acts_as_q\n    extend QHookExt\n  end\nend\n")
          { "QExtM" => "extend QHookExt", "QExt2M" => "extend QHookExt2", "QOuterM" => "include QOuter", "QActsM" => "extend QActs\n  acts_as_q" }.each do |name, line|
            write_model(dir, name, "class #{name} < ApplicationRecord\n  #{line}\n  before_save :first\n  stamp\nend\n")
          end

          expect(static_save(dir).slice("QExtM", "QExt2M", "QOuterM", "QActsM")).to eq(
            "QExtM" => %w[first s], "QExt2M" => %w[first t], "QOuterM" => %w[first s], "QActsM" => %w[first s]
          )
        end
      end

      # Runtime: LocM :first, :loc, :sb, :ro.
      it "reads the class methods an initializer defines on ActiveRecord::Base as the outermost definitions" do
        Dir.mktmpdir do |dir|
          FileUtils.mkdir_p(File.join(dir, "config", "initializers"))
          File.write(File.join(dir, "config", "initializers", "base_ext.rb"), <<~RUBY)
            ActiveRecord::Base.class_eval do
              class << self
                def validates_loc(options = {})
                  before_save :loc if options[:allow_nil]
                end
              end

              def self.stamp_base
                before_save :sb
              end
            end
          RUBY
          File.write(File.join(dir, "config", "initializers", "base_reopen.rb"), "class ActiveRecord::Base\n  def self.reopened\n    before_save :ro\n  end\nend\n")
          write_model(dir, "LocM", "class LocM < ApplicationRecord\n  before_save :first\n  validates_loc allow_nil: true\n  stamp_base\n  reopened\nend\n")
          write_model(dir, "NoLoc", "class NoLoc < ApplicationRecord\n  validates_loc\nend\n")

          static = static_save(dir)
          expect(static.slice("LocM", "NoLoc")).to eq("LocM" => %w[first loc sb ro], "NoLoc" => nil)
        end
      end

      it "loses only the initializer macro call it cannot expand, not the other calls" do
        Dir.mktmpdir do |dir|
          FileUtils.mkdir_p(File.join(dir, "config", "initializers"))
          File.write(File.join(dir, "config", "initializers", "base_ext.rb"),
                     "class ActiveRecord::Base\n  def self.loc(options = {})\n    before_save :loc if options[:on]\n  end\n\n  def self.stamp_base\n    before_save :sb\n  end\nend\n")
          write_model(dir, "BadLoc", "class BadLoc < ApplicationRecord\n  loc on: true, bad: true\n  stamp_base\nend\n")
          write_model(dir, "GoodLoc", "class GoodLoc < ApplicationRecord\n  loc on: true\nend\n")
          allow(RailsAiContext::Introspectors::CallSiteExpansion).to receive(:entries).and_wrap_original do |original, definition, call, listeners|
            raise ArgumentError, "unreadable" if call&.slice&.include?("bad")

            original.call(definition, call, listeners)
          end

          expect(static_save(dir).slice("BadLoc", "GoodLoc")).to eq("BadLoc" => %w[sb], "GoodLoc" => %w[loc])
        end
      end

      # Runtime: Account validates inclusion of default_locale, User of locale and browser_locale, Course of
      # locale (the method's default), each `if: :<field>_changed?`, and each runs one before_validation block.
      it "reads an initializer's macro at each call, its fields bound from the call, in place of the call's own row" do
        Dir.mktmpdir do |dir|
          FileUtils.mkdir_p(File.join(dir, "config", "initializers"))
          File.write(File.join(dir, "config", "initializers", "i18n.rb"), <<~'RUBY')
            ActiveRecord::Base.class_eval do
              class << self
                LOCALE_LIST = %w[en fr].freeze

                def validates_locale(*args)
                  options = args.last.is_a?(Hash) ? args.pop : {}
                  args << :locale if args.empty?
                  if options[:allow_nil] && !options[:allow_empty]
                    before_validation do |record|
                      args.each do |field|
                        record[field] = nil if record[field] == ""
                      end
                    end
                  end
                  args.each do |field|
                    validates_inclusion_of field, options.merge(in: LOCALE_LIST, if: :"#{field}_changed?")
                  end
                end
              end
            end
          RUBY
          write_model(dir, "Account", "class Account < ApplicationRecord\n  validates_locale :default_locale, allow_nil: true\nend\n")
          write_model(dir, "User", "class User < ApplicationRecord\n  validates_locale :locale, :browser_locale, allow_nil: true\nend\n")
          write_model(dir, "Course", "class Course < ApplicationRecord\n  validates_locale allow_nil: true\nend\n")

          models = described_class.new(RailsAiContext::StaticApp.new(dir)).static_call
          read = %w[Account User Course].to_h do |name|
            [ name, models[name][:validations].map { |v| [ v[:kind], v[:attributes], v[:options][:if] ] } ]
          end
          expect(read).to eq(
            "Account" => [ [ "inclusion", [ "default_locale" ], :default_locale_changed? ] ],
            "User" => [ [ "inclusion", [ "locale" ], :locale_changed? ], [ "inclusion", [ "browser_locale" ], :browser_locale_changed? ] ],
            "Course" => [ [ "inclusion", [ "locale" ], :locale_changed? ] ]
          )
          %w[Account User Course].each { |name| expect(models[name][:callbacks]).to eq("before_validation" => %w[[inline_block]]) }
        end
      end

      # Runtime (initializers load sorted): WSame :first, :b_same; WFar :first, :b_far; WThree :first, :leaf3;
      # XP6 :first, :init_p6 (the initializer reopens ApplicationRecord after its file ran).
      it "takes an initializer's class method from the file Rails loads last, and one on ApplicationRecord over its own" do
        Dir.mktmpdir do |dir|
          initializers = File.join(dir, "config", "initializers")
          FileUtils.mkdir_p(initializers)
          {
            "a_ext.rb" => "ActiveRecord::Base.class_eval do\n  def self.dup_same\n    before_save :a_same\n  end\n  def self.p6\n    before_save :base_p6\n  end\n" \
                          "  def self.outer3\n    mid3\n  end\n#{"\n" * 7}  def self.dup_far\n    before_save :a_far\n  end\nend\n",
            "b_ext.rb" => "ActiveRecord::Base.class_eval do\n  def self.dup_same\n    before_save :b_same\n  end\n  def self.pb\n    before_save :pb\n  end\n" \
                          "  def self.dup_far\n    before_save :b_far\n  end\nend\n",
            "c_ext.rb" => "ActiveRecord::Base.class_eval do\n  def self.zz\n    before_save :zz\n  end\n  def self.leaf3\n    before_save :leaf3\n  end\nend\n",
            "d_ext.rb" => "ActiveRecord::Base.class_eval do\n  def self.zz2\n    before_save :zz2\n  end\n  def self.zz3\n    before_save :zz3\n  end\n  def self.mid3\n    leaf3\n  end\nend\n",
            "e_ar.rb" => "ApplicationRecord.class_eval do\n  def self.p6\n    before_save :init_p6\n  end\nend\n"
          }.each { |name, source| File.write(File.join(initializers, name), source) }
          write_model(dir, "ApplicationRecord", "class ApplicationRecord < ActiveRecord::Base\n  self.abstract_class = true\n  def self.p6\n    before_save :ar_own\n  end\nend\n")
          write_model(dir, "WSame", "class WSame < ApplicationRecord\n  before_save :first\n  dup_same\nend\n")
          write_model(dir, "WFar", "class WFar < ApplicationRecord\n  before_save :first\n  dup_far\nend\n")
          write_model(dir, "WThree", "class WThree < ApplicationRecord\n  before_save :first\n  outer3\nend\n")
          write_model(dir, "XP6", "class XP6 < ApplicationRecord\n  before_save :first\n  p6\nend\n")

          expect(static_save(dir).slice("WSame", "WFar", "WThree", "XP6")).to eq(
            "WSame" => %w[first b_same], "WFar" => %w[first b_far], "WThree" => %w[first leaf3], "XP6" => %w[first init_p6]
          )
        end
      end

      # Runtime: EvChild :own_t (the base's own method over the every-model one);
      # Guest2 runs after_save :persist, :own (InstM joins where Acc2's Avi block calls acts_as_inst).
      it "reads a module every model has as the outermost definition, and a mixin a called method includes at the call" do
        Dir.mktmpdir do |dir|
          FileUtils.mkdir_p(File.join(dir, "config", "initializers"))
          File.write(File.join(dir, "config", "initializers", "tracking.rb"), <<~RUBY)
            module Tracking
              def self.included(base)
                base.extend ClassMethods
              end

              module ClassMethods
                def acts_as_tracked
                  before_save :tracked
                end

                def acts_as_inst
                  send :include, InstM
                end
              end

              module InstM
                extend ActiveSupport::Concern
                included do
                  after_save :persist
                end
              end
            end
            ActiveRecord::Base.include Tracking
          RUBY
          write_model(dir, "Concerns::Avi", "module Avi\n  extend ActiveSupport::Concern\n  included do\n    acts_as_inst\n  end\nend\n")
          write_model(dir, "EvBase", "class EvBase < ApplicationRecord\n  def self.acts_as_tracked\n    before_save :own_t\n  end\n  acts_as_tracked\nend\n")
          write_model(dir, "EvChild", "class EvChild < EvBase\n  acts_as_tracked\nend\n")
          write_model(dir, "Acc2", "class Acc2 < ApplicationRecord\n  include Avi\n  after_save :own\nend\n")
          write_model(dir, "Guest2", "class Guest2 < Acc2\nend\n")

          expect(static_save(dir).slice("EvBase", "EvChild")).to eq("EvBase" => %w[own_t], "EvChild" => %w[own_t])
          expect(static_save(dir, "after_save").slice("Acc2", "Guest2")).to eq("Acc2" => %w[persist own], "Guest2" => %w[persist own])
        end
      end

      # Runtime: Attachment runs after_save :first, :save_journals, :last. The macro's private helper
      # includes SaveHooks, which a glob require loads from beside the plugin's own file.
      # An empty namespace stub before the module, on one line or several, is not its definition.
      it "follows a called method's call to a private helper, and the mixin that helper includes" do
        [ "", "module Acts; module Journalized; end; end\n", "module Acts\n  module Journalized\n  end\nend\n" ].each do |stub|
          Dir.mktmpdir do |dir|
            plugin = File.join(dir, "lib", "plugins", "aaj")
            FileUtils.mkdir_p(File.join(plugin, "lib", "acts", "journalized"))
            File.write(File.join(plugin, "init.rb"), "#{stub}require File.expand_path('lib/acts_as_journalized', __dir__)\nActiveRecord::Base.include(Acts::Journalized)\n")
            File.write(File.join(plugin, "lib", "acts_as_journalized.rb"), <<~RUBY)
              Dir[File.expand_path("acts/journalized/*.rb", __dir__)].each { |f| require f }
              #{stub}module Acts
                module Journalized
                  def self.included(base)
                    base.extend ClassMethods
                  end

                  module ClassMethods
                    def acts_as_journalized
                      include_aaj_modules
                    end

                    private

                    def include_aaj_modules
                      include SaveHooks
                    end
                  end
                end
              end
            RUBY
            File.write(File.join(plugin, "lib", "acts", "journalized", "save_hooks.rb"), <<~RUBY)
              module Acts::Journalized
                module SaveHooks
                  def self.included(base)
                    base.class_eval do
                      after_save :save_journals
                    end
                  end
                end
              end
            RUBY
            write_model(dir, "Attachment", "class Attachment < ApplicationRecord\n  after_save :first\n  acts_as_journalized\n  after_save :last\nend\n")

            expect(static_save(dir, "after_save")["Attachment"]).to eq(%w[first save_journals last])
            expect(booted_callbacks(dir, "Attachment")).to eq("after_save" => %w[first save_journals last])
          end
        end
      end

      # Runtime: OChild :persist, :own, :c; TwiceInc :a, :persist, :b; LateInc :own, :persist.
      it "runs a Concern a called method includes at the first call only, and a class method's include where it is called" do
        Dir.mktmpdir do |dir|
          write_model(dir, "Concerns::InstM", "module InstM\n  extend ActiveSupport::Concern\n  included do\n    before_save :persist\n  end\nend\n")
          write_model(dir, "Concerns::Incl", "module Incl\n  extend ActiveSupport::Concern\n  class_methods do\n    def acts_as_inst\n      include InstM\n    end\n  end\nend\n")
          write_model(dir, "OBase", "class OBase < ApplicationRecord\n  include Incl\n  acts_as_inst\n  before_save :own\nend\n")
          write_model(dir, "OChild", "class OChild < OBase\n  acts_as_inst\n  before_save :c\nend\n")
          write_model(dir, "TwiceInc", "class TwiceInc < ApplicationRecord\n  include Incl\n  before_save :a\n  acts_as_inst\n  before_save :b\n  acts_as_inst\nend\n")
          write_model(dir, "LateInc", "class LateInc < ApplicationRecord\n  def self.setup\n    include InstM\n  end\n  before_save :own\n  setup\nend\n")

          expect(static_save(dir).slice("OChild", "TwiceInc", "LateInc")).to eq(
            "OChild" => %w[persist own c], "TwiceInc" => %w[a persist b], "LateInc" => %w[own persist]
          )
          %w[TwiceInc LateInc].each { |name| expect(booted_callbacks(dir, name)).to eq("before_save" => static_save(dir)[name]) }
        end
      end

      # Runtime: one presence validator on title, and callbacks :first, :inner, :outer.
      it "reads a module nested in the model's file once when another nested module includes it" do
        Dir.mktmpdir do |dir|
          write_model(dir, "NestDeep", <<~RUBY)
            class NestDeep < ApplicationRecord
              module Inner
                extend ActiveSupport::Concern
                included do
                  validates :title, presence: true
                  before_save :inner
                end
              end
              module Outer
                extend ActiveSupport::Concern
                include Inner
                included do
                  before_save :outer
                end
              end
              before_save :first
              include Outer
            end
          RUBY

          model = described_class.new(RailsAiContext::StaticApp.new(dir)).static_call["NestDeep"]

          expect(model[:callbacks]).to eq("before_save" => %w[first inner outer])
          expect(model[:validations].map { |v| v[:kind] }).to eq(%w[presence])
        end
      end
    end

    # A module mixed into every model is reached from a base's call as from the
    # class's own: OpenProject's User calls acts_as_customizable for its subclasses.
    it "keeps what a base's call declares through a module every model has" do
      Dir.mktmpdir do |dir|
        FileUtils.mkdir_p(File.join(dir, "config", "initializers"))
        File.write(File.join(dir, "config", "initializers", "tracking.rb"), <<~RUBY)
          module Tracking
            def self.included(base)
              base.extend ClassMethods
            end

            module ClassMethods
              def acts_as_tracked
                before_save :tracked
              end
            end
          end
          ActiveRecord::Base.include Tracking
        RUBY
        write_model(dir, "Account", "class Account < ApplicationRecord\n  before_save :first\n  acts_as_tracked\nend\n")
        write_model(dir, "Guest", "class Guest < Account\n  before_save :last\nend\n")

        static = described_class.new(RailsAiContext::StaticApp.new(dir)).static_call

        expect(static["Account"][:callbacks]).to eq("before_save" => %w[first tracked])
        expect(static["Guest"][:callbacks]).to eq("before_save" => %w[first tracked last])
      end
    end

    # Runtime: Fromblock runs :first, :track, :last and Crossblock :mid, :s, :last.
    it "places a declaration a concern's included block makes through a call where that concern is included" do
      Dir.mktmpdir do |dir|
        write_model(dir, "Concerns::Hooky", "module Hooky\n  extend ActiveSupport::Concern\n  included do\n    loud!\n  end\nend\n")
        write_model(dir, "Concerns::Stampy", <<~RUBY)
          module Stampy
            extend ActiveSupport::Concern
            class_methods do
              def stamp
                before_save :s
              end
            end
          end
        RUBY
        write_model(dir, "Concerns::Caller", "module Caller\n  extend ActiveSupport::Concern\n  included do\n    stamp\n  end\nend\n")
        write_model(dir, "Fromblock", <<~RUBY)
          class Fromblock < ApplicationRecord
            def self.loud!
              before_save :track
            end
            before_save :first
            include Hooky
            before_save :last
          end
        RUBY
        write_model(dir, "Crossblock", <<~RUBY)
          class Crossblock < ApplicationRecord
            include Stampy
            before_save :mid
            include Caller
            before_save :last
          end
        RUBY

        static = described_class.new(RailsAiContext::StaticApp.new(dir)).static_call

        expect(static["Fromblock"][:callbacks]).to eq("before_save" => %w[first track last])
        expect(static["Crossblock"][:callbacks]).to eq("before_save" => %w[mid s last])
        expect(booted_callbacks(dir, "Fromblock")).to eq(static["Fromblock"][:callbacks])
        expect(booted_callbacks(dir, "Crossblock")).to eq(static["Crossblock"][:callbacks])
      end
    end

    # Rails builds the chain base first, a concern where its include runs,
    # then the class body; a later declaration replaces an earlier one.
    it "lists callbacks across a base, a concern and the class in chain order" do
      Dir.mktmpdir do |dir|
        write_model(dir, "BaseThing", <<~RUBY)
          class BaseThing < ApplicationRecord
            before_save :b_only
            before_save :basex, if: :from_base?
          end
        RUBY
        write_model(dir, "Thing", <<~RUBY)
          class Thing < BaseThing
            include Stampable
            before_save :m_only
            before_save :basex, if: :from_model?
          end
        RUBY
        write_model(dir, "Early", <<~RUBY)
          class Early < ApplicationRecord
            before_save :shared, if: :from_model?
            include Stampable
          end
        RUBY
        write_model(dir, "Concerns::Stampable", <<~RUBY)
          module Stampable
            extend ActiveSupport::Concern
            included do
              before_save :c_only
              before_save :shared, if: :from_concern?
            end
          end
        RUBY

        models = described_class.new(RailsAiContext::StaticApp.new(dir)).static_call

        expect(models["Thing"][:callbacks]["before_save"]).to eq(%w[b_only c_only shared m_only basex])
        expect(models["Thing"][:callback_conditions]["before_save"]).to eq(
          [ nil, nil, { if: :from_concern? }, nil, { if: :from_model? } ]
        )
        expect(models["Early"][:callbacks]["before_save"]).to eq(%w[c_only shared])
        expect(models["Early"][:callback_conditions]["before_save"]).to eq([ nil, { if: :from_concern? } ])
        expect(booted_callbacks(dir, "Early")).to eq(models["Early"][:callbacks])
      end
    end

    # ActiveSupport::Concern skips `included` for a class whose base already
    # has the module, so its callbacks stay where the base put them.
    it "keeps a concern the base already included at the base's place" do
      Dir.mktmpdir do |dir|
        write_model(dir, "Concerns::Mixy", <<~RUBY)
          module Mixy
            extend ActiveSupport::Concern
            included do
              before_save :c
              before_save { 1 }
            end
          end
        RUBY
        write_model(dir, "Base2", <<~RUBY)
          class Base2 < ApplicationRecord
            include Mixy
            before_save :b
          end
        RUBY
        write_model(dir, "Child2", <<~RUBY)
          class Child2 < Base2
            include Mixy
            before_save :d
          end
        RUBY

        child = described_class.new(RailsAiContext::StaticApp.new(dir)).static_call["Child2"]

        expect(child[:callbacks]["before_save"]).to eq(%w[c [inline_block] b d])
      end
    end

    # A plain module's `self.included` and a class method the child calls
    # again do run again, unlike an ActiveSupport::Concern's `included` block.
    it "runs a plain included hook and a called class method again for the child" do
      Dir.mktmpdir do |dir|
        write_model(dir, "Concerns::Plain", <<~RUBY)
          module Plain
            def self.included(base)
              base.before_save :p
              base.before_save { 1 }
            end
          end
        RUBY
        write_model(dir, "Concerns::Cm", <<~RUBY)
          module Cm
            extend ActiveSupport::Concern
            class_methods do
              def stampable
                before_save :cm_only
                before_save { 2 }
              end
            end
          end
        RUBY
        write_model(dir, "Pb", "class Pb < ApplicationRecord\n  include Plain\n  before_save :b\nend\n")
        write_model(dir, "Pc", "class Pc < Pb\n  include Plain\n  before_save :d\nend\n")
        write_model(dir, "Mb", "class Mb < ApplicationRecord\n  include Cm\n  stampable\n  before_save :b\nend\n")
        write_model(dir, "Mc", "class Mc < Mb\n  include Cm\n  stampable\n  before_save :d\nend\n")
        write_model(dir, "Concerns::Nst", <<~RUBY)
          module Nst
            extend ActiveSupport::Concern
            class_methods do
              def nstamp
                before_save :n_only
                before_save { 3 }
              end
            end
            included do
              nstamp
            end
          end
        RUBY
        write_model(dir, "Concerns::Ph", <<~RUBY)
          module Ph
            def self.included(base)
              base.extend(ClassMethods)
              base.hstamp
            end
            module ClassMethods
              def hstamp
                before_save :h_only
              end
            end
          end
        RUBY
        write_model(dir, "Nb", "class Nb < ApplicationRecord\n  include Nst\n  before_save :b\nend\n")
        write_model(dir, "Nc", "class Nc < Nb\n  include Nst\n  before_save :d\nend\n")
        write_model(dir, "Hb", "class Hb < ApplicationRecord\n  include Ph\n  before_save :b\nend\n")
        write_model(dir, "Hc", "class Hc < Hb\n  include Ph\n  before_save :d\nend\n")

        models = described_class.new(RailsAiContext::StaticApp.new(dir)).static_call

        expect(models["Pc"][:callbacks]["before_save"]).to eq(%w[[inline_block] b p [inline_block] d])
        expect(models["Mc"][:callbacks]["before_save"]).to eq(%w[[inline_block] b cm_only [inline_block] d])
        expect(models["Nc"][:callbacks]["before_save"]).to eq(%w[n_only [inline_block] b d])
        expect(models["Hc"][:callbacks]["before_save"]).to eq(%w[b h_only d])
      end
    end

    it "credits a Class.new body and a top-level line to no other class in the file" do
      Dir.mktmpdir do |dir|
        write_model(dir, "Concerns::Stampable", "module Stampable\n  extend ActiveSupport::Concern\nend\n")
        write_model(dir, "Pair", <<~RUBY)
          class Pair < ApplicationRecord
            include Stampable
          end
          Sib = Class.new(ApplicationRecord) do
            include Comparable
            before_save :z
          end
        RUBY
        write_model(dir, "Lone", "include Comparable\nclass Lone < ApplicationRecord\n  before_save :q\nend\n")

        models = described_class.new(RailsAiContext::StaticApp.new(dir)).static_call

        expect(models["Pair"][:callbacks]).to eq({})
        expect(booted_callbacks(dir, "Pair")).to eq({})
        expect(models["Pair"][:concerns]).to eq([ "Stampable" ])
        expect(models["Lone"][:concerns]).to eq([])
      end
    end

    it "reads the callbacks of a model written as Class.new" do
      Dir.mktmpdir do |dir|
        write_model(dir, "Anon", <<~RUBY)
          Anon = Class.new(ApplicationRecord) do
            before_save :x, if: :a?
          end
        RUBY

        expect(booted_callbacks(dir, "Anon")).to eq("before_save" => %w[x])
      end
    end

    it "reads no callback a class nested in the model's body declares" do
      Dir.mktmpdir do |dir|
        write_model(dir, "Outer", <<~RUBY)
          class Outer < ApplicationRecord
            before_save :x, if: :outer?
            class Inner < ApplicationRecord
              before_save :x, if: :inner?
              before_save :only_inner
            end
            before_save :y
            before_save :y, if: :later?
          end
        RUBY

        outer = described_class.new(RailsAiContext::StaticApp.new(dir)).static_call["Outer"]

        expect(outer[:callbacks]).to eq("before_save" => %w[x y])
        expect(outer[:callback_conditions]).to eq("before_save" => [ { if: :outer? }, { if: :later? } ])
        expect(booted_callbacks(dir, "Outer")).to eq(outer[:callbacks])
      end
    end

    describe "transaction callbacks and prepend: true" do
      def write_config(dir, application, initializer = nil)
        FileUtils.mkdir_p(File.join(dir, "config", "initializers"))
        File.write(File.join(dir, "config", "application.rb"),
                   "module Demo\n  class Application < Rails::Application\n    #{application}\n  end\nend\n")
        return unless initializer

        File.write(File.join(dir, "config", "initializers", "new_framework_defaults.rb"), "#{initializer}\n")
      end

      def write_order(dir)
        write_model(dir, "Order", <<~RUBY)
          class Order < ApplicationRecord
            after_commit :first
            after_commit :second
            after_rollback :r1
            after_rollback :r2
            after_save :s1
            after_save :s2
          end
        RUBY
      end

      def booted_with_flag(dir, flag)
        if flag.nil?
          allow(ActiveRecord).to receive(:respond_to?).and_call_original
          allow(ActiveRecord).to receive(:respond_to?).with(:run_after_transaction_callbacks_in_order_defined).and_return(false)
        else
          allow(ActiveRecord).to receive(:run_after_transaction_callbacks_in_order_defined).and_return(flag)
        end
        booted_callbacks(dir, "Order")
      end

      reversed = { "after_commit" => %w[second first], "after_rollback" => %w[r2 r1], "after_save" => %w[s1 s2] }
      in_order = { "after_commit" => %w[first second], "after_rollback" => %w[r1 r2], "after_save" => %w[s1 s2] }

      # Rails 7.0 always runs them from the last declared; 7.1 adds the setting
      # and `load_defaults 7.1` turns it on.
      it "lists after_commit and after_rollback last declared first unless the app runs them in order" do
        {
          [ "config.load_defaults 7.0", nil ] => reversed,
          [ "config.load_defaults 6.1", nil ] => reversed,
          [ "config.load_defaults 7.1", nil ] => in_order,
          [ "config.load_defaults 8.1", nil ] => in_order,
          [ "config.load_defaults 7.0",
            "Rails.application.config.active_record.run_after_transaction_callbacks_in_order_defined = true" ] => in_order,
          [ "config.load_defaults 7.1\n    config.active_record.run_after_transaction_callbacks_in_order_defined = false", nil ] => reversed,
          [ "config.active_record.run_after_transaction_callbacks_in_order_defined = false\n    config.load_defaults 7.1", nil ] => in_order,
          [ "config.active_record.run_after_transaction_callbacks_in_order_defined = false\n    config.load_defaults 7.0", nil ] => reversed,
          [ "config.load_defaults 7.1",
            "Rails.application.config.active_record.run_after_transaction_callbacks_in_order_defined = false" ] => reversed,
          [ "config.active_record.run_after_transaction_callbacks_in_order_defined = false\n    config.load_defaults 7.0",
            "Rails.application.config.active_record.run_after_transaction_callbacks_in_order_defined = true" ] => in_order,
          [ "config.load_defaults 7.1\n    config.active_record.run_after_transaction_callbacks_in_order_defined = nil", nil ] => reversed
        }.each do |(application, initializer), expected|
          Dir.mktmpdir do |dir|
            write_config(dir, application, initializer)
            write_order(dir)

            details = described_class.new(RailsAiContext::StaticApp.new(dir)).static_call["Order"]

            expect(details[:callbacks]).to eq(expected), application
            expect(details).not_to have_key(:commit_order_unread)
          end
        end
      end

      def skip_without_setting
        return if ActiveRecord.respond_to?(:run_after_transaction_callbacks_in_order_defined)

        skip "ActiveRecord #{ActiveRecord::VERSION::STRING} has no run_after_transaction_callbacks_in_order_defined"
      end

      it "reverses when booted on a Rails without the setting" do
        Dir.mktmpdir do |dir|
          write_order(dir)

          expect(booted_with_flag(dir, nil)).to eq(reversed)
        end
      end

      it "reads the running setting when booted" do
        skip_without_setting
        Dir.mktmpdir do |dir|
          write_order(dir)

          expect(booted_with_flag(dir, false)).to eq(reversed)
          expect(booted_with_flag(dir, true)).to eq(in_order)
        end
      end

      # Rails tests the setting for truth, so nil runs them last declared first.
      it "reverses when booted with the setting nil" do
        skip_without_setting
        Dir.mktmpdir do |dir|
          write_order(dir)
          allow(ActiveRecord).to receive(:run_after_transaction_callbacks_in_order_defined).and_return(nil)

          expect(booted_callbacks(dir, "Order")).to eq(reversed)
        end
      end

      it "keeps declaration order statically when the config cannot say, and marks it" do
        [ nil, "config.load_defaults Rails::VERSION::STRING.to_f",
          "config.load_defaults 7.0\n    config.active_record.run_after_transaction_callbacks_in_order_defined = ENV.key?(\"X\")" ].each do |application|
          Dir.mktmpdir do |dir|
            write_config(dir, application) if application
            write_order(dir)

            details = described_class.new(RailsAiContext::StaticApp.new(dir)).static_call["Order"]

            expect(details[:callbacks]).to eq(in_order), application.inspect
            expect(details[:commit_order_unread]).to be(true)
          end
        end
      end

      it "marks only a chain that holds two transaction callbacks" do
        {
          "after_commit :a\n  after_rollback :b" => false,
          "after_create_commit :a\n  after_update_commit :b" => true
        }.each do |body, marked|
          Dir.mktmpdir do |dir|
            write_model(dir, "Order", "class Order < ApplicationRecord\n  #{body}\nend\n")

            details = described_class.new(RailsAiContext::StaticApp.new(dir)).static_call["Order"]

            expect(details.key?(:commit_order_unread)).to be(marked), body
          end
        end
      end

      it "puts a prepend: true callback first in its chain, ahead of the base's" do
        Dir.mktmpdir do |dir|
          write_config(dir, "config.load_defaults 7.0")
          write_model(dir, "Account", "class Account < ApplicationRecord\n  before_destroy :base_guard\nend\n")
          write_model(dir, "Order", <<~RUBY)
            class Order < Account
              before_destroy :a
              before_destroy :check, prepend: true
              before_destroy :late_check, prepend: true
              around_save :wrap
              around_save :outer, prepend: true
              after_commit :x, prepend: true
              after_commit :y
              after_save :s1, prepend: true
              after_save :s2
            end
          RUBY

          details = described_class.new(RailsAiContext::StaticApp.new(dir)).static_call["Order"]

          expect(details[:callbacks]).to eq(
            "before_destroy" => %w[late_check check base_guard a],
            "around_save" => %w[outer wrap],
            "after_commit" => %w[y x],
            "after_save" => %w[s1 s2]
          )
        end
      end
    end

    it "keeps on: as a condition wherever the type does not already say it" do
      Dir.mktmpdir do |dir|
        write_model(dir, "Order", <<~RUBY)
          class Order < ApplicationRecord
            before_validation :prep, on: :create
            after_validation :prep, unless: :draft?, on: [:create, :update], if: :a?
            after_commit :sync, on: :create
          end
        RUBY

        conditions = described_class.new(RailsAiContext::StaticApp.new(dir)).static_call["Order"][:callback_conditions]

        expect(conditions["before_validation"]).to eq([ { on: :create } ])
        expect(conditions["after_validation"].first.to_a).to eq([ [ :on, %i[create update] ], [ :unless, :draft? ], [ :if, :a? ] ])
        expect(conditions).not_to have_key("after_commit_on_create")
      end
    end

    it "reports a block callback booted, and names no framework filter" do
      Dir.mktmpdir do |dir|
        write_model(dir, "Blocky", <<~RUBY)
          class Blocky < ApplicationRecord
            before_save do
              self.title = title.to_s.strip
            end
          end
        RUBY

        expect(booted_callbacks(dir, "Blocky")).to eq("before_save" => [ "[inline_block]" ])
      end
    end

    it "keys the commit family the same in both tiers" do
      Dir.mktmpdir do |dir|
        write_model(dir, "Committer", <<~RUBY)
          class Committer < ApplicationRecord
            after_create_commit :refresh
            after_commit :announce, on: :create
            around_create Snowflake
            after_touch :bust
          end
        RUBY

        # Both tiers read the same source through the same grouping now, so
        # the parity line alone would stay green through a change of shape in
        # that one producer. The literal is what pins the shape.
        expect(booted_callbacks(dir, "Committer")).to eq(
          "after_create_commit" => [ "refresh" ],
          "after_commit_on_create" => [ "announce" ],
          "around_create" => [ "Snowflake" ],
          "after_touch" => [ "bust" ]
        )
        expect(static_callbacks(dir, "Committer")).to eq(booted_callbacks(dir, "Committer"))
      end
    end
  end

  # The static builder walked the model's own file alone, so a model whose
  # associations all live in concerns answered `0 assoc` with no marker.
  describe "#static_call concern-declared macros" do
    it "merges what the concerns declare and tags each entry" do
      Dir.mktmpdir do |dir|
        FileUtils.mkdir_p(File.join(dir, "app", "models", "concerns"))
        File.write(File.join(dir, "app", "models", "post.rb"), <<~RUBY)
          class Post < ApplicationRecord
            include Publishable

            belongs_to :author
            validates :title, presence: true
          end
        RUBY
        File.write(File.join(dir, "app", "models", "concerns", "publishable.rb"), <<~RUBY)
          module Publishable
            extend ActiveSupport::Concern

            included do
              has_many :revisions
              belongs_to :editor
              validates :body, presence: true
              scope :published, -> { where(published: true) }
              before_save :stamp
              encrypts :secret
            end
          end
        RUBY

        post = described_class.new(RailsAiContext::StaticApp.new(dir)).static_call["Post"]

        expect(post[:associations].map { |a| a[:name] }).to contain_exactly("author", "revisions", "editor")
        expect(post[:validations].size).to eq(2)
        expect(post[:scopes].map { |s| s[:name] }).to include("published")
        expect(post[:callbacks]["before_save"]).to include("stamp")
        expect(post[:encrypts]).to eq([ "secret" ])
        expect(post[:associations].find { |a| a[:name] == "revisions" }[:from_concern]).to eq("Publishable")
        expect(post[:associations].find { |a| a[:name] == "author" }).not_to have_key(:from_concern)
        expect(post).not_to have_key(:concerns_unread)
        expect(post[:concern_callbacks].map { |cb| cb[:confidence] }).to eq([ RailsAiContext::Confidence::STATIC ])
      end
    end

    it "sees a macro in a bare module body too" do
      Dir.mktmpdir do |dir|
        FileUtils.mkdir_p(File.join(dir, "app", "models", "concerns"))
        File.write(File.join(dir, "app", "models", "widget.rb"), "class Widget < ApplicationRecord\n  include Wired\nend\n")
        File.write(File.join(dir, "app", "models", "concerns", "wired.rb"), "module Wired\n  has_many :wires\nend\n")

        result = described_class.new(RailsAiContext::StaticApp.new(dir)).static_call

        expect(result["Widget"][:associations].map { |a| a[:name] }).to contain_exactly("wires")
      end
    end

    it "does not report an association twice when the model redeclares one" do
      Dir.mktmpdir do |dir|
        FileUtils.mkdir_p(File.join(dir, "app", "models", "concerns"))
        File.write(File.join(dir, "app", "models", "widget.rb"), <<~RUBY)
          class Widget < ApplicationRecord
            include Wired
            has_many :wires, dependent: :destroy
          end
        RUBY
        File.write(File.join(dir, "app", "models", "concerns", "wired.rb"), "module Wired\n  has_many :wires\nend\n")

        wires = described_class.new(RailsAiContext::StaticApp.new(dir)).static_call["Widget"][:associations]

        expect(wires.size).to eq(1)
        expect(wires.first[:options]).to include(dependent: :destroy)
      end
    end

    # A gem's module is genuinely out of reach, and the footer promises that
    # is marked rather than silently dropped.
    it "names the concerns whose file it could not read" do
      Dir.mktmpdir do |dir|
        FileUtils.mkdir_p(File.join(dir, "app", "models"))
        File.write(File.join(dir, "app", "models", "widget.rb"), "class Widget < ApplicationRecord\n  include Discard::Model\nend\n")

        widget = described_class.new(RailsAiContext::StaticApp.new(dir)).static_call["Widget"]

        expect(widget[:concerns_unread]).to eq([ "Discard::Model" ])
      end
    end

    # A base is a class, not a concern, and a child with no concerns at all
    # never reached the line that named it.
    it "names an unreadable STI base apart from the unread concerns" do
      Dir.mktmpdir do |dir|
        FileUtils.mkdir_p(File.join(dir, "app", "models"))
        base_path = File.join(dir, "app", "models", "post.rb")
        File.write(base_path, "class Post < ApplicationRecord\n  scope :published, -> { all }\nend\n")
        File.write(File.join(dir, "app", "models", "article.rb"),
                   "class Article < Post\n  scope :recent, -> { all }\nend\n")
        make_unreadable(base_path)

        article = described_class.new(RailsAiContext::StaticApp.new(dir)).static_call["Article"]

        expect(article[:bases_unread]).to eq([ "Post" ])
        expect(article).not_to have_key(:concerns_unread)
      ensure
        File.chmod(0o644, base_path) if base_path && File.exist?(base_path)
      end
    end
  end

  # Reflection answers associations, validations and enums, but scopes,
  # macros and custom validates come off the model's own file - so without
  # the same merge the static tier would out-answer the booted one.
  # A gem's model was reported at app/models/<name>.rb, a file the app does
  # not have, and that path shipped into the app's own .ai-context.json.
  describe "#extract_model_details for a model the app does not own" do
    def details_for(dir, class_name, source_location)
      model = Class.new(ApplicationRecord) { self.table_name = "oauth_access_grants" }
      model.define_singleton_method(:name) { class_name }
      allow(Object).to receive(:const_source_location).and_call_original
      allow(Object).to receive(:const_source_location).with(class_name).and_return(source_location)
      described_class.new(RailsAiContext::StaticApp.new(dir)).send(:extract_model_details, model)
    end

    # Marked, because every other model's file resolves against the app root
    # and this one does not exist there.
    it "carries the gem's own path, not an invented app path" do
      Dir.mktmpdir do |dir|
        gem_file = File.join(Gem.path.first.to_s, "gems", "doorkeeper-5.8.2", "app", "models",
                             "doorkeeper", "access_grant.rb")

        details = details_for(dir, "Doorkeeper::AccessGrant", [ gem_file, 1 ])

        expect(details[:file]).to eq("gem:doorkeeper-5.8.2/app/models/doorkeeper/access_grant.rb")
      end
    end

    it "leaves an app-owned model's file unmarked" do
      Dir.mktmpdir do |dir|
        details = details_for(dir, "Widget", [ File.join(dir, "app", "models", "widget.rb"), 1 ])

        expect(details[:file]).to eq("app/models/widget.rb")
      end
    end

    it "records no file when Ruby knows of no source for the class" do
      Dir.mktmpdir do |dir|
        expect(details_for(dir, "Doorkeeper::AccessToken", nil)).not_to have_key(:file)
      end
    end

    # A model whose file raised partway through leaves Ruby recording the
    # autoload registration site instead of the file. The fallback used to
    # know app/models alone, so the same model one directory over kept
    # Zeitwerk's cref.rb as its file.
    it "reads a pack model's own file, not the autoload site Ruby recorded" do
      Dir.mktmpdir do |dir|
        pack = File.join(dir, "packs", "billing", "app", "models")
        FileUtils.mkdir_p(pack)
        File.write(File.join(pack, "invoice.rb"), "class Invoice < ApplicationRecord\nend\n")
        cref = File.join(Gem.path.first.to_s, "gems", "zeitwerk-2.8.3", "lib", "zeitwerk", "cref.rb")

        details = details_for(dir, "Invoice", [ cref, 47 ])

        expect(details[:file]).to eq("packs/billing/app/models/invoice.rb")
      end
    end

    # An app inflection only changes case, so the name does not round-trip to
    # the path: `ActivityPub::Activity` underscores to activity_pub/activity.rb
    # and the file is at activitypub/activity.rb. The walk that read the files
    # knows which one declares the constant.
    it "reads a model whose namespace the app inflected" do
      Dir.mktmpdir do |dir|
        FileUtils.mkdir_p(File.join(dir, "app", "models", "activitypub"))
        File.write(File.join(dir, "app", "models", "activitypub", "activity.rb"), <<~RUBY)
          module ActivityPub
            class Activity < ApplicationRecord
              scope :recent, -> { all }
            end
          end
        RUBY
        cref = File.join(Gem.path.first.to_s, "gems", "zeitwerk-2.8.3", "lib", "zeitwerk", "cref.rb")

        details = details_for(dir, "ActivityPub::Activity", [ cref, 47 ])

        expect(details[:file]).to eq("app/models/activitypub/activity.rb")
        expect(details[:scopes].map { |s| s[:name] }).to eq([ "recent" ])
      end
    end

    # An engine keeps its models under engines/<name>/app/models, and a
    # configured extra path is a model directory the same way.
    it "reads an engine model's own file" do
      Dir.mktmpdir do |dir|
        engine = File.join(dir, "engines", "billing", "app", "models")
        FileUtils.mkdir_p(engine)
        File.write(File.join(engine, "ledger.rb"), "class Ledger < ApplicationRecord\nend\n")
        cref = File.join(Gem.path.first.to_s, "gems", "zeitwerk-2.8.3", "lib", "zeitwerk", "cref.rb")

        details = details_for(dir, "Ledger", [ cref, 47 ])

        expect(details[:file]).to eq("engines/billing/app/models/ledger.rb")
      end
    end

    # Every example above stubs const_source_location, and the real thing does
    # not always name the file holding the `class` keyword: when Zeitwerk sets
    # the constant rather than letting the file define it, Ruby records
    # Zeitwerk's own cref.rb. Reading that file answers nothing the model
    # declares, so this one asks the real question of the real dummy app.
    it "reads the model's own file, not wherever Ruby happened to record the constant" do
      details = described_class.new(Rails.application).call["UserWithAttrs"]

      expect(details[:file]).to eq("app/models/user_with_attrs.rb")
      expect(details[:callbacks]["after_commit_on_create"]).to include("sync_to_crm")
      expect(details[:callbacks]["after_commit"]).to include("notify_admin")
      expect(details[:concerns_unread]).to be_blank
    end
  end

  # Rails runs what a superclass declares in every child, abstract or not. Only
  # the table stops at an abstract base: a child of one has its own. The walk
  # that merges declarations followed the table chain, so a per-connection base
  # like `Analytics::Record` gave its children nothing, while the booted tier
  # listed its concerns off the ancestor chain.
  describe "what an abstract base declares" do
    def analytics_app(dir)
      FileUtils.mkdir_p(File.join(dir, "app", "models", "concerns"))
      File.write(File.join(dir, "app", "models", "concerns", "trackable.rb"), <<~RUBY)
        module Trackable
          extend ActiveSupport::Concern

          included do
            has_many :audits
            before_save :touch_tracker
          end
        end
      RUBY
      File.write(File.join(dir, "app", "models", "analytics_record.rb"), <<~RUBY)
        class AnalyticsRecord < ApplicationRecord
          self.abstract_class = true
          include Trackable
          scope :recent, -> { order(created_at: :desc) }
          before_save :stamp
          validates :name, presence: true
        end
      RUBY
      File.write(File.join(dir, "app", "models", "page_view.rb"), "class PageView < AnalyticsRecord\nend\n")
    end

    it "reaches the child that declares nothing of its own" do
      Dir.mktmpdir do |dir|
        analytics_app(dir)

        page_view = described_class.new(RailsAiContext::StaticApp.new(dir)).static_call["PageView"]

        expect(page_view[:concerns]).to eq([ "Trackable" ])
        expect(page_view[:scopes].map { |s| s[:name] }).to eq([ "recent" ])
        expect(page_view[:callbacks]["before_save"]).to contain_exactly("stamp", "touch_tracker")
        expect(page_view[:associations].map { |a| a[:name] }).to eq([ "audits" ])
        expect(page_view[:validations].map { |v| [ v[:kind], v[:attributes] ] }).to eq([ [ "presence", [ "name" ] ] ])
      end
    end

    # The table is the one thing an abstract base does not pass down.
    it "leaves the child its own table, and the base out of the listing" do
      Dir.mktmpdir do |dir|
        analytics_app(dir)

        result = described_class.new(RailsAiContext::StaticApp.new(dir)).static_call

        expect(result.keys).to eq([ "PageView" ])
        expect(result["PageView"][:table_name]).to eq("page_views")
        expect(result["PageView"]).not_to have_key(:sti)
      end
    end

    # The app's own base is a superclass like any other: Mastodon's
    # ApplicationRecord includes Remotable, and Rails runs it in all 111
    # models. It stays out of the listing because it is not a model.
    it "reaches the child from the app's own base" do
      Dir.mktmpdir do |dir|
        FileUtils.mkdir_p(File.join(dir, "app", "models", "concerns"))
        File.write(File.join(dir, "app", "models", "concerns", "remotable.rb"), <<~RUBY)
          module Remotable
            extend ActiveSupport::Concern

            included do
              before_save :fetch_remote
            end
          end
        RUBY
        File.write(File.join(dir, "app", "models", "application_record.rb"), <<~RUBY)
          class ApplicationRecord < ActiveRecord::Base
            primary_abstract_class
            include Remotable
            scope :ordered, -> { order(:id) }
          end
        RUBY
        File.write(File.join(dir, "app", "models", "widget.rb"), "class Widget < ApplicationRecord\nend\n")

        result = described_class.new(RailsAiContext::StaticApp.new(dir)).static_call

        expect(result.keys).to eq([ "Widget" ])
        expect(result["Widget"][:concerns]).to eq([ "Remotable" ])
        expect(result["Widget"][:scopes].map { |s| s[:name] }).to eq([ "ordered" ])
        expect(result["Widget"][:callbacks]["before_save"]).to eq([ "fetch_remote" ])
      end
    end

    # Every model loses what the base declared, so every model says so. The
    # base itself is still not a row.
    it "names the app's own base when its file cannot be read" do
      Dir.mktmpdir do |dir|
        FileUtils.mkdir_p(File.join(dir, "app", "models"))
        base = File.join(dir, "app", "models", "application_record.rb")
        File.write(base, "class ApplicationRecord < ActiveRecord::Base\n  primary_abstract_class\nend\n")
        File.write(File.join(dir, "app", "models", "post.rb"), "class Post < ApplicationRecord\nend\n")
        make_unreadable(base)

        result = described_class.new(RailsAiContext::StaticApp.new(dir)).static_call

        expect(result.keys).to eq([ "Post" ])
        expect(result["Post"][:bases_unread]).to eq([ "ApplicationRecord" ])
        expect(result["Post"][:table_name]).to eq("posts")
      ensure
        File.chmod(0o644, base) if base && File.exist?(base)
      end
    end

    # Keyed on the record, the line number went into the key, so the same
    # declaration read from two files never compared equal and the answer
    # printed it twice.
    it "reports a macro the base and the child both declare once" do
      Dir.mktmpdir do |dir|
        FileUtils.mkdir_p(File.join(dir, "app", "models"))
        File.write(File.join(dir, "app", "models", "application_record.rb"), <<~RUBY)
          class ApplicationRecord < ActiveRecord::Base
            primary_abstract_class

            encrypts :secret
          end
        RUBY
        File.write(File.join(dir, "app", "models", "analytics_record.rb"), <<~RUBY)
          class AnalyticsRecord < ApplicationRecord
            self.abstract_class = true
            encrypts :secret
            encrypts :token
          end
        RUBY
        File.write(File.join(dir, "app", "models", "visit.rb"), "class Visit < AnalyticsRecord\nend\n")

        visit = described_class.new(RailsAiContext::StaticApp.new(dir)).static_call["Visit"]

        expect(visit[:encrypts]).to eq(%w[secret token])
        expect(visit[:encryption_details].map { |e| e[:field] }).to eq(%w[secret token])
      end
    end

    # The chain is nearest first, and the merge keeps the first of two
    # declarations that share a name, so the order is what decides which one
    # the child answers with. With the chain almost always one base long that
    # never showed; every model has at least two now.
    it "takes the nearest base's declaration when two bases declare the same name" do
      Dir.mktmpdir do |dir|
        FileUtils.mkdir_p(File.join(dir, "app", "models"))
        File.write(File.join(dir, "app", "models", "application_record.rb"), <<~RUBY)
          class ApplicationRecord < ActiveRecord::Base
            primary_abstract_class

            scope :recent, -> { order(:id) }
          end
        RUBY
        File.write(File.join(dir, "app", "models", "analytics_record.rb"), <<~RUBY)
          class AnalyticsRecord < ApplicationRecord
            self.abstract_class = true
            scope :recent, -> { order(created_at: :desc) }
          end
        RUBY
        File.write(File.join(dir, "app", "models", "page_view.rb"), "class PageView < AnalyticsRecord\nend\n")

        page_view = described_class.new(RailsAiContext::StaticApp.new(dir)).static_call["PageView"]

        expect(page_view[:scopes].map { |s| s[:name] }).to eq([ "recent" ])
        expect(page_view[:scopes].first[:body]).to eq("order(created_at: :desc)")
      end
    end

    # The static tier can only walk files under the app root, so a booted walk
    # that read a gem's base would answer a scope the other tier can never see.
    # Reflection still carries that base's associations, validations and enums.
    it "reads no file the static walk could not read" do
      Dir.mktmpdir do |dir|
        FileUtils.mkdir_p(File.join(dir, "app", "models"))
        # Outside the app entirely, the way an installed gem is.
        FileUtils.mkdir_p(File.join(dir, "..", "gemmy"))
        gem_base = File.expand_path(File.join(dir, "..", "gemmy_base.rb"))
        File.write(gem_base, <<~RUBY)
          class GemmyBase < ActiveRecord::Base
            self.abstract_class = true
            scope :from_the_gem, -> { all }
          end
        RUBY
        File.write(File.join(dir, "app", "models", "widget.rb"), <<~RUBY)
          class Widget < GemmyBase
            scope :from_the_app, -> { all }
          end
        RUBY
        load gem_base
        model = Class.new(GemmyBase) do
          self.table_name = "posts"
          def self.name = "Widget"
        end
        introspector = described_class.new(RailsAiContext::StaticApp.new(dir))

        booted = introspector.send(:extract_model_details, model)

        expect(booted[:scopes].map { |s| s[:name] }).to eq([ "from_the_app" ])
        # And the static tier says nothing about this model at all, rather than
        # guessing: nothing under the model directories says GemmyBase is one.
        expect(introspector.static_call).not_to have_key("Widget")
      ensure
        Object.send(:remove_const, :GemmyBase) if defined?(GemmyBase)
        File.delete(gem_base) if gem_base && File.exist?(gem_base)
      end
    end

    # A concern the model and one of its bases both include is walked once per
    # class, so one `validates` line arrived twice. ActiveSupport::Concern runs
    # `included do` once, so Rails holds one validator and the answer says one.
    it "reports one concern's declaration once when two classes in the chain include it" do
      Dir.mktmpdir do |dir|
        FileUtils.mkdir_p(File.join(dir, "app", "models", "concerns"))
        File.write(File.join(dir, "app", "models", "concerns", "trackable.rb"), <<~RUBY)
          module Trackable
            extend ActiveSupport::Concern

            included do
              validates :name, presence: true
              before_save :touch_tracker
            end
          end
        RUBY
        File.write(File.join(dir, "app", "models", "application_record.rb"), <<~RUBY)
          class ApplicationRecord < ActiveRecord::Base
            primary_abstract_class
            include Trackable
          end
        RUBY
        File.write(File.join(dir, "app", "models", "widget.rb"), "class Widget < ApplicationRecord\n  include Trackable\nend\n")

        widget = described_class.new(RailsAiContext::StaticApp.new(dir)).static_call["Widget"]

        expect(widget[:validations].size).to eq(1)
        expect(widget[:callbacks]["before_save"]).to eq([ "touch_tracker" ])
      end
    end

    # Rails keeps one entry for a symbol callback declared twice and two
    # validators for a validation declared twice, so the answer says one and
    # two. Checked against a real ActiveRecord class rather than assumed.
    it "reports a repeated callback once and a repeated validation twice" do
      Dir.mktmpdir do |dir|
        FileUtils.mkdir_p(File.join(dir, "app", "models"))
        File.write(File.join(dir, "app", "models", "analytics_record.rb"), <<~RUBY)
          class AnalyticsRecord < ApplicationRecord
            self.abstract_class = true
            before_save :stamp
            validates :title, presence: true
          end
        RUBY
        File.write(File.join(dir, "app", "models", "visit.rb"), <<~RUBY)
          class Visit < AnalyticsRecord
            before_save :stamp
            validates :title, presence: true
          end
        RUBY

        visit = described_class.new(RailsAiContext::StaticApp.new(dir)).static_call["Visit"]

        expect(visit[:callbacks]["before_save"]).to eq([ "stamp" ])
        expect(visit[:validations].size).to eq(2)
      end
    end

    # The root `ApplicationRecord` is in `excluded_models` by default, so every
    # example that writes one passes whether or not the abstract check reads
    # `primary_abstract_class`. A namespaced base is in no such list: it is the
    # one that says the check works. GitLab has Ci::ApplicationRecord.
    it "keeps a namespaced base out of the listing on what its source says" do
      Dir.mktmpdir do |dir|
        FileUtils.mkdir_p(File.join(dir, "app", "models", "ci"))
        File.write(File.join(dir, "app", "models", "application_record.rb"),
                   "class ApplicationRecord < ActiveRecord::Base\n  primary_abstract_class\nend\n")
        File.write(File.join(dir, "app", "models", "ci", "application_record.rb"), <<~RUBY)
          module Ci
            class ApplicationRecord < ::ApplicationRecord
              primary_abstract_class
              scope :for_ci, -> { all }
            end
          end
        RUBY
        File.write(File.join(dir, "app", "models", "ci", "build.rb"), <<~RUBY)
          module Ci
            class Build < Ci::ApplicationRecord
            end
          end
        RUBY

        result = described_class.new(RailsAiContext::StaticApp.new(dir)).static_call

        expect(result.keys).to eq([ "Ci::Build" ])
        expect(result["Ci::Build"][:table_name]).to eq("builds")
        expect(result["Ci::Build"][:scopes].map { |s| s[:name] }).to eq([ "for_ci" ])
      end
    end

    # A name rule stood in for a fact the source states. The app's own base
    # says `primary_abstract_class`, and a concrete model whose name happens to
    # end the same way is still a model.
    it "keeps a concrete model whose name ends in ApplicationRecord" do
      Dir.mktmpdir do |dir|
        FileUtils.mkdir_p(File.join(dir, "app", "models"))
        File.write(File.join(dir, "app", "models", "application_record.rb"),
                   "class ApplicationRecord < ActiveRecord::Base\n  primary_abstract_class\nend\n")
        File.write(File.join(dir, "app", "models", "sec_application_record.rb"), <<~RUBY)
          class SecApplicationRecord < ApplicationRecord
            scope :secure, -> { where(secure: true) }
          end
        RUBY
        File.write(File.join(dir, "app", "models", "post.rb"), "class Post < ApplicationRecord\nend\n")

        result = described_class.new(RailsAiContext::StaticApp.new(dir)).static_call

        expect(result.keys).to contain_exactly("Post", "SecApplicationRecord")
        expect(result["SecApplicationRecord"][:table_name]).to eq("sec_application_records")
      end
    end

    # The booted concern list comes off the ancestor chain whatever the walk
    # does, so it is the scopes and the callbacks that this pins on that side;
    # the static concern list is the walk's own answer.
    it "answers the base's scopes and callbacks on both tiers" do
      Dir.mktmpdir do |dir|
        analytics_app(dir)
        stub_const("Trackable", Module.new)
        base = Class.new(ApplicationRecord) do
          self.abstract_class = true
          include Trackable
          def self.name = "AnalyticsRecord"
        end
        stub_const("AnalyticsRecord", base)
        child = Class.new(base) do
          self.table_name = "posts"
          def self.name = "PageView"
        end
        introspector = described_class.new(RailsAiContext::StaticApp.new(dir))

        static = introspector.static_call["PageView"]
        booted = introspector.send(:extract_model_details, child)

        expect(booted[:concerns]).to include("Trackable")
        expect(static[:concerns]).to eq([ "Trackable" ])
        expect(booted[:scopes].map { |s| s[:name] }).to eq([ "recent" ])
        expect(booted[:callbacks]["before_save"]).to contain_exactly("stamp", "touch_tracker")
      end
    end
  end

  # The child's record already carries what its base's concerns declared, so a
  # Concerns section that named none of them contradicted the Callbacks
  # section under it, which credits them by name.
  describe "a concern an STI base includes" do
    def sti_app(dir)
      FileUtils.mkdir_p(File.join(dir, "app", "models", "concerns"))
      File.write(File.join(dir, "app", "models", "concerns", "trackable.rb"), <<~RUBY)
        module Trackable
          extend ActiveSupport::Concern

          included do
            before_save :touch_tracker
          end
        end
      RUBY
      File.write(File.join(dir, "app", "models", "vehicle.rb"),
                 "class Vehicle < ApplicationRecord\n  include Trackable\nend\n")
      File.write(File.join(dir, "app", "models", "car.rb"), "class Car < Vehicle\nend\n")
    end

    it "is named in the child's concerns, the way the child's callbacks credit it" do
      Dir.mktmpdir do |dir|
        sti_app(dir)

        car = described_class.new(RailsAiContext::StaticApp.new(dir)).static_call["Car"]

        expect(car[:concerns]).to eq([ "Trackable" ])
        expect(car[:concern_callbacks].map { |c| c[:from_concern] }).to eq([ "Trackable" ])
      end
    end

    it "is counted as hidden for the child when the key hides it" do
      Dir.mktmpdir do |dir|
        sti_app(dir)
        original = RailsAiContext.configuration.excluded_concerns
        RailsAiContext.configuration.excluded_concerns = [ /\ATrackable\z/ ]

        car = described_class.new(RailsAiContext::StaticApp.new(dir)).static_call["Car"]

        expect(car[:concerns_hidden]).to eq(1)
        expect(car[:concerns]).to be_empty
      ensure
        RailsAiContext.configuration.excluded_concerns = original
      end
    end
  end

  # The booted listing globs app/models for files reflection has not loaded and
  # names each by camelizing its path. An app inflection only changes case, so
  # `app/models/activitypub/activity.rb` was offered as `Activitypub::Activity`,
  # which constantizes to nothing: the app got a second model entry saying its
  # own file would not load.
  describe "the booted listing over a namespace the app inflected" do
    it "names the file by what it declares, so one file is one model" do
      Dir.mktmpdir do |dir|
        FileUtils.mkdir_p(File.join(dir, "app", "models", "activitypub"))
        File.write(File.join(dir, "app", "models", "activitypub", "activity.rb"), <<~RUBY)
          module ActivityPub
            class Activity < ApplicationRecord
            end
          end
        RUBY

        stub_const("ActivityPub", Module.new)
        activity = Class.new(ApplicationRecord) do
          self.table_name = "posts"
          def self.name = "ActivityPub::Activity"
        end
        stub_const("ActivityPub::Activity", activity)
        introspector = described_class.new(RailsAiContext::StaticApp.new(dir))
        allow(ActiveRecord::Base).to receive(:descendants).and_return([ activity ])

        names = introspector.call.keys

        expect(names).to eq([ "ActivityPub::Activity" ])
      end
    end
  end

  describe "the booted listing over a root the app pushes under a namespace" do
    it "names the file by the namespaced class it declares" do
      Dir.mktmpdir do |dir|
        FileUtils.mkdir_p(File.join(dir, "app", "domain", "billing"))
        FileUtils.mkdir_p(File.join(dir, "config", "initializers"))
        File.write(File.join(dir, "config", "initializers", "autoloading.rb"), <<~RUBY)
          module Domain; end
          Rails.autoloaders.main.push_dir(Rails.root.join("app/domain"), namespace: Domain)
        RUBY
        File.write(File.join(dir, "app", "domain", "billing", "invoice.rb"), <<~RUBY)
          module Domain
            module Billing
              class Invoice < ApplicationRecord
              end
            end
          end
        RUBY

        invoice = Class.new(ApplicationRecord) do
          self.table_name = "posts"
          def self.name = "Domain::Billing::Invoice"
        end
        stub_const("Domain::Billing::Invoice", invoice)
        introspector = described_class.new(RailsAiContext::StaticApp.new(dir))
        allow(ActiveRecord::Base).to receive(:descendants).and_return([])

        expect(introspector.call.keys).to eq([ "Domain::Billing::Invoice" ])
      end
    end
  end

  # Rails reads the prefix off the innermost namespace that declares one and
  # falls back to the class itself, so a model declaring its own is the case
  # `full_table_name_prefix` ends on. The walk read the namespaces only.
  describe "a table prefix the model declares itself" do
    it "prefixes the table the way Rails does" do
      Dir.mktmpdir do |dir|
        FileUtils.mkdir_p(File.join(dir, "app", "models"))
        File.write(File.join(dir, "app", "models", "article.rb"), <<~RUBY)
          class Article < ApplicationRecord
            def self.table_name_prefix = "blog_"
          end
        RUBY
        File.write(File.join(dir, "app", "models", "widget.rb"), "class Widget < ApplicationRecord\nend\n")

        result = described_class.new(RailsAiContext::StaticApp.new(dir)).static_call

        expect(result["Article"][:table_name]).to eq("blog_articles")
        expect(result["Widget"][:table_name]).to eq("widgets")
      end
    end

    # The namespace wins where both declare one, which is the order
    # `module_parents.detect { ... } || self` gives.
    it "lets the enclosing namespace's prefix win over the model's own" do
      Dir.mktmpdir do |dir|
        FileUtils.mkdir_p(File.join(dir, "app", "models", "blog"))
        File.write(File.join(dir, "app", "models", "blog.rb"), <<~RUBY)
          module Blog
            def self.table_name_prefix = "blog_"
          end
        RUBY
        File.write(File.join(dir, "app", "models", "blog", "article.rb"), <<~RUBY)
          module Blog
            class Article < ApplicationRecord
              def self.table_name_prefix = "own_"
            end
          end
        RUBY

        result = described_class.new(RailsAiContext::StaticApp.new(dir)).static_call

        expect(result["Blog::Article"][:table_name]).to eq("blog_articles")
      end
    end
  end

  # The static shaper writes the value the model declared; the booted one used
  # to write the key only when it was truthy, so one model read two ways
  # carried two different key sets into .ai-context.json.
  describe "an association option declared false" do
    it "carries the same keys on both tiers" do
      Dir.mktmpdir do |dir|
        FileUtils.mkdir_p(File.join(dir, "app", "models"))
        File.write(File.join(dir, "app", "models", "comment.rb"), <<~RUBY)
          class Comment < ApplicationRecord
            belongs_to :subject, polymorphic: false, optional: false
          end
        RUBY

        model = Class.new(ApplicationRecord) do
          self.table_name = "comments"
          belongs_to :subject, polymorphic: false, optional: false, class_name: "Post"
          def self.name = "Comment"
        end
        introspector = described_class.new(RailsAiContext::StaticApp.new(dir))

        static = introspector.static_call["Comment"][:associations].first
        booted = introspector.send(:extract_model_details, model)[:associations].first

        expect(booted[:polymorphic]).to eq(static[:polymorphic])
        expect(booted[:optional]).to eq(static[:optional])
        expect(booted[:polymorphic]).to be(false)
      end
    end
  end

  # A habtm's join table and keys are what the missing-index check and the
  # schema's join-table list look for; the booted record carried none of them,
  # so a custom join_table was read as the default name on that tier.
  describe "a has_and_belongs_to_many with its own join table and keys" do
    it "records join_table and both keys, the same on both tiers" do
      Dir.mktmpdir do |dir|
        FileUtils.mkdir_p(File.join(dir, "app", "models"))
        File.write(File.join(dir, "app", "models", "post.rb"), <<~RUBY)
          class Post < ApplicationRecord
            has_and_belongs_to_many :labels, class_name: "Tag", join_table: "post_labels",
                                    foreign_key: "article_id", association_foreign_key: "label_id"
          end
        RUBY

        model = Class.new(ApplicationRecord) do
          # habtm builds a middle model from the owner's name, so it is set first.
          def self.name = "Post"
          self.table_name = "posts"
          has_and_belongs_to_many :labels, class_name: "Tag", join_table: "post_labels",
                                           foreign_key: "article_id", association_foreign_key: "label_id"
        end
        introspector = described_class.new(RailsAiContext::StaticApp.new(dir))

        static = introspector.static_call["Post"][:associations].first
        booted = introspector.send(:extract_model_details, model)[:associations].first

        expected = { join_table: "post_labels", foreign_key: "article_id", association_foreign_key: "label_id" }
        expect(static).to include(expected)
        expect(booted).to include(expected)
      end
    end
  end

  # Rails runs the class's own declaration: the child's enum replaces the
  # base's mapping and the model's replaces the concern's. The merge appended
  # both and the Hash builder let the last one win, which is the inherited
  # one, so the values the class actually runs with never appeared.
  describe "an enum the model redeclares" do
    it "keeps the child's mapping over its STI base's" do
      Dir.mktmpdir do |dir|
        FileUtils.mkdir_p(File.join(dir, "app", "models"))
        File.write(File.join(dir, "app", "models", "vehicle.rb"),
                   "class Vehicle < ApplicationRecord\n  enum :status, { parked: 0, moving: 1 }\nend\n")
        File.write(File.join(dir, "app", "models", "car.rb"),
                   "class Car < Vehicle\n  enum :status, { idle: 0, driving: 1, towed: 2 }\nend\n")

        result = described_class.new(RailsAiContext::StaticApp.new(dir)).static_call

        expect(result["Car"][:enums]).to eq("status" => { "idle" => 0, "driving" => 1, "towed" => 2 })
        expect(result["Vehicle"][:enums]).to eq("status" => { "parked" => 0, "moving" => 1 })
      end
    end

    it "keeps the model's own mapping over a concern's" do
      Dir.mktmpdir do |dir|
        FileUtils.mkdir_p(File.join(dir, "app", "models", "concerns"))
        File.write(File.join(dir, "app", "models", "van.rb"), <<~RUBY)
          class Van < ApplicationRecord
            include Statused
            enum :status, { idle: 0 }
          end
        RUBY
        File.write(File.join(dir, "app", "models", "concerns", "statused.rb"),
                   "module Statused\n  enum :status, { parked: 9 }\n  enum :size, { small: 1 }\nend\n")

        van = described_class.new(RailsAiContext::StaticApp.new(dir)).static_call["Van"]

        expect(van[:enums]).to eq("status" => { "idle" => 0 }, "size" => { "small" => 1 })
      end
    end
  end

  # `excluded_concerns` hides the concern's name, and since both tiers merge
  # what a concern declared, it hides those declarations too. The record says
  # how many concerns went with it; naming them would undo the hiding.
  describe "a concern the excluded_concerns key hides" do
    around do |example|
      original = RailsAiContext.configuration.excluded_concerns
      RailsAiContext.configuration.excluded_concerns = [ /\AAuditable\z/ ]
      example.run
      RailsAiContext.configuration.excluded_concerns = original
    end

    def app_with_hidden_concern(dir)
      FileUtils.mkdir_p(File.join(dir, "app", "models", "concerns"))
      File.write(File.join(dir, "app", "models", "post.rb"), <<~RUBY)
        class Post < ApplicationRecord
          include Auditable
          belongs_to :author
        end
      RUBY
      File.write(File.join(dir, "app", "models", "concerns", "auditable.rb"), <<~RUBY)
        module Auditable
          has_many :audits
        end
      RUBY
    end

    it "counts it on the static record" do
      Dir.mktmpdir do |dir|
        app_with_hidden_concern(dir)

        post = described_class.new(RailsAiContext::StaticApp.new(dir)).static_call["Post"]

        expect(post[:concerns_hidden]).to eq(1)
        expect(post[:concerns]).to be_empty
        expect(post[:associations].map { |a| a[:name] }).to eq([ "author" ])
      end
    end

    it "counts nothing when the app has no file for the hidden name" do
      Dir.mktmpdir do |dir|
        FileUtils.mkdir_p(File.join(dir, "app", "models"))
        File.write(File.join(dir, "app", "models", "post.rb"), <<~RUBY)
          class Post < ApplicationRecord
            include Auditable
          end
        RUBY

        post = described_class.new(RailsAiContext::StaticApp.new(dir)).static_call["Post"]

        expect(post).not_to have_key(:concerns_hidden)
      end
    end

    # The walk reads the model's own file and its STI bases, and stops at an
    # abstract one. A count derived from the runtime ancestor chain instead
    # counted a concern nothing had merged, so the two tiers answered 1 and
    # nothing for the same app.
    it "counts nothing on either tier for a concern the walk never reaches" do
      Dir.mktmpdir do |dir|
        FileUtils.mkdir_p(File.join(dir, "app", "models", "concerns"))
        File.write(File.join(dir, "app", "models", "post.rb"), "class Post < ApplicationRecord\nend\n")
        File.write(File.join(dir, "app", "models", "concerns", "auditable.rb"), "module Auditable\nend\n")

        stub_const("Auditable", Module.new)
        model = Class.new(ApplicationRecord) do
          self.table_name = "posts"
          include Auditable
          def self.name = "Post"
        end
        introspector = described_class.new(RailsAiContext::StaticApp.new(dir))

        static = introspector.static_call["Post"]
        booted = introspector.send(:extract_model_details, model)

        expect(booted[:concerns_hidden]).to eq(static[:concerns_hidden])
        expect(booted).not_to have_key(:concerns_hidden)
      end
    end

    it "counts a hidden concern the walk reaches through another concern" do
      Dir.mktmpdir do |dir|
        FileUtils.mkdir_p(File.join(dir, "app", "models", "concerns"))
        File.write(File.join(dir, "app", "models", "post.rb"), "class Post < ApplicationRecord\n  include Outer\nend\n")
        File.write(File.join(dir, "app", "models", "concerns", "outer.rb"),
                   "module Outer\n  include Auditable\n  has_many :things\nend\n")
        File.write(File.join(dir, "app", "models", "concerns", "auditable.rb"), "module Auditable\nend\n")

        post = described_class.new(RailsAiContext::StaticApp.new(dir)).static_call["Post"]

        expect(post[:concerns_hidden]).to eq(1)
        expect(post[:associations].map { |a| a[:name] }).to eq([ "things" ])
      end
    end

    it "counts it on the booted record" do
      Dir.mktmpdir do |dir|
        app_with_hidden_concern(dir)
        stub_const("Auditable", Module.new)
        model = Class.new(ApplicationRecord) do
          self.table_name = "posts"
          include Auditable
          def self.name = "Post"
        end

        details = described_class.new(RailsAiContext::StaticApp.new(dir)).send(:extract_model_details, model)

        expect(details[:concerns_hidden]).to eq(1)
        expect(details[:concerns]).not_to include("Auditable")
      end
    end
  end

  describe "#extract_model_details concern-declared macros" do
    it "merges concern scopes and macros into the booted answer" do
      Dir.mktmpdir do |dir|
        FileUtils.mkdir_p(File.join(dir, "app", "models", "concerns"))
        model_path = File.join(dir, "app", "models", "widget.rb")
        File.write(model_path, <<~RUBY)
          class Widget < ApplicationRecord
            include Wired
            scope :own, -> { all }
          end
        RUBY
        File.write(File.join(dir, "app", "models", "concerns", "wired.rb"), <<~RUBY)
          module Wired
            extend ActiveSupport::Concern

            included do
              scope :shared, -> { all }
              encrypts :secret
              before_save :stamp
            end
          end
        RUBY

        stub_const("Wired", Module.new)
        model = Class.new(ApplicationRecord) do
          self.table_name = "posts"
          include Wired
          def self.name = "Widget"
        end

        introspector = described_class.new(RailsAiContext::StaticApp.new(dir))
        # Named, not blanket: this is asked for every class in the chain, and a
        # base answering the model's own file would merge it into itself.
        allow(introspector).to receive(:model_source_path) { |klass| model_path if klass.name == "Widget" }

        details = introspector.send(:extract_model_details, model)

        expect(details[:scopes].map { |s| s[:name] }).to contain_exactly("own", "shared")
        expect(details[:encrypts]).to eq([ "secret" ])
        expect(details[:concern_callbacks].map { |c| c[:method] }).to eq([ "stamp" ])
      end
    end

    it "marks a concern whose file it could not read" do
      Dir.mktmpdir do |dir|
        model_path = File.join(dir, "app", "models", "gadget.rb")
        FileUtils.mkdir_p(File.dirname(model_path))
        File.write(model_path, <<~RUBY)
          class Gadget < ApplicationRecord
            include Elsewhere
          end
        RUBY

        stub_const("Elsewhere", Module.new)
        model = Class.new(ApplicationRecord) do
          self.table_name = "posts"
          include Elsewhere
          def self.name = "Gadget"
        end

        introspector = described_class.new(RailsAiContext::StaticApp.new(dir))
        allow(introspector).to receive(:model_source_path).and_return(model_path)

        expect(introspector.send(:extract_model_details, model)[:concerns_unread]).to eq([ "Elsewhere" ])
      end
    end
  end

  describe "#extract_model_details STI-inherited macros" do
    # Reflection inherits associations, validations and enums, and nothing
    # else: scopes, callbacks and the attribute macros are read off the file.
    # A child that reads its own file alone answers empty for all three while
    # the static tier answers the base's - and the child really does run them.
    it "merges the STI base's source-read macros into the booted answer" do
      Dir.mktmpdir do |dir|
        FileUtils.mkdir_p(File.join(dir, "app", "models"))
        base_path = File.join(dir, "app", "models", "post.rb")
        child_path = File.join(dir, "app", "models", "article.rb")
        File.write(base_path, <<~RUBY)
          class Post < ApplicationRecord
            scope :published, -> { where(published: true) }
            encrypts :secret
            before_save :touch_it
          end
        RUBY
        File.write(child_path, "class Article < Post\nend\n")

        base = Class.new(ApplicationRecord) do
          self.table_name = "posts"
          def self.name = "Post"
        end
        child = Class.new(base) do
          def self.name = "Article"
        end

        introspector = described_class.new(RailsAiContext::StaticApp.new(dir))
        paths = { "Post" => base_path, "Article" => child_path }
        allow(introspector).to receive(:model_source_path) { |model| paths[model.name] }

        details = introspector.send(:extract_model_details, child)

        expect(details[:scopes].map { |s| s[:name] }).to eq([ "published" ])
        expect(details[:callbacks]).to eq("before_save" => [ "touch_it" ])
        expect(details[:encrypts]).to eq([ "secret" ])
      end
    end

    # A base the walk cannot read costs that base's own declarations. Without
    # a guard the read escaped the walk and the child's whole entry - table,
    # associations, validations, enums, callbacks, scopes - became one error.
    it "keeps the child's own answer when the STI base is over the size cap" do
      Dir.mktmpdir do |dir|
        FileUtils.mkdir_p(File.join(dir, "app", "models"))
        base_path = File.join(dir, "app", "models", "post.rb")
        child_path = File.join(dir, "app", "models", "article.rb")
        File.write(base_path, "class Post < ApplicationRecord\n  scope :published, -> { all }\n" \
                              "  # #{"x" * 400}\nend\n")
        File.write(child_path, "class Article < Post\n  scope :recent, -> { all }\nend\n")

        base = Class.new(ApplicationRecord) do
          self.table_name = "posts"
          def self.name = "Post"
        end
        child = Class.new(base) do
          def self.name = "Article"
        end

        introspector = described_class.new(RailsAiContext::StaticApp.new(dir))
        paths = { "Post" => base_path, "Article" => child_path }
        allow(introspector).to receive(:model_source_path) { |model| paths[model.name] }
        allow(RailsAiContext.configuration).to receive(:max_file_size).and_return(200)

        details = introspector.send(:extract_model_details, child)

        expect(details[:scopes].map { |s| s[:name] }).to eq([ "recent" ])
        expect(details[:bases_unread]).to eq([ "Post" ])
        expect(details).not_to have_key(:concerns_unread)
      end
    end

    it "keeps the child's own answer when the STI base cannot be read" do
      Dir.mktmpdir do |dir|
        FileUtils.mkdir_p(File.join(dir, "app", "models"))
        base_path = File.join(dir, "app", "models", "post.rb")
        child_path = File.join(dir, "app", "models", "article.rb")
        File.write(base_path, "class Post < ApplicationRecord\n  scope :published, -> { all }\nend\n")
        File.write(child_path, "class Article < Post\n  scope :recent, -> { all }\nend\n")
        make_unreadable(base_path)

        base = Class.new(ApplicationRecord) do
          self.table_name = "posts"
          def self.name = "Post"
        end
        child = Class.new(base) do
          def self.name = "Article"
        end

        introspector = described_class.new(RailsAiContext::StaticApp.new(dir))
        paths = { "Post" => base_path, "Article" => child_path }
        allow(introspector).to receive(:model_source_path) { |model| paths[model.name] }

        details = introspector.send(:extract_model_details, child)

        expect(details[:scopes].map { |s| s[:name] }).to eq([ "recent" ])
        expect(details[:bases_unread]).to eq([ "Post" ])
        expect(details).not_to have_key(:concerns_unread)
      ensure
        File.chmod(0o644, base_path) if base_path && File.exist?(base_path)
      end
    end

    it "reads the shared base once for two children" do
      Dir.mktmpdir do |dir|
        FileUtils.mkdir_p(File.join(dir, "app", "models"))
        base_path = File.join(dir, "app", "models", "post.rb")
        File.write(base_path, "class Post < ApplicationRecord\n  scope :published, -> { all }\nend\n")
        %w[article draft].each do |name|
          File.write(File.join(dir, "app", "models", "#{name}.rb"), "class #{name.capitalize} < Post\nend\n")
        end

        base = Class.new(ApplicationRecord) do
          self.table_name = "posts"
          def self.name = "Post"
        end
        children = %w[Article Draft].map do |name|
          Class.new(base) { define_singleton_method(:name) { name } }
        end

        introspector = described_class.new(RailsAiContext::StaticApp.new(dir))
        allow(introspector).to receive(:model_source_path) do |model|
          File.join(dir, "app", "models", "#{model.name.downcase}.rb")
        end

        allow(RailsAiContext::Introspectors::SourceIntrospector).to receive(:walk_source).and_call_original
        expect(RailsAiContext::Introspectors::SourceIntrospector)
          .to receive(:walk_source).with(a_string_including("scope :published")).once.and_call_original
        children.each { |child| introspector.send(:extract_model_details, child) }
      end
    end
  end

  describe "#extract_model_details over a file the tier cannot read" do
    def details_for(model_source, max_file_size: nil, unreadable: false)
      Dir.mktmpdir do |dir|
        FileUtils.mkdir_p(File.join(dir, "app", "models"))
        path = File.join(dir, "app", "models", "post.rb")
        File.write(path, model_source)
        make_unreadable(path) if unreadable

        model = Class.new(ApplicationRecord) do
          self.table_name = "posts"
          def self.name = "Post"
        end

        introspector = described_class.new(RailsAiContext::StaticApp.new(dir))
        allow(introspector).to receive(:model_source_path).and_return(path)
        allow(RailsAiContext.configuration).to receive(:max_file_size).and_return(max_file_size) if max_file_size

        begin
          introspector.send(:extract_model_details, model)
        ensure
          File.chmod(0o644, path)
        end
      end
    end

    # The constants walk parses the file a second time, on its own, so a file
    # the source walk already declared unreadable still reached it - and the
    # raise took the model's whole entry with it.
    it "still answers for a model whose own file cannot be read" do
      details = details_for("class Post < ApplicationRecord\n  ROLES = %w[a b]\nend\n", unreadable: true)

      expect(details[:table_name]).to eq("posts")
      expect(details).not_to have_key(:constants)
    end

    it "names an escaped constant symbol by what it means, not by its source text" do
      details = details_for(%Q(class Post < ApplicationRecord\n  ROLES = [:admin, :"super\\u0020user"]\nend\n))

      roles = details[:constants].find { |c| c[:name] == "ROLES" }
      expect(roles[:values]).to eq([ "admin", "super user" ])
    end

    it "does not read constants out of a file it declared over the size cap" do
      source = "class Post < ApplicationRecord\n  ROLES = %w[a b]\n  # #{"x" * 400}\nend\n"
      details = details_for(source, max_file_size: 200)

      expect(details[:table_name]).to eq("posts")
      expect(details).not_to have_key(:constants)
    end
  end

  describe "confidence on a static entry" do
    # The entry says [STATIC] while its own records claimed [VERIFIED], so one
    # answer contradicted itself: the renderer prints the scope tag next to the
    # header tag, and --format json hands every one of these keys through.
    it "does not let a record claim more than the tier that carries it" do
      Dir.mktmpdir do |dir|
        FileUtils.mkdir_p(File.join(dir, "app", "models"))
        File.write(File.join(dir, "app", "models", "post.rb"), <<~RUBY)
          class Post < ApplicationRecord
            belongs_to :user
            validates :title, presence: true
            scope :published, -> { all }
            def summary = title
          end
        RUBY

        post = described_class.new(RailsAiContext::StaticApp.new(dir)).static_call["Post"]

        expect(post[:confidence]).to eq(RailsAiContext::Confidence::STATIC)
        %i[associations validations scopes methods].each do |key|
          expect(post[key].map { |r| r[:confidence] })
            .to all(eq(RailsAiContext::Confidence::STATIC)), "#{key} still claims more than the entry"
        end
      end
    end

    it "keeps a record the parser could not resolve at its own lower mark" do
      Dir.mktmpdir do |dir|
        FileUtils.mkdir_p(File.join(dir, "app", "models"))
        File.write(File.join(dir, "app", "models", "post.rb"),
                   "class Post < ApplicationRecord\n  scope :recent, SOME_LAMBDA\nend\n")

        post = described_class.new(RailsAiContext::StaticApp.new(dir)).static_call["Post"]

        expect(post[:scopes].map { |s| s[:confidence] }).to eq([ RailsAiContext::Confidence::INFERRED ])
      end
    end
  end

  describe "a database a base class connects to" do
    it "names it on the model that inherits it, with the class that declares it" do
      Dir.mktmpdir do |dir|
        FileUtils.mkdir_p(File.join(dir, "app", "models"))
        File.write(File.join(dir, "app", "models", "analytics_record.rb"), <<~RUBY)
          class AnalyticsRecord < ApplicationRecord
            self.abstract_class = true
            connects_to database: { writing: :analytics, reading: :analytics }
          end
        RUBY
        File.write(File.join(dir, "app", "models", "page_view.rb"), "class PageView < AnalyticsRecord\nend\n")
        File.write(File.join(dir, "app", "models", "post.rb"), "class Post < ApplicationRecord\nend\n")

        models = described_class.new(RailsAiContext::StaticApp.new(dir)).static_call

        expect(models["PageView"][:database]).to eq(connects_to: "connects_to database: { writing: :analytics, reading: :analytics }",
                                                    declared_in: "AnalyticsRecord", writing: "analytics")
        expect(models["Post"]).not_to have_key(:database)
      end
    end
  end

  describe "a connects_to under a condition" do
    it "keeps the condition and routes no table to its database" do
      Dir.mktmpdir do |dir|
        FileUtils.mkdir_p(File.join(dir, "app", "models"))
        File.write(File.join(dir, "app", "models", "replica_record.rb"), <<~RUBY)
          class ReplicaRecord < ApplicationRecord
            self.abstract_class = true
            connects_to database: { writing: :primary, reading: :replica } if DatabaseHelper.replica_enabled?
          end
        RUBY
        File.write(File.join(dir, "app", "models", "status.rb"), "class Status < ReplicaRecord\nend\n")

        models = described_class.new(RailsAiContext::StaticApp.new(dir)).static_call

        expect(models["Status"][:database]).to eq(connects_to: "connects_to database: { writing: :primary, reading: :replica }",
                                                  condition: "if DatabaseHelper.replica_enabled?", declared_in: "ReplicaRecord")
      end
    end
  end

  describe "STI on the booted tier" do
    it "reads the type column the model names, not a fixed one" do
      parent = Class.new { def self.name = "Vehicle" }
      model = double("Car", inheritance_column: "kind", connected?: true, table_exists?: true,
                     columns_hash: { "kind" => double }, descendants: [], superclass: parent)

      sti = described_class.new(Rails.application).send(:extract_sti_info, model)

      expect(sti).to eq(sti_base: false, sti_parent: "Vehicle", type_column: "kind")
    end
  end

  describe "STI on the static tier" do
    # The booted tier reports the hierarchy under :sti and the graph tool
    # renders it from there. The static tier resolves the same chain to share
    # the base's table and its macros, so it can answer the same question.
    it "reports the base, the parent and the children" do
      Dir.mktmpdir do |dir|
        FileUtils.mkdir_p(File.join(dir, "app", "models"))
        File.write(File.join(dir, "app", "models", "post.rb"), <<~RUBY)
          class Post < ApplicationRecord
            has_many :comments
          end
        RUBY
        File.write(File.join(dir, "app", "models", "article.rb"), "class Article < Post\nend\n")

        models = described_class.new(RailsAiContext::StaticApp.new(dir)).static_call

        expect(models["Post"][:sti]).to eq(sti_base: true, sti_children: [ "Article" ], type_column: "type")
        expect(models["Article"][:sti]).to eq(sti_base: false, sti_parent: "Post", type_column: "type")
      end
    end

    it "reports no STI where the schema shows the base's table has no type column" do
      Dir.mktmpdir do |dir|
        FileUtils.mkdir_p(File.join(dir, "app", "models"))
        FileUtils.mkdir_p(File.join(dir, "db"))
        File.write(File.join(dir, "db", "schema.rb"), <<~RUBY)
          ActiveRecord::Schema[7.1].define(version: 1) do
            create_table "users" do |t|
              t.string "name"
              t.bigint "type_id"
            end
            create_table "principals" do |t|
              t.string "type"
            end
          end
        RUBY
        File.write(File.join(dir, "app", "models", "user.rb"), "class User < ApplicationRecord\nend\n")
        File.write(File.join(dir, "app", "models", "null_user.rb"), "class NullUser < User\nend\n")
        File.write(File.join(dir, "app", "models", "principal.rb"), "class Principal < ApplicationRecord\nend\n")
        File.write(File.join(dir, "app", "models", "group.rb"), "class Group < Principal\nend\n")

        models = described_class.new(RailsAiContext::StaticApp.new(dir)).static_call

        expect(models["User"]).not_to have_key(:sti)
        expect(models["NullUser"]).not_to have_key(:sti)
        expect(models["NullUser"][:table_name]).to eq("users")
        expect(models["Group"][:sti]).to include(sti_parent: "Principal", type_column: "type")
      end
    end

    it "takes the type column from an inheritance_column a base sets" do
      Dir.mktmpdir do |dir|
        FileUtils.mkdir_p(File.join(dir, "app", "models"))
        File.write(File.join(dir, "app", "models", "vehicle.rb"), <<~RUBY)
          class Vehicle < ApplicationRecord
            self.inheritance_column = :kind
          end
        RUBY
        File.write(File.join(dir, "app", "models", "car.rb"), "class Car < Vehicle\nend\n")
        File.write(File.join(dir, "app", "models", "boat.rb"), "class Boat < ApplicationRecord\n  self.inheritance_column = KIND\nend\n")
        File.write(File.join(dir, "app", "models", "dinghy.rb"), "class Dinghy < Boat\nend\n")

        models = described_class.new(RailsAiContext::StaticApp.new(dir)).static_call

        expect(models["Car"][:sti]).to include(sti_parent: "Vehicle", type_column: "kind")
        expect(models["Car"][:model_settings]).to eq("inheritance_column" => ":kind")
        expect(models["Vehicle"][:sti]).to include(type_column: "kind")
        expect(models["Boat"][:sti]).to include(type_column: RailsAiContext::Confidence::INFERRED)
      end
    end

    it "reports no STI where a base turns it off, and reads a quoted or escaped column name off the node" do
      Dir.mktmpdir do |dir|
        FileUtils.mkdir_p(File.join(dir, "app", "models"))
        FileUtils.mkdir_p(File.join(dir, "db"))
        File.write(File.join(dir, "db", "schema.rb"), <<~RUBY)
          ActiveRecord::Schema[7.1].define(version: 1) do
            create_table "vehicles" do |t|
              t.string "type"
            end
          end
        RUBY
        File.write(File.join(dir, "app", "models", "vehicle.rb"), "class Vehicle < ApplicationRecord\n  self.inheritance_column = nil\nend\n")
        File.write(File.join(dir, "app", "models", "car.rb"), "class Car < Vehicle\nend\n")
        File.write(File.join(dir, "app", "models", "boat.rb"), "class Boat < ApplicationRecord\n  self.inheritance_column = %w[kind].first\n  self.inheritance_column = %s(sort)\nend\n")
        File.write(File.join(dir, "app", "models", "dinghy.rb"), "class Dinghy < Boat\nend\n")

        models = described_class.new(RailsAiContext::StaticApp.new(dir)).static_call

        expect(models["Car"]).not_to have_key(:sti)
        expect(models["Vehicle"]).not_to have_key(:sti)
        expect(models["Dinghy"][:sti]).to include(type_column: "sort")
      end
    end

    it "leaves a model with no STI chain without the key" do
      Dir.mktmpdir do |dir|
        FileUtils.mkdir_p(File.join(dir, "app", "models"))
        File.write(File.join(dir, "app", "models", "post.rb"), "class Post < ApplicationRecord\nend\n")

        models = described_class.new(RailsAiContext::StaticApp.new(dir)).static_call

        expect(models["Post"]).not_to have_key(:sti)
      end
    end
  end

  # A `has_many :through` naming an association the model does not declare
  # loads fine and only raises when something touches it. Reading it cost the
  # whole model: its callbacks, its table heading and its graph node were
  # replaced by one error line.
  describe "a reflection that cannot resolve" do
    let(:owner) { double("Post", reflect_on_association: nil) }

    let(:resolvable) do
      double("comments", name: :comments, macro: :has_many, class_name: "Comment",
                         foreign_key: "post_id", options: {})
    end

    let(:dangling) do
      double("reader_emails", name: :reader_emails, macro: :has_many,
                              options: { through: :reader }, active_record: owner).tap do |reflection|
        allow(reflection).to receive(:class_name).and_raise(NoMethodError, "undefined method 'klass' for nil")
      end
    end

    it "keeps every other association and marks the one that failed" do
      model = double("Post", reflect_on_all_associations: [ resolvable, dangling ])

      associations = introspector.send(:extract_associations, model)

      expect(associations.first).to include(name: "comments", class_name: "Comment")
      expect(associations.last).to include(name: "reader_emails",
                                           unavailable: "through :reader is not an association")
    end

    # has_one_attached defines avatar_attachment with Rails' own options; the
    # app wrote none of them, and the static tier has nothing to print.
    it "prints no options for an association the source does not declare" do
      generated = double("avatar_attachment", name: :avatar_attachment, macro: :has_one, class_name: "ActiveStorage::Attachment",
                                              foreign_key: "record_id", options: { as: :record, inverse_of: :record, strict_loading: false })
      model = double("User", reflect_on_all_associations: [ generated ])

      association = introspector.send(:extract_associations, model).first

      expect(association).to include(name: "avatar_attachment")
      expect(association).not_to have_key(:declared_options)
    end
  end
  # A display cap must not decide whether a method exists, so the model's own
  # methods travel uncapped beside the capped list every renderer reads.
  describe "the model's own methods" do
    it "carries them uncapped on the static tier" do
      Dir.mktmpdir do |dir|
        FileUtils.mkdir_p(File.join(dir, "app", "models"))
        bodies = (1..35).map { |i| "  def step_#{format('%02d', i)}; end" }.join("\n")
        File.write(File.join(dir, "app", "models", "post.rb"), "class Post < ApplicationRecord\n#{bodies}\nend\n")

        result = described_class.new(RailsAiContext::StaticApp.new(dir)).send(:static_call)

        expect(result["Post"][:instance_methods].size).to eq(described_class::PAYLOAD_METHOD_CAP)
        expect(result["Post"][:source_instance_methods].size).to eq(35)
        expect(result["Post"][:source_instance_methods]).to include("step_35")
      end
    end

    it "carries them uncapped on the booted tier" do
      Dir.mktmpdir do |dir|
        bodies = (1..35).map { |i| "  def step_#{format('%02d', i)}; end" }.join("\n")
        path = File.join(dir, "post.rb")
        File.write(path, "class Post < ApplicationRecord\n#{bodies}\nend\n")
        allow(introspector).to receive(:introspect_source).and_return(RailsAiContext::Introspectors::SourceIntrospector.call(path))

        details = introspector.send(:extract_model_details, Post)

        expect(details[:instance_methods].size).to eq(described_class::PAYLOAD_METHOD_CAP)
        expect(details[:source_instance_methods].size).to eq(35)
        expect(details[:source_instance_methods]).to include("step_35")
      end
    end
  end
end
