# frozen_string_literal: true

require "prism"

module RailsAiContext
  module Introspectors
    module Listeners
      # Base class for Prism Dispatcher listeners.
      # Provides shared helpers for extracting values from AST nodes.
      class BaseListener
        attr_reader :results
        # The walk's comments, for a listener that slices source: a fold onto
        # one line would otherwise comment out what follows.
        attr_writer :comments

        def initialize
          @results = []
          @comments = []
        end

        private

        # A node's source with its comments removed, folded onto one line.
        def one_line_source(node)
          start = node.location.start_offset
          finish = node.location.end_offset
          cuts = Array(@comments).filter_map do |comment|
            location = comment.location
            [ location.start_offset, location.end_offset, "" ] if location.start_offset >= start && location.end_offset <= finish
          end
          cuts.concat(multiline_literals(node))

          # The node's text runs on past its end when it opens a heredoc, and
          # every cut sits inside the node, so the offsets still line up.
          text = NodeSource.text(node).dup
          cuts.sort_by(&:first).reverse_each do |from, to, replacement|
            text[(from - start)...(to - start)] = replacement
          end
          fold_newlines(text)
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

          kinds = newline_kinds(tokens)
          folded = +""
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
          folded.strip.sub(/;\z/, "").strip
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
          Prism.lex(text).value.map(&:first)
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

        # The source of a call's default: option, for a value no literal carries.
        def default_source(node)
          value = default_node(node)
          value && NodeSource.text(value)
        end

        def proc_default?(node)
          value = default_node(node)
          value.is_a?(Prism::LambdaNode) ||
            (value.is_a?(Prism::CallNode) && value.receiver.nil? && %i[lambda proc].include?(value.name) && !value.block.nil?)
        end

        def default_node(node)
          args = node.arguments&.arguments || []
          assoc = args.grep(Prism::KeywordHashNode)
                      .flat_map(&:elements)
                      .find { |e| e.is_a?(Prism::AssocNode) && extract_key(e.key) == :default }
          assoc&.value
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
          else RailsAiContext::Confidence::INFERRED
          end

          return value unless value == RailsAiContext::Confidence::INFERRED && source

          one_line_source(node)
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

              name = app_name(assoc.value)
              return name if name
            end
          end
          nil
        end

        # A Rack app as a route names it: a constant, or a call on one with no
        # arguments (`ActionCable.server`). Anything else is not readable here.
        def app_name(node)
          case node
          when Prism::ConstantReadNode then node.name.to_s
          when Prism::ConstantPathNode then constant_path_string(node)
          when Prism::CallNode
            receiver = node.receiver
            constant = receiver.is_a?(Prism::ConstantReadNode) || receiver.is_a?(Prism::ConstantPathNode)
            # `Flipper::UI.app(Flipper)` is named by what builds it, arguments off.
            # `PagesController.action(:show)` is a controller endpoint, not an app.
            "#{constant_path_string(receiver)}.#{node.name}" if constant && node.block.nil? && node.name != :action
          end
        end

        # The name is the source text: `::Foo::Bar` and `Foo::Bar` are the same
        # constant, so only the root scope operator comes off.
        def constant_path_string(node)
          node.slice.delete_prefix("::")
        end

        def hash_node_to_hash(node, source: false)
          elements = node.respond_to?(:elements) ? node.elements : []
          elements.each_with_object({}) do |assoc, h|
            next unless assoc.is_a?(Prism::AssocNode)
            h[extract_key(assoc.key)] = extract_value(assoc.value, source: source)
          end
        end

        def confidence_for(node)
          RailsAiContext::Confidence.for_node(node)
        end
      end
    end
  end
end
