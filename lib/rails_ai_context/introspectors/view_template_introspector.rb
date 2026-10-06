# frozen_string_literal: true

require "prism"

module RailsAiContext
  module Introspectors
    # Reads actual view template contents and extracts metadata:
    # partial references, Stimulus controller usage, line counts.
    # Separate from ViewIntrospector which focuses on structural discovery.
    #
    # Every extractor here is regex by design. The same matcher runs over ERB,
    # HAML, Slim and Phlex `.rb` views, and only the last of those has a Ruby
    # AST. Splitting the Phlex path onto listeners would mean two definitions
    # of "what a partial reference is" that could drift apart.
    class ViewTemplateIntrospector < Base
      extend StaticTier
      static_tier :files_only

      # The buffer and path locals ERB itself sets are not the controller's.
      RENDER_LOCALS = %w[output_buffer virtual_path _request].freeze

      # A word character before the `@` makes it an address, and a second `@`
      # makes it a class variable; neither is an ivar the controller assigned.
      # A digit cannot open an ivar name either, so `:'@1x'` is a symbol.
      IVAR = /(?<![\w@])@([A-Za-z_]\w*)/

      def call
        views_dir = File.join(root, "app", "views")

        {
          templates: scan_templates(views_dir),
          partials: scan_partials(views_dir)
        }
      end

      # Template handlers whose whole source is Ruby.
      RUBY_TEMPLATE_EXTENSIONS = %w[.rb .jbuilder .builder .ruby].freeze

      # The one reader of a template's ivars, so `get_view` and this
      # introspector cannot disagree about what a template uses. Only the Ruby
      # inside ERB tags: over the whole file the regex read the CSS rule
      # `@page` as an ivar the controller assigns.
      def self.ivars_in(content, path: nil)
        text = content.to_s
        erb = path ? path.to_s.end_with?(".erb") : RailsAiContext::ErbSource.tagged?(text)
        ruby = erb ? RailsAiContext::ErbSource.tag_bodies(text) : text
        # Only where what is left is Ruby. A HAML or Slim template is prose
        # with Ruby lines in it, and its apostrophes are apostrophes: reading
        # them as string quotes swallows every ivar between two of them.
        ruby = strip_string_literals(ruby) if erb || path.to_s.end_with?(*RUBY_TEMPLATE_EXTENSIONS)
        ruby.scan(IVAR).flatten.uniq.reject { |v| RENDER_LOCALS.include?(v) }.sort
      end

      # Detect whether a view file is a Phlex view (Ruby DSL, not ERB)
      def self.phlex_view?(path, content)
        return false unless path.end_with?(".rb")
        # Check for Phlex class patterns: inherits from a View/Base class and defines view_template
        content.match?(/class\s+\S+\s*<\s*\S+/) && content.match?(/def\s+view_template\b/)
      end

      # Extract component render calls from Phlex Ruby DSL
      # Matches: render ComponentName.new(...), render(ComponentName.new(...))
      # Also matches: render Components::Nested::Name.new(...)
      def self.extract_phlex_component_renders(content)
        components = Set.new
        content.scan(/render[\s(]+([A-Z]\w+(?:::\w+)*)\.new/).each do |match|
          components << match[0]
        end
        components.to_a.sort
      end

      # A data attribute written as HTML (`=`) or as a HAML/Ruby hash key
      # (`=>` or `:`). One builder so every scan reads all three spellings.
      def self.data_attr(name)
        /#{Regexp.escape(name)}["']?\s*(?:=>|=|:)\s*["']([^"']*)["']/
      end

      DATA_CONTROLLER_ATTR = data_attr("data-controller")

      # `data: { controller: "x" }` in markup, never the routing `url_for(controller: "x")`.
      DATA_HASH_CONTROLLER = /\bdata:\s*\{[^}]*\bcontroller:\s*["']([^"']+)["']/

      # Phlex keyword attribute: data_controller: "x".
      PHLEX_CONTROLLER_ATTR = /\bdata_controller:\s*["']([^"']+)["']/

      # Every Stimulus controller an element in this template declares.
      def self.stimulus_refs(content)
        [ DATA_CONTROLLER_ATTR, DATA_HASH_CONTROLLER, PHLEX_CONTROLLER_ATTR ]
          .flat_map { |pattern| content.scan(pattern).flat_map { |m| m[0].split } }
          .uniq
      end

      # An app's own helper names its controller as surely as data-controller does.
      IDENTIFIER_HELPER = /\b(?:content|body)_controller\s*\(?\s*["']([\w-]+)["']/
      TARGET_ATTR = /\bdata-([\w-]+?)-target\s*[:=]/
      TARGET_KEY = /["']([\w-]+?)-target["']\s*(?:=>|:)/
      # One descriptor: optional `event.filter->`, `identifier#method`, then `:options`.
      ACTION_DESCRIPTOR = /(?:\A|\s)([\w:.@+-]+->)?([\w-]+)#\w+((?::\w+)*)(?=\s|\z)/
      # A markup key and its quoted value: `data-action="..."`, `"data-action" => "..."`,
      # `hiddenFieldAction: "..."`; `action_key_kind` decides whether it is an action.
      KEY_VALUE = /(?<![\w-])["']?([A-Za-z_][\w-]*)["']?\s*(?:=>|=|:)\s*(["'])((?:(?!\2).)*)\2/m
      DATA_HASH = /\bdata:\s*(?=\{)/
      # `data-action`, `confirm_actions`, `hiddenFieldAction`, `REFRESH_ACTION`. A bare
      # `action` outside a data hash can list routes, so it is read strictly.
      ACTION_KEY = /\A(?:[\w-]*[_-]actions?|[a-z]\w*Actions?|[A-Z][A-Z0-9_]*_ACTIONS?)\z/
      BARE_ACTION = /\A(?:actions?|ACTIONS?)\z/
      CONTROLLER_KEY = /\Adata[-_]controller\z/

      # Every identifier a file names, however: wider than `stimulus_refs`, since a
      # file that only sets a target or an action still says what it is called.
      def self.stimulus_identifiers(content, ruby: false)
        content = content.gsub(/^\s*#.*$/, "") if ruby
        (stimulus_refs(content) +
          [ IDENTIFIER_HELPER, TARGET_ATTR, TARGET_KEY ].flat_map { |pattern| content.scan(pattern).flatten } +
          (ruby ? ruby_identifiers(content) : action_identifiers(content))).uniq
      end

      # Descriptors are read inside quoted values only, so `users#show` in
      # prose is not a controller.
      # The one rule for an action key, in markup and Ruby alike: a named action key
      # is read whole, a bare `action` strictly unless it sits in a data hash.
      def self.action_descriptors(name, values, in_data_hash:)
        if name.match?(ACTION_KEY) || (in_data_hash && name.match?(BARE_ACTION))
          values.flat_map { |value| descriptors_in(value) }
        elsif name.match?(BARE_ACTION)
          values.flat_map { |value| descriptors_in(value, strict: true) }
        else
          []
        end
      end

      def self.action_identifiers(content)
        found = content.scan(KEY_VALUE).flat_map { |key, _quote, value| action_descriptors(key, [ value ], in_data_hash: false) }
        content.to_enum(:scan, DATA_HASH).each do
          hash = RailsAiContext::Brackets.span(content, Regexp.last_match.end(0), comments: :ruby) or next
          found.concat(hash.scan(KEY_VALUE).flat_map { |key, _quote, value| action_descriptors(key, [ value ], in_data_hash: true) })
        end
        found
      end

      # `strict`: only a descriptor with an event or an option, since outside a data
      # hash a bare `controller#action` is as likely a Rails route.
      def self.descriptors_in(value, strict: false)
        value.scan(ACTION_DESCRIPTOR).filter_map do |event, identifier, options|
          identifier unless strict && event.nil? && options.empty?
        end
      end

      # A Ruby file's identifiers through its AST: `controller:` in a `data` hash
      # (`tag.div(data: {...})`, `data = {...}`), and an action key's or variable's value.
      def self.ruby_identifiers(source)
        return [] unless (source.include?("controller") && source.include?("data")) || source.match?(/action/i)

        root = AstCache.parse_uncached(source).value

        found = []
        AstWalk.each(root) do |node|
          # A method named for data attributes (`def data`, `def card_data`) returns a data hash.
          if node.is_a?(Prism::DefNode) && node.name.to_s.match?(/\A(?:\w+_)?data\z/)
            Array(node.body&.then { |b| b.is_a?(Prism::StatementsNode) ? b.body : [ b ] }).each { |n| data_controllers(n, found) }
            next
          end

          name, value =
            case node
            when Prism::AssocNode
              [ key_name(node.key), node.value ]
            when Prism::LocalVariableWriteNode, Prism::InstanceVariableWriteNode, Prism::ConstantWriteNode
              [ node.name.to_s.delete_prefix("@"), node.value ]
            end
          next unless name

          data_controllers(value, found) if name == "data"
          found.concat(string_parts(value).flat_map(&:split)) if name.match?(CONTROLLER_KEY)
          found.concat(action_descriptors(name, string_parts(value), in_data_hash: false))
        end
        found.uniq
      rescue StandardError, ScriptError => e
        RailsAiContext.debug_fail(e, [], label: "ruby_identifiers")
      end

      def self.key_name(key)
        key.unescaped if key.is_a?(Prism::SymbolNode) || key.is_a?(Prism::StringNode)
      end

      # The literal text in a value: every string in it, both branches of a
      # conditional, the fixed parts of an interpolation.
      def self.string_parts(node)
        AstWalk.each(node).select { |n| n.is_a?(Prism::StringNode) }.map(&:unescaped)
      end

      def self.data_controllers(hash, found)
        return unless hash.is_a?(Prism::HashNode) || hash.is_a?(Prism::KeywordHashNode)

        hash.elements.each do |element|
          next unless element.is_a?(Prism::AssocNode) && element.key.is_a?(Prism::SymbolNode)

          key = element.key.unescaped
          if key == "controller"
            found.concat(element.value.unescaped.split) if element.value.is_a?(Prism::StringNode)
          else
            found.concat(action_descriptors(key, string_parts(element.value), in_data_hash: true))
          end
        end
      end
      private_class_method :key_name, :string_parts, :data_controllers

      # Extract helper method calls from Phlex views
      # Phlex views use include to pull in helpers, and call them directly
      PHLEX_HELPER_METHODS = %w[
        link_to image_tag content_for button_to form_with form_for
        content_tag tag number_to_currency number_to_human
        time_ago_in_words distance_of_time_in_words
        truncate pluralize raw sanitize dom_id
      ].freeze

      def self.extract_phlex_helper_calls(content)
        PHLEX_HELPER_METHODS.select { |method| content.match?(/\b#{method}\b/) }
      end

      private

      def scan_templates(_views_dir)
        templates = {}
        RailsAiContext::ViewFile.each(root).each do |path, relative|
          next if File.basename(path).start_with?("_") # skip partials
          next if path.include?("/layouts/")
          # An asset that happens to sit under app/views is not a template:
          # counted as one, and the ivar regex read names out of its bytes.
          next unless RailsAiContext::ViewFile.template?(path)

          content = RailsAiContext::SafeFile.read(path) or next
          markup = self.class.strip_markup_comments(content)

          slots = extract_slot_refs(markup)

          entry = {
            lines: content.lines.count,
            ivars: extract_ivars(markup, path),
            partials: extract_partial_refs(markup),
            stimulus: extract_stimulus_refs(markup)
          }
          if self.class.phlex_view?(path, content)
            entry.merge!(
              components: self.class.extract_phlex_component_renders(markup),
              helpers: self.class.extract_phlex_helper_calls(markup),
              phlex: true
            )
          end
          entry[:slots] = slots unless slots.empty?
          templates[relative] = entry
        end
        templates
      end

      # A string literal inside a tag body is text the template prints, so a
      # `@handle` in it names no instance variable - a Slack user id in a
      # quoted string was reported as the template's interface. What a double
      # quoted string interpolates is code, and an ivar read there is real, so
      # only the interpolations survive.
      def self.strip_string_literals(ruby)
        # One line at a time. A Ruby literal may span lines and rarely does in
        # a template, while an apostrophe in a comment is ordinary: read as an
        # opening quote it swallowed every line up to the next apostrophe, and
        # every ivar in between with it. One pass, so whichever quote opens
        # first owns the literal: `"Don't"` is not the start of a single-quoted
        # string.
        ruby.lines.map { |line|
          line.gsub(/"(?:\\.|[^"\\\n])*"|'(?:\\.|[^'\\\n])*'/) do |literal|
            literal.start_with?('"') ? literal.scan(/#\{.*?\}/).join(" ") : "''"
          end
        }.join
      end

      # Blanks HAML `-#` comments (and what is indented under them) and ERB `<%# %>`
      # tags, keeping their lines so nothing else shifts.
      def self.strip_markup_comments(content)
        return content unless content.include?("-#") || content.include?("<%#") || content.include?("<%-#")

        block_indent = nil
        content.gsub(/<%-?#.*?%>/m, "").lines.map { |line|
          indent = line[/\A[ \t]*/].length
          if block_indent && (line.strip.empty? || indent > block_indent)
            "\n"
          elsif (opener = line.match(/\A([ \t]*)-#/))
            block_indent = opener[1].length
            "\n"
          else
            block_indent = nil
            line
          end
        }.join
      end

      def extract_ivars(content, path = nil)
        self.class.ivars_in(content, path: path)
      end

      def scan_partials(_views_dir)
        partials = {}
        RailsAiContext::ViewFile.each(root, "**/_*").each do |path, relative|
          next unless RailsAiContext::ViewFile.template?(path)
          content = RailsAiContext::SafeFile.read(path) or next
          markup = self.class.strip_markup_comments(content)
          partials[relative] = {
            lines: content.lines.count,
            fields: extract_model_fields(markup),
            helpers: extract_helper_calls(markup)
          }
        end
        partials
      end

      EXCLUDED_METHODS = %w[
        each map select reject first last size count any? empty? present? blank?
        new build create find where order limit nil? join class html_safe
        to_s to_i to_f inspect strip chomp downcase upcase capitalize
        humanize pluralize singularize truncate gsub sub scan match split
        freeze dup clone length bytes chars reverse uniq compact flatten
        flat_map zip sort sort_by min max sum group_by
        persisted? new_record? valid? errors reload save destroy update
        delete respond_to? is_a? kind_of? send try
        abs round ceil floor
        strftime iso8601 beginning_of_day end_of_day ago from_now
      ].freeze

      def extract_model_fields(content)
        fields = []
        # Only extract from @variable.field patterns (instance variable receivers)
        content.scan(/@\w+\.(\w+)/).each do |m|
          field = m[0]
          next if field.length < 3 || field.length > 40
          next if field.match?(/\A[0-9a-f]+\z/)
          next if field.match?(/\A[A-Z]/)
          next if EXCLUDED_METHODS.include?(field)
          next if field.start_with?("to_", "html_")
          next if field.end_with?("?", "!")
          fields << field
        end
        # Also extract from form helper symbols: f.text_field :name, f.select :status
        content.scan(/f\.\w+(?:_field|_area|_select)?\s+:(\w+)/).each do |m|
          fields << m[0] if m[0].length >= 2
        end
        fields.uniq.first(15)
      end

      def extract_helper_calls(content)
        helpers = []
        # Custom helper methods (render_*, format_*, *_path, *_url)
        content.scan(/\b(render_\w+|format_\w+)\b/).each { |m| helpers << m[0] }
        helpers.uniq
      end

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
      RENDER_NAMED = /(?:\b(?:partial|template)\s*:|:(?:partial|template)\s*=>)\s*["']([^"']+)["']/
      # `render @posts`, `render(post)`, `render @posts, cached: true`: a bare record or collection, or a
      # chain on one (`@post.comments.recent`), matched against "render <args>"; RenderedRecord reads the chain.
      IMPLICIT_RENDER = /\Arender\s*\(?\s*@?((?:[a-z_]\w*\.)*[a-z_]\w*)\s*(?:[,)]|\s(?:if|unless)\b|-?\s*\z)/

      def extract_partial_refs(content)
        refs = []
        # The partial or template a render call names, positionally or as a
        # keyword anywhere in its arguments, with or without parentheses.
        self.class.render_calls(content).each do |_, args|
          named = [ args[RENDER_POSITIONAL, 2], *top_level(args).scan(RENDER_NAMED).flatten ].compact
          # An interpolated name is decided at runtime, not a partial on disk.
          refs.concat(named.select { |name| name.match?(PARTIAL_NAME) })
          chain = self.class.render_line(args)[IMPLICIT_RENDER, 1] if named.empty?
          name, model = chain && !RENDER_KEYWORD_ARGS.include?(chain) && RenderedRecord.resolve(chain, root, @rendered_models ||= {})
          # The records' model names the partial; `replies` with class_name "Comment" renders comments/_comment.
          refs << (name == name.singularize ? model : model.pluralize) if model
        end
        # Phlex: render ComponentName.new(...) or render(ComponentName.new(...))
        content.scan(/render[\s(]+([A-Z]\w+(?:::\w+)*)\.new/).each { |m| refs << m[0] }
        refs.uniq
      end

      # A render call's ERB-free arguments on one line, as IMPLICIT_RENDER reads them.
      def self.render_line(args)
        "render #{args.split("%>", 2).first.gsub(/\s+/, " ").strip}"
      end

      # Each render call as [offset, argument text]: its balanced parentheses,
      # or the rest of the line and every line a trailing comma continues onto.
      def self.render_calls(content)
        content.to_enum(:scan, RENDER_CALL).map do
          at = Regexp.last_match.end(0)
          rest = content[at..]
          open = rest[/\A\s*\(/]
          next [ at, continued_line(rest) ] unless open

          span = RailsAiContext::Brackets.span(rest, open.length - 1, comments: :ruby)
          [ at, span ? span[1...-1] : rest[open.length..] ]
        end
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

      # The argument text with every nested (), [] and {} group dropped, so a
      # `template:` inside `locals: {...}` or `Foo.new(...)` is not the call's.
      def top_level(args)
        kept = +""
        RailsAiContext::Brackets.each_top_level(args, comments: :ruby) { |piece, kind| kept << piece unless %i[group comment].include?(kind) }
        kept
      end

      def extract_stimulus_refs(content)
        self.class.stimulus_refs(content)
      end

      def extract_slot_refs(content)
        content.scan(/\b(?:renders_one|renders_many)\s+:(\w+)/).flatten
      rescue => e
        RailsAiContext.debug_fail(e, [], label: "extract_slot_refs")
      end
    end
  end
end
