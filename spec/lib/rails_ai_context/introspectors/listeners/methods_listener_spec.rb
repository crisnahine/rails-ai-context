# frozen_string_literal: true

require "spec_helper"

RSpec.describe RailsAiContext::Introspectors::Listeners::MethodsListener do
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

  it "records the hooks Ruby always makes private as private, unless marked public" do
    source = <<~RUBY
      class User
        def initialize; end
        def initialize_copy(other); end
        def initialize_dup(other); end
        def initialize_clone(other, freeze: nil); end
        def respond_to_missing?(name, all = false) = false
        public def initialize_copy(other); end
        def self.respond_to_missing?(name, all = false) = false
      end
    RUBY
    results = RailsAiContext::Introspectors::SourceIntrospector.walk_source(source, { methods: -> { described_class.new(include_initialize: true) } })[:methods]

    expect(results.map { |r| [ r[:name], r[:scope], r[:visibility] ] }).to eq([
      [ "initialize", :instance, :private ], [ "initialize_copy", :instance, :private ], [ "initialize_dup", :instance, :private ],
      [ "initialize_clone", :instance, :private ], [ "respond_to_missing?", :instance, :private ],
      [ "initialize_copy", :instance, :public ], [ "respond_to_missing?", :class, :public ]
    ])
  end

  it "records the always-private hooks as private when an alias, define_method or attr names them" do
    source = <<~RUBY
      class User
        def real_one = 1
        alias_method :respond_to_missing?, :real_one
        alias initialize_clone real_one
        define_method(:initialize_dup) { |other| nil }
        attr_reader :initialize_copy
        define_method(:respond_to_missing?) { |*| false }
        public :respond_to_missing?
        class << self
          define_method(:initialize_dup) { |other| nil }
        end
      end
    RUBY
    results = parse_and_dispatch(source)

    expect(results.map { |r| [ r[:name], r[:scope], r[:visibility] ] }).to eq([
      [ "real_one", :instance, :public ], [ "respond_to_missing?", :instance, :private ],
      [ "initialize_clone", :instance, :private ], [ "initialize_dup", :instance, :private ],
      [ "initialize_copy", :instance, :private ], [ "respond_to_missing?", :instance, :public ],
      [ "initialize_dup", :class, :public ]
    ])
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

  it "records initialize, with its owner, when asked for it" do
    source = <<~RUBY
      class Service
        class Failure < StandardError
          def initialize(message, accounts)
            super(message)
          end
        end

        def initialize
          @started = true
        end
      end
    RUBY
    results = parse_and_dispatch(source, include_initialize: true)
    ctors = results.select { |m| m[:name] == "initialize" }
    expect(ctors.map { |m| [ m[:owner].join("::"), m[:signature] ] }).to contain_exactly(
      [ "Service::Failure", "initialize(message, accounts)" ],
      [ "Service", "initialize" ]
    )
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

    it "leaves a comment inside the parameter list out of the signature" do
      source = <<~RUBY
        class S
          def call(
            recipient, # who it goes to
            options = {}
          )
          end
        end
      RUBY
      expect(parse_and_dispatch(source).first[:signature]).to eq("call(recipient, options = {})")
    end

    it "keeps every kind of parameter in order" do
      results = parse_and_dispatch("class S\n  def call(a, b = 1, *rest, c:, d: 2, **opts, &blk)\n  end\nend\n")
      expect(results.first[:signature]).to eq("call(a, b = 1, *rest, c:, d: 2, **opts, &blk)")
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

  it "keeps an inline private def to its own class" do
    methods = parse_and_dispatch("class A\n  def x; end\nend\nclass B\n  private def x; end\nend\n")
    expect(methods.map { |m| [ m[:owner], m[:visibility] ] }).to eq([ [ %w[A], :public ], [ %w[B], :private ] ])
  end

  it "flips only the current class's method on private :x" do
    methods = parse_and_dispatch("class A\n  def x; end\nend\nclass B\n  def x; end\n  private :x\nend\n")
    expect(methods.map { |m| [ m[:owner], m[:visibility] ] }).to eq([ [ %w[A], :public ], [ %w[B], :private ] ])
  end

  it "records private def as private" do
    methods = parse_and_dispatch("class A\n  private def hidden; end\n  def shown; end\nend\n")
    expect(methods.map { |m| [ m[:name], m[:visibility] ] }).to eq([ [ "hidden", :private ], [ "shown", :public ] ])
  end

  it "records methods inside class_methods and included blocks with their scope" do
    source = <<~RUBY
      module Searchable
        extend ActiveSupport::Concern
        included do
          def from_included; end
        end
        class_methods do
          def search; end
        end
        def own; end
      end
    RUBY
    methods = parse_and_dispatch(source)
    expect(methods.find { |m| m[:name] == "search" }[:scope]).to eq(:class)
    expect(methods.find { |m| m[:name] == "from_included" }[:scope]).to eq(:instance)
    expect(methods.find { |m| m[:name] == "own" }[:scope]).to eq(:instance)
  end

  it "keeps a private section inside class_methods to that block" do
    source = <<~RUBY
      module Importable
        class_methods do
          def import; end
          private
          def parse; end
        end
        def own; end
      end
    RUBY
    methods = parse_and_dispatch(source)
    expect(methods.map { |m| [ m[:name], m[:scope], m[:visibility] ] }).to eq([
      [ "import", :class, :public ], [ "parse", :class, :private ], [ "own", :instance, :public ]
    ])
  end

  it "records the methods a delegation defines, public whatever section it sits in" do
    source = <<~RUBY
      class WorkersController < ApplicationController
        extend Forwardable
        def_delegators :@service, :run, :stop
        private
        def_delegator :@service, :pause, :halt
        delegate :name, to: :service
        delegate :code, to: :service, prefix: true
        delegate :size, to: :service, prefix: :queue
        delegate :token, to: :service, private: true
        def helper
          delegate :inside, to: :service
        end
      end
    RUBY
    methods = parse_and_dispatch(source)
    expect(methods.map { |m| [ m[:name], m[:scope], m[:visibility] ] }).to eq([
      [ "run", :instance, :public ], [ "stop", :instance, :public ], [ "halt", :instance, :public ],
      [ "name", :instance, :public ], [ "service_code", :instance, :public ], [ "queue_size", :instance, :public ],
      [ "token", :instance, :private ], [ "helper", :instance, :private ]
    ])
    expect(methods.first).to include(signature: "run", location: 3)
    expect(methods.first).not_to have_key(:end_location)
    expect(source[methods.last[:offset]...methods.last[:end_offset]]).to eq("def helper\n    delegate :inside, to: :service\n  end")
  end

  it "reads Forwardable's hash form and a delegation in class << self" do
    source = <<~RUBY
      class Box
        extend Forwardable
        delegate [:first, :last] => :@items, :count => :@items
        class << self
          def_delegators :registry, :lookup
        end
      end
    RUBY
    methods = parse_and_dispatch(source)
    expect(methods.map { |m| [ m[:name], m[:scope] ] }).to eq([
      [ "first", :instance ], [ "last", :instance ], [ "count", :instance ], [ "lookup", :class ]
    ])
  end
