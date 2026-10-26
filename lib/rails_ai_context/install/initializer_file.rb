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
      BARE_GUARD = /^([ \t]*)if defined\?\(RailsAiContext\)$/
      CURRENT_GUARD = /^[ \t]*if defined\?\(RailsAiContext\)\s*&&\s*RailsAiContext\.respond_to\?\(:configure\)$/
      GUARD_LINE = "if defined?(RailsAiContext) && RailsAiContext.respond_to?(:configure)"
      CONFIGURE_CALL = /^[ \t]*RailsAiContext\.configure\b/
      GUARD_EXPRESSION = /defined\?\(\s*RailsAiContext\b|RailsAiContext\.respond_to\?\(\s*:configure\s*\)/

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
        content.match?(CONFIGURE_CALL)
      end

      def bare_guard?(content)
        content.match?(BARE_GUARD)
      end

      # Either form counts as guarded, so a re-run neither double-wraps an
      # initializer nor treats an unguarded one as guarded.
      def guarded?(content)
        content.match?(BARE_GUARD) || content.match?(CURRENT_GUARD)
      end

      # The two spellings this gem writes are not the only ones that work: a
      # hand-written `if RailsAiContext.respond_to?(:configure)` or an early
      # `return unless defined?(RailsAiContext)` protects the call just as
      # well. Anything that tests for the gem above the configure call counts,
      # so a report cannot call a safe file unguarded.
      def any_guard_before_configure?(content)
        index = content.index(CONFIGURE_CALL)
        return false unless index

        content[0, index].match?(GUARD_EXPRESSION)
      end
    end
  end
end
