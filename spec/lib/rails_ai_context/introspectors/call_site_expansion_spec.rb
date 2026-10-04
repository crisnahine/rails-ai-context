# frozen_string_literal: true

require "spec_helper"

RSpec.describe RailsAiContext::Introspectors::CallSiteExpansion do
  # The entries `call_source` declares by calling the one method `method_source` defines.
  def expand(method_source, call_source)
    definition = Prism.parse(method_source).value.statements.body.first
    call = Prism.parse(call_source).value.statements.body.first
    described_class.entries(definition, call, RailsAiContext::Introspectors::SourceIntrospector::LISTENER_MAP)
  end

  def associations(data)
    Array(data[:associations]).map { |a| [ a[:type], a[:name].to_s ] }
  end

  describe "binding a parameter to the call's literal" do
    it "leaves a parameter the method reassigns unbound" do
      data = expand(<<~RUBY, "attachable :picture")
        def attachable(name)
          name = "\#{name}_file"
          has_one name
        end
      RUBY

      expect(data[:associations].map { |a| a[:name].to_s }).not_to include("picture")
    end

    it "leaves a parameter a block reassigns unbound" do
      data = expand(<<~RUBY, "attachable :picture")
        def attachable(name)
          [1].each { name = :"\#{name}_file" }
          has_one name
        end
      RUBY

      expect(associations(data)).not_to include([ "has_one", "picture" ])
    end

    it "leaves a read that a block parameter shadows unbound" do
      data = expand(<<~RUBY, "many :things, [:alpha, :beta]")
        def many(name, kinds)
          kinds.each { |name| has_many name }
          has_one name
        end
      RUBY

      expect(associations(data)).to include([ "has_one", "things" ])
      expect(associations(data)).not_to include([ "has_many", "things" ])
    end

    it "binds a read inside a block that does not shadow it" do
      data = expand(<<~RUBY, "tagged :labels")
        def tagged(name)
          [1].each { has_many name }
        end
      RUBY

      expect(associations(data)).to eq([ [ "has_many", "labels" ] ])
    end
  end

  # Canvas's plugin_settings runs `module_eval <<~RUBY` with interpolation;
  # a heredoc's body sits past its node's slice, and reading it crashed.
  it "reads a method whose heredoc interpolates, keeping what follows it" do
    data = expand(<<~'RUBY', "recent_by :created_at")
      def recent_by(column)
        scope :recent, -> { where(<<~SQL) }
          #{column} > now()
        SQL
        has_many :entries
      end
    RUBY

    expect(data[:scopes].map { |scope| scope[:name] }).to eq([ "recent" ])
    expect(associations(data)).to eq([ [ "has_many", "entries" ] ])
  end

  # OpenProject's acts_as_customizable declares custom_comments only
  # `if can_have_custom_comments?`, which the call's literals cannot decide;
  # WorkPackage, which does not pass comments:, was listed as having it.
  describe "a declaration under a condition the literals cannot decide" do
    it "is conditional, with its condition, and not listed as present" do
      data = expand(<<~RUBY, "customizable validate_on: :saving")
        def customizable(options = {})
          has_many :custom_values
          if can_have_custom_comments?
            has_many :custom_comments,
                     dependent: :delete_all
          end
          if options[:comments]
            has_many :comment_links
          end
        end
      RUBY

      expect(associations(data)).to eq([ [ "has_many", "custom_values" ] ])
      expect(data[:conditional].map { |c| [ c[:declaration], c[:condition] ] })
        .to eq([ [ "has_many :custom_comments, dependent: :delete_all", "can_have_custom_comments?" ] ])
    end

    it "names the declaration by its call, less the block it takes" do
      data = expand(<<~RUBY, "noted")
        def noted
          if enabled?
            has_many :notes, dependent: :destroy do
              def recent; end
            end
          end
        end
      RUBY

      expect(data[:conditional].first[:declaration]).to eq("has_many :notes, dependent: :destroy")
    end

    it "lists what every branch declares alike, and holds the rest as conditional" do
      data = expand(<<~RUBY, "taggable Kind.current")
        def taggable(kind)
          if kind.admin?
            has_many :tags
            has_one :summary
          else
            has_many :tags
            has_many :summary
          end
        end
      RUBY

      expect(associations(data)).to eq([ [ "has_many", "tags" ] ])
      expect(data[:conditional].map { |c| [ c[:declaration], c[:condition] ] })
        .to eq([ [ "has_one :summary", "kind.admin?" ], [ "has_many :summary", "not kind.admin?" ] ])
    end
  end

  describe "a case the call's literals decide or cannot" do
    let(:method_source) do
      <<~RUBY
        def setup(type: :many)
          case type
          when :one then has_one :thing
          when :many, :some
            has_many :things
          end
        end
      RUBY
    end

    it "takes the one branch the literal picks" do
      expect(associations(expand(method_source, "setup type: :one"))).to eq([ [ "has_one", "thing" ] ])
      expect(associations(expand(method_source, "setup type: :some"))).to eq([ [ "has_many", "things" ] ])
      expect(associations(expand(method_source, "setup type: :neither"))).to eq([])
    end

    it "holds every branch back as conditional when the literals cannot pick" do
      data = expand(method_source, "setup type: Kind.current")

      expect(associations(data)).to eq([])
      expect(data[:conditional].map { |c| [ c[:declaration], c[:condition] ] }).to eq(
        [ [ "has_one :thing", "type is :one" ], [ "has_many :things", "type is :many, :some" ] ]
      )
    end
  end

  # Consul's validates_translation validates on translation_class inside
  # `translation_class.instance_eval { }`: that block declares on the
  # translation class, not on the model the method is called in.
  describe "a block evaluated on another receiver" do
    let(:method_source) do
      <<~RUBY
        def validates_translation(method, options = {})
          validates(method, options)
          translation_class.instance_eval do
            validates method, length: options[:length]
          end
          Proposal::Translation.class_eval { has_many :notes }
          self.class_eval { has_many :drafts }
        end
      RUBY
    end

    it "is not the model's, and is named with the receiver it declares on" do
      data = expand(method_source, "validates_translation :title, presence: true, length: { maximum: 80 }")

      expect(data[:validations].map { |v| [ v[:kind], v[:attributes] ] }).to eq([ [ "presence", [ "title" ] ], [ "length", [ "title" ] ] ])
      expect(associations(data)).to eq([ [ "has_many", "drafts" ] ])
      expect(data[:foreign].map { |f| [ f[:declaration], f[:receiver] ] }).to eq(
        [ [ "validates :title, length: { maximum: 80 }", "translation_class" ],
          [ "has_many :notes", "Proposal::Translation" ] ]
      )
    end
  end

  # An options hash the call leaves at its empty default wrote `has_one :picture, `
  # with a dangling comma, and the next line became that call's argument.
  it "drops an empty options argument whole, keeping the next declaration" do
    data = expand(<<~RUBY, "attachable :picture")
      def attachable(name, options = {})
        has_one name, options
        after_save :touch_attachment
        validates(name, options)
        has_many :versions
      end
    RUBY

    expect(associations(data)).to eq([ [ "has_one", "picture" ], [ "has_many", "versions" ] ])
    expect(data[:callbacks].map { |c| c[:method] }).to eq([ "touch_attachment" ])
  end

  # Consul's validates_translation passes `options.merge(if: ...)`: the rules
  # the call names, each under that condition, and never a computed attribute.
  it "reads merge, reject, slice and except on the call's options hash" do
    data = expand(<<~RUBY, "validates_translation :title, presence: true, length: { in: 4..Proposal.title_max_length }")
      def validates_translation(method, options = {})
        validates(method, options.merge(if: -> { translations.blank? }))
        validates :summary, options.reject { |key| key == :length }
        validates :body, options.slice(:length)
        validates :intro, options.except(:presence, :length)
      end
    RUBY

    rules = data[:validations].map { |v| [ v[:kind], v[:attributes], v[:options].keys.sort ] }
    expect(rules).to eq([
      [ "presence", [ "title" ], %i[if] ], [ "length", [ "title" ], %i[if in] ],
      [ "presence", [ "summary" ], [] ],
      [ "length", [ "body" ], %i[in] ]
    ])
    expect(data[:validations].flat_map { |v| Array(v[:computed_attributes]) }).to be_empty
  end

  # Consul validates the translation class a second time only `if options.many?`.
  describe "a block on another receiver under a condition" do
    let(:method_source) do
      <<~RUBY
        def validates_translation(method, options = {})
          if options.many?
            translation_class.instance_eval { validates method, options.reject { |key| key == :length } }
          end
          translation_class.instance_eval { has_many :notes } if enabled?
        end
      RUBY
    end

    it "is left out when the call's options decide the condition false, and carries a condition it cannot decide" do
      data = expand(method_source, "validates_translation :description, presence: true")

      expect(data[:foreign].map { |f| [ f[:declaration], f[:receiver], f[:condition] ] })
        .to eq([ [ "has_many :notes", "translation_class", "enabled?" ] ])
    end

    it "is listed with no condition when the call's options decide it true" do
      data = expand(method_source, "validates_translation :title, presence: true, length: { maximum: 80 }")

      expect(data[:foreign].first.slice(:declaration, :condition)).to eq({ declaration: "validates :title, presence: true" })
    end
  end

  # Canvas's validates_locale, written before keyword arguments; `extract_options!` is the Rails spelling.
  describe "an options hash taken off the end of a *args parameter" do
    [ "args.last.is_a?(Hash) ? args.pop : {}", "args.extract_options!" ].each do |taken|
      method_source = <<~RUBY
        def validates_loc(*args)
          options = #{taken}
          before_validation :blank_to_nil if options[:allow_nil] && !options[:allow_empty]
        end
      RUBY

      it "reads the call's trailing hash, or none, through `#{taken}`" do
        callbacks = ->(call) { Array(expand(method_source, call)[:callbacks]).map { |cb| cb[:method].to_s } }

        expect(callbacks.call("validates_loc :locale, allow_nil: true")).to eq(%w[blank_to_nil])
        expect(callbacks.call("validates_loc allow_nil: true, allow_empty: true")).to eq([])
        expect(callbacks.call("validates_loc :locale")).to eq([])
      end
    end

    it "stays unbound when the method writes the local again" do
      data = expand(<<~RUBY, "validates_loc allow_nil: true")
        def validates_loc(*args)
          options = args.extract_options!
          options = {} if options.empty?
          before_validation :blank_to_nil if options[:allow_nil]
        end
      RUBY

      expect(data[:conditional].map { |c| c[:condition] }).to eq([ "options[:allow_nil]" ])
    end

    # Ruby registers :x for every change here but `delete` and `&&= false`, which drop the key's truth.
    it "stays unbound when the method changes the hash in place" do
      [ "options.reverse_merge!(allow_nil: true)", "options[:allow_nil] = true", "options.delete(:allow_nil)",
        "options[:allow_nil] ||= true", "options[:allow_nil] &&= false", "options[:allow_nil] |= false" ].each do |change|
        data = expand("def vl(*args)\n  options = args.extract_options!\n  #{change}\n  before_save :x if options[:allow_nil]\nend\n",
                      "vl :a, allow_nil: true")

        expect([ Array(data[:callbacks]), data[:conditional].map { |c| c[:condition] } ]).to eq([ [], [ "options[:allow_nil]" ] ])
      end
    end

    it "takes only the arguments past the other parameters" do
      method_source = "def vl(name, *args)\n  options = args.extract_options!\n  before_save :x if options[:allow_nil]\nend\n"

      expect(Array(expand(method_source, "vl :a, allow_nil: true")[:callbacks]).map { |cb| cb[:method] }).to eq(%w[x])
      expect(Array(expand(method_source, "vl allow_nil: true")[:callbacks])).to eq([])
    end

    # Ruby fills requireds and posts first, then optionals, and `*args` takes what is left.
    it "takes the rest after requireds, optionals and posts, less a hash the keywords take, unknown past a splat" do
      each_field = "  args.each do |field|\n    validates_presence_of field\n  end\nend\n"
      read = ->(head, call) { expand("#{head}\n  options = args.extract_options!\n#{each_field}", call)[:validations].map { |v| v[:attributes] } }
      posts = "def vl(first, second = :s, *args, last)"

      expect(read.call(posts, "vl :a, :b, :c, :d, :e")).to eq([ [ "c" ], [ "d" ] ])
      expect(read.call(posts, "vl :a, :b, :c")).to eq([])
      expect(read.call(posts, "vl :a, :b")).to eq([])
      expect(read.call("def vl(*args, allow_nil: false)", "vl :a, allow_nil: true")).to eq([ [ "a" ] ])
      expect(read.call("def vl(*args)", "vl :a, allow_nil: true")).to eq([ [ "a" ] ])
      expect(read.call("def vl(*args)", "vl(*fields)")).to eq([ [] ])

      keywords = "def vl(*args, allow_nil: false)\n  options = args.extract_options!\n  before_save :x if options[:allow_nil]\nend\n"
      expect(Array(expand(keywords, "vl :a, allow_nil: true")[:callbacks])).to eq([])
      named = "def vl(name, *args)\n  options = args.extract_options!\n  before_save :x if options[:allow_nil]\nend\n"
      expect(expand(named, "vl(*fields, allow_nil: true)")[:conditional].map { |c| c[:condition] }).to eq([ "options[:allow_nil]" ])
    end

    it "pushes with `push` too, and only when the modifier's predicate holds" do
      method_source = "def vl(*args)\n  args.push(:locale, :zone) if args.empty?\n  args.each do |field|\n    validates_presence_of field\n  end\nend\n"
      read = ->(call) { expand(method_source, call)[:validations].map { |v| v[:attributes] } }

      expect(read.call("vl")).to eq([ [ "locale" ], [ "zone" ] ])
      expect(read.call("vl :a")).to eq([ [ "a" ] ])
    end

    # Ruby: `vl :a, :b` validates a and b; `vl` validates locale, the default the body pushes.
    it "writes a block over the rest of the list once per item, with what the leading statements push" do
      method_source = <<~'RUBY'
        def vl(*args)
          options = args.last.is_a?(Hash) ? args.pop : {}
          args << :locale if args.empty?
          args.each do |field|
            validates_inclusion_of field, options.merge(if: :"#{field}_changed?")
          end
        end
      RUBY
      read = ->(call) { expand(method_source, call)[:validations].map { |v| [ v[:attributes], v[:options] ] } }

      expect(read.call("vl :a, :b, allow_nil: true")).to eq(
        [ [ [ "a" ], { allow_nil: true, if: :a_changed? } ], [ [ "b" ], { allow_nil: true, if: :b_changed? } ] ]
      )
      expect(read.call("vl")).to eq([ [ [ "locale" ], { if: :locale_changed? } ] ])
    end
  end

  describe "a hash parameter the body changes in place" do
    it "is bound to nothing" do
      data = expand("def vl(name, options = {})\n  options[:allow_nil] = true\n  before_save :x if options[:allow_nil]\nend\n", "vl :a")

      expect([ Array(data[:callbacks]), data[:conditional].map { |c| c[:condition] } ]).to eq([ [], [ "options[:allow_nil]" ] ])
    end
  end
end