end

RSpec.describe RailsAiContext::Introspectors::Listeners::MethodsListener, "visibility scopes" do
  def rows(source)
    parse_and_dispatch(source).map { |m| [ m[:name], m[:scope], m[:visibility] ] }
  end

  it "keeps a private inside class << self to the singleton body" do
    source = <<~RUBY
      class OrdersController
        class << self
          private
          def internal_helper; end
        end
        def index; end
      end
    RUBY
    expect(rows(source)).to eq([ [ "internal_helper", :class, :private ], [ "index", :instance, :public ] ])
  end

  it "starts a class << self body public after a private section" do
    source = <<~RUBY
      class Widget
        def theta_instance; end
        private
        class << self
          def iota_class_after_private_section; end
        end
        def still_private; end
      end
    RUBY
    expect(rows(source)).to eq([
      [ "theta_instance", :instance, :public ],
      [ "iota_class_after_private_section", :class, :public ],
      [ "still_private", :instance, :private ]
    ])
  end

  it "keeps a private inside a concerning block to that block" do
    source = <<~RUBY
      class WidgetLog
        concerning :Exporting do
          def export; end
          private
          def export_rows; end
        end
        def summary_after_concerning; end
      end
    RUBY
    expect(rows(source)).to eq([
      [ "export", :instance, :public ], [ "export_rows", :instance, :private ],
      [ "summary_after_concerning", :instance, :public ]
    ])
  end

  it "flips only the singleton method on private :x inside class << self" do
    source = "class Widget\n  def x; end\n  class << self\n    def x; end\n    private :x\n  end\nend\n"
    expect(rows(source)).to eq([ [ "x", :instance, :public ], [ "x", :class, :private ] ])
  end

  it "reads def Const.x as a class method of that constant" do
    source = "class Widget\n  def Widget.beta_class_via_const; end\nend\n"
    expect(parse_and_dispatch(source).first).to include(name: "beta_class_via_const", scope: :class,
                                                        visibility: :public, signature: "self.beta_class_via_const")
  end

  it "leaves a singleton def on another object out of the class's methods" do
    expect(rows("class Widget\n  def other.x; end\n  def Other.y; end\nend\n")).to eq([])
  end

  it "keeps def self.x public after a bare private, as Ruby does" do
    expect(rows("class Widget\n  private\n  def self.x; end\nend\n")).to eq([ [ "x", :class, :public ] ])
  end

  it "reads private_class_method, inline and by name, as private class methods" do
    source = <<~RUBY
      class Widget
        private_class_method def self.zeta_private_class; end
        def self.eta_class; end
        private_class_method :eta_class
        def eta_class; end
      end
    RUBY
    expect(rows(source)).to eq([
      [ "zeta_private_class", :class, :private ], [ "eta_class", :class, :private ], [ "eta_class", :instance, :public ]
    ])
  end

  it "reads module_function as a public module method and a private instance method" do
    source = <<~RUBY
      module PriceCalc
        module_function
        def total(items) = items.sum
      end
      module Fmt
        def money(x) = x
        module_function :money
      end
    RUBY
    methods = parse_and_dispatch(source)
    expect(methods.map { |m| [ m[:name], m[:scope], m[:visibility] ] }).to contain_exactly(
      [ "total", :instance, :private ], [ "total", :class, :public ],
      [ "money", :instance, :private ], [ "money", :class, :public ]
    )
    expect(methods.find { |m| m[:name] == "total" && m[:scope] == :class }[:signature]).to eq("self.total(items)")
  end

  it "leaves methods in a scope or association extension block out of the model" do
    source = <<~RUBY
      class User
        scope :recent, -> { order(created_at: :desc) } do
          def first_two = limit(2)
        end
        has_many :ext_users, class_name: "User" do
          def newest; end
        end
        has_one :profile do
          def ignored; end
        end
        with_options presence: true do
          def kept; end
        end
      end
    RUBY
    expect(rows(source)).to eq([ [ "kept", :instance, :public ] ])
  end

  it "leaves methods in a Struct.new, Data.define, Class.new or Module.new block out of the class" do
    source = <<~RUBY
      class PointHolder < ApplicationRecord
        Point = Struct.new(:x) do
          def dist; end
        end
        Coord = ::Data.define(:lat) do
          def to_s = lat.to_s
        end
        Anon = Class.new(Base) do
          def anon_m; end
        end
        Mixin = Module.new { def mixed; end }
        Other = Builder.new do
          def built; end
        end
        def real_m; end
      end
    RUBY
    own = parse_and_dispatch(source).select { |m| m[:owner] == [ "PointHolder" ] }.map { |m| [ m[:name], m[:scope], m[:visibility] ] }
    expect(own).to eq([ [ "built", :instance, :public ], [ "real_m", :instance, :public ] ])
  end

  it "reads a builder block assigned to a constant as that constant's body" do
    source = <<~RUBY
      module ServiceListeners
        EditorialRemarker = Struct.new(:edition, :author) do
          def save_remark!; end
        end
        Outer::Mixin = Module.new { def mixed; end }
      end
    RUBY
    expect(parse_and_dispatch(source).map { |m| [ m[:owner], m[:name] ] })
      .to eq([ [ %w[ServiceListeners EditorialRemarker], "save_remark!" ], [ %w[ServiceListeners Outer::Mixin], "mixed" ] ])
  end

  it "keeps a Module.new block held in a local with the class that includes it" do
    source = <<~RUBY
      module ContentItem
        def stored
          methods = Module.new do
            def __remove_items; end
          end
          include methods
        end
      end
    RUBY
    expect(parse_and_dispatch(source).map { |m| [ m[:owner], m[:name] ] })
      .to eq([ [ [ "ContentItem" ], "stored" ], [ [ "ContentItem" ], "__remove_items" ] ])
  end

  it "marks a def self.x in an included block as a class method the includer gains" do
    source = <<~RUBY
      module Sluggable
        extend ActiveSupport::Concern
        included do
          def self.find_by_slug_or_id(slug); end
          class << self
            def by_slug; end
          end
          def to_param; end
        end
        def self.own; end
      end
    RUBY
    rows = parse_and_dispatch(source).map { |m| [ m[:name], m[:scope], !!m[:class_methods_block] ] }
    expect(rows).to eq([
      [ "find_by_slug_or_id", :class, true ], [ "by_slug", :class, true ],
      [ "to_param", :instance, false ], [ "own", :class, false ]
    ])
  end

  it "leaves out a def self.x or a class << self def inside class_methods, which only ClassMethods responds to" do
    source = <<~RUBY
      module Sluggable
        extend ActiveSupport::Concern
        class_methods do
          def by_slug; end
          def self.own_of_class_methods; end
          class << self
            def registry; end
            attr_accessor :setting
          end
        end
      end
    RUBY
    rows = parse_and_dispatch(source).map { |m| [ m[:name], !!m[:class_methods_block] ] }
    expect(rows).to eq([ [ "by_slug", true ] ])
  end
