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
        expect(ssn_entry[:options][:deterministic]).to be true
        expect(ssn_entry[:options][:downcase]).to be true
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
        expect(email_entry[:transformation]).to eq("[INFERRED]")
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
        expect(email_token[:expires_in]).to eq("[INFERRED]")
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
        expect(data[:encryption_details]).to eq([ { field: "private_key", options: { deterministic: true } } ])
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
        expect(post[:validations].map { |v| v[:kind] }).not_to include(:custom)
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
        expect(result.keys).to contain_exactly("Good")
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

    it "reports the validator with no attributes rather than raising" do
      result = described_class.new(Rails.application).call
      kinds = Array(result["Comment"][:validations]).map { |v| v[:kind] }
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

    it "prepends the table_name_prefix the enclosing module declares" do
      Dir.mktmpdir do |dir|
        write_models(dir,
          "admin.rb" => "module Admin\n  def self.table_name_prefix\n    'admin_'\n  end\nend\n",
          "admin/action_log.rb" => "module Admin\n  class ActionLog < ApplicationRecord\n  end\nend\n")

        result = described_class.new(RailsAiContext::StaticApp.new(dir)).static_call

        expect(result["Admin::ActionLog"][:table_name]).to eq("admin_action_logs")
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
        allow(introspector).to receive(:model_source_path).and_return(model_path)

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

        expect(models["Post"][:sti]).to eq(sti_base: true, sti_children: [ "Article" ])
        expect(models["Article"][:sti]).to eq(sti_base: false, sti_parent: "Post")
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
end
