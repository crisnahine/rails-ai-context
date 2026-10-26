# frozen_string_literal: true

require "prism"

module RailsAiContext
  module Introspectors
    module Listeners
      # Base class for Prism Dispatcher listeners.
      # Provides shared helpers for extracting values from AST nodes.
      class BaseListener
        # Object's methods that run their block once, during the call, handing it the receiver.
        RUN_ONCE = %i[tap then yield_self].freeze

        attr_reader :results
        # The walk's comments, for a listener that slices source: a fold onto
        # one line would otherwise comment out what follows.
        attr_writer :comments
        # Whether the app keeps a constant in a file of its own, from a constant name; nil reads the walked file's declarations alone.
        attr_accessor :app_constant

        def initialize
          @results = []
          @comments = []
        end

        private

        # A node's source with its comments removed, folded onto one line, its secrets filtered,
        # since the payload carries it. `upto` ends the text at that offset (a call without its block).
        def one_line_source(node, upto: nil)
          start = node.location.start_offset
          finish = upto || node.location.end_offset
          cuts = Array(@comments).filter_map do |comment|
            location = comment.location
            [ location.start_offset, location.end_offset, "" ] if location.start_offset >= start && location.end_offset <= finish
          end
          cuts.concat(multiline_literals(node).select { |_, to, _| to <= finish })

          # The node's text runs on past its end when it opens a heredoc, and
          # every cut sits inside the node, so the offsets still line up.
          # Offsets count bytes, so the cuts work on the bytes and the text gets its encoding back after.
          source = NodeSource.text(node)
          text = source.b
          text = text.byteslice(0, finish - start) if upto
          cuts.sort_by(&:first).reverse_each do |from, to, replacement|
            text[(from - start)...(to - start)] = replacement.b
          end
          filtered(fold_newlines(text.force_encoding(source.encoding)))
        end

        # Source text a record carries into the payload, its secrets filtered.
        def filtered(text)
          RailsAiContext::Redaction.source_slice(text)
        end

        # A plain multi-line string literal (a SQL fragment) is respelt on one line as `inspect`
        # would; a heredoc and an interpolated string stay as written.
        def multiline_literals(node)
          found = []
          walk = lambda do |current|
            if current.is_a?(Prism::StringNode) && current.opening_loc && !current.heredoc? &&
               current.slice.include?("\n")
              found << [ current.location.start_offset, current.location.end_offset, current.unescaped.inspect ]
            else
              current.compact_child_nodes.each { |child| walk.call(child) }
            end
          end
          walk.call(node)
          found
        end

        # The lexer's NEWLINE ends a statement (`;`), IGNORED_NEWLINE continues it (a space), and
        # any other is inside a string and stays; a call split at the dot joins with nothing.
        def fold_newlines(text)
          tokens = lex(text)
          # A heredoc body only exists on its own lines, so there is no one
          # line to fold it onto.
          return text.strip if tokens.any? { |token| token.type == :HEREDOC_START }

          encoding = text.encoding
          kinds = newline_kinds(tokens)
          # Token offsets count bytes, so the fold walks the bytes; everything it compares is ASCII.
          # Outside a heredoc a backslash ending a line only continues it, so it folds as a continuation.
          text = text.b.gsub("\\\n") do
            kinds[Regexp.last_match.begin(0) + 1] = :continuation
            " \n"
          end
          folded = "".b
          index = 0
          while index < text.length
            unless text[index] == "\n" && kinds.key?(index)
              folded << text[index]
              index += 1
              next
            end

            folded.sub!(/[ \t]+\z/, "")
            terminator = false
            while index < text.length && (text[index] == " " || text[index] == "\t" ||
                                          (text[index] == "\n" && kinds.key?(index)))
              terminator ||= kinds[index] == :terminator
              index += 1
            end
            next if index >= text.length || folded.empty?

            joiner = if joined_call?(folded, text, index) then ""
            elsif terminator && !CLOSERS.include?(text[index]) then "; "
            else " "
            end
            folded << joiner
          end
          folded.strip.sub(/;\z/, "").strip.force_encoding(encoding)
        end

        # No statement begins with one of these, so a newline in front of one
        # separates nothing however the lexer names it.
        CLOSERS = [ ")", "]", "}", "," ].freeze

        # A call split at the dot, on either side of the break.
        def joined_call?(folded, text, index)
          text[index] == "." || text[index, 2] == "&." ||
            folded.end_with?(".") || folded.end_with?("&.")
        end

        def newline_kinds(tokens)
          tokens.each_with_object({}) do |token, found|
            case token.type
            when :NEWLINE         then found[token.location.start_offset] = :terminator
            when :IGNORED_NEWLINE then found[token.location.start_offset] = :continuation
            end
          end
        end

        def lex(text)
          Prism.lex(text, version: AstCache::NEWEST_GRAMMAR).value.map(&:first)
        rescue StandardError
          []
        end

        # Extract the first positional symbol argument from a call node.
        # e.g. `has_many :posts` → :posts
        def extract_first_symbol(node)
          arg = node.arguments&.arguments&.first
          case arg
          when Prism::SymbolNode then arg.unescaped.to_sym
          when Prism::StringNode then arg.unescaped.to_sym
          else RailsAiContext::Confidence::INFERRED
          end
        end

        # `belongs_to owner_name` passes a local that reads like `:owner_name` once it is text,
        # so only the node can say whether the first argument was a literal.
        def first_name_and_literal(node)
          name = extract_first_symbol(node)
          return [ name, true ] unless name == RailsAiContext::Confidence::INFERRED

          arg = node.arguments&.arguments&.first
          [ arg ? one_line_source(arg) : name, false ]
        end

        # Extract keyword options from a call node.
        # e.g. `has_many :posts, dependent: :destroy` → { dependent: :destroy }
        def extract_keyword_options(node)
          keyword_hash(node) { |value| extract_value(value) }
        end

        # The call's keyword arguments, each value passed through the block.
        def keyword_hash(node)
          args = node.arguments&.arguments || []
          args.select { |a| a.is_a?(Prism::KeywordHashNode) }
              .flat_map(&:elements)
              .each_with_object({}) do |assoc, h|
            next unless assoc.is_a?(Prism::AssocNode)
            h[extract_key(assoc.key)] = yield(assoc.value)
          end
        end

        # Extract all symbol arguments (skipping keyword hashes).
        # e.g. `validates :email, :name, presence: true` → [:email, :name]
        def extract_symbol_args(node)
          args = node.arguments&.arguments || []
          args.filter_map { |a| literal_string(a)&.to_sym }
        end

        # Extract every positional argument as a value, falling back to the raw
        # source slice for expressions that have no literal value (`2.hours`).
        def extract_arg_values(node)
          args = node.arguments&.arguments || []
          args.reject { |a| a.is_a?(Prism::KeywordHashNode) }.map { |a| value_or_source(a) }
        end

        # Keyword options with the raw source slice kept for expressions that
        # have no literal value (`every: 3.seconds`).
        def extract_keyword_sources(node)
          keyword_hash(node) { |value| value_or_source(value) }
        end

        # Keyword options as their raw Prism nodes, for callers that need to
        # inspect the structure of an expression rather than its value.
        def extract_keyword_nodes(node)
          keyword_hash(node) { |value| value }
        end

        def boolean_value(node)
          case node
          when Prism::TrueNode then true
          when Prism::FalseNode then false
          end
        end

        # A change_column_null's nullability: a boolean literal, or null_nil for the literal nil, which Rails reads by version.
        def null_fields(node)
          node.is_a?(Prism::NilNode) ? { null: nil, null_nil: true } : { null: boolean_value(node) }
        end

        # A call's default: for a value no literal carries: its source, and whether it is a proc.
        # key: reads create_table's default for its implicit key.
        def default_fields(node, key: false)
          value_fields(key ? key_default_node(node) : default_node(node))
        end

        # change_column_default's new value, positional or to:, as default_fields gives a default:, and its from: for a revert;
        # new_default is a positional value's literal.
        def new_default_fields(node, positional)
          positional = nil if positional.is_a?(Prism::KeywordHashNode)
          options = extract_keyword_nodes(node)
          from = value_fields(options[:from])
          fields = value_fields(positional || options[:to])
            .merge(from_source: from[:default_source], from_proc: from[:default_proc], from_literal: from[:default_literal])
          positional ? fields.merge(new_default: extract_value(positional)) : fields
        end

        # A proc whose body is one string is SQL the dump writes back as `-> { "sql" }`: default_literal holds that string.
        def value_fields(value)
          literal = proc_literal(value)
          fields = { default_source: literal ? "-> { #{literal.inspect} }" : value && filtered(NodeSource.text(value)), default_proc: proc_argument?(value) }
          literal ? fields.merge(default_literal: literal) : fields
        end

        def proc_literal(value)
          return unless proc_argument?(value)

          body = (value.is_a?(Prism::LambdaNode) ? value : value.block).body
          statements = body.is_a?(Prism::StatementsNode) ? body.body : []
          statements.first.unescaped if statements.size == 1 && statements.first.is_a?(Prism::StringNode)
        end

        # `-> {}`, `lambda {}`, `proc {}` or `Proc.new {}`.
        def proc_argument?(arg)
          return true if arg.is_a?(Prism::LambdaNode)
          return false unless arg.is_a?(Prism::CallNode) && arg.block.is_a?(Prism::BlockNode)

          receiver = arg.receiver
          return %i[lambda proc].include?(arg.name) if receiver.nil?

          arg.name == :new && (receiver.is_a?(Prism::ConstantReadNode) || receiver.is_a?(Prism::ConstantPathNode)) && constant_path_string(receiver) == "Proc"
        end

        # The default create_table gives its implicit key: an `id: { default: }` over its own `default:`.
        def key_default_node(node)
          id = extract_keyword_nodes(node)[:id]
          inner = id.elements.find { |e| e.is_a?(Prism::AssocNode) && extract_key(e.key) == :default } if id.is_a?(Prism::HashNode)
          inner&.value || default_node(node)
        end

        def default_node(node)
          args = node.arguments&.arguments || []
          assoc = args.grep(Prism::KeywordHashNode)
                      .flat_map(&:elements)
                      .find { |e| e.is_a?(Prism::AssocNode) && extract_key(e.key) == :default }
          assoc&.value
        end

        # The source of each positional argument, or array element, that is no literal,
        # since `arguments` gives a local variable's source and a string's value alike.
        def computed_arguments(node)
          positional_elements(node).select { |arg| extract_value(arg) == RailsAiContext::Confidence::INFERRED }.map { |arg| one_line_source(arg) }
        end

        # Argument as `arguments` gives it => the constant it is, or builds with `.new`.
        def constant_arguments(node)
          positional_elements(node).each_with_object({}) do |arg, found|
            target = arg.is_a?(Prism::CallNode) && arg.name == :new ? arg.receiver : arg
            next unless target.is_a?(Prism::ConstantReadNode) || target.is_a?(Prism::ConstantPathNode)

            found[value_or_source(arg)] = constant_path_string(target)
          end
        end

        def positional_elements(node)
          (node.arguments&.arguments || []).flat_map { |arg| arg.is_a?(Prism::ArrayNode) ? arg.elements : [ arg ] }
        end

        def value_or_source(node)
          extract_value(node, source: true)
        end

        # A string or symbol literal's characters, escapes applied; nil for any other node.
        def literal_string(node)
          node.unescaped if node.is_a?(Prism::StringNode) || node.is_a?(Prism::SymbolNode)
        end

        # An array of literals or a single one; anything unreadable is dropped.
        def literal_strings(node)
          return node.elements.filter_map { |e| literal_string(e) } if node.is_a?(Prism::ArrayNode)

          Array(literal_string(node))
        end

        def extract_key(node)
          case node
          when Prism::SymbolNode then node.unescaped.to_sym
          when Prism::StringNode then node.unescaped.to_sym
          else RailsAiContext::Confidence::INFERRED
          end
        end

        # `source: true` swaps the marker for the node's own text, at every
        # depth: an option nested in a hash is as readable as a top-level one.
        def extract_value(node, source: false)
          value = case node
          when Prism::SymbolNode         then node.unescaped.to_sym
          when Prism::StringNode         then node.unescaped
          when Prism::InterpolatedStringNode then adjacent_literals(node)
          when Prism::IntegerNode        then node.value
          when Prism::FloatNode          then node.value
          when Prism::TrueNode           then true
          when Prism::FalseNode          then false
          when Prism::NilNode            then nil
          when Prism::ConstantReadNode   then node.name.to_s
          when Prism::ConstantPathNode   then constant_path_string(node)
          when Prism::ArrayNode          then node.elements.map { |e| extract_value(e, source: source) }
          when Prism::HashNode           then hash_node_to_hash(node, source: source)
          when Prism::KeywordHashNode    then hash_node_to_hash(node, source: source)
          when Prism::CallNode           then module_name(node)
          else RailsAiContext::Confidence::INFERRED
          end

          return value unless value == RailsAiContext::Confidence::INFERRED && source

          one_line_source(node)
        end

        # `Cron::CleanupJob.name` is the constant's own name; `APP_SETTINGS.name` holds a value, so it stays unknown.
        def module_name(node)
          receiver = node.receiver
          constant = receiver.is_a?(Prism::ConstantReadNode) || receiver.is_a?(Prism::ConstantPathNode)
          return RailsAiContext::Confidence::INFERRED unless constant && node.name == :name && node.arguments.nil? && node.block.nil?

          value_constant?(receiver) ? RailsAiContext::Confidence::INFERRED : constant_path_string(receiver)
        end

        # An all-caps constant (`APP_SETTINGS`, `Config::APP`) is how Ruby code spells a value.
        def value_constant?(node)
          (node.is_a?(Prism::ConstantReadNode) || node.is_a?(Prism::ConstantPathNode)) && node.name.match?(/\A[A-Z0-9_]+\z/)
        end

        # `"a" "b"` and its line-continued form parse as one interpolated node
        # with only literal parts. Anything with a real `#{}` stays inferred.
        def adjacent_literals(node)
          parts = node.parts
          return RailsAiContext::Confidence::INFERRED unless parts.all? { |p| p.is_a?(Prism::StringNode) }
          parts.map(&:unescaped).join
        end

        # Rails' Mapper.normalize_path: "//" is one slash, "/(/x)" becomes "(/x)",
        # and a path of optional segments alone keeps its leading slash.
        def normalize_route_path(path)
          path = path.squeeze("/").gsub(%r{/(\(+)/?}, '\1/')
          path = path.sub(%r{\A(\(+)/}, '/\1') if path.match?(%r{\A(\(+[^)]+\))(\(+/:[^)]+\))*\z})
          path
        end

        # The Rack app a route call attaches: a constant as its `to:` value
        # (`match "/metrics", to: MetricsApp`) or as the value of the
        # path => app form (`get "/metrics" => MetricsApp`). A string there is a controller
        # action. MountListener names the app and RoutesDslListener skips the
        # call, so both read it here or one endpoint is counted twice.
        def rack_app_constant(args)
          args.reverse_each do |arg|
            next unless arg.is_a?(Prism::KeywordHashNode) || arg.is_a?(Prism::HashNode)

            arg.elements.reverse_each do |assoc|
              next unless assoc.is_a?(Prism::AssocNode)
              # `to: App`, or the path => App form, whose key is the path.
              next unless extract_key(assoc.key) == :to || assoc.key.is_a?(Prism::StringNode)

              name = rack_app_name(assoc.value)
              return name if name
            end
          end
          nil
        end

        # A route to a value, or to a bare value constant the file does not assign, attaches no app; a path such as `Admin::UI` is one.
        # shortcut: an unassigned `to: API` reads as no app and `to: Settings::HOME` as one, read the constant's file if either is wrong.
        def rack_app_name(node)
          value = written_value(node)
          return if value.is_a?(Prism::ConstantReadNode) && value_constant?(value)

          name = app_name(node)
          name unless name == RailsAiContext::Confidence::INFERRED
        end

        def written_value(node)
          name = constant_reference(node)
          (name && @constants&.dig(name)) || node
        end

        # The full name of the constant the file declares that a reference reaches, as Ruby looks it up.
        def constant_reference(node)
          return unless node.is_a?(Prism::ConstantReadNode) || node.is_a?(Prism::ConstantPathNode)

          declared = DeclaredConstant.lookup_declared(node.slice, @nesting || [], @declared ||= {})
          return declared unless @app_constant

          nesting = @nesting || []
          DeclaredConstant.lookup(node.slice, nesting: nesting, ancestors: DeclaredConstant.ancestors_in(nesting, @declared), exists: ->(name) { name == declared || @app_constant.call(name) }) || declared
        end

        # A constant app reads as what it holds; a `.new` one as booted names it: an instance by its class (`AL.new` by the class
        # AL holds), `Class.new` by the constant.
        def app_value(node)
          value = written_value(node)
          receiver = value.receiver if value.is_a?(Prism::CallNode) && value.name == :new
          return value unless receiver.is_a?(Prism::ConstantReadNode) || receiver.is_a?(Prism::ConstantPathNode)

          held = written_value(receiver)
          receiver = held if held.is_a?(Prism::ConstantReadNode) || held.is_a?(Prism::ConstantPathNode)
          %w[Class Module].include?(constant_path_string(receiver)) ? node : receiver
        end

        # A Rack app as a route names it: a constant, or a call on one with no
        # arguments (`ActionCable.server`). Anything else is not readable here.
        def app_name(node)
          node = app_value(node)
          case node
          when Prism::ConstantReadNode then (constant_reference(node) || node.name).to_s
          when Prism::ConstantPathNode then constant_path_string(node)
          when Prism::CallNode
            receiver = node.receiver
            constant = receiver.is_a?(Prism::ConstantReadNode) || receiver.is_a?(Prism::ConstantPathNode)
            # `Flipper::UI.app(Flipper)` is named by what builds it, arguments off.
            # `PagesController.action(:show)` is a controller endpoint, not an app.
            # `APPS[:x]` or `APPS.fetch(:x)` is an app the constant holds, which only a boot can name.
            return unless constant && node.block.nil? && node.name != :action
            return RailsAiContext::Confidence::INFERRED if CallSiteExpansion::HELD_READERS.include?(node.name)

            "#{constant_path_string(receiver)}.#{node.name}"
          end
        end

        # The name is the source text: `::Foo::Bar` and `Foo::Bar` are the same
        # constant, so only the root scope operator comes off.
        def constant_path_string(node)
          node.slice.delete_prefix("::")
        end

        # `File` or `::File`, and a bare `__dir__`, as a path anchored at the walked file is written.
        def file_constant?(node)
          (node.is_a?(Prism::ConstantReadNode) || node.is_a?(Prism::ConstantPathNode)) && constant_path_string(node) == "File"
        end

        def dir_call?(node)
          node.is_a?(Prism::CallNode) && node.name == :__dir__ && node.receiver.nil? && node.arguments.nil?
        end

        # A first argument that is neither a literal nor the options: `scope PREFIX do`, `scope "/v#{n}" do`.
        # Rails joins `scope nil` into no segment.
        def positional_prefix?(node)
          first = node.arguments&.arguments&.first
          !first.nil? && !first.is_a?(Prism::KeywordHashNode) && !first.is_a?(Prism::HashNode) && !first.is_a?(Prism::NilNode)
        end

        # The full name a class or module open or a constant write defines inside `nesting` (Module.nesting, innermost
        # first), read against those walked so far; nil for an `||=` that defines nothing.
        def declare_constant(node, nesting)
          DeclaredConstant.declare_node(node, nesting, @declared ||= {})&.delete_prefix("::")
        end

        # The writes beside `on_constant_write_node_enter` that define a constant for a later declare_constant.
        CONSTANT_WRITE_EVENTS = %i[on_constant_path_write_node_enter on_constant_or_write_node_enter on_constant_path_or_write_node_enter
                                   on_constant_target_node_enter on_constant_path_target_node_enter].freeze

        def hash_node_to_hash(node, source: false)
          elements = node.respond_to?(:elements) ? node.elements : []
          elements.each_with_object({}) do |assoc, h|
            next unless assoc.is_a?(Prism::AssocNode)
            h[extract_key(assoc.key)] = extract_value(assoc.value, source: source)
          end
        end

        def confidence_for(node) = self.class.confidence_for(node)

        def self.confidence_for(node) = RailsAiContext::Confidence.for_node(node)
      end
    end
  end
end