end

RSpec.describe RailsAiContext::Introspectors::Listeners::MethodsListener, "methods defined without def" do
  def rows(source)
    parse_and_dispatch(source).map { |m| [ m[:signature], m[:scope], m[:visibility] ] }
  end

  it "records alias, alias_method, attr_*, define_method, class_attribute and cattr_accessor" do
    source = <<~RUBY
      class Gadget < ApplicationRecord
        attr_accessor :draft_note
        attr_reader :cached_total
        class_attribute :default_color
        cattr_accessor :registry
        define_method(:dyn_inst) { 1 }

        def summary(style = :short)
          name.to_s
        end
        alias full_title summary
        alias_method :headline, :summary
      end
    RUBY
    expect(rows(source)).to contain_exactly(
      [ "draft_note", :instance, :public ], [ "draft_note=(value)", :instance, :public ],
      [ "cached_total", :instance, :public ],
      [ "default_color", :class, :public ], [ "default_color=(value)", :class, :public ], [ "default_color?", :class, :public ],
      [ "default_color", :instance, :public ], [ "default_color=(value)", :instance, :public ], [ "default_color?", :instance, :public ],
      [ "registry", :class, :public ], [ "registry=(value)", :class, :public ],
      [ "registry", :instance, :public ], [ "registry=(value)", :instance, :public ],
      [ "dyn_inst", :instance, :public ],
      [ "summary(style = :short)", :instance, :public ],
      [ "full_title(style = :short)", :instance, :public ],
      [ "headline(style = :short)", :instance, :public ]
    )
  end

  it "gives an alias its original's params as well as its signature" do
    source = "class Gadget\n  def build(name, size: 1)\n  end\n  alias_method :setup, :build\n  alias again setup\nend\n"
    methods = parse_and_dispatch(source).to_h { |m| [ m[:name], m ] }

    expect(methods["setup"]).to include(signature: "setup(name, size: 1)", params: methods["build"][:params])
    expect(methods["again"]).to include(signature: "again(name, size: 1)", params: methods["build"][:params])
  end

  it "honors the options that leave instance methods out" do
    source = <<~RUBY
      class Gadget
        class_attribute :a, instance_writer: false, instance_predicate: false
        class_attribute :b, instance_accessor: false
        mattr_reader :c, instance_reader: false
      end
    RUBY
    expect(rows(source)).to contain_exactly(
      [ "a", :class, :public ], [ "a=(value)", :class, :public ], [ "a", :instance, :public ],
      [ "b", :class, :public ], [ "b=(value)", :class, :public ], [ "b?", :class, :public ],
      [ "c", :class, :public ]
    )
  end

  it "keeps attr_* and define_method in the visibility section and an alias at its original's" do
    source = <<~RUBY
      class Gadget
        private
        attr_reader :secret
        define_method(:hidden) { 1 }
        def inner; end
        alias outer inner
        alias_method :saved, :save
        class << self
          attr_accessor :setting
        end
      end
    RUBY
    expect(rows(source)).to contain_exactly(
      [ "secret", :instance, :private ], [ "hidden", :instance, :private ], [ "inner", :instance, :private ],
      [ "outer", :instance, :private ], [ "saved", :instance, :public ],
      [ "setting", :class, :public ], [ "setting=(value)", :class, :public ]
    )
  end

  it "applies an inline private or protected to the names attr_*, define_method and alias_method define" do
    source = <<~RUBY
      class Gadget
        private attr_reader :a
        protected attr_writer :b
        private attr_accessor :c
        private define_method(:d) { 1 }
        def e; end
        private alias_method :f, :e
        attr_reader :g
      end
    RUBY
    expect(rows(source)).to contain_exactly(
      [ "a", :instance, :private ], [ "b=(value)", :instance, :protected ],
      [ "c", :instance, :private ], [ "c=(value)", :instance, :private ],
      [ "d", :instance, :private ], [ "e", :instance, :public ], [ "f", :instance, :private ],
      [ "g", :instance, :public ]
    )
  end

  it "skips a computed name and a definer run inside a method" do
    source = <<~RUBY
      class Gadget
        %w[a b].each { |n| define_method("\#{n}_x") { n } }
        attr_reader(*COLUMNS)
        def self.build
          define_method(:later) { 1 }
          attr_accessor :later_too
        end
      end
    RUBY
    expect(rows(source)).to eq([ [ "self.build", :class, :public ] ])
  end
end
