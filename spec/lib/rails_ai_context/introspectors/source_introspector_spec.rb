# frozen_string_literal: true

require "spec_helper"

RSpec.describe RailsAiContext::Introspectors::SourceIntrospector do
  describe ".from_source" do
    subject(:result) { described_class.from_source(source) }

    context "with a full model" do
      let(:source) do
        <<~RUBY
          class User < ApplicationRecord
            has_many :posts, dependent: :destroy
            has_one :profile
            belongs_to :organization

            validates :email, presence: true, uniqueness: true
            validate :custom_check

            scope :active, -> { where(active: true) }
            scope :admins, -> { where(role: :admin) }

            enum :role, { admin: 0, member: 1 }, prefix: true

            before_save :normalize_email
            after_create :send_welcome

            has_secure_password
            encrypts :ssn, deterministic: true
            normalizes :email, with: ->(e) { e.strip.downcase }
            delegate :company_name, to: :organization

            def full_name
              "\#{first_name} \#{last_name}"
            end

            def self.search(query)
              where("name LIKE ?", "%\#{query}%")
            end

            private

            def normalize_email
              self.email = email.downcase
            end
          end
        RUBY
      end

      it "extracts associations" do
        assocs = result[:associations]
        expect(assocs.size).to eq(3)
        expect(assocs).to include(a_hash_including(type: :has_many, name: :posts))
        expect(assocs).to include(a_hash_including(type: :has_one, name: :profile))
        expect(assocs).to include(a_hash_including(type: :belongs_to, name: :organization))
      end

      it "includes association options" do
        has_many = result[:associations].find { |a| a[:name] == :posts }
        expect(has_many[:options]).to eq({ dependent: :destroy })
      end

      it "includes confidence for associations" do
        result[:associations].each do |assoc|
          expect(assoc[:confidence]).to eq("[VERIFIED]").or eq("[INFERRED]")
        end
      end

      it "includes line locations" do
        result[:associations].each do |assoc|
          expect(assoc[:location]).to be_a(Integer)
          expect(assoc[:location]).to be > 0
        end
      end

      it "extracts validations" do
        vals = result[:validations]
        presence_val = vals.find { |v| v[:kind] == :presence }
        expect(presence_val).not_to be_nil
        expect(presence_val[:attributes]).to include("email")
      end

      it "extracts custom validates" do
        customs = result[:validations].select { |v| v[:kind] == :custom }
        expect(customs.map { |v| v[:attributes] }.flatten).to include("custom_check")
      end

      it "extracts scopes" do
        scopes = result[:scopes]
        expect(scopes.size).to eq(2)
        expect(scopes.map { |s| s[:name] }).to contain_exactly("active", "admins")
      end

      it "extracts enums with values and options" do
        enums = result[:enums]
        expect(enums.size).to eq(1)
        expect(enums.first[:name]).to eq("role")
        expect(enums.first[:values]).to eq({ admin: 0, member: 1 })
        expect(enums.first[:options]).to include(prefix: true)
      end

      it "extracts callbacks" do
        cbs = result[:callbacks]
        expect(cbs).to include(a_hash_including(type: "before_save", method: "normalize_email"))
        expect(cbs).to include(a_hash_including(type: "after_create", method: "send_welcome"))
      end

      it "extracts macros" do
        macros = result[:macros]
        expect(macros).to include(a_hash_including(macro: :has_secure_password))
        expect(macros).to include(a_hash_including(macro: :encrypts, attribute: "ssn"))
        expect(macros).to include(a_hash_including(macro: :normalizes, attribute: "email"))
        expect(macros).to include(a_hash_including(macro: :delegate))
      end

      it "extracts public methods" do
        methods = result[:methods]
        public_instance = methods.select { |m| m[:scope] == :instance && m[:visibility] == :public }
        public_class    = methods.select { |m| m[:scope] == :class && m[:visibility] == :public }
        private_methods = methods.select { |m| m[:visibility] == :private }

        expect(public_instance.map { |m| m[:name] }).to include("full_name")
        expect(public_class.map { |m| m[:name] }).to include("search")
        expect(private_methods.map { |m| m[:name] }).to include("normalize_email")
      end
    end

    context "with empty source" do
      let(:source) { "class Empty < ApplicationRecord; end" }

      it "returns empty arrays for all keys" do
        expect(result[:associations]).to be_empty
        expect(result[:validations]).to be_empty
        expect(result[:scopes]).to be_empty
        expect(result[:enums]).to be_empty
        expect(result[:callbacks]).to be_empty
        expect(result[:macros]).to be_empty
      end
    end

    context "with multi-line associations" do
      let(:source) do
        <<~RUBY
          class Order < ApplicationRecord
            has_many :items,
              class_name: "OrderItem",
              dependent: :destroy,
              inverse_of: :order
          end
        RUBY
      end

      it "parses multi-line options correctly" do
        assoc = result[:associations].first
        expect(assoc[:name]).to eq(:items)
        expect(assoc[:options][:dependent]).to eq(:destroy)
        expect(assoc[:options][:class_name]).to eq("OrderItem")
        expect(assoc[:options][:inverse_of]).to eq(:order)
      end
    end

    context "with legacy enum syntax" do
      let(:source) do
        <<~RUBY
          class Post < ApplicationRecord
            enum status: { draft: 0, published: 1, archived: 2 }
          end
        RUBY
      end

      it "extracts legacy enum definitions" do
        enums = result[:enums]
        expect(enums.size).to eq(1)
        expect(enums.first[:name]).to eq("status")
        expect(enums.first[:values]).to include(draft: 0, published: 1, archived: 2)
      end
    end
  end
end
