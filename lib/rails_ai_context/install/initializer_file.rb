# frozen_string_literal: true

require "ripper"
require_relative "../unbooted_settings"

module RailsAiContext
  module Install
    # The initializer guard's vocabulary, in one place. The generator wraps
    # and upgrades the guard and the doctor diagnoses it; each carried its own
    # copy of the pattern, and the copies had already been restated once.
    #
    # The bare form predates the respond_to? check: a path:/git: gemspec is
    # evaluated in-process by Bundler in every environment, defining a
    # VERSION-only stub `RailsAiContext` module even when the gem is not in
    # the current group - so `defined?(RailsAiContext)` alone does not prove
    # `.configure` exists.
    module InitializerFile
      BARE_GUARD = /^([ \t]*)if defined\?\(RailsAiContext\)(?=[ \t]*(?:#.*)?\r?$)/
      CURRENT_GUARD = /^[ \t]*if defined\?\(RailsAiContext\)\s*&&\s*RailsAiContext\.respond_to\?\(:configure\)$/
      GUARD_LINE = "if defined?(RailsAiContext) && RailsAiContext.respond_to?(:configure)"

      # The first `RailsAiContext.configure` call with a block. Lines count
      # from 1 and the column is in bytes. `param` is the block's one plain
      # param and `head_line` the line it is on, both nil for a block that
      # names none; `close_*` is where its `end` or `}` starts.
      ConfigureBlock = Struct.new(:param, :call_line, :head_line, :close_line, :close_column, :empty, keyword_init: true) do
        # The byte offset in `source` where the block's `end` or `}` starts.
        def close_offset(source)
          source.lines.first(close_line - 1).sum(&:bytesize) + close_column
        end
      end

      # Ripper's tree, each block carrying where its closing token starts:
      # the token last scanned when the parser builds the block.
      class BlockTree < Ripper::SexpBuilderPP
        SCANNER_EVENTS.each do |event|
          define_method(:"on_#{event}") do |token|
            @scanned = [ lineno, column ]
            super(token)
          end
        end

        def on_do_block(*args)
          super(*args).push(@scanned)
        end

        def on_brace_block(*args)
          super(*args).push(@scanned)
        end
      end
      private_constant :BlockTree

      module_function

      # The configure block, found by parsing, so a heredoc that quotes one,
      # a note after its param and any param name read right.
      #
      # @return [ConfigureBlock, nil] nil when the source does not parse or has no such block
      def configure_block(source)
        parser = BlockTree.new(source)
        tree = parser.parse
        return nil if parser.error? || tree.nil?

        walk = UnbootedSettings::Walk
        stack = [ tree ]
        until stack.empty?
          node = stack.pop
          next unless node.is_a?(Array)

          receiver, block = walk.configure_of(node)
          return configure_block_of(receiver, block, walk) if receiver

          stack.concat(node.reverse)
        end
        nil
      end

      def configure_block_of(receiver, block, walk)
        param = walk.block_params(block).first if block[1]
        body = block[2][0] == :bodystmt ? block[2][1] : block[2]
        ConfigureBlock.new(param: param, call_line: receiver[1][2][0], head_line: param && block[1][1][1][0][2][0],
                           close_line: block.last[0], close_column: block.last[1], empty: body.all? { |stmt| stmt[0] == :void_stmt })
      end
      private_class_method :configure_block_of

      # What a guard is there to protect: a file that never calls into the gem
      # needs none.
      def configures?(content)
        !configure_path(content).nil?
      end

      # The nodes from the root down to the first `RailsAiContext.configure`
      # call, nil when the source does not parse or makes no such call.
      def configure_path(content)
        parser = BlockTree.new(content)
        tree = parser.parse
        return nil if parser.error? || tree.nil?

        parents = {}.compare_by_identity
        stack = [ tree ]
        until stack.empty?
          node = stack.pop
          if configure_call?(node)
            path = [ node ]
            path.unshift(parents[path.first]) while parents.key?(path.first)
            return path
          end
          node.reverse_each do |child|
            next unless child.is_a?(Array)

            parents[child] = node
            stack << child
          end
        end
        nil
      end
      private_class_method :configure_path

      def configure_call?(node)
        %i[call command_call].include?(node[0]) && node[3].is_a?(Array) && node[3][1] == "configure" && UnbootedSettings::Walk.gem?(node[1])
      end
      private_class_method :configure_call?

      def bare_guard?(content)
        bare_guard_lines(content).any?
      end

      # The lines of the bare guards the configure call runs under. A closed
      # `if defined?(RailsAiContext)` elsewhere in the file protects nothing.
      def bare_guard_lines(content)
        path = configure_path(content) or return []

        lines = content.lines
        path.each_cons(2).filter_map do |parent, child|
          next unless parent[0] == :if && parent[2].equal?(child)

          line = first_line(parent[1])
          line if line && lines[line - 1].match?(BARE_GUARD)
        end
      end

      def first_line(node)
        return node[2][0] if node[0].is_a?(Symbol) && node[0].start_with?("@")

        node.each do |child|
          line = child.is_a?(Array) && first_line(child)
          return line if line
        end
        nil
      end
      private_class_method :first_line

      # Either form anywhere in the text, for a file with no configure call
      # to place a guard around, so a re-run does not wrap it twice.
      def guarded?(content)
        content.match?(BARE_GUARD) || content.match?(CURRENT_GUARD)
      end

      # The two spellings this gem writes are not the only ones that work: a
      # hand-written `if RailsAiContext.respond_to?(:configure)` or an early
      # `return unless defined?(RailsAiContext)` protects the call just as
      # well. Any test for the gem counts that the call runs under, or that an
      # earlier exit takes, so a report cannot call a safe file unguarded.
      def any_guard_before_configure?(content)
        path = configure_path(content) or return false

        path.each_cons(2).any? do |parent, child|
          next guards?(parent, child) unless parent[0].is_a?(Array)

          parent.take_while { |statement| !statement.equal?(child) }.any? { |statement| exits_on_gem_test?(statement) }
        end
      end

      def guards?(node, child)
        case node[0]
        when :if, :unless, :elsif, :if_mod, :unless_mod, :ifop then !node[1].equal?(child) && tests_gem?(node[1])
        when :binary then %i[&& and].include?(node[2]) && node[3].equal?(child) && tests_gem?(node[1])
        else false
        end
      end
      private_class_method :guards?

      def exits_on_gem_test?(node)
        case node[0]
        when :if, :unless, :if_mod, :unless_mod then tests_gem?(node[1]) && UnbootedSettings::Walk.exits?(node[2])
        when :binary then %i[|| or].include?(node[2]) && tests_gem?(node[1]) && UnbootedSettings::Walk.exits?(node[3])
        else false
        end
      end
      private_class_method :exits_on_gem_test?

      # `defined?` of the gem or a name under it, or `respond_to?` asked of the gem.
      def tests_gem?(condition)
        walk = UnbootedSettings::Walk
        stack = [ condition ]
        until stack.empty?
          node = stack.pop
          next unless node.is_a?(Array)
          return true if node[0] == :defined && under_gem?(node[1])
          return true if node[0] == :method_add_arg && (call = walk.call_of(node[1])) && call.last == "respond_to?" && walk.gem?(call.first)

          stack.concat(node)
        end
        false
      end
      private_class_method :tests_gem?

      def under_gem?(node)
        walk = UnbootedSettings::Walk
        node = node[1] while node.is_a?(Array) && %i[const_path_ref call].include?(node[0]) && !walk.gem?(node)
        walk.gem?(node)
      end
      private_class_method :under_gem?
    end
  end
end
