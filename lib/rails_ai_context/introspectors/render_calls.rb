# frozen_string_literal: true

module RailsAiContext
  module Introspectors
    # A template's render calls read as RenderingHelper#render reads them: the
    # partial each names and the locals it hands over. The view introspector,
    # rails_get_view and rails_get_partial_interface all read them here.
    module RenderCalls
      # Template handlers whose whole source is Ruby.
      RUBY_TEMPLATE_EXTENSIONS = %w[.rb .jbuilder .builder .ruby].freeze

      RENDER_KEYWORD_ARGS = %w[
        partial layout collection json plain html text xml body file inline
        js status location content_type template formats spacer_template
        cached as object each_serializer
      ].to_set.freeze

      # Not a method on a receiver: `turnstile.render(...)` in an inline script is JavaScript.
      RENDER_CALL = /(?<![.\w])render\b/
      RENDER_POSITIONAL = /\A\s*(["'])((?:\\.|(?!\1).)*)\1/m
      # A partial or template name: a path, never text with spaces or quotes in it.
      PARTIAL_NAME = %r{\A[\w./-]+\z}
      PARTIAL_NAMED = /(?:\bpartial\s*:|:partial\s*=>)\s*["']([^"']+)["']/
      TEMPLATE_NAMED = /(?:\btemplate\s*:|:template\s*=>)\s*["']([^"']+)["']/
      # The partials an options hash renders beside its own: a partial layout and a collection's spacer.
      PARTIAL_LAYOUT = /(?:\blayout\s*:|:layout\s*=>)\s*["']([^"']+)["']/
      SPACER_TEMPLATE = /(?:\bspacer_template\s*:|:spacer_template\s*=>)\s*["']([^"']+)["']/
      PARTIAL_KEY = /(?<![\w:])partial:(?!:)|:partial\s*=>/
      # A block on the call: a `do` ending an unparenthesised call's text, or a `do` or `{` right after its parentheses.
      TRAILING_DO = /\bdo\s*(?:\|[^|]*\|)?\s*-?\s*\z/
      BLOCK_AFTER = /\A[ \t]*(?:do\b|\{)/
      # A block passed as an argument: `&blk`, `&:sym`, `&method(:x)`, or a bare `&`.
      BLOCK_PASS = /(?:\A|,)\s*&(?:\s*(?:,|\z)|[\w@:(])/
      # A partial named outside a render call: turbo_stream.prepend and the
      # broadcast_* methods take `partial:`, and jbuilder renders one with
      # `json.partial!` or `json.array! ..., partial:`.
      PARTIAL_ARG = /(?:\bjson\.partial!\s*\(?\s*|\bpartial:\s*|:partial\s*=>\s*)(["'])([^"']+)\1/
      # `render @posts`, `render(post)`, `render @posts, cached: true`: a bare record or collection, or a
      # chain on one (`@post.comments.recent`), matched against "render <args>"; RenderedRecord reads the chain.
      IMPLICIT_RENDER = /\Arender\s*\(?\s*(@?(?:[a-z_]\w*\.)*[a-z_]\w*)\s*(?:[,)}]|\s(?:if|unless)\b|-?\s*\z)/

      # A helper called with arguments or a block, never a `fields:` key, a `:fields` symbol or a `fields.each`;
      # captures a bare local receiver (none for an @ivar, a Constant or a chain), its dot and `_for`.
      # Regex, as every reader here, since ERB, HAML, Slim and Phlex share it.
      FORM_BUILDER_CALL = /(?:(?:(?:(?<![\w.:@])([a-z_]\w*))?(\.))?(?<![\w:])(?:simple_)?fields(_for)?|(?<![\w.:])(?:simple_form_for|form_with|form_for))(?=[(\s])(?!\s*[.=])/
      FORM_BUILDER_WORD = /fields|form_with|form_for/

      # A render call's ERB-free arguments on one line, as IMPLICIT_RENDER reads them.
      def self.render_line(args)
        "render #{args.gsub(/\s+/, " ").strip}"
      end

      # Each render call as [offset, argument text, whether it takes a block]: its balanced
      # parentheses, or the rest of the line and every line a trailing comma continues onto,
      # up to the ERB tag's `%>`.
      def self.render_calls(content, path: nil)
        return [] unless content.match?(RENDER_CALL)

        kind = template_kind(content, path)
        code_text(content, kind, RENDER_CALL).to_enum(:scan, RENDER_CALL).map do
          at = Regexp.last_match.end(0)
          rest = call_text(content[at..], kind)
          open = rest[/\A\s*\(/]
          unless open
            # Ruby binds a `{` here as the call's block: its body is no argument.
            next [ at, "", true ] if rest.match?(/\A[ \t]*\{/)

            args = (kind == :erb ? rest : continued_line(rest)).split("%>", 2).first
            next [ at, args, top_level(args).match?(TRAILING_DO) || block_pass?(args) ]
          end

          span = RailsAiContext::Brackets.span(rest, open.length - 1, comments: :ruby)
          next [ at, rest[open.length..].split("%>", 2).first, false ] unless span

          args = span[1...-1]
          [ at, args, rest[(open.length - 1 + span.length)..].match?(BLOCK_AFTER) || block_pass?(args) ]
        end
      end

      def self.block_pass?(args)
        top_level(args).rstrip.match?(BLOCK_PASS)
      end
      private_class_method :block_pass?

      # A braced options hash, `render({ partial: "x" })`, as the bare keywords Rails reads it the same as;
      # RenderingHelper#render ignores a second argument beside a Hash.
      def self.bare_options(args)
        open = args[/\A\s*\{/] or return args
        group = RailsAiContext::Brackets.span(args, open.length - 1, comments: :ruby)
        group ? group[1...-1] : args
      end

      def self.continued_line(text)
        lines = []
        text.each_line do |line|
          lines << line
          break unless line.rstrip.end_with?(",", "\\")
        end
        lines.join
      end
      private_class_method :continued_line

      # How far a call in the template can run: :erb to its tag's `%>`, whatever Ruby is open; :ruby (a Phlex view)
      # through its brackets; :markup (HAML, Slim) over the lines a trailing comma or backslash continues it onto.
      def self.template_kind(content, path)
        return RailsAiContext::ErbSource.tagged?(content) ? :erb : :ruby unless path
        return :erb if path.to_s.end_with?(".erb")

        path.to_s.end_with?(*RUBY_TEMPLATE_EXTENSIONS) ? :ruby : :markup
      end

      # The template with what Ruby never runs blanked, every offset kept: ERB through `ErbSource.masked`, parsing only
      # the tags that hold `word`, a Ruby template whole. HAML and Slim stay whole, and so does Ruby that cannot be read.
      def self.code_text(content, kind, word)
        case kind
        when :erb then RailsAiContext::ErbSource.masked(content, only: word)
        when :ruby then RailsAiContext::RubySource.code_only(content)
        else content
        end
      rescue => e
        RailsAiContext.debug_fail(e, content, label: "RenderCalls.code_text")
      end

      def self.call_text(text, kind)
        case kind
        when :erb then text[0...(text.index("%>") || text.length)]
        when :markup then continued_line(text)
        else text
        end
      end
      private_class_method :call_text

      # A call's text as Ruby reads it: parenthesised arguments to their closing paren, however many lines they take.
      def self.call_line(text, kind)
        text = call_text(text, kind)
        span = text.start_with?("(") && RailsAiContext::Brackets.span(text, 0, comments: :ruby)
        span ? span + continued_line(text[span.length..]) : continued_line(text)
      end
      private_class_method :call_line

      # The argument text with every nested (), [] and {} group dropped, so a
      # `template:` inside `locals: {...}` or `Foo.new(...)` is not the call's.
      def self.top_level(args)
        kept = +""
        RailsAiContext::Brackets.each_top_level(args, comments: :ruby) { |piece, kind| kept << piece unless %i[group comment].include?(kind) }
        kept
      end

      # "shared/_badge.html.erb" as a render call names it: "shared/badge".
      def self.canonical_name(partial_path)
        parts = partial_path.split("/")
        (parts[0...-1] + [ parts.last.delete_prefix("_").sub(/\..*\z/, "") ]).join("/")
      end

      # Block parameter => its builder's FormBuilder#to_partial_path ("form"; nil for a class without the _builder
      # suffix); a name not in the map is no builder. `f.fields_for`, `f.fields` and `g = f` keep f's builder class.
      # shortcut: builder names and `g = f` count template-wide, ERB and Phlex locals per line, HAML and Slim ones per template;
      # a handed-in local's `fields` (a record's too), default_form_builder: "form"; `(f).fields`, `g = @f`, `[f].each do |g|`:
      # none. Read block scope, callers and the controller when an app shows one of these.
      def self.form_builders(content, path: nil)
        return {} unless content.match?(FORM_BUILDER_WORD)

        locals = nil
        kind = template_kind(content, path)
        code_text(content, kind, FORM_BUILDER_WORD).to_enum(:scan, FORM_BUILDER_CALL).each_with_object({}) do |_, builders|
          match = Regexp.last_match
          source = match[1]
          # FormBuilder alone defines `fields`: its receiver is a known builder, a local handed in or one assigned
          # either, never another local the template's Ruby binds there. `fields_for` on any receiver is the helper.
          if match[2] && !match[3] && !builders.key?(source)
            next unless source

            lines, bound = locals ||= template_locals(content, path)
            source, own = bound.fetch([ (content[0...match.begin(0)].count("\n") + 1 if lines), source ], [ source, false ])
            next unless source && (builders.key?(source) || !own)
          end

          call = call_line(content[match.end(0)..], kind).split(/<%|%>/, 2).first
          param = block_param(call) or next

          builder = call[/\bbuilder:\s*(?:::)?([A-Z][\w:]*)/, 1]
          builders[param] = if builder then builder.demodulize.underscore[/\A(.+)_builder\z/, 1]
          else builders.fetch(source, "form")
          end
        end
      end

      # [lines?, map]: each `name.fields` on a local the template's Ruby binds, as Prism reads it, [line, name] => [the
      # local it was assigned from, whether the template binds that one], else [nil]. ERB compiles line for line;
      # HAML and Slim code loses its lines, so there the line is nil.
      def self.template_locals(content, path)
        pieces = RailsAiContext::MarkupSource.pieces(content, path)
        erb = !pieces && (path ? path.to_s.end_with?(".erb") : RailsAiContext::ErbSource.tagged?(content))
        ruby = if pieces then pieces.map(&:first).join("\n")
        elsif erb then RailsAiContext::ErbSource.compiled(content)
        else content
        end
        header = erb ? RailsAiContext::ErbSource.compiled_header_lines(ruby) : 0
        writes = {}
        reads = []
        stack = [ RailsAiContext::AstCache.parse_string(ruby).value ]
        while (node = stack.pop)
          stack.concat(node.compact_child_nodes)
          if node.is_a?(Prism::LocalVariableWriteNode)
            writes[node.name] = writes.key?(node.name) ? [ nil ] : assigned_local(node.value)
          elsif node.is_a?(Prism::CallNode) && node.name == :fields && node.receiver.is_a?(Prism::LocalVariableReadNode)
            reads << node.receiver
          end
        end
        [ !pieces, reads.to_h { |read| [ [ (read.location.start_line - header unless pieces), read.name.to_s ], writes.fetch(read.name, [ nil ]) ] } ]
      end
      private_class_method :template_locals

      # `g = f`: f's name and whether the template binds it; [nil] when the right side is anything else.
      def self.assigned_local(value)
        if value.is_a?(Prism::LocalVariableReadNode) then [ value.name.to_s, true ]
        elsif value.is_a?(Prism::CallNode) && value.variable_call? then [ value.name.to_s, false ]
        else [ nil ]
        end
      end
      private_class_method :assigned_local

      # The helper's own block parameter, as Ruby binds a block: a `do` at the call's top level, or a brace block
      # right after the helper or its parenthesised arguments (a later one is an argument's). None when a bracket
      # closes first, as in `%i[fields tags].each do`, or when a call chained on the parenthesised arguments takes it.
      def self.block_param(call)
        flat = +""
        RailsAiContext::Brackets.each_top_level(call, comments: :ruby) do |piece, kind|
          flat << (kind == :char ? piece : piece[/\A\{\s*\|\s*\w+/] || " ")
        end
        return if call.start_with?("(") && flat.match?(/\A\s*&?\./)

        block = flat.match(/\A\s*\{\s*\|\s*(\w+)|\bdo\s*\|\s*(\w+)/) or return
        block[1] || block[2] unless block.pre_match.match?(/[)\]}]/)
      end
      private_class_method :block_param

      # Every partial under the view roots by its canonical name, as a render call names it.
      def self.partials_on_disk(root)
        RailsAiContext::ViewFile.each(root, "**/_*").filter_map { |path, relative| canonical_name(relative) if RailsAiContext::ViewFile.template?(path) }.to_set
      end

      # The partials a render call's arguments name: a positional name, after which the hash is
      # locals, or what a leading options hash renders.
      def self.partial_names(args, block: false)
        args = bare_options(args)
        positional = args[RENDER_POSITIONAL, 2]
        return [ positional ] if positional
        return [] unless args.match?(OPTIONS_HASH)

        top = top_level(args)
        named = { "layout" => top[PARTIAL_LAYOUT, 1], "spacer_template" => top[SPACER_TEMPLATE, 1] }
        named["partial"] = top[PARTIAL_NAMED, 1] if top.match?(PARTIAL_KEY)
        options_partials(named, block: block)
      end

      # As RenderingHelper#render reads a leading options hash (key => string name, or nil):
      # with a block it renders the layout: as the partial, merged over any partial:;
      # without one a layout: and spacer_template: go with a partial:, and beside anything else a layout: is a layout.
      def self.options_partials(named, block:)
        keys = if block then %w[layout spacer_template]
        elsif named.key?("partial") then %w[partial layout spacer_template]
        else []
        end
        named.values_at(*keys).compact
      end

      # The partials and templates a render call's arguments name.
      def self.rendered_names(args, block: false)
        args = bare_options(args)
        names = partial_names(args, block: block)
        return names if block || !args.match?(OPTIONS_HASH)

        names + top_level(args).scan(TEMPLATE_NAMED).flatten
      end

      # The partial a render call's arguments name, positionally or as `partial:`.
      def self.rendered_name(args, block: false)
        rendered_names(args, block: block).first
      end

      # The partial a render name reaches from a view in `folder`, given the
      # canonical names of the partials on disk: a bare name is looked up under
      # the controller's prefixes, its own folder and then application.
      # `prefixes` are the folders of the controller that renders the view, nearest first; without
      # them the view's folder stands in (shortcut: a partial rendered from another controller resolves elsewhere).
      def self.partial_key(ref, folder, partials, prefixes: nil)
        return ref if ref.include?("/")

        if prefixes
          keys = (prefixes + [ "application" ]).uniq.map { |prefix| "#{prefix}/#{ref}" }
          return keys.find { |key| partials.include?(key) } || keys.first
        end
        own = folder == "." ? ref : "#{folder}/#{ref}"
        !partials.include?(own) && partials.include?("application/#{ref}") ? "application/#{ref}" : own
      end

      OPTIONS_HASH = /\A\s*(?:\w+:(?!:)|:\w+\s*=>)/
      HASH_KEY = /(?<![\w:])(\w+):(?!:)|(?<![\w:]):(\w+)\s*=>/
      LOCALS_HASH = /(?:\blocals:|:locals\s*=>)\s*(?=\{)/
      AS_NAME = /(?:\bas:|:as\s*=>)\s*:(\w+)/

      # The locals a render call hands its partial, as RenderingHelper#render
      # reads the arguments: after a positional name or record, the hash that
      # follows is the locals whole; an options hash passes its `locals:`.
      def self.render_locals(args)
        args = bare_options(args)
        return passed_locals(args) if args.match?(OPTIONS_HASH)

        rest = +""
        RailsAiContext::Brackets.each_top_level(args, comments: :ruby) { |piece, _kind| rest << piece unless rest.empty? && piece != "," }
        rest = rest.delete_prefix(",").strip
        hash_keys(rest.start_with?("{") ? RailsAiContext::Brackets.unwrap(rest) : rest)
      end

      # The locals an options hash passes: its `locals:` hash and the record
      # an `object:` or `collection:` hands over.
      def self.passed_locals(text)
        (locals_keys(text) + record_locals(text)).uniq
      end

      def self.locals_keys(text)
        found = text.match(LOCALS_HASH)
        found ? hash_keys(RailsAiContext::Brackets.span(text, found.end(0), comments: :ruby).to_s[1...-1].to_s) : []
      end

      # The names AbstractRenderer#local_variable gives the record: `as:` or
      # the partial's own name, with CollectionRenderer's _counter and _iteration.
      def self.record_locals(text, collection: nil)
        keys = hash_keys(text)
        collection = keys.include?("collection") if collection.nil?
        return [] unless collection || keys.include?("object")

        name = text[AS_NAME, 1] || (partial = rendered_name(text)) && canonical_name(partial).split("/").last
        return [] unless name

        collection ? [ name, "#{name}_counter", "#{name}_iteration" ] : [ name ]
      end

      # A hash's own keys, never those of a hash or call nested in a value.
      def self.hash_keys(text)
        flat = +""
        RailsAiContext::Brackets.each_top_level(text, comments: :ruby) do |piece, kind|
          flat << ({ group: " ", comment: " ", string: "''", literal: "''" }[kind] || piece)
        end
        flat.scan(HASH_KEY).map { |pair| pair.compact.first }.uniq
      end
    end
  end
end
