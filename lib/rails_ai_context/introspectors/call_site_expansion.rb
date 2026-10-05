# frozen_string_literal: true

require "prism"

module RailsAiContext
  module Introspectors
    # What one call of a mixin's macro-declaring method declares: parameters bind to the
    # call's literals, and a branch they decide is taken alone. What a condition they cannot
    # decide holds back is not declared for certain: it comes back under `:conditional`
    # with the condition, and is listed only when every way through declares it alike.
    module CallSiteExpansion
      UNKNOWN = Object.new.freeze
      # `pairs` is set for a literal hash: its `key: value` text, which reads
      # as keyword arguments where the parameter is passed as the last one.
      # `items` is set for a list of literals: each one's source.
      Binding = Struct.new(:value, :source, :pairs, :value_sources, :items)

      # The rewritten body, and for each of its lines the line of the mixin's
      # file it came from, so what the body declares keeps its real location.
      class Output
        # The blocks the body evaluates on another receiver, each [receiver
        # source, the block's own Output, the conditions it runs under].
        attr_reader :text, :foreign

        def initialize
          @text = +""
          @lines = []
          @code = false
          @foreign = []
        end

        # A line takes the source line of its first code; text the call supplies keeps its parameter's line.
        def append(chunk, source_line, from_call: false)
          chunk.each_char do |char|
            @text << char
            if char == "\n"
              source_line += 1 unless from_call
              @code = false
            elsif !@code && !char.match?(/\s/)
              @lines[line] = source_line
              @code = true
            end
          end
          self
        end

        def line
          @text.count("\n") + 1
        end

        def source_line(line)
          @lines[line]
        end
      end

      module_function

      # @param definition [Prism::DefNode] the method called
      # @param call [Prism::CallNode, nil] the call site, nil when unknown
      # @param listeners [Hash] the listener map to read the body with
      # @param includer [Set, nil] ids of the call's argument nodes that are the including class
      # @return [Hash{Symbol => Array<Hash>}]
      def entries(definition, call, listeners, includer: nil)
        return {} unless definition.body

        bound = includer_bound(bind(definition.parameters, call), definition.parameters, call, includer)
        bindings = rest_bindings(unwritten(bound, definition.body), definition, call)
        out = Output.new
        undecided = []
        emit(definition.body, bindings, out, undecided, 0, [])
        data = SourceIntrospector.walk_source(out.text, listeners)
        conditional = []
        if undecided.any?
          all = data.flat_map { |key, found| Array(found).map { |entry| [ key, entry ] } }
          data = data.to_h do |key, found|
            kept = Array(found).select do |entry|
              held = holding_branch(key, entry, all, undecided)
              conditional << declaration(entry, out, held.last) if held.is_a?(Array)
              held.nil?
            end
            [ key, kept ]
          end
        end
        unbound = bindings.filter_map { |name, binding| name if name.is_a?(Symbol) && binding.source.nil? }
        if unbound.any?
          data = data.transform_values do |found|
            Array(found).reject do |entry|
              held = names_unbound?(entry, out, unbound)
              conditional << declaration(entry, out, []) if held
              held
            end
          end
        end
        data = data.transform_values { |found| Array(found).map { |entry| relocated(entry, out) } }
        data.merge(conditional: conditional, foreign: foreign_entries(out, listeners))
      end

      EVALS = %i[instance_eval class_eval class_exec instance_exec module_eval module_exec].freeze

      # The including class a mixin hook hands on (`enhance_controller(base)`), which a block evaluated on runs as the class.
      INCLUDER = Object.new.freeze

      # `other.instance_eval { validates ... }` runs its block with `other` as
      # self, so what it declares is `other`'s, not the calling class's.
      def foreign_eval?(node, bindings = {}, depth = 0)
        node.is_a?(Prism::CallNode) && EVALS.include?(node.name) && node.block.is_a?(Prism::BlockNode) &&
          node.receiver && !node.receiver.is_a?(Prism::SelfNode) &&
          !(node.receiver.is_a?(Prism::LocalVariableReadNode) && bound(bindings, node.receiver, depth)&.value.equal?(INCLUDER))
      end

      # A required parameter the call passes the including class to stands for that class.
      def includer_bound(bindings, parameters, call, includer)
        return bindings unless parameters && call && includer&.any?

        Array(call.arguments&.arguments).zip(parameters.requireds).each do |argument, param|
          bindings[param.name] = Binding.new(INCLUDER, "self") if param.respond_to?(:name) && includer.include?(argument.__id__)
        end
        bindings
      end

      # What each block evaluated on another receiver declares, named with the
      # receiver as the source writes it.
      def foreign_entries(out, listeners)
        out.foreign.flat_map do |receiver, block_out, conditions|
          SourceIntrospector.walk_source(block_out.text, listeners).flat_map do |_key, found|
            Array(found).filter_map do |entry|
              declaration(entry, block_out, conditions).merge(receiver: receiver) if entry.is_a?(Hash) && entry[:location]
            end
          end
        end.sort_by { |entry| entry[:location].to_i }
      end

      # The branch whose condition holds the entry back; nil when every way
      # through the undecided condition around it declares it alike, and
      # :repeated for the copy of such an entry a later way declares.
      def holding_branch(key, entry, all, undecided)
        line = entry.is_a?(Hash) && entry[:location]
        return nil unless line

        mine = identity(key, entry)
        undecided.select { |group| group.any? { |range, _| range&.cover?(line) } }
                 .min_by { |group| group.filter_map { |range, _| range&.size }.sum }
                 &.then do |group|
                   branch = group.find { |range, _| range&.cover?(line) }
                   everywhere = group.all? do |range, _|
                     range && all.any? { |k, other| range.cover?(other[:location].to_i) && identity(k, other) == mine }
                   end
                   next branch unless everywhere

                   group.first.first&.cover?(line) ? nil : :repeated
                 end
      end

      # The call written at the entry's line, less any block, with the
      # conditions it runs under.
      def declaration(entry, out, conditions)
        call = call_at(out, entry[:location])
        { declaration: call ? call_source(call) : out.text.lines[entry[:location] - 1].to_s.strip,
          condition: (conditions.join(" and ") if conditions.any?),
          location: out.source_line(entry[:location]) || entry[:location] }.compact
      end

      def call_at(out, line)
        AstWalk.each(AstCache.parse_string(out.text).value).find do |node|
          node.is_a?(Prism::CallNode) && node.location.start_line == line
        end
      end

      # A parameter the expansion cannot bind is written as its bare name, which a
      # listener would read as what the call declares.
      def names_unbound?(entry, out, names)
        return false unless entry.is_a?(Hash) && entry[:location]

        Array(call_at(out, entry[:location])&.arguments&.arguments).any? do |argument|
          argument = argument.expression if argument.is_a?(Prism::SplatNode)
          (argument.is_a?(Prism::LocalVariableReadNode) || (argument.is_a?(Prism::CallNode) && argument.variable_call?)) &&
            names.include?(argument.name)
        end
      end

      def call_source(call)
        text = call.slice
        text = text.byteslice(0, call.block.location.start_offset - call.location.start_offset) if call.block.is_a?(Prism::BlockNode)
        text.strip.gsub(/\s*\n\s*/, " ")
      end

      def relocated(entry, out)
        return entry unless entry.is_a?(Hash) && entry[:location]

        moved = entry.merge(location: out.source_line(entry[:location]) || entry[:location])
        moved[:proc_lines] = entry[:proc_lines].map { |line| out.source_line(line) || line } if entry[:proc_lines].is_a?(Array)
        moved
      end

      def identity(key, entry)
        [ key, entry[:type], entry[:name] || entry[:method] || entry[:attributes] ]
      end

      # The method's parameters, each bound to the literal the call passes,
      # its literal default, or UNKNOWN.
      def bind(parameters, call)
        return {} unless parameters

        arguments = call ? Array(call.arguments&.arguments) : nil
        keywords = arguments&.last.is_a?(Prism::KeywordHashNode) ? arguments.last : nil
        takes_keywords = parameters.keywords.any? || parameters.keyword_rest
        positional = arguments ? arguments.dup : []
        positional.pop if keywords && takes_keywords

        bindings = {}
        parameters.requireds.each do |param|
          next unless param.respond_to?(:name)

          bindings[param.name] = arguments ? literal(positional.shift) : unknown
        end
        parameters.optionals.each do |param|
          bindings[param.name] =
            if arguments.nil? then unknown
            elsif positional.any? then literal(positional.shift)
            else literal(param.value)
            end
        end
        parameters.keywords.each do |param|
          given = keywords&.elements&.find { |pair| pair.is_a?(Prism::AssocNode) && key_of(pair) == param.name }
          bindings[param.name] =
            if arguments.nil? then unknown
            elsif given then literal(given.value)
            elsif param.respond_to?(:value) then literal(param.value)
            else unknown
            end
        end
        rest = parameters.keyword_rest
        bindings[rest.name] = keyword_rest_binding(parameters, arguments, keywords) if rest.respond_to?(:name) && rest.name
        bindings
      end

      # `**options` holds the call's keywords the named ones leave.
      def keyword_rest_binding(parameters, arguments, keywords)
        return unknown if arguments.nil?
        return hash_binding({}, {}) unless keywords
        return unknown unless symbol_keyed?(keywords)

        named = parameters.keywords.map(&:name)
        kept = keywords.elements.reject { |pair| named.include?(key_of(pair)) }
        hash_binding(kept.to_h { |pair| [ key_of(pair), value_of(pair.value) ] }, kept.to_h { |pair| [ key_of(pair), pair.value.slice ] })
      end

      def unknown
        Binding.new(UNKNOWN, nil)
      end

      WRITES = [
        Prism::LocalVariableWriteNode, Prism::LocalVariableTargetNode, Prism::LocalVariableOperatorWriteNode,
        Prism::LocalVariableOrWriteNode, Prism::LocalVariableAndWriteNode
      ].freeze

      # A parameter the body assigns or changes in place, in a block too, no
      # longer holds the call's argument wherever it is read, so it is bound to nothing.
      def unwritten(bindings, body)
        changed(body, deleted_keys(bindings, body)).each { |name| bindings[name] = unknown if bindings.key?(name) }
        bindings
      end

      # Leading `options.delete(:key)` on a literal hash parameter leave it bound to the other keys.
      def deleted_keys(bindings, body)
        return [] unless body.is_a?(Prism::StatementsNode)

        body.body.take_while do |node|
          call = node.is_a?(Prism::LocalVariableWriteNode) ? node.value : node
          next false unless call.is_a?(Prism::CallNode) && call.name == :delete && call.block.nil?

          receiver = call.receiver
          key = Array(call.arguments&.arguments)
          binding = receiver.is_a?(Prism::LocalVariableReadNode) && receiver.depth.zero? && bindings[receiver.name]
          next false unless binding&.value_sources && key.one? && key.first.is_a?(Prism::SymbolNode)
          next false if node.is_a?(Prism::LocalVariableWriteNode) && node.name == receiver.name

          key = key.first.unescaped.to_sym
          value = binding.value.is_a?(Hash) ? binding.value.except(key) : binding.value
          bindings[receiver.name] = hash_binding(value, binding.value_sources.except(key))
        end
      end

      # `local[key] ||= v`, `&&=` and `+=` change the local in place too.
      INDEX_WRITES = [ Prism::IndexOrWriteNode, Prism::IndexAndWriteNode, Prism::IndexOperatorWriteNode ].freeze

      # Methods that change their receiver in place.
      MUTATORS = %i[<< []= push append unshift prepend insert concat pop shift delete delete_at delete_if keep_if
                    clear replace store update fill].freeze

      # Readers that return an object the receiver holds, not a copy.
      HELD_READERS = %i[[] fetch dig].freeze

      # The method's own locals the body writes or changes in place, outside the `kept` statements.
      def changed(body, kept = [])
        found = Set.new
        stack = [ [ body, 0 ] ]
        until stack.empty?
          node, blocks = stack.pop
          next if kept.any? { |statement| statement.equal?(node) }

          found << node.name if WRITES.include?(node.class) && node.depth == blocks
          receiver = node.receiver if INDEX_WRITES.include?(node.class) ||
                                      (node.is_a?(Prism::CallNode) && (MUTATORS.include?(node.name) || node.name.match?(/\w!\z/)))
          # `options[:a][:b] = v` changes what `options` holds; `options.dup[:a] = v` changes a copy.
          receiver = receiver.receiver while receiver.is_a?(Prism::CallNode) && HELD_READERS.include?(receiver.name)
          found << receiver.name if receiver.is_a?(Prism::LocalVariableReadNode) && receiver.depth == blocks
          blocks += 1 if node.is_a?(Prism::BlockNode) || node.is_a?(Prism::LambdaNode)
          stack.concat(node.compact_child_nodes.map { |child| [ child, blocks ] })
        end
        found
      end

      # `*args` holds the call's positionals past the other parameters, less a trailing hash the body takes
      # (`extract_options!`), plus literals the leading statements push; a local changed elsewhere is unknown.
      def rest_bindings(bindings, definition, call)
        rest = definition.parameters&.rest
        return bindings unless call && rest.is_a?(Prism::RestParameterNode) && definition.body.is_a?(Prism::StatementsNode)
        return anonymous_rest(bindings, definition, call) unless rest.name

        given = rest_arguments(definition.parameters, call)
        taken = [ "#{rest.name}.extract_options!", "#{rest.name}.last.is_a?(Hash)?#{rest.name}.pop:{}" ]
        kept = []
        list = given
        leading = true
        definition.body.body.each do |node|
          if node.is_a?(Prism::LocalVariableWriteNode) && taken.include?(node.value.slice.delete(" "))
            last = given&.last
            bindings[node.name] =
              if given.nil? then unknown
              elsif symbol_keyed?(last) then literal(last)
              elsif last.nil? || literal_source?(last) then hash_binding({}, {})
              else unknown
              end
            list = leading && list && (symbol_keyed?(list.last) ? list[0...-1] : list)
            kept << node
          elsif leading && (grown = pushed(node, rest.name, list, bindings))
            list = grown
            kept << node
          else
            leading = false
          end
        end
        changed_names = changed(definition.body, kept)
        kept.each { |node| bindings[node.name] = unknown if node.is_a?(Prism::LocalVariableWriteNode) && changed_names.include?(node.name) }
        # A trailing keyword hash no statement took stays in the rest, as Ruby leaves it.
        items = list && (symbol_keyed?(list.last) ? list[0...-1] : list)
        list = nil if !list || changed_names.include?(rest.name) || items.any? { |item| !literal_source?(item) }
        bindings[rest.name] = list ? list_binding(list) : unknown
        bindings
      end

      # A bare `*` holds what the call passes there, which the body can only pass on whole.
      def anonymous_rest(bindings, definition, call)
        given = rest_arguments(definition.parameters, call)
        last = given&.last
        options = symbol_keyed?(last) ? [ last ] : []
        items = given && (given - options)
        bindings[ANONYMOUS_REST] = items&.all? { |item| literal_source?(item) } ? list_binding(items + options) : unknown
        bindings
      end

      ANONYMOUS_REST = :*

      # The call's arguments `*rest` takes, nil when they cannot be told (a splat, too few).
      def rest_arguments(parameters, call)
        arguments = Array(call.arguments&.arguments)
        return nil if arguments.any? { |argument| argument.is_a?(Prism::SplatNode) }

        takes_keywords = parameters.keywords.any? || parameters.keyword_rest
        arguments = arguments[0...-1] if takes_keywords && arguments.last.is_a?(Prism::KeywordHashNode)
        before = parameters.requireds.size
        after = parameters.posts.size
        return nil if arguments.size < before + after

        before += [ parameters.optionals.size, arguments.size - before - after ].min
        arguments[before...(arguments.size - after)]
      end

      # The list `args << :x` or `args.push(:x)` leaves, under a modifier `if` the bindings decide; nil for any other statement.
      def pushed(node, name, list, bindings)
        return nil unless list

        if node.is_a?(Prism::IfNode) || node.is_a?(Prism::UnlessNode)
          return nil if node.is_a?(Prism::IfNode) ? node.subsequent : node.else_clause
          return nil unless node.statements&.body&.one? && (grown = pushed(node.statements.body.first, name, list, bindings))

          truth = truth_of(evaluate(node.predicate, bindings.merge(name => list_binding(list)), 0))
          return nil if truth == UNKNOWN

          return (node.is_a?(Prism::UnlessNode) ? !truth : truth) ? grown : list
        end
        return nil unless node.is_a?(Prism::CallNode) && %i[<< push].include?(node.name) && node.block.nil?
        return nil unless node.receiver.is_a?(Prism::LocalVariableReadNode) && node.receiver.name == name

        items = Array(node.arguments&.arguments)
        list + items if items.all? { |item| literal_source?(item) }
      end

      def list_binding(items)
        Binding.new(items.map { |item| value_of(item) }, "[#{items.map(&:slice).join(", ")}]", nil, nil, items.map { |item| item_source(item) })
      end

      # A trailing `key: value` hash passes on as the keywords it spells.
      def item_source(item)
        item.is_a?(Prism::HashNode) && symbol_keyed?(item) ? item.elements.map(&:slice).join(", ") : item.slice
      end

      # A hash with symbol keys binds by its pairs' own source, whatever
      # the values are: `length: { in: 4..Proposal.max }` stands in for itself.
      def literal(node)
        if symbol_keyed?(node)
          sources = node.elements.to_h { |pair| [ key_of(pair), pair.value.slice ] }
          return hash_binding(value_of(node), sources)
        end

        Binding.new(value_of(node), literal_source?(node) ? node.slice : nil)
      end

      def hash_binding(value, sources)
        pairs = sources.map { |key, source| "#{key}: #{source}" }.join(", ")
        Binding.new(value, "{ #{pairs} }", pairs, sources)
      end

      def symbol_keyed?(node)
        (node.is_a?(Prism::HashNode) || node.is_a?(Prism::KeywordHashNode)) &&
          node.elements.all? { |pair| pair.is_a?(Prism::AssocNode) && key_of(pair) }
      end

      # Every value a literal the parameter can stand in for, nested hashes too.


      def literal_source?(node)
        [ Prism::SymbolNode, Prism::StringNode, Prism::IntegerNode, Prism::TrueNode,
          Prism::FalseNode, Prism::NilNode ].any? { |type| node.is_a?(type) }
      end

      def value_of(node)
        case node
        when Prism::SymbolNode then node.unescaped.to_sym
        when Prism::StringNode then node.unescaped
        when Prism::IntegerNode then node.value
        when Prism::TrueNode then true
        when Prism::FalseNode then false
        when Prism::NilNode then nil
        when Prism::HashNode, Prism::KeywordHashNode
          node.elements.each_with_object({}) do |pair, hash|
            return UNKNOWN unless pair.is_a?(Prism::AssocNode) && (key = key_of(pair))

            hash[key] = value_of(pair.value)
          end
        else UNKNOWN
        end
      end

      def key_of(pair)
        pair.key.unescaped.to_sym if pair.key.is_a?(Prism::SymbolNode)
      end

      # Writes the node's source into `out`, bound parameters substituted and
      # decided branches pruned; an undecided branch's lines go on `undecided`.
      #
      # `depth` counts the blocks around the node: a read reaches the method's
      # parameter only when its own depth says so, and one a block parameter
      # of the same name shadows reads the block's.
      def emit(node, bindings, out, undecided, depth, conditions)
        case node
        when Prism::LocalVariableReadNode
          source = bound(bindings, node, depth)&.source
          return out.append(source, node.location.start_line, from_call: true) if source
        when Prism::InterpolatedSymbolNode, Prism::InterpolatedStringNode
          folded = !heredoc?(node) && interpolated(node, bindings, depth)
          return out.append(folded.inspect, node.location.start_line) if folded
        when Prism::CallNode
          return emit_each(node, bindings, out, undecided, depth, conditions) if unrolled?(node, bindings, depth)

          looked_up = hash_lookup(node, bindings, depth)
          return out.append(looked_up, node.location.start_line, from_call: true) if looked_up
        when Prism::IfNode, Prism::UnlessNode
          return emit_branch(node, bindings, out, undecided, depth, conditions)
        when Prism::CaseNode
          return emit_case(node, bindings, out, undecided, depth, conditions)
        when Prism::ArgumentsNode
          return emit_arguments(node, bindings, out, undecided, depth, conditions)
        when Prism::BlockNode, Prism::LambdaNode
          depth += 1
        end
        if foreign_eval?(node, bindings, depth)
          block_out = Output.new
          emit(node.block.body, bindings, block_out, [], depth + 1, conditions) if node.block.body
          out.foreign << [ node.receiver.slice, block_out, conditions ]
          out.foreign.concat(block_out.foreign)
          return out.append("nil", node.location.start_line)
        end
        # A heredoc's node is its opener; its body lies past the enclosing
        # call's slice, in the statements around it, which write it verbatim.
        return out.append(node.slice, node.location.start_line) if heredoc?(node)

        text = node.slice
        start = node.location.start_offset
        line_at = ->(position) { node.location.start_line + text.byteslice(0, position).count("\n") }
        position = 0
        node.compact_child_nodes.sort_by { |child| child.location.start_offset }.each do |child|
          offset = child.location.start_offset - start
          next if offset < position

          out.append(text.byteslice(position, offset - position), line_at.call(position))
          emit(child, bindings, out, undecided, depth, conditions)
          position = child.location.end_offset - start
        end
        out.append(text.byteslice(position, text.bytesize - position), line_at.call(position))
      end

      # The binding a read reaches: the method's parameter, or the parameter of a block written once per item.
      def bound(bindings, node, depth)
        level = depth - node.depth
        level.zero? ? bindings[node.name] : bindings[[ node.name, level ]]
      end

      # `"#{field}_changed?"` with every part a literal or a bound literal, as the value it makes.
      def interpolated(node, bindings, depth)
        text = node.parts.map do |part|
          next part.unescaped if part.is_a?(Prism::StringNode)

          statements = part.is_a?(Prism::EmbeddedStatementsNode) && part.statements&.body
          return nil unless statements&.one?

          inner = statements.first
          value = inner.is_a?(Prism::LocalVariableReadNode) ? bound(bindings, inner, depth)&.value : value_of(inner)
          return nil if value.nil? || value == UNKNOWN || value.is_a?(Hash) || value.is_a?(Array)

          value.to_s
        end.join
        node.is_a?(Prism::InterpolatedSymbolNode) ? text.to_sym : text
      end

      # `args.each do |field| ... end` over a bound list of literals.
      def unrolled?(node, bindings, depth)
        receiver = node.receiver
        return false unless node.name == :each && node.arguments.nil? && node.block.is_a?(Prism::BlockNode) && node.block.body
        return false unless receiver.is_a?(Prism::LocalVariableReadNode) && bound(bindings, receiver, depth)&.items

        params = node.block.parameters&.parameters
        params && params.requireds.one? && params.requireds.first.respond_to?(:name) && params.optionals.empty? && params.rest.nil? && params.posts.empty?
      end

      # The block's body written once per item, its parameter bound to that item.
      def emit_each(node, bindings, out, undecided, depth, conditions)
        name = node.block.parameters.parameters.requireds.first.name
        binding = bound(bindings, node.receiver, depth)
        binding.items.zip(binding.value).each do |source, value|
          emit(node.block.body, bindings.merge([ name, depth + 1 ] => Binding.new(value, source)), out, undecided, depth + 1, conditions)
          out.append("\n", node.location.end_line)
        end
        out
      end

      # A call's arguments, each written from its own node and joined with a
      # comma: an argument that stands for no keywords at all (an options hash
      # left at `{}`) is left out whole, with no separator to dangle.
      def emit_arguments(node, bindings, out, undecided, depth, conditions)
        written = false
        node.arguments.each do |argument|
          pairs = keyword_argument(node, argument, bindings, depth) || splatted_items(argument, bindings, depth)
          next if pairs&.empty?

          out.append(", ", argument.location.start_line) if written
          pairs ? out.append(pairs, argument.location.start_line, from_call: true) : emit(argument, bindings, out, undecided, depth, conditions)
          written = true
        end
        out
      end

      # `*names` over a bound list of literals is its items.
      def splatted_items(argument, bindings, depth)
        return unless argument.is_a?(Prism::SplatNode)
        return bindings[ANONYMOUS_REST]&.items&.join(", ") if argument.expression.nil?
        return unless argument.expression.is_a?(Prism::LocalVariableReadNode)

        bound(bindings, argument.expression, depth)&.items&.join(", ")
      end

      # `options[:length]` on a hash parameter the call passed as a literal:
      # the value's own source, or `nil` for a key the call left out.
      def hash_lookup(node, bindings, depth)
        return unless node.name == :[] && node.receiver.is_a?(Prism::LocalVariableReadNode)

        sources = bound(bindings, node.receiver, depth)&.value_sources
        key = Array(node.arguments&.arguments)
        return unless sources && key.one? && key.first.is_a?(Prism::SymbolNode)

        sources.fetch(key.first.unescaped.to_sym, "nil")
      end

      # A hash parameter passed as a call's last argument reads as the keywords
      # it holds: `validates method, options` is `validates :title, presence: true`.
      def keyword_argument(node, child, bindings, depth)
        return unless node.is_a?(Prism::ArgumentsNode) && child.equal?(node.arguments.last)
        return splatted_keywords(child, bindings, depth) if child.is_a?(Prism::KeywordHashNode)

        hash_expression(child, bindings, depth)&.pairs
      end

      # `key: v, **options` with `options` a bound hash, as the pairs it spells out.
      def splatted_keywords(node, bindings, depth)
        parts = node.elements.map do |element|
          next emit(element, bindings, Output.new, [], depth, []).text unless element.is_a?(Prism::AssocSplatNode)

          hash_expression(element.value, bindings, depth)&.pairs or return nil
        end
        parts.reject(&:empty?).join(", ") if node.elements.any?(Prism::AssocSplatNode)
      end

      # The bound hash an expression names: the parameter itself, or `merge`,
      # `slice`, `except` or a `reject { |key| key == :x }` on it. Anything else
      # on it is not read, and the expression stays as written.
      def hash_expression(node, bindings, depth)
        return bound(bindings, node, depth)&.then { |b| b if b.value_sources } if node.is_a?(Prism::LocalVariableReadNode)
        return unless node.is_a?(Prism::CallNode) && node.receiver

        base = hash_expression(node.receiver, bindings, depth) or return
        sources = base.value_sources
        arguments = Array(node.arguments&.arguments)
        keys = arguments.all?(Prism::SymbolNode) ? arguments.map { |a| a.unescaped.to_sym } : nil
        case node.name
        when :merge
          return unless arguments.one? && symbol_keyed?(arguments.first) && node.block.nil?

          added = arguments.first.elements.to_h { |pair| [ key_of(pair), emit(pair.value, bindings, Output.new, [], depth, []).text ] }
          hash_binding(UNKNOWN, sources.merge(added))
        when :slice then keys && hash_binding(UNKNOWN, sources.slice(*keys))
        when :except then keys && hash_binding(UNKNOWN, sources.except(*keys))
        when :reject
          dropped = rejected_key(node.block)
          dropped && hash_binding(UNKNOWN, sources.except(dropped))
        end
      end

      # The one key a `reject { |key| key == :x }` block drops.
      def rejected_key(block)
        return unless block.is_a?(Prism::BlockNode) && block.parameters && block.body&.body&.one?

        param = block.parameters.parameters&.requireds&.first
        test = block.body.body.first
        return unless param.respond_to?(:name) && test.is_a?(Prism::CallNode) && test.name == :==
        return unless test.receiver.is_a?(Prism::LocalVariableReadNode) && test.receiver.name == param.name

        key = Array(test.arguments&.arguments).first
        key.unescaped.to_sym if key.is_a?(Prism::SymbolNode)
      end

      def heredoc?(node)
        NodeSource::HEREDOC_TYPES.include?(node.class) && node.heredoc?
      end

      def emit_branch(node, bindings, out, undecided, depth, conditions)
        truth = truth_of(evaluate(node.predicate, bindings, depth))
        unless_node = node.is_a?(Prism::UnlessNode)
        truth = !truth if unless_node && truth != UNKNOWN
        taken = node.statements
        other = unless_node ? node.else_clause : node.subsequent
        other = other.statements if other.is_a?(Prism::ElseNode)

        if truth == UNKNOWN
          predicate = node.predicate.slice
          runs = unless_node ? "not #{predicate}" : predicate
          skips = unless_node ? predicate : "not #{predicate}"
          undecided << emit_ways(out, bindings, undecided, depth, conditions, [ [ taken, runs ], [ other, skips ] ])
        else
          branch = truth ? taken : other
          emit(branch, bindings, out, undecided, depth, conditions) if branch
        end
        out
      end

      # A `case` the literals decide takes its one branch; one they cannot
      # decide holds each branch back under its `when`. Only a literal `when`
      # is compared, so a class or a range reads as undecided.
      def emit_case(node, bindings, out, undecided, depth, conditions)
        subject = node.predicate ? evaluate(node.predicate, bindings, depth) : nil
        chosen = pick_when(node, subject, bindings, depth)
        if chosen == UNKNOWN
          label = node.predicate&.slice
          ways = node.conditions.map do |branch|
            tested = branch.conditions.map(&:slice).join(", ")
            [ branch.statements, label ? "#{label} is #{tested}" : tested ]
          end
          ways << [ node.else_clause&.statements, "no `when` matches" ]
          undecided << emit_ways(out, bindings, undecided, depth, conditions, ways)
        elsif chosen
          emit(chosen, bindings, out, undecided, depth, conditions)
        end
        out
      end

      # The statements the literals pick, nil for none, UNKNOWN when they cannot.
      def pick_when(node, subject, bindings, depth)
        return UNKNOWN if node.predicate && subject == UNKNOWN

        node.conditions.each do |branch|
          branch.conditions.each do |test|
            value = node.predicate ? value_of(test) : truth_of(evaluate(test, bindings, depth))
            return UNKNOWN if value == UNKNOWN
            return branch.statements if node.predicate ? value == subject : value
          end
        end
        node.else_clause&.statements
      end

      # Emits each way through an undecided condition and returns its output
      # lines with the conditions it runs under; a way with no body (a lone
      # `if`) has no lines, and whatever the others declare is held back.
      def emit_ways(out, bindings, undecided, depth, conditions, ways)
        ways.map do |branch, condition|
          path = conditions + [ condition ]
          next [ nil, path ] unless branch

          first = out.line
          emit(branch, bindings, out, undecided, depth, path).append("\n", branch.location.end_line)
          [ first..(out.line - 1), path ]
        end
      end

      def truth_of(value)
        value == UNKNOWN ? UNKNOWN : !!value
      end

      def evaluate(node, bindings, depth)
        case node
        when Prism::LocalVariableReadNode
          (bound(bindings, node, depth) || unknown).value
        when Prism::ParenthesesNode
          body = node.body&.body
          body&.one? ? evaluate(body.first, bindings, depth) : UNKNOWN
        when Prism::AndNode, Prism::OrNode then evaluate_logic(node, bindings, depth)
        when Prism::CallNode then evaluate_call(node, bindings, depth)
        else value_of(node)
        end
      end

      def evaluate_logic(node, bindings, depth)
        left = truth_of(evaluate(node.left, bindings, depth))
        right = -> { truth_of(evaluate(node.right, bindings, depth)) }
        if node.is_a?(Prism::AndNode)
          return false if left == false

          left == UNKNOWN ? (right.call == false ? false : UNKNOWN) : right.call
        else
          return true if left == true

          left == UNKNOWN ? (right.call == true ? true : UNKNOWN) : right.call
        end
      end

      def evaluate_call(node, bindings, depth)
        receiver = node.receiver && evaluate(node.receiver, bindings, depth)
        return UNKNOWN if receiver == UNKNOWN

        arguments = Array(node.arguments&.arguments).map { |argument| value_of(argument) }
        return UNKNOWN if arguments.any?(UNKNOWN)

        case node.name
        when :! then !receiver
        when :nil? then receiver.nil?
        when :[] then receiver.is_a?(Hash) ? receiver[arguments.first] : UNKNOWN
        when :key?, :has_key?, :include? then receiver.is_a?(Hash) ? receiver.key?(arguments.first) : UNKNOWN
        when :many?, :any?, :empty?, :size, :length
          return UNKNOWN unless (receiver.is_a?(Hash) || receiver.is_a?(Array)) && arguments.empty? && !node.block

          node.name == :many? ? receiver.size > 1 : receiver.public_send(node.name)
        when :fetch
          return UNKNOWN unless receiver.is_a?(Hash)

          receiver.key?(arguments.first) ? receiver[arguments.first] : arguments.fetch(1, UNKNOWN)
        else UNKNOWN
        end
      end
    end
  end
end
