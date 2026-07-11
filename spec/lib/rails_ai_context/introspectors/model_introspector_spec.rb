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
      expect(introspector.send(:framework_concern?, "DEBUGGER__::TrapInterceptor")).to be true
      expect(result["User"][:concerns]).not_to include("DEBUGGER__::TrapInterceptor")
    end

    it "extracts class_methods as array" do
      expect(result["User"][:class_methods]).to be_an(Array)
    end

    it "extracts instance_methods as array" do
      expect(result["User"][:instance_methods]).to be_an(Array)
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
        expect(widget[:associations].map { |a| a[:name] }).to contain_exactly(:factory, :parts)
        expect(widget[:validations]).not_to be_empty
        expect(result["Admin::Report"][:table_name]).to eq("reports")
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
        expect(result["Invoice"][:associations].map { |a| a[:name] }).to eq([ :user ])
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
  end
end
