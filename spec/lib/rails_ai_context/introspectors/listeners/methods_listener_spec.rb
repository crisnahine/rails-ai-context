# frozen_string_literal: true

require "spec_helper"

RSpec.describe RailsAiContext::Introspectors::Listeners::MethodsListener do
  def parse_and_dispatch(source)
    result     = Prism.parse(source)
    listener   = described_class.new
    RailsAiContext::Introspectors::ListenerRegistration.dispatcher_for(listener).dispatch(result.value)
    listener.results
  end

  it "detects public instance methods" do
    source = <<~RUBY
      class User
        def full_name
          "\#{first} \#{last}"
        end
      end
    RUBY
    results = parse_and_dispatch(source)
    expect(results.first).to include(name: "full_name", scope: :instance, visibility: :public)
  end

  it "detects class methods with self." do
    source = <<~RUBY
      class User
        def self.search(q)
          where(name: q)
        end
      end
    RUBY
    results = parse_and_dispatch(source)
    expect(results.first).to include(name: "search", scope: :class, visibility: :public)
  end

  it "detects class methods in class << self" do
    source = <<~RUBY
      class User
        class << self
          def find_by_email(email)
            find_by(email: email)
          end
        end
      end
    RUBY
    results = parse_and_dispatch(source)
    expect(results.first).to include(name: "find_by_email", scope: :class)
  end

  it "tracks private visibility" do
    source = <<~RUBY
      class User
        def public_method; end
        private
        def secret_method; end
      end
    RUBY
    results = parse_and_dispatch(source)
    pub = results.find { |m| m[:name] == "public_method" }
    priv = results.find { |m| m[:name] == "secret_method" }
    expect(pub[:visibility]).to eq(:public)
    expect(priv[:visibility]).to eq(:private)
  end

  it "skips initialize" do
    source = <<~RUBY
      class Service
        def initialize(user)
          @user = user
        end
        def call; end
      end
    RUBY
    results = parse_and_dispatch(source)
    names = results.map { |m| m[:name] }
    expect(names).not_to include("initialize")
    expect(names).to include("call")
  end

  it "extracts method parameters" do
    source = <<~RUBY
      class User
        def update(name, age: nil, **opts, &block)
        end
      end
    RUBY
    results = parse_and_dispatch(source)
    params = results.first[:params]
    types = params.map { |p| p[:type] }
    expect(types).to include(:required, :keyword, :keyword_rest, :block)
  end

  it "handles inline private :method_name form" do
    source = <<~RUBY
      class User
        def secret_method; end
        private :secret_method

        def public_method; end
      end
    RUBY
    results = parse_and_dispatch(source)
    secret = results.find { |m| m[:name] == "secret_method" }
    pub = results.find { |m| m[:name] == "public_method" }
    expect(secret[:visibility]).to eq(:private)
    expect(pub[:visibility]).to eq(:public)
  end

  it "includes line locations" do
    results = parse_and_dispatch("def foo; end")
    expect(results.first[:location]).to eq(1)
  end

  it "marks all methods as VERIFIED" do
    results = parse_and_dispatch("def foo; end")
    expect(results.first[:confidence]).to eq("[VERIFIED]")
  end

  it "does not leak visibility across classes in multi-class files" do
    source = <<~RUBY
      class Foo
        private
        def secret; end
      end

      class Bar
        def public_method; end
      end
    RUBY
    results = parse_and_dispatch(source)
    bar_method = results.find { |m| m[:name] == "public_method" }
    expect(bar_method[:visibility]).to eq(:public)
  end

  it "preserves inline visibility across nested class boundaries" do
    source = <<~RUBY
      class Outer
        def outer_public; end
        private :outer_public

        class Inner
          def inner_public; end
          private :inner_public
        end

        def another_outer; end
        private :another_outer
      end
    RUBY
    results = parse_and_dispatch(source)
    outer_pub = results.find { |m| m[:name] == "outer_public" }
    inner_pub = results.find { |m| m[:name] == "inner_public" }
    another   = results.find { |m| m[:name] == "another_outer" }
    expect(outer_pub[:visibility]).to eq(:private)
    expect(inner_pub[:visibility]).to eq(:private)
    expect(another[:visibility]).to eq(:private)
  end

  describe "signature" do
    it "keeps parameter defaults as written" do
      results = parse_and_dispatch("class S\n  def call(query, account = nil, options = {})\n  end\nend\n")
      expect(results.first[:signature]).to eq("call(query, account = nil, options = {})")
    end

    it "prefixes a class method with self." do
      results = parse_and_dispatch("class S\n  def self.call(a)\n  end\nend\n")
      expect(results.first[:signature]).to eq("self.call(a)")
    end

    it "omits the parens when a method takes no parameters" do
      results = parse_and_dispatch("class S\n  def call\n  end\nend\n")
      expect(results.first[:signature]).to eq("call")
    end

    it "folds a parameter list split over several lines onto one line" do
      source = <<~RUBY
        class S
          def call(
            recipient,
            options = {}
          )
          end
        end
      RUBY
      expect(parse_and_dispatch(source).first[:signature]).to eq("call(recipient, options = {})")
    end

    it "keeps parameters written without parens" do
      results = parse_and_dispatch("class S\n  def call a, b\n  end\nend\n")
      expect(results.first[:signature]).to eq("call(a, b)")
    end
  end

  describe "owner" do
    it "names the enclosing class of each method, outermost first" do
      source = <<~RUBY
        class AccountSearchService
          class QueryBuilder
            def build
            end
          end

          def call
          end
        end
      RUBY
      results = parse_and_dispatch(source)
      expect(results.find { |m| m[:name] == "build" }[:owner]).to eq(%w[AccountSearchService QueryBuilder])
      expect(results.find { |m| m[:name] == "call" }[:owner]).to eq(%w[AccountSearchService])
    end

    it "records a module namespace as its own level" do
      source = <<~RUBY
        module Admin
          class SuspendService
            def call
            end
          end
        end
      RUBY
      results = parse_and_dispatch(source)
      expect(results.first[:owner]).to eq(%w[Admin SuspendService])
    end

    it "joins the compact form to the same constant as the nested form" do
      source = <<~RUBY
        class Admin::SuspendService
          def call
          end
        end
      RUBY
      results = parse_and_dispatch(source)
      expect(results.first[:owner].join("::")).to eq("Admin::SuspendService")
    end

    it "is empty for a method defined at the top level" do
      results = parse_and_dispatch("def bare_helper\nend\n")
      expect(results.first[:owner]).to eq([])
    end
  end
end
