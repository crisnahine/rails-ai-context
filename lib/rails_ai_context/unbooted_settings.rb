# frozen_string_literal: true

require "yaml"
require "date"
require "ripper"
require_relative "configuration"
require_relative "safe_file"
require_relative "install/ai_tool"

module RailsAiContext
  # An app's settings as its boot would apply them, read from its files without running any: a union key keeps the YAML's
  # entries beside every literal the code writes, any other key the last one written. What cannot be read is a Refusal.
  # The selection readers use the standard library alone; #config, #refusals and #served_tool_names need the gem loaded.
  module UnbootedSettings
    # The keys this reader takes the last literal of; InitializerSettings reads the union keys.
    KEYS = (Configuration::YAML_KEYS - Configuration::UNION_KEYS).freeze
    YAML_FILE = Configuration::CONFIG_FILENAME
    # Ruby config files are small, and both readers refuse a larger one.
    MAX_SOURCE = 10_000_000
    COMPUTED = Object.new.freeze

    # The environment the app boots in, as Rails reads it.
    def self.running_environment
      [ ENV["RAILS_ENV"], ENV["RACK_ENV"] ].find { |name| name.to_s.match?(/\A\w+\z/) } || "development"
    end
    # Why a write is not read, by what keeps it from the configuration at boot.
    UNREAD = {
      COMPUTED => "is computed at boot",
      conditional: "is written under a condition or in a block that runs later",
      edited: "is changed in place or written by its name",
      late: "is written to `config.rails_ai_context`, which is set only after the initializers run"
    }.freeze
    KEYWORDS = { "true" => true, "false" => false, "nil" => nil }.freeze
    # A branch, and a body that runs later or only when called: a write under one is not read. The `if defined?`
    # guard of the generated initializer and a configure block's own body are read as running.
    CONDITIONAL = %i[if unless elsif case while until for if_mod unless_mod ifop rescue rescue_mod while_mod until_mod
                     def defs lambda brace_block do_block].freeze
    # Calls that change a value in place, besides any ending in `!`, and calls that write a setting by its name.
    EDITS = %w[<< push append concat unshift prepend insert delete delete_at delete_if keep_if clear replace pop shift fill
               merge update store].freeze
    SENDS = %w[send public_send __send__ instance_variable_set].freeze
    # The edits followed in order when their arguments are literals; any other is reported.
    FOLLOWED = %w[<< push append concat unshift prepend delete clear].freeze
    # Calls that hand back nothing of the value they are called on, so a key read for one is only read.
    PURE_READS = %w[size length count empty? any? none? include? member? join inspect to_sym frozen? nil? index find_index].freeze
    # Calls that hand back a new list holding the value's own elements: a read unless an element of it is changed.
    COPIES = %w[dup clone sort uniq compact reverse take drop].freeze
    # Calls that hand back one of the value's own elements: a read only where nothing changes what they return.
    ELEMENTS = %w[first last min max to_s].freeze
    # Calls that change a list and no element in it.
    LIST_EDITS = %w[<< push append concat unshift prepend insert clear delete delete_at pop shift].freeze
    CONDITIONS = %i[if unless elsif while until if_mod unless_mod while_mod until_mod ifop].freeze
    # Lists that hide things from the tools: a line this reader cannot follow never takes what it read of one away.
    HIDING = %i[excluded_models excluded_controllers excluded_route_prefixes excluded_filters excluded_middleware
                excluded_association_names excluded_concerns query_redacted_columns].freeze
    # A literal edit of a key's value in place, and a write this reader cannot follow with the literals it did read, which a
    # list that hides things keeps.
    # What a list of names holds.
    NAME = ->(value) { value.is_a?(String) || value.is_a?(Symbol) }
    Edit = Struct.new(:name, :values)
    Unread = Struct.new(:reason, :floor)

    # stops_static: true when the static tier serves nothing until the line is fixed; text: what to say in place of the reason.
    Refusal = Struct.new(:file, :line, :key, :reason, :stops_static, :text) do
      def stops_static?
        stops_static
      end

      def location
        line ? "#{file}:#{line}" : file
      end

      def message
        "#{location}: #{text || reason}"
      end
    end

    # The elements of a `%i[]` list, which Ripper's tree otherwise hands back as the strings of a `%w[]` list.
    class SymbolList < Array; end

    # Ripper's tree, with a `%i[]` list marked and the text of each string as Ruby reads it, escapes undone.
    class Parser < Ripper::SexpBuilderPP
      ESCAPES = { "n" => "\n", "t" => "\t", "s" => " ", "r" => "\r", "0" => "\0", "e" => "\e", "a" => "\a", "b" => "\b", "f" => "\f", "v" => "\v" }.freeze
      CLOSERS = { "(" => ")", "[" => "]", "{" => "}", "<" => ">" }.freeze

      def initialize(*)
        super
        @openers = []
      end

      def on_qsymbols_new = SymbolList.new
      def on_symbols_new = SymbolList.new

      %i[tstring_beg symbeg qwords_beg qsymbols_beg words_beg symbols_beg heredoc_beg].each do |event|
        define_method(:"on_#{event}") do |token|
          @openers.push([ event, token ])
          super(token)
        end
      end

      %i[tstring_end label_end heredoc_end].each do |event|
        define_method(:"on_#{event}") do |token|
          @openers.pop
          super(token)
        end
      end

      def on_tstring_content(token)
        node = super
        return node unless @openers.any?

        @meta = false
        node[1] = unescaped(token, *@openers.last)
        # A control or meta escape is left as typed; the node no longer reads as text, so the setting is reported.
        node[0] = :@meta_content if @meta
        node
      end

      private

      def unescaped(token, event, opener)
        close = CLOSERS.fetch(opener[-1], opener[-1])
        case event
        when :qwords_beg, :qsymbols_beg then token.gsub(/\\([\s\\#{Regexp.escape(opener[-1])}#{Regexp.escape(close)}])/m, "\\1")
        when :tstring_beg, :symbeg
          single = opener.match?(/\A(?::')?'\z|\A%q|\A%s|\A:'/)
          single ? token.gsub(/\\([\\#{Regexp.escape(opener[-1])}#{Regexp.escape(close)}])/, "\\1") : double(token, opener)
        when :heredoc_beg then opener.match?(/\A<<[-~]?'/) ? token : double(token, opener)
        # An escaped newline in a `%W[]` or `%I[]` list is a newline in the word.
        when :words_beg, :symbols_beg then double(token, opener, joined: false)
        else token
        end
      end

      def double(token, opener, joined: true)
        token.gsub(/\\(?:u\{([0-9a-fA-F ]+)\}|u(\h{4})|x(\h{1,2})|([0-7]{1,3})|(\r?\n)|(.))/m) do
          if $1 then $1.split.map { |code| code.hex.chr(Encoding::UTF_8) }.join
          elsif $2 then $2.hex.chr(Encoding::UTF_8)
          elsif $3 then $3.hex.chr.force_encoding(Encoding::UTF_8)
          elsif $4 then $4.oct.chr.force_encoding(Encoding::UTF_8)
          elsif $5 then joined ? "" : $5
          else
            @meta ||= %w[C c M].include?($6)
            ESCAPES.fetch($6, $6)
          end
        end
      end
    end

    module_function

    # The tree Ripper.sexp builds, with each `%i[]` list marked; nil when the source does not parse.
    def sexp(source)
      parser = Parser.new(source)
      tree = parser.parse
      tree unless parser.error?
    end

    # Whether a recorded write is one this reader does not take as the setting's value.
    def unread?(value)
      value = value.reason if value.is_a?(Unread)
      UNREAD.key?(value)
    end

    # A file name as text to print: the bytes the filesystem holds are kept for opening it, and a name not valid as UTF-8 is scrubbed.
    def label(name)
      name.to_s.dup.force_encoding(Encoding::UTF_8).scrub
    end

    def read(root)
      Result.new(File.expand_path(root.to_s))
    end

    # Each write of a key in one file's source, as #read takes it: [[line, column], key, value]. nil when the source does not parse.
    def writes(source)
      tree = Ripper.sexp(source)
      tree && Walk.assignments(tree)
    end

    # How one file's Ruby writes the configuration, read without running it.
    module Walk
      API = Configuration.public_instance_methods(false).freeze

      module_function

      # [[line, column], key, value] for each write of a key, and for each line that reaches the configuration as a
      # whole with the key nil; a stack, so no nesting runs out of stack.
      def assignments(tree)
        found = []
        claimed = {}.compare_by_identity
        stack = [ [ tree, false, [].freeze, nil ] ]
        until stack.empty?
          node, conditional, roots, use = stack.pop
          next unless node.is_a?(Array)

          found.concat(records(node, conditional, roots, use, claimed))
          children(node, conditional, roots).each do |entry|
            stack << [ *entry, use_for(node, entry.first, use, roots) ] if entry.first.is_a?(Array)
          end
        end
        found
      end

      def records(node, conditional, roots, use, claimed)
        found = []
        if %i[assign opassign].include?(node[0]) && (key, position, late = field(node[1], roots))
          found << [ position, key, refused(node, conditional, late, floor(node)) || literal(node[2]) ]
        elsif (key, position, late, change = edit(node, roots, claimed))
          found << [ position, key, refused(node, conditional, late, (change.values.flatten if additive?(change))) || change ]
          found << [ position, key, refused(node, conditional, late) || :edited ] if use == :kept && change.is_a?(Edit) && LIST_EDITS.include?(change.name)
        elsif (position, late = reflective(node, roots, claimed))
          found << [ position, nil, refused(node, conditional, late) || :edited ]
        end
        found.concat(multiple(node, conditional, roots)) if node[0] == :massign
        # A key read used any way but as a plain read, and the configuration handed on, change what this reader cannot see.
        if !claimed.key?(node) && !%i[safe cond].include?(use) && (key, position, late = field(node, roots, :call))
          found << [ position, key, refused(node, conditional, late) || :edited ]
        elsif !%i[receiver cond].include?(use) && (late = configuration(node, roots))
          found << [ root_position(node), nil, refused(node, conditional, late == :late) || :edited ]
        end
        found
      end

      # `a.key, b = 1, 2`: each key target takes its value when the targets are plain and the values listed, else it is edited.
      def multiple(node, conditional, roots)
        targets, values = node[1], node[2]
        plain = targets.is_a?(Array) && targets.all? { |target| target.is_a?(Array) && %i[field var_field].include?(target[0]) }
        listed = values.is_a?(Array) && values[0] == :mrhs_new_from_args && values[1].is_a?(Array) && values[1].first.is_a?(Array) &&
                 values[2].is_a?(Array)
        list = values[1] + [ values[2] ] if listed
        keys(targets).filter_map do |target|
          next unless (key, at, late = field(target, roots))

          value = list[targets.index { |each| each.equal?(target) }] if plain && list && !list.any? { |item| item[0] == :args_add_star }
          found = refused(node, conditional, late) || (value ? literal(value) : :edited)
          [ at, key, found ]
        end
      end

      # Every key write a target list holds, nested and splatted ones too.
      def keys(targets)
        Array(targets).flat_map do |target|
          next [] unless target.is_a?(Array)

          case target[0]
          when :field then [ target ]
          when :mlhs then keys(target.drop(1))
          when :rest_param then keys([ target[1] ])
          else []
          end
        end
      end

      def refused(node, conditional, late, floor = nil)
        reason = unread(node, conditional, late) or return nil
        floor.is_a?(Array) && !floor.empty? && floor.all?(&NAME) ? Unread.new(reason, floor) : reason
      end

      # What a write that may not run still adds to a list: the literals of `=`, `+=` and `|=`.
      def floor(node)
        value = node[0] == :assign ? literal(node[2]) : (literal(node[3]) if %w[+= |=].include?(node[2][1]))
        value if value.is_a?(Array)
      end

      def additive?(edit)
        edit.is_a?(Edit) && %w[<< push append unshift prepend concat].include?(edit.name)
      end

      def unread(node, conditional, late)
        return :late if late
        return :conditional if conditional

        COMPUTED if node[0] == :opassign
      end

      def root_position(node)
        node[0] == :call ? node[3][2] : node[1][2]
      end

      # How a child's value is used: :receiver of a call on the configuration, :safe as the receiver of a read that changes
      # nothing, :cond where only its truth is asked (and passed on to what a condition is made of), :blocked on a call given a block.
      def use_for(parent, child, use, roots)
        type = parent[0]
        return (use == :cond ? :cond : nil) if type.is_a?(Array)
        return :cond if (CONDITIONS.include?(type) && parent[1].equal?(child)) || %i[defined string_embexpr].include?(type)
        return :cond if use == :cond && (%i[paren unary].include?(type) || (type == :binary && parent[2] != :<<))
        if (type == :binary && parent[2] == :<< || %i[call command_call].include?(type) && LIST_EDITS.include?(method_name(parent[3]))) && parent[1].equal?(child)
          # An edit hands back the list it edits, so an element taken from that result is still the setting's own.
          return use == :kept ? :kept : :list
        end
        return :blocked if type == :method_add_block && parent[1].equal?(child)
        return (use == :blocked || block_arg?(parent[2]) ? :blocked : use) if type == :method_add_arg && parent[1].equal?(child)
        return nil unless %i[call command_call field aref_field aref].include?(type) && parent[1].equal?(child)
        return :receiver if configuration(child, roots)

        return nil unless %i[call command_call].include?(type) && use != :blocked && !(type == :command_call && block_arg?(parent[4]))

        name = method_name(parent[3])
        if PURE_READS.include?(name) || (COPIES.include?(name) && %i[safe cond list].include?(use)) ||
           (ELEMENTS.include?(name) && %i[safe cond].include?(use))
          :safe
        else
          :kept
        end
      end

      def block_arg?(args)
        args = args[1] if args.is_a?(Array) && args[0] == :arg_paren
        args.is_a?(Array) && args[0] == :args_add_block && args[2] ? true : false
      end

      def method_name(node)
        node[1] if node.is_a?(Array) && %i[@ident @op @const].include?(node[0])
      end

      # A call on the configuration the API does not name (tap, instance_eval, send by a computed name, method) can write any key.
      def reflective(node, roots, claimed)
        return nil unless %i[call command_call].include?(node[0]) && !claimed.key?(node) && (name = method_name(node[3])) && (late = configuration(node[1], roots))
        return nil if API.include?(name.to_sym) || name == "respond_to?"

        [ node[3][2], late == :late ]
      end

      # Each child with whether it may not run, and the names that hold the configuration in it. A block's own
      # params hide the names outside it, and a method's body sees none of them.
      def children(node, conditional, roots)
        if node[0] == :method_add_block
          receiver, name = call_of(node[1])
          block = node[2]
          return [ [ node[1], conditional, roots ], [ block.last, conditional, (roots + block_params(block)).freeze ] ] if configure_of(node)

          inner = (roots - (block[1] ? declared(block[1]) : %w[_1 it])).freeze
          runs = name == "configure" && (receiver.nil? || rails_application?(receiver))
          return [ [ node[1], conditional, roots ], runs ? [ block.last, conditional, inner ] : [ block, conditional, inner ] ]
        end
        return [ [ node[2], true, (roots - declared(node[1])).freeze ] ] if node[0] == :lambda
        return node.map { |child| [ child, true, [].freeze ] } if %i[def defs].include?(node[0])
        return [ [ node[2], conditional, roots ], [ node[3], true, roots ] ] if node[0] == :if && guard?(node[1])
        return [ [ node[2], conditional, roots ] ] if node[0] == :if_mod && guard?(node[1])

        inner = conditional || CONDITIONAL.include?(node[0]) || (node[0] == :binary && %i[&& || and or].include?(node[2]))
        return statements(node, inner, roots) if node[0].is_a?(Array)

        node.map { |child| [ child, inner, roots ] }
      end

      # A statement list: whatever follows a return, next or raise that a condition may take runs only when it does not.
      def statements(list, conditional, roots)
        list.map do |statement|
          entry = [ statement, conditional, roots ]
          conditional ||= leaves?(statement)
          entry
        end
      end

      LEAVES = %w[return next break raise exit exit! abort fail].freeze

      # A statement that may end the file, block or method early, apart from one that leaves only where the gem is not there.
      def leaves?(node)
        return false unless node.is_a?(Array)

        case node[0]
        when :if_mod, :if, :elsif then !absent_guard?(node[1]) && exits?(node[2])
        when :unless_mod, :unless then !guard?(node[1]) && exits?(node[2])
        when :ifop then exits?(node[2]) || exits?(node[3])
        when :binary then %i[&& || and or].include?(node[2]) && exits?(node[3])
        else false
        end
      end

      # `!defined?(RailsAiContext)`: true only where the gem is not there, so an exit under it never runs.
      def absent_guard?(node)
        node[0] == :unary && %i[! not].include?(node[1]) && guard?(node[2])
      end

      def exits?(node)
        return false unless node.is_a?(Array)
        return true if %i[return return0 next break].include?(node[0])
        return exits?(node[1]) if node[0] == :void_stmt
        return node.any? { |statement| exits?(statement) } if node[0].is_a?(Array)

        %i[vcall fcall command].include?(node[0]) && LEAVES.include?(node[1][1])
      end

      # A key's value changed in place, or a key written by its name: [key, position, late, an Edit or :edited], or nil.
      def edit(node, roots, claimed)
        case node[0]
        when :binary then chained(node, roots, claimed) if node[2] == :<< && !claimed.key?(node)
        when :aref_field then edit_of(node[1], roots, claimed, "[]=", nil)
        when :command_call then called(node, node, node[4], roots, claimed)
        when :method_add_arg then called(node, node[1], node[2], roots, claimed) if node[1][0] == :call
        when :call then called(node, node, nil, roots, claimed) unless claimed.key?(node)
        end
      end

      # `config.key << a << b`, each link taken once.
      def chained(node, roots, claimed)
        values = [ typed_value(node[3]) ]
        receiver = unparen(node[1])
        while receiver[0] == :binary && receiver[2] == :<<
          claimed[receiver] = true
          values.unshift(typed_value(receiver[3]))
          receiver = unparen(receiver[1])
        end
        edit_of(receiver, roots, claimed, "<<", values)
      end

      def typed_value(node)
        %i[symbol_literal string_literal dyna_symbol].include?(node[0]) ? (typed(node) || COMPUTED) : literal(node)
      end

      def unparen(node)
        node = node[1][0] while node[0] == :paren && node[1].is_a?(Array) && node[1].size == 1 && node[1][0].is_a?(Array)
        node
      end

      def called(node, call, args, roots, claimed)
        name = method_name(call[3]) or return nil
        if SENDS.include?(name)
          sent = sent(call, args.is_a?(Array) && args[0] == :arg_paren ? args[1] : args, roots) or return nil
          claimed[call] = true
          return sent + [ :edited ]
        end
        return nil unless EDITS.include?(name) || name.end_with?("!")

        found = edit_of(call[1], roots, claimed, name, arguments(args))
        claimed[call] = true if found
        found
      end

      def edit_of(receiver, roots, claimed, name, values)
        read = field(receiver, roots, :call) or return nil
        key, position, late = read
        claimed[receiver] = true
        [ key, position, late, values && FOLLOWED.include?(name) ? Edit.new(name, values) : :edited ]
      end

      # The literal each argument is, or nil when one is splatted or a block is given.
      def arguments(args)
        args = args[1] if args.is_a?(Array) && args[0] == :arg_paren
        return [] if args.nil?
        return nil unless args.is_a?(Array) && args[0] == :args_add_block && !args[2] && args[1].is_a?(Array)
        return nil unless args[1].empty? || args[1].first.is_a?(Array)

        args[1].map { |arg| typed_value(arg) }
      end

      def sent(call, args, roots)
        return nil unless call[3].is_a?(Array) && SENDS.include?(call[3][1]) && args.is_a?(Array) && args[0] == :args_add_block

        key = word(args[1].first)&.delete_prefix("@")&.delete_suffix("=")&.to_sym
        return nil unless KEYS.include?(key) && (root = configuration(call[1], roots))

        [ key, call[3][2], root == :late ]
      end

      # `defined?(RailsAiContext)`, alone or with `&&` and a `respond_to?` call on the module, as the generated initializer writes it.
      def guard?(node)
        case node[0]
        when :defined then gem?(node[1])
        when :binary then %i[&& and].include?(node[2]) && guard?(node[1]) && guard?(node[3])
        when :method_add_arg then (call = call_of(node[1])) && call.last == "respond_to?" && gem?(call.first)
        else false
        end
      end

      def call_of(node)
        node = node[1] if node[0] == :method_add_arg
        case node[0]
        when :call then node[3].is_a?(Array) ? [ node[1], node[3][1] ] : nil
        when :fcall then [ nil, node[1][1] ]
        end
      end

      # The receiver and block of a `RailsAiContext.configure { }` node, nil for any other node.
      def configure_of(node)
        receiver, name = node[0] == :method_add_block && call_of(node[1])
        [ receiver, node[2] ] if name == "configure" && gem?(receiver)
      end

      # RailsAiContext, ::RailsAiContext or Object::RailsAiContext.
      def gem?(node)
        return false unless node.is_a?(Array)
        return node[1][1] == "RailsAiContext" if %i[var_ref top_const_ref].include?(node[0])

        node[0] == :const_path_ref && node[2][1] == "RailsAiContext" && node[1][0] == :var_ref && node[1][1][1] == "Object"
      end

      # Another library's configure block may run at any time; the app's own runs as its file loads.
      def rails_application?(node)
        receiver, name = call_of(node)
        name == "application" && receiver.is_a?(Array) && %i[var_ref top_const_ref].include?(receiver[0]) && receiver[1][1] == "Rails"
      end

      # Every name a block or lambda declares, its block-local ones too. A default value only reads names.
      def declared(params)
        names = []
        stack = [ params ]
        until stack.empty?
          node = stack.pop
          next unless node.is_a?(Array)

          case node[0]
          when :@ident then names << node[1]
          when :@label then names << node[1].delete_suffix(":")
          when :params
            stack.push(node[1], node[3], node[4], node[6], node[7], *Array(node[2]).map(&:first), *Array(node[5]).map(&:first))
          else node.each { |child| stack << child }
          end
        end
        names
      end

      # The configure block's param, or the numbered and `it` params of a block that names none.
      def block_params(block)
        vars = block[1]
        return %w[_1 it] if vars.nil?

        params = vars[1]
        required = params[1]
        plain = required.is_a?(Array) && required.size == 1 && required[0][0] == :@ident && params[2..].all?(&:nil?)
        plain ? [ required[0][1] ] : []
      end

      # A write to the configuration: the configure block's param, RailsAiContext.configuration or config.rails_ai_context,
      # and whether it is the last, which no boot reaches before the initializers have run.
      def field(node, roots, type = :field)
        return nil unless node.is_a?(Array) && node[0] == type && node[3].is_a?(Array) && node[3][0] == :@ident

        key = node[3][1].to_sym
        return nil unless KEYS.include?(key) && (root = configuration(node[1], roots))

        [ key, node[3][2], root == :late ]
      end

      def configuration(node, roots)
        case node[0]
        when :var_ref, :vcall then node[1][0] == :@ident && roots.include?(node[1][1])
        when :call
          name = node[3].is_a?(Array) && node[3][1]
          receiver = node[1]
          return true if name == "configuration" && gem?(receiver)

          :late if name == "rails_ai_context" && !(receiver[0] == :call && receiver[3].is_a?(Array) && receiver[3][1] == "x")
        end
      end

      def literal(node)
        case node[0]
        when :array
          return [] if node[1].nil? || node[1].empty?

          words = node[1].map { |element| typed(element, node[1].is_a?(SymbolList)) } if node[1].is_a?(Array)
          words&.none?(&:nil?) ? words : COMPUTED
        when :symbol_literal, :string_literal, :dyna_symbol then word(node) || COMPUTED
        when :var_ref then node[1][0] == :@kw ? KEYWORDS.fetch(node[1][1], COMPUTED) : COMPUTED
        when :@int then Integer(node[1].delete("_"), exception: false) || COMPUTED
        when :@float then Float(node[1].delete("_"), exception: false) || COMPUTED
        when :call then node[3].is_a?(Array) && node[3][1] == "freeze" ? literal(node[1]) : COMPUTED
        when :unary then node[1] == :-@ && %i[@int @float].include?(node[2][0]) ? negative(literal(node[2])) : COMPUTED
        else COMPUTED
        end
      end

      # An element as Ruby holds it: a Symbol for a symbol literal or an element of `%i[]`, else a String.
      def typed(node, symbols = false)
        text = word(node)
        text && (symbols || %i[symbol_literal dyna_symbol].include?(node[0])) ? text.to_sym : text
      end

      def negative(number)
        number.equal?(COMPUTED) ? COMPUTED : -number
      end

      def word(node)
        return nil unless node.is_a?(Array)

        case node[0]
        when :@tstring_content then node[1]
        when :symbol_literal then node[1].is_a?(Array) && node[1][0] == :symbol ? node[1][1][1] : nil
        when :string_literal, :dyna_symbol
          parts = node[1].is_a?(Array) && node[1][0] == :string_content ? node[1].drop(1) : nil
          return nil unless parts
          return "" if parts.empty?

          parts.size == 1 && parts.first[0] == :@tstring_content ? parts.first[1] : nil
        # A word of a `%W[]` or `%I[]` list, its parts as the list holds them.
        when Array then node.size == 1 && node.first[0] == :@tstring_content ? node.first[1] : nil
        end
      end
    end

    class Result
      include Walk

      attr_reader :root

      def initialize(root)
        @root = root
        @yaml, @yaml_error = read_yaml
        @code, @code_refusals = read_code
      end

      # A name that is no AI tool is kept, as the boot keeps it; writing context files refuses it by name.
      #
      # @return [Array<Symbol>, nil] the AI tools picked, an empty list for none, nil when nothing sets them
      def ai_tools
        names = setting(:ai_tools)
        names = Array(names).compact unless names.nil?
        return nil unless names&.all? { |name| name.is_a?(String) || name.is_a?(Symbol) }

        names.map(&:to_sym)
      end

      # @return [Symbol, nil] nil when nothing sets it
      def tool_mode
        mode = setting(:tool_mode)
        mode.to_sym if mode.is_a?(String) || mode.is_a?(Symbol)
      end

      # @return [Boolean, nil] nil when nothing sets it
      def context_files
        value = setting(:context_files)
        value.nil? ? nil : !!value
      end

      # Whether the code or the YAML writes this selection key in any shape, a value computed at boot included.
      def assigned?(key)
        !written_in(key).nil? || (@yaml.is_a?(Hash) && !@yaml[key.to_s].nil?)
      end

      # The file of the code's last write of this key, nil when only the YAML or nothing writes it.
      def written_in(key)
        @code_lines.dig(key, 0)
      end

      # The configuration the static tier runs with: defaults, the YAML, then the code's literals.
      def config
        @config ||= build
      end

      def refusals
        config
        [ yaml_refusal, *@code_refusals, *@setter_refusals, *@security_refusals ].compact
      end

      # What each line this reader could not follow, and that is not a reason to stop, changed: its file and line, and what answers instead.
      def notes
        refusals.reject(&:stops_static?).select(&:line).map(&:message)
      end

      # The first refusal that keeps the static tier from serving, or nil.
      def static_refusal
        refusals.find(&:stops_static?)
      end

      # The refusal that leaves skip_tools unknown without a boot, so any tool may be off: one on skip_tools or on no key.
      def skip_tools_refusal
        refusals.find { |refusal| refusal.stops_static? && [ nil, :skip_tools ].include?(refusal.key) }
      end

      def served_tool_names
        Server.active_tools(config).map(&:tool_name)
      end

      # The tools a router that refuses a call without starting the app may count as off: a skip_tools entry counts only when
      # the YAML, or a write that runs outright in the app's environment, gives it. A conditional one starts the app.
      def routed_tool_names
        return served_tool_names unless app?

        certain = InitializerSettings.definite(@root, :skip_tools)
        return served_tool_names if certain.nil?

        base = Configuration.new
        base.app_root = @root
        base.config_file_applied!
        Configuration.apply_yaml(@yaml, yaml_path, base) if @yaml.is_a?(Hash) && File.exist?(yaml_path)
        base.skip_tools = (base.skip_tools + certain).uniq
        Server.active_tools(base).map(&:tool_name)
      end

      private

      def yaml_path
        File.join(@root, YAML_FILE)
      end

      def read_yaml
        return [ {}, nil ] unless File.exist?(yaml_path)

        data, error = Configuration.read_yaml(yaml_path)
        return [ data, error ] unless data.is_a?(Hash)

        [ data.to_h { |key, value| [ key.to_s, value ] }, nil ]
      end

      def yaml_refusal
        return Refusal.new(YAML_FILE, nil, nil, Configuration.yaml_problem(YAML_FILE, @yaml_error), false) if @yaml_error
        return nil if @yaml.is_a?(Hash)

        Refusal.new(YAML_FILE, nil, nil, "the file holds no `key: value` settings", false)
      end

      def setting(key)
        return @code[key] if @code.key?(key)

        @yaml.is_a?(Hash) ? @yaml[key.to_s] : nil
      end

      def build
        config = Configuration.new
        config.app_root = @root
        config.config_file_applied!
        if @yaml_error
          $stderr.puts "[rails-ai-context] WARNING: #{Configuration.yaml_problem(yaml_path, @yaml_error)}"
        elsif File.exist?(yaml_path)
          Configuration.apply_yaml(@yaml, yaml_path, config)
        end
        @setter_refusals = @code.filter_map do |key, value|
          config.public_send(:"#{key}=", value.nil? ? nil : Configuration.coerce_value(key, value))
          nil
        rescue ArgumentError => e
          file, line = @code_lines[key]
          Refusal.new(file, line, key, e.message, false)
        end
        # No boot runs the Ruby of a folder with no app in it, which may be a home folder too large to walk.
        @security_refusals = app? ? InitializerSettings.apply(@root, config) : []
        config
      end

      def app?
        %w[config app].any? { |folder| File.directory?(File.join(@root, folder)) }
      end

      # The literal each selection key is last given, edits in place followed, in the order the boot runs the files.
      def read_code
        @code = {}
        @code_lines = {}
        @unread = {}
        code_files.each do |relative|
          source = SafeFile.read(File.join(@root.b, relative), max_size: MAX_SOURCE)
          tree = source && UnbootedSettings.sexp(source)
          next unless tree

          assignments(tree).sort_by(&:first).each do |(line, _column), key, value|
            (key ? [ key ] : KEYS).each { |each| @code_lines[each] = [ UnbootedSettings.label(relative), line ] }
            if value.is_a?(Edit)
              follow(key, value, relative, line)
            elsif UnbootedSettings.unread?(value)
              refuse(key, value, relative, line)
            else
              @unread.delete(key)
              @code.delete(key)
              @code[key] = value
            end
          end
        end
        [ @code, @unread.values ]
      end

      def follow(key, edit, relative, line)
        before = @code.key?(key) ? @code[key] : (list_base(key) unless @unread.key?(key) || relative.match?(InitializerSettings::BEFORE_YAML))
        after = edited(edit, before) if before.is_a?(Array) && before.all?(&NAME)
        return refuse(key, :edited, relative, line) unless after

        @unread.delete(key)
        @code.delete(key)
        @code[key] = after
      end

      # The list after an edit with literal arguments, or nil for a shape this does not follow.
      def edited(edit, list)
        values = edit.values
        return nil if values.any? { |value| value.equal?(COMPUTED) }

        case edit.name
        when "<<", "push", "append" then list + values if values.all?(&NAME)
        when "unshift", "prepend" then values + list if values.all?(&NAME)
        when "concat" then list + values.flatten if values.all? { |value| value.is_a?(Array) && value.all?(&NAME) }
        when "delete" then list.reject { |name| name == values.first } if values.size == 1 && NAME.(values.first)
        when "clear" then [] if values.empty?
        end
      end

      # The YAML's list for a key, else the default's.
      def list_base(key)
        yaml = @yaml.is_a?(Hash) ? @yaml[key.to_s] : nil
        value = yaml.nil? ? Configuration.new.public_send(key) : Configuration.coerce_value(key, yaml)
        value if value.is_a?(Array)
      rescue ArgumentError
        nil
      end

      # A write this reader cannot follow takes the key's literals away, so the YAML or the default answers, except for a
      # list that hides things: that keeps what was read, with the literals the write holds.
      def refuse(key, value, relative, line)
        reason = value.is_a?(Unread) ? value.reason : value
        floor = value.floor if value.is_a?(Unread)
        (key ? [ key ] : KEYS).each do |each|
          next @code.delete(each) unless HIDING.include?(each)

          @code[each] = ((@code.key?(each) ? @code[each] : list_base(each)) || []) | floor if floor
        end
        text = key ? "`#{key}` #{UNREAD[reason]}, so #{HIDING.include?(key) ? "what was read before it, with the YAML's entries, answers" : "the YAML or the default answers"} here" :
                     "this line hands the configuration on or calls it in a way this reader cannot follow, so every setting it reads comes from the YAML or the default, " \
                     "and a list that hides things keeps what was read before it"
        @unread[key || [ relative, line ]] = Refusal.new(UnbootedSettings.label(relative), line, key, text, false)
      end

      # Names are kept as bytes, the one encoding that joins to a root of any spelling under a C locale.
      def code_files
        [ "config/application.rb", "config/environments/#{UnbootedSettings.running_environment}.rb",
          *Dir.glob("config/initializers/**/*.rb", base: @root.b).map(&:b).sort ].map(&:b)
      end
    end
  end
end
