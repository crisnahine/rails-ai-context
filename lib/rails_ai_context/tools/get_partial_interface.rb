# frozen_string_literal: true

require "prism"

module RailsAiContext
  module Tools
    class GetPartialInterface < BaseTool
      tool_name "rails_get_partial_interface"
      description "Analyze a partial's interface: local variables it expects, where it's rendered from, and what methods are called on each local. " \
        "Use when: rendering a partial, understanding what locals to pass, or refactoring partial dependencies. " \
        "Specify partial:\"shared/status_badge\" to see its full interface. Supports both underscore-prefixed and non-prefixed names."

      input_schema(
        properties: {
          partial: {
            type: "string",
            description: "Partial path relative to app/views (e.g. 'shared/status_badge', 'users/form'). The leading underscore is optional."
          },
          detail: RailsAiContext::DetailLevel.schema("Detail level. summary: locals list + usage count. standard: locals + usage examples from codebase (default). full: locals + usage + full partial source.")
        },
        required: [ "partial" ]
      )

      guide_row(
        order: 17,
        mcp: "rails_get_partial_interface(partial:\"X\")",
        cli_args: "partial=X",
        summary: "Partial locals contract: what to pass + usage examples"
      )

      annotations(read_only_hint: true, destructive_hint: false, idempotent_hint: true, open_world_hint: false)

      def self.call(partial:, detail: "standard", server_context: nil)
        # Guard: required parameter
        if partial.nil? || partial.strip.empty?
          return text_response("The `partial` parameter is required. Provide a partial path relative to app/views (e.g. 'shared/status_badge').")
        end

        root = rails_app.root.to_s
        # Every views root the app has, so a partial an in-repo engine or
        # plugin keeps is found the way one under app/views is.
        view_dirs = RailsAiContext::PathResolver.view_dirs(root)
        views_dir = File.join(root, "app", "views")

        # Only the caller string is judged here; the candidate search below
        # decides whether the partial exists.
        guard = RailsAiContext::SafePath.locate(partial, under: views_dir, root: root)
        case guard.refusal
        when :traversal then return error_response("Path not allowed: #{echo_input(partial)}")
        when :sensitive then return error_response("Path not allowed: #{echo_input(partial)} (sensitive file)")
        end

        if view_dirs.empty?
          note = api_only_note("app/views", dir: "app/views")
          return text_response(note) if note

          return text_response("No app/views/ directory found.")
        end

        # A bare name is a name, not a path: an app has several `_form`, and the first in sorted
        # order would give one directory's locals for another's.
        same_name = view_dirs.flat_map { |dir| bare_name_matches(dir, partial) }
        if same_name.size > 1
          return empty_response(
            [ "Partial '#{partial}' matches #{count_phrase(same_name.size, 'file')}:", "",
              *same_name.map { |f| "- `#{view_relative(f, view_dirs)}`" }, "",
              "_Pass one with its directory, e.g. `#{view_relative(same_name.first, view_dirs).sub(%r{/_}, "/").sub(/\..*\z/, "")}`._" ].join("\n")
          )
        end

        located = view_dirs.lazy.filter_map { |dir| resolve_partial_path(dir, partial) }.first

        # The file the name resolves to, refused on policy: a link out of the app.
        case located&.refusal
        when :traversal, :outside then return error_response("Path not allowed: #{echo_input(partial)}")
        when :sensitive then return error_response("Path not allowed: #{echo_input(partial)} (sensitive file)")
        end

        unless located
          available = view_dirs.flat_map { |dir| find_available_partials(dir, root) }.uniq.sort.first(30)
          return not_found_response("Partial", partial, available,
            recovery_tool: call_pointer("rails_get_view", %(detail:"summary"), "to see all views and partials"), note: static_engine_views_note)
        end

        file_path = located.realpath
        if located.refusal == :too_large
          return text_response("Partial file too large: #{file_path} (#{File.size(file_path)} bytes, max: #{max_file_size})")
        end

        source = safe_read(file_path)
        return text_response("Could not read partial file.") unless source

        relative_path = located.relative
        # The resolved file, not the caller's spelling: a bare name has no
        # directory for a render site to be matched against.
        partial_name = view_relative(File.expand_path(relative_path, root), view_dirs)

        # Parse the partial's interface
        magic_locals = extract_magic_comment_locals(source)
        # One memo for every view root, so the prefix setting and each model are read once a call.
        records = {}
        on_disk = Introspectors::RenderCalls.partials_on_disk(root)
        render_sites = view_dirs.flat_map { |dir| find_render_sites(dir, partial_name, root, records, on_disk) } +
                       code_render_sites(root, Introspectors::RenderCalls.canonical_name(partial_name))
        # `_post.html.erb` and `_post.json.jbuilder` share a name but not their
        # callers: each renders only where its format is the one looked up.
        partial_format = template_format(file_path)
        render_sites = render_sites.select { |site| renders_format?(site, partial_format) }
        method_calls = {}

        # Primary: locals from render call sites (ground truth)
        render_locals = render_sites.flat_map { |rs| rs[:locals] || [] }.uniq

        # Secondary: local_assigns checks + defined? guards in partial source
        helpers = Introspectors::HelperNames.for(root)
        source_locals = if file_path.end_with?(".jbuilder")
          jbuilder_locals(source, helpers)
        else
          extract_local_variable_references(source, helpers, file_path)
        end

        # Combine: render-site locals first, then source-detected locals
        # Filter out noise: single chars, capitalized words, known helpers
        all_locals = (Array(magic_locals) + render_locals + source_locals).uniq
          .reject { |l| l.length <= 1 || l.match?(/\A[A-Z*]/) || l.match?(/\Arender_/) }
          .sort

        # Extract method calls only for confirmed locals
        method_calls = extract_method_calls_on_locals(source, all_locals, file_path) if all_locals.any?

        case detail
        when "summary"
          format_summary(partial_name, all_locals, magic_locals, render_sites)
        else
          format_detail(partial_name, relative_path, source, all_locals, magic_locals, render_sites, method_calls,
                        full: RailsAiContext::DetailLevel.full?(detail))
        end
      end

      private_class_method def self.format_summary(partial_name, all_locals, magic_locals, render_sites)
        lines = [ "# Partial: #{partial_name}", "" ]

        if all_locals.any?
          magic_note = magic_locals&.any? ? " (#{magic_locals.size} declared via magic comment)" : ""
          lines << "**Locals:** #{all_locals.join(', ')}#{magic_note}"
        else
          lines << "**Locals:** none detected"
        end

        lines << "**Rendered from:** #{count_phrase(render_sites.size, "location")}"
        lines << ""
        lines << "_Use `detail:\"standard\"` for usage examples, or `detail:\"full\"` for full partial source._"

        text_response(lines.join("\n"))
      end

      private_class_method def self.format_detail(partial_name, relative_path, source, all_locals, magic_locals, render_sites, method_calls, full:)
        lines = [ "# Partial: #{partial_name}", "" ]
        lines << "**File:** `#{relative_path}` (#{count_phrase(source.lines.size, "line")})"

        if magic_locals
          declared = magic_locals.any? ? magic_locals.join(", ") : "none, so passing any local raises"
          lines << "**Declared locals** (Rails 7.1+ magic comment): #{declared}"
        end

        if all_locals.any?
          lines << "" << "## Local Variables"
          all_locals.each do |local|
            methods = method_calls[local]
            if methods&.any?
              shown = full ? methods : methods.first(10)
              more = !full && methods.size > 10 ? ", ...and #{methods.size - 10} more" : ""
              lines << "- **#{local}** - calls: #{shown.join(', ')}#{more}"
            else
              lines << "- **#{local}**"
            end
          end
        elsif !full && !magic_locals
          lines << "" << "_No local variables detected in this partial._"
        end

        if render_sites.any?
          cap = full ? 25 : 15
          lines << "" << "## Rendered From (#{render_sites.size})"
          render_sites.first(cap).each do |site|
            locals_str = site[:locals].any? ? " - locals: #{site[:locals].join(', ')}" : ""
            lines << "- `#{site[:file]}:#{site[:line]}`#{locals_str}"
            next unless full && site[:snippet]

            lines << "  ```erb"
            lines << "  #{RailsAiContext::Redaction.redact_source(site[:snippet].strip, path: site[:file])}"
            lines << "  ```"
          end
          if render_sites.size > cap
            lines << "- _...and #{render_sites.size - cap} more_"
          end
        elsif !full
          lines << "" << "_No render calls found for this partial._"
        end

        if full
          lines << "" << "## Source"
          lines << "```erb"
          lines << RailsAiContext::Redaction.redact_source(source, path: relative_path)
          lines << "```"
        else
          add_next_hint(lines, pointer("rails_get_view", %(path:"#{partial_name}"), "for full file content"))
        end

        text_response(lines.join("\n"))
      end

      # Resolve a partial reference to an actual file path on disk.
      # Handles both underscore-prefixed filenames and non-prefixed input.
      # Falls back to recursive search when no directory is specified.
      private_class_method def self.resolve_partial_path(views_dir, partial)
        # Normalize: strip leading underscore from basename if provided
        parts = partial.split("/")
        basename = parts.last
        dir_parts = parts[0...-1]

        # Try with underscore prefix (standard Rails partial naming)
        prefixed_basename = basename.start_with?("_") ? basename : "_#{basename}"
        unprefixed_basename = basename.delete_prefix("_")

        # A fixed extension list refused `.text.erb`, which the Available
        # list built by globbing had just offered. Rails names a partial by
        # its directory and basename, whatever format and handler follow.
        # The plain file before a locale or variant one: Rails renders it for a request that asks for neither.
        plain_first = ->(paths) { paths.sort_by { |path| [ view_alternate_of(path) ? 1 : 0, path ] } }
        dir = File.join(views_dir, *dir_parts)
        candidates = [
          *plain_first.call(named_files(dir, prefixed_basename)),
          *plain_first.call(named_files(dir, unprefixed_basename)),
          File.join(views_dir, partial)
        ]

        found = candidates.find { |c| File.file?(c) }

        found = bare_name_matches(views_dir, partial).first if found.nil? && dir_parts.empty?

        return nil unless found

        # A refused file comes back with its refusal, so the caller says so rather than call it missing.
        located = RailsAiContext::SafePath.locate(found.delete_prefix(views_dir + File::SEPARATOR), under: views_dir, root: rails_app.root.to_s)
        located.refusal == :missing ? nil : located
      end

      # A view file's name as the app renders it: its path under the innermost
      # views root that holds it.
      private_class_method def self.view_relative(path, view_dirs)
        dir = RailsAiContext::ViewFile.root_for(path, view_dirs)
        dir ? path.delete_prefix(dir + File::SEPARATOR) : path
      end

      # Every partial of this name anywhere under app/views, for a caller who
      # gave a name with no directory. Empty for a path: that names one file.
      private_class_method def self.bare_name_matches(views_dir, partial)
        name = partial.to_s.strip
        return [] if name.include?("/")

        name = "_#{name}" unless name.start_with?("_")
        RailsAiContext::ViewFile.glob(rails_app.root.to_s, views_dir, "**/*").select { |c| File.basename(c).start_with?("#{name}.") && File.file?(c) }
      end

      # The entries of `dir` named `name.<format>.<handler>`. The caller's name is matched as written:
      # as a glob, each `{a,b}` in it doubled the lookups.
      private_class_method def self.named_files(dir, name)
        Dir.children(dir).select { |child| child.start_with?("#{name}.") }.map { |child| File.join(dir, child) }
      rescue SystemCallError
        []
      end

      # ActionView::Template::STRICT_LOCALS_REGEX as of Rails 8.0, held here so
      # the static tier reads the comment the same way.
      STRICT_LOCALS = /\#\s+locals:\s+\((.*?)\)(?=\s*-?%>|\s*$)/m

      # The names a strict locals comment declares; nil without one, [] for
      # `()`, which allows no locals at all.
      def self.extract_magic_comment_locals(source)
        list = source[STRICT_LOCALS, 1]
        return nil unless list

        result = RailsAiContext::AstCache.parse_string("def _(#{list}); end")
        return list.scan(/(\w+):/).flatten.uniq unless result.success?

        params = result.value.statements.body.first.parameters
        return [] unless params

        rest = params.keyword_rest
        params.keywords.map { |p| p.name.to_s } + (rest.is_a?(Prism::KeywordRestParameterNode) ? [ "**#{rest.name}" ] : [])
      rescue => e
        RailsAiContext.debug_fail(e, nil, label: "extract_magic_comment_locals")
      end

      # Extract local variable references from ERB source.
      # Locals are variables NOT prefixed with @ and NOT known Ruby/Rails globals.
      private_class_method def self.extract_local_variable_references(source, helpers = Set.new, path = nil)
        locals = Set.new
        # Known non-local identifiers to exclude
        known_non_locals = Set.new(%w[
          true false nil self yield render partial content_for
          form_for form_with form_tag fields_for button_to link_to
          image_tag stylesheet_link_tag javascript_include_tag
          csrf_meta_tags csp_meta_tag action_name controller_name
          content_tag tag concat raw html_safe j escape_javascript
          t translate l localize pluralize truncate number_to_currency
          number_with_delimiter number_to_percentage number_to_human
          simple_format sanitize strip_tags highlight excerpt
          time_ago_in_words distance_of_time_in_words
          debug inspect to_s to_i to_f to_a to_h
          each map select reject find collect detect any? all? none?
          first last size length count empty? blank? present?
          if else elsif unless case when end do begin rescue ensure
          class module def return break next raise
          puts print p require require_relative
          turbo_frame_tag turbo_stream_from turbo_stream
          capture provide request response params session flash cookies
          current_page? url_for polymorphic_path polymorphic_url
          new_record? persisted? errors model_name local_assigns
        ])

        erb = path.nil? || path.end_with?(".erb")
        template_nodes(source, path).each do |node|
          case node
          when Prism::StatementsNode
            next unless erb

            # 1. Standalone ERB output: <%= local_name %> or <%= local_name.method %>.
            # A name called with parentheses is a method, and one ending in
            # _path or _url a route helper: `dom_id(notification)` and
            # `mark_read_notification_path(notification)` were listed as locals.
            node.body.each do |statement|
              name = leading_name(statement)
              locals << name if name && !(known_non_locals.include?(name) || helpers.include?(name) || route_helper?(name))
            end
          when Prism::CallNode
            key = local_assigns_key(node)
            locals << key if key
          when Prism::DefinedNode
            # 2. defined?(local) guard pattern
            guarded = node.value
            locals << guarded.name.to_s if guarded.is_a?(Prism::CallNode) && guarded.variable_call?
          end
        end

        # Filter out things that are clearly method definitions or blocks
        locals.reject { |l| l.match?(/\A(each|map|select|reject|find|collect|do|end)\z/) }.to_a.sort
      rescue => e
        RailsAiContext.debug_fail(e, [], label: "extract_local_variable_references")
      end

      # Every node of the Ruby a template runs; text, HTML comments and `<%#`
      # comments are no Ruby, as ERB sends them to the page.
      private_class_method def self.template_nodes(source, path)
        template_ruby(source, path).flat_map do |ruby|
          Introspectors::AstWalk.each(RailsAiContext::AstCache.parse_string(ruby).value).to_a
        end
      end

      # The template's Ruby in pieces that each parse alone: ERB compiled
      # whole, each HAML or Slim piece, a Ruby template as it is.
      private_class_method def self.template_ruby(source, path)
        return [ RailsAiContext::ErbSource.compiled(source) ] if path.nil? || path.end_with?(".erb")

        pieces = RailsAiContext::MarkupSource.pieces(source, path)
        return pieces.map(&:first) if pieces

        path.end_with?(*Introspectors::RenderCalls::RUBY_TEMPLATE_EXTENSIONS) ? [ source ] : []
      end

      # The bare call a statement opens with, as a passed-in local parses (`row` in `row.title`);
      # nil for a block parameter or a local the template assigns.
      private_class_method def self.leading_name(node)
        until node.nil? || (node.is_a?(Prism::CallNode) && node.variable_call?)
          start = node.location.start_offset
          node = node.compact_child_nodes.find { |child| child.location.start_offset == start }
        end
        node&.name&.to_s
      end

      # `name` in local_assigns[:name] and local_assigns.fetch(:name).
      private_class_method def self.local_assigns_key(node)
        return unless %i[[] fetch].include?(node.name)

        receiver = node.receiver
        return unless receiver.is_a?(Prism::CallNode) && receiver.variable_call? && receiver.name == :local_assigns

        key = node.arguments&.arguments&.first
        key.unescaped if key.is_a?(Prism::SymbolNode)
      end

      # Every template a render site can sit in, jbuilder's Ruby included.
      SITE_GLOB = "**/*.{erb,haml,slim,jbuilder}"

      # Whether a site looks a partial of this format up: in the formats the
      # call names, else those its place gives it (nil for any).
      private_class_method def self.renders_format?(site, format)
        return true unless format

        formats = site.key?(:formats) ? site[:formats] : template_lookup(site[:file])
        formats.nil? || formats.include?(format)
      end

      # A template looks in its own format: a json.jbuilder in json, an
      # html.erb in html, and one whose name gives none in any. A
      # turbo_stream template looks in html too (Turbo's request accepts
      # html), as a js one does (Rails' html fallback for js).
      private_class_method def self.template_lookup(file)
        own = template_format(file) or return nil
        %w[turbo_stream js].include?(own) ? [ own, "html" ] : [ own ]
      end

      # `render partial: "posts/post", formats: [:json]`: the formats a call
      # names, which Rails looks the partial up in whatever the request asked.
      # Action View reads `options[:formats]` alone, from the hash it renders
      # with: the one holding `partial:`, or json.partial!'s keywords. So a
      # `format:` is a local, as is any key inside `locals: {}`, and in
      # `render "shared/date", date: d, format: :short` every key is one.
      FORMATS_OPTION = /(?<![\w:])(?:formats:|:formats\s*=>)\s*(?:%[iIwW])?(\[[^\]]*\]|:\w+|["']\w+["'])/

      # The formats the options beside offset `at` name: those of the
      # innermost bracket group holding it, or of the whole call, read with
      # each hash and call nested there blanked. nil for no offset, which a
      # call that names its partial first has.
      private_class_method def self.named_formats(call, at)
        return nil unless at

        level = +""
        RailsAiContext::Brackets.each_top_level(call, comments: :ruby) do |piece, kind|
          from = level.length
          return named_formats(piece[1...-1], at - from - 1) if kind == :group && at > from && at < from + piece.length - 1

          nested = kind == :comment || (kind == :group && !piece.start_with?("["))
          level << (nested ? " " * piece.length : piece)
        end
        code = code_of(level)
        level.to_enum(:scan, FORMATS_OPTION).map { Regexp.last_match }.find { |found| code[found.begin(0)] != " " }&.[](1)&.scan(/\w+/)
      end

      # `text` with every string, literal and comment blanked, inside brackets
      # too, so a key found in it is code; each offset still points at `text`.
      private_class_method def self.code_of(text)
        out = +""
        RailsAiContext::Brackets.each_top_level(text, comments: :ruby) do |piece, kind|
          out << case kind
          when :char then piece
          when :group then piece[0] + code_of(piece[1...-1]) + piece[-1]
          else piece.tr("^\n", " ")
          end
        end
        out
      end

      # Where a render names the partial as its `partial:` option, or nil
      # where it names it first, as the shorthand does.
      private_class_method def self.partial_key_at(line, name)
        code = code_of(line)
        line.to_enum(:scan, /(?:\bpartial:|:partial\s*=>)\s*(["'])#{Regexp.escape(name)}\1/).map { Regexp.last_match.begin(0) }.find { |at| code[at] != " " }
      end

      # The formats a call in Ruby renders its partial in when it names none.
      # A Turbo Stream builder renders html, and so do a broadcast and
      # ApplicationController.render outside a request. In a controller or a
      # helper the request decides, html or json alike, unless the call sits
      # in a `format.json { }` block of a respond_to.
      private_class_method def self.code_site_formats(call, relative, line, format_blocks)
        return [ "html" ] if code_of(call).match?(/\bturbo_stream\.\w+/)

        block = format_blocks.select { |from, to, _| from <= line && line <= to }.max_by(&:first)
        return (block.last == "any" ? nil : [ block.last ]) if block
        return nil if relative.match?(%r{(?:\A|/)app/(?:controllers|helpers)/})

        [ "html" ]
      end

      # [first line, last line, format] of each `format.json { }` block a
      # respond_to holds, whatever its block names the collector.
      private_class_method def self.format_blocks(content)
        blocks = []
        visit = lambda do |node|
          if node.is_a?(Prism::CallNode) && node.name == :respond_to && node.block.is_a?(Prism::BlockNode)
            param = node.block.parameters&.parameters&.requireds&.first
            collector = param.respond_to?(:name) ? param.name : nil
            collect = lambda do |inner|
              if inner.is_a?(Prism::CallNode) && inner.block && inner.receiver.is_a?(Prism::LocalVariableReadNode) && inner.receiver.name == collector
                blocks << [ inner.block.location.start_line, inner.block.location.end_line, inner.name.to_s ]
              end
              inner.compact_child_nodes.each(&collect)
            end
            collect.call(node.block)
          end
          node.compact_child_nodes.each(&visit)
        end
        visit.call(RailsAiContext::AstCache.parse_string(content).value)
        blocks
      rescue => e
        RailsAiContext.debug_fail(e, [], label: "format_blocks")
      end

      # A template's format as its name gives it; jbuilder's handler writes
      # json, its default format, when the name gives none.
      private_class_method def self.template_format(path)
        RailsAiContext::ViewFile.format_of(path) || ("json" if path.end_with?(".jbuilder"))
      end

      private_class_method def self.route_helper?(name)
        name.match?(/_(?:path|url)\z/)
      end

      # Names Ruby cannot tell from a method call at parse time that a jbuilder
      # template reads without defining them itself.
      JBUILDER_NON_LOCALS = %w[json local_assigns params request controller current_page? render cache!].to_set.freeze

      # A jbuilder partial is Ruby throughout, so the ERB tag scan found none
      # of its locals: `invoice` in api/v1/invoices/_invoice.json.jbuilder.
      # A local reads as a bare name the file never assigns, which Prism marks
      # as a variable call; a helper or a route helper is not one.
      private_class_method def self.jbuilder_locals(source, helpers)
        names = Set.new
        visit = lambda do |node|
          names << node.name.to_s if node.is_a?(Prism::CallNode) && node.variable_call?
          node.compact_child_nodes.each(&visit)
        end
        visit.call(RailsAiContext::AstCache.parse_string(source).value)
        names.reject { |name| JBUILDER_NON_LOCALS.include?(name) || helpers.include?(name) || route_helper?(name) }.sort
      rescue => e
        RailsAiContext.debug_fail(e, [], label: "jbuilder_locals")
      end

      # Where a partial is named outside a render call: turbo_stream.prepend
      # in a .turbo_stream.erb, broadcast_prepend_to in a model, json.partial!
      # and json.array! in jbuilder. Ruby code outside the views names a
      # partial by its full path, since it has no view directory of its own.
      CODE_DIRS = %w[app/models app/controllers app/jobs app/channels app/helpers].freeze
      # The options jbuilder keeps from a partial's locals; every other key is one.
      JBUILDER_OPTIONS = %w[partial as collection cached].freeze

      private_class_method def self.partial_arg_sites(content, relative, names, skip_spans: [], code: false)
        lines = content.lines
        sites = []
        blocks = nil
        reader = Introspectors::RenderCalls
        kind = reader.template_kind(content, relative)
        ruby_code = reader.code_text(content, kind, /partial/) unless kind == :markup
        content.to_enum(:scan, reader::PARTIAL_ARG).each do
          match = Regexp.last_match
          at = match.begin(0)
          next unless names.include?(match[2])
          next if skip_spans.any? { |from, to| at >= from && at < to }
          next if ruby_code && ruby_code[at] == " "
          next if ruby_code && reader.nested_hash_key?(ruby_code, at)

          # The line the call starts on, which a trailing comma carries onto this one.
          start = content[0...at].count("\n")
          start -= 1 while start.positive? && lines[start - 1].rstrip.end_with?(",")
          call = call_lines(lines, start)
          site = { file: relative, line: start + 1, locals: partial_call_locals(call), snippet: call.squish }
          # The name's own offset in the call: the options it is rendered
          # with sit beside it, inside json.partial!'s parentheses too.
          named = named_formats(call, match.begin(1) - lines.first(start).sum(&:length))
          if code
            site[:formats] = named || code_site_formats(call, relative, start + 1, blocks ||= format_blocks(content))
          elsif named
            site[:formats] = named
          end
          sites << site
        end
        sites
      end

      # The line a call starts on and every line a trailing comma carries it onto.
      private_class_method def self.call_lines(lines, index)
        taken = []
        lines[index..].each do |line|
          taken << line
          break unless line.split("%>", 2).first.rstrip.end_with?(",")
        end
        taken.join.split("%>", 2).first
      end

      # The locals a call hands the partial: its `locals:` hash and the record
      # it renders, or for jbuilder without `locals:` every other key, as
      # JbuilderTemplate#_render_partial_with_options reads its options.
      private_class_method def self.partial_call_locals(call)
        reader = Introspectors::RenderCalls
        code = code_of(call)
        found = code.match(/\bjson\.(partial!)\s*/) || code.match(/\A\s*json\.(\w+!?)\s*/)
        return reader.passed_locals(call) unless found

        verb = found[1]
        args = RailsAiContext::Brackets.unwrap(call[found.end(0)..].strip)
        keys = reader.hash_keys(args)
        own = keys.include?("locals") ? reader.locals_keys(args) : keys - JBUILDER_OPTIONS
        records = case verb
        when "partial!" then reader.record_locals(args)
        when "array!" then reader.record_locals(args, collection: true)
        # Any other json.<key> hands its value over under the `as:` name.
        else [ args[reader::AS_NAME, 1] ].compact
        end
        (own + records).uniq
      end

      private_class_method def self.code_render_sites(root, canonical)
        CODE_DIRS.flat_map { |kind| RailsAiContext::PathResolver.dirs_for(root, kind) }.uniq.flat_map do |dir|
          RailsAiContext::FileWalk.glob(dir, "**/*.rb", root: root).flat_map do |path|
            content = safe_read(path)
            next [] unless content&.include?(canonical)

            partial_arg_sites(content, RailsAiContext::PortablePath.relativize(path, root), [ canonical ], code: true)
          end
        end
      rescue => e
        RailsAiContext.debug_fail(e, [], label: "code_render_sites")
      end

      # Find all views that render this partial and extract the locals they pass.
      private_class_method def self.find_render_sites(views_dir, partial, root, records, on_disk)
        sites = []
        reader = Introspectors::RenderCalls
        # A render names the partial whole ("shared/status_badge") or bare, from a folder it is looked up in.
        canonical = reader.canonical_name(partial)
        basename = canonical.split("/").last

        view_files = RailsAiContext::ViewFile.glob(root, views_dir, SITE_GLOB)
        view_files.each do |file|
          content = safe_read(file)
          next unless content

          relative = RailsAiContext::PortablePath.relativize(file, root)
          view_dir = File.dirname(file.delete_prefix(views_dir + File::SEPARATOR))
          names = [ canonical, basename ].uniq.select { |name| reader.partial_key(name, view_dir, on_disk) == canonical }

          lines = content.lines
          builders = reader.form_builders(Introspectors::ViewTemplateIntrospector.strip_markup_comments(content), path: file)
          # Per call, not per line: `render(` and a call split over lines are
          # one call whose arguments the line alone does not hold.
          covered = 0
          spans = []
          reader.render_calls(content, path: file).each do |at, args, block|
            spans << [ at, at + args.length ]
            # A render inside the arguments of a call already credited is part of that call's site.
            next if at < covered

            line_num = content[0...at].count("\n") + 1
            line = reader.render_line(args)
            spanned = lines[(line_num - 1)..(line_num - 1 + args.chomp.count("\n"))]
            snippet = spanned.size > 1 ? spanned.join(" ").squish : lines[line_num - 1].strip

            matched_line = false
            rendered = reader.partial_names(args, block: block)
            names.each do |search_name|
              # Match render "partial_name" or render partial: "partial_name",
              # the name whole: "comments/form" is another directory's form.
              next unless rendered.include?(search_name)

              locals_passed = reader.render_locals(args)

              site = { file: relative, line: line_num, locals: locals_passed, snippet: snippet }
              named = named_formats(line, partial_key_at(line, search_name))
              site[:formats] = named if named
              sites << site
              covered = at + args.length
              matched_line = true
              break # one match per call is enough
            end

            next if matched_line

            chain = line[reader::IMPLICIT_RENDER, 1]
            next unless chain && !line.include?("partial:")

            partial = builders.fetch(chain) do
              Introspectors::RenderedRecord.rendered_partial(chain, view_dir, root, records, booted: booted_app?, partials: on_disk)
            end
            next unless partial && reader.partial_key(partial, view_dir, on_disk) == canonical

            sites << { file: relative, line: line_num, locals: [], snippet: snippet }
            covered = at + args.length
          end

          sites.concat(partial_arg_sites(content, relative, names, skip_spans: spans))
        end

        sites
      rescue => e
        RailsAiContext.debug_fail(e, [], label: "find_render_sites")
      end

      # Extract method calls made on each local variable within the partial.
      private_class_method def self.extract_method_calls_on_locals(source, locals, path = nil)
        calls = {}
        return calls if locals.empty?

        wanted = locals.to_set
        template_nodes(source, path).each do |node|
          # local.method_name or local&.method_name
          next unless node.is_a?(Prism::CallNode) && %w[. &.].include?(node.call_operator)

          receiver = node.receiver
          next unless (receiver.is_a?(Prism::CallNode) && receiver.variable_call?) || receiver.is_a?(Prism::LocalVariableReadNode)
          next unless wanted.include?(receiver.name.to_s)

          method_name = node.name.to_s.sub(/(?<=\w)=\z/, "")
          next unless method_name.match?(/\A\w+[?!]?\z/)
          # Exclude common Ruby/ERB noise
          next if %w[to_s to_i to_f to_a to_h to_json to_param inspect class nil? is_a? respond_to? send freeze dup clone].include?(method_name)

          (calls[receiver.name.to_s] ||= Set.new) << method_name
        end

        calls.transform_values { |methods| methods.to_a.sort }
      rescue => e
        RailsAiContext.debug_fail(e, {}, label: "extract_method_calls_on_locals")
      end

      # Find available partials for fuzzy matching in not_found_response.
      private_class_method def self.find_available_partials(views_dir, root)
        RailsAiContext::ViewFile.glob(root, views_dir, File.join("**", "_*")).select { |f| File.file?(f) && RailsAiContext::ViewFile.template?(f) }.map do |f|
          relative = f.sub("#{views_dir}/", "")
          # Strip underscore prefix and extension for display
          parts = relative.split("/")
          parts[-1] = parts[-1].delete_prefix("_").sub(/\..*\z/, "")
          parts.join("/")
        end.uniq.sort.first(30)
      rescue => e
        RailsAiContext.debug_fail(e, [], label: "find_available_partials")
      end
    end
  end
end
