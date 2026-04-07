# frozen_string_literal: true

require "spec_helper"

RSpec.describe RailsAiContext::Introspectors::Listeners::MethodsListener do
  def parse_and_dispatch(source)
    result     = Prism.parse(source)
    dispatcher = Prism::Dispatcher.new
    listener   = described_class.new
    dispatcher.register(listener, :on_call_node_enter, :on_def_node_enter,
                        :on_singleton_class_node_enter, :on_singleton_class_node_leave,
                        :on_class_node_enter, :on_class_node_leave,
                        :on_module_node_enter, :on_module_node_leave)
    dispatcher.dispatch(result.value)
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
end
