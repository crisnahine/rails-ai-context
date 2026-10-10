# frozen_string_literal: true

module RailsAiContext
  module Introspectors
    # N+1 risks read the way one happens: an action loads records into a
    # collection, a loop or a collection render walks it, and the code run for
    # each record calls one of that record's associations.
    #
    # The action's own body and the before filters that run for it say what
    # each instance variable holds (`@reviews = @product.reviews.latest` is a
    # Review collection). Its templates and the partials they render say what
    # walks it: `@reviews.each do |review|`, `render @reviews`, `render
    # partial: "reviews/review", collection: @reviews`, or a loop record handed
    # to a partial as a local. Only an association call on such a loop record
    # is a risk, so a view that reads `review.user` is one and a view that
    # mentions `nav.orders` in an i18n key is not. ERB and jbuilder are read as
    # Ruby; Haml and Slim are not read, so they add nothing rather than guesses.
    class NPlusOneScan
      # Block calls that hand the block one record at a time.
      LOOP_METHODS = %i[
        each map flat_map filter_map collect select filter reject each_with_index each_with_object
        find_each sort_by group_by index_by partition min_by max_by sum detect find any? all? none?
      ].to_set.freeze

      # A relation call that answers one record.
      ONE_RECORD = %i[
        find find_by find_by! first first! last last! take take! sole find_sole_by second third
        new build create create! find_or_create_by find_or_create_by! find_or_initialize_by
      ].to_set.freeze

      # A relation call that answers no records.
      NO_RECORDS = %i[
        count size length sum average minimum maximum pluck pick ids exists? any? many? none? empty?
        calculate to_sql explain update_all delete_all destroy_all touch_all
      ].to_set.freeze

      # Calls a has_many answers from the counter column a counter_cache
      # keeps, with no query (Reflection#has_active_cached_counter?).
      COUNTER_READS = %i[size any? empty? none?].to_set.freeze

      PRELOAD = /\.(?:includes|preload|eager_load)\(/
      STRICT_LOCALS = /\#\s+locals:\s+\((.*?)\)/m
      MAX_PARTIAL_DEPTH = 4

      # What an expression holds: records of `models` (several when a branch
      # picks between classes), one or a collection. A loop record keeps the
      # collection it came from in `loop`, and that collection's `chain` is the
      # query text that loaded it, which says what it preloads. `parent` is the
      # [models, association] a collection was read through, for Rails'
      # automatic inverse.
      Type = Struct.new(:models, :collection, :chain, :loop, :parent, keyword_init: true)
      Env = Struct.new(:ivars, :locals, :flags, keyword_init: true)

      def initialize(root, models)
        @root = root.to_s
        @models = models.is_a?(Hash) ? models.select { |_, d| d.is_a?(Hash) && !d[:error] } : {}
        @risks = []
        @counted = Set.new.compare_by_identity
        @counter_reads = Set.new.compare_by_identity
        @trees = {}
        @record_partials = {}
      end

      def call
        SourceScan.each(@root, kind: "app/controllers").each do |record|
          scan_controller(record)
        rescue StandardError => e
          RailsAiContext.debug_fail(e, nil, label: "n+1 scan of #{record.file}")
        end
        @risks.uniq { |r| [ r[:model], r[:association], r[:controller], r[:action] ] }
      end

      # The public instance methods a controller file defines for its own class.
      def self.controller_actions(source)
        ActionResolver.own_methods_in(source, nil)
          .select { |m| m[:scope] == :instance && m[:visibility] == :public }
          .to_h { |m| [ m[:name], ActionResolver.body_of(source, m)&.dig(:code).to_s ] }
      end

      private

      def scan_controller(record)
        source = record.source
        bodies = ActionResolver.own_methods_in(source, nil).select { |m| m[:scope] == :instance }
                               .to_h { |m| [ m[:name], ActionResolver.body_of(source, m)&.dig(:code) ] }
        filters = ControllerFilters.from_source(source, root: @root)
                                   .select { |f| %w[before around].include?(f[:kind].to_s) && !f[:skipped] }
        path = record.file.to_s.sub(%r{\A.*app/controllers/}, "").sub(/(?:_controller)?\.rb\z/, "")
        scopes = path.split("/")[0...-1].then { |parts| parts.length.downto(0).map { |n| parts.first(n).join("/").camelize } }

        self.class.controller_actions(source).each do |action, body|
          context = { controller: record.file, action: action, path: path, scopes: scopes, view: nil, depth: 0 }
          env = Env.new(ivars: {}, locals: {}, flags: {})
          run = filters.select { |f| runs_on?(f, action) }.filter_map { |f| bodies[f[:name].to_s] }
          (run + [ body ]).each { |code| assign(tree(code), env, context) }
          action_tree = tree(body)
          visit(action_tree, env, context)
          templates(path, action, action_tree).each do |file, relative|
            template = template_tree(file)
            visit(template, env.dup.tap { |e| e.locals = {} }, context.merge(view: relative, format: format_of(file))) if template
          end
        end
      end

      def runs_on?(filter, action)
        only = Array(filter[:only]).map(&:to_s)
        except = Array(filter[:except]).map(&:to_s)
        only.any? ? only.include?(action) : !except.include?(action)
      end

      def tree(code)
        code ? AstCache.parse_string(code.to_s).value : nil
      end

      # Instance and local variable assignments, in source order, each typed
      # from what is known by then.
      def assign(node, env, context)
        return unless node.is_a?(Prism::Node)

        case node
        when Prism::InstanceVariableWriteNode, Prism::InstanceVariableOrWriteNode
          type = type_of(node.value, env, context)
          env.ivars[node.name.to_s.delete_prefix("@")] = type if type
        when Prism::LocalVariableWriteNode
          type = type_of(node.value, env, context)
          env.locals[node.name.to_s] = type if type
        end
        node.compact_child_nodes.each { |child| assign(child, env, context) }
      end

      # ── Typing ──────────────────────────────────────────────────────────

      def type_of(node, env, context)
        case node
        when Prism::InstanceVariableReadNode then env.ivars[node.name.to_s.delete_prefix("@")]
        when Prism::LocalVariableReadNode then env.locals[node.name.to_s]
        when Prism::ConstantReadNode, Prism::ConstantPathNode
          (model = constant_model(node.slice, context)) && Type.new(models: [ model ], collection: true, chain: "")
        when Prism::ParenthesesNode, Prism::StatementsNode then type_of(last_statement(node), env, context)
        when Prism::IfNode, Prism::UnlessNode then branch_type(node, env, context)
        when Prism::CallNode then call_type(node, env, context)
        end
      end

      def last_statement(node)
        body = node.is_a?(Prism::ParenthesesNode) ? node.body : node
        body.is_a?(Prism::StatementsNode) ? body.body.last : body
      end

      # A branch that picks between records (`Product.find_by!(...)` or
      # `Post.find_by!(...)`) holds either; nil when the branches disagree on one or many.
      def branch_type(node, env, context)
        types = branches(node).filter_map { |branch| type_of(branch, env, context) }
        return nil if types.empty? || types.map(&:collection).uniq.size > 1

        Type.new(models: types.flat_map(&:models).uniq, collection: types.first.collection, chain: types.map(&:chain).join)
      end

      def branches(node)
        found = []
        found << last_statement(node.statements) if node.statements
        other = node.is_a?(Prism::IfNode) ? node.subsequent : node.else_clause
        case other
        when Prism::IfNode then found.concat(branches(other))
        when Prism::ElseNode then found << last_statement(other.statements) if other.statements
        end
        found.compact
      end

      def call_type(node, env, context)
        return receiverless_type(node, env, context) if node.receiver.nil?
        return user_type if node.name == :user && node.receiver.slice == "Current"

        receiver = type_of(node.receiver, env, context)
        return nil unless receiver

        if (targets = association_targets(receiver.models, node.name.to_s))
          many, models = targets
          chain = receiver.loop ? receiver.loop.chain : ""
          return Type.new(models: models, collection: many, chain: chain, parent: [ receiver.models, node.name.to_s ]) if models.any?

          return nil
        end
        return nil unless receiver.collection
        return nil if NO_RECORDS.include?(node.name)

        written = node.slice[(node.receiver.location.end_offset - node.location.start_offset)..].to_s
        written += scope_body(receiver.models, node.name.to_s)
        return Type.new(models: receiver.models, collection: false, chain: receiver.chain + written) if one_record?(node.name)

        Type.new(models: receiver.models, collection: true, chain: receiver.chain + written, parent: receiver.parent)
      end

      def receiverless_type(node, env, context)
        return user_type if node.name == :current_user && node.arguments.nil?
        return env.locals[node.name.to_s] if node.arguments.nil? && node.block.nil?

        nil
      end

      def one_record?(name)
        ONE_RECORD.include?(name) || name.to_s.match?(/\Afind_by_\w+!?\z/)
      end

      # A named scope's body, read into the chain as if written there:
      # `Post.with_author` preloads what `scope :with_author, -> {
      # includes(:user) }` does. A scope the body calls is read in turn.
      def scope_body(models, name, depth = 0)
        return "" if depth > 3

        models.filter_map do |model|
          body = Array(@models.dig(model, :scopes)).find { |s| s.is_a?(Hash) && s[:name].to_s == name }&.dig(:body)
          next unless body

          called = body.to_s.scan(/\b([a-z_]\w*)\b/).flatten.uniq - [ name ]
          ".#{body}" + called.map { |inner| scope_body([ model ], inner, depth + 1) }.join
        end.join
      end

      # `current_user` is the signed-in User in Devise and in the Rails 8
      # authentication generator alike, when the app has a User.
      def user_type
        @models.key?("User") ? Type.new(models: [ "User" ], collection: false, chain: "") : nil
      end

      # A bare constant resolves in the controller's lexical scopes, outermost
      # last, as Ruby resolves it; nil when no scope names a model.
      def constant_model(name, context)
        written = name.delete_prefix("::")
        return written if @models.key?(written) && name.start_with?("::")

        context[:scopes].each do |scope|
          candidate = scope.empty? ? written : "#{scope}::#{written}"
          return candidate if @models.key?(candidate)
        end
        nil
      end

      # [many?, target models] for an association `name` of any of `models`; nil when none declares it.
      def association_targets(models, name)
        found = models.filter_map { |model| [ model, association(model, name) ] if association(model, name) }
        return nil if found.empty?

        many = %w[has_many has_and_belongs_to_many].include?(found.first.last[:type].to_s)
        [ many, found.filter_map { |model, assoc| target_model(model, assoc) }.uniq ]
      end

      def association(model, name)
        Array(@models.dig(model, :associations)).find { |a| a.is_a?(Hash) && a[:name].to_s == name }
      end

      def target_model(owner, assoc)
        return nil if assoc[:polymorphic]

        written = assoc[:class_name] || (%w[has_many has_and_belongs_to_many].include?(assoc[:type].to_s) ? assoc[:name].to_s.singularize.camelize : assoc[:name].to_s.camelize)
        TableName.model_for(written.to_s, owner, @models)
      end

      # The association a call on a record reads: its own name, or a delegated
      # method (`delegate :name, to: :category, prefix: true` defines category_name).
      def association_read(models, name)
        models.each do |model|
          return name if association(model, name)

          Array(@models.dig(model, :delegations)).each do |delegation|
            next unless delegation.is_a?(Hash) && association(model, delegation[:to].to_s)

            defined = Array(delegation[:defines] || delegation[:methods]).map(&:to_s)
            return delegation[:to].to_s if defined.include?(name)
          end
        end
        nil
      end

      # ── Walking ─────────────────────────────────────────────────────────

      def visit(node, env, context)
        return unless node.is_a?(Prism::Node)

        case node
        when Prism::CallNode then visit_call(node, env, context)
        when Prism::IfNode, Prism::UnlessNode then visit_branch(node, env, context)
        else node.compact_child_nodes.each { |child| visit(child, env, context) }
        end
      end

      # A branch on a local the render passed as a literal (`show_seller: false`) runs one side only.
      def visit_branch(node, env, context)
        value = flag_value(node.predicate, env)
        return node.compact_child_nodes.each { |child| visit(child, env, context) } if value.nil?

        visit(node.predicate, env, context)
        taken = node.is_a?(Prism::UnlessNode) ? !value : value
        visit(taken ? node.statements : (node.is_a?(Prism::IfNode) ? node.subsequent : node.else_clause), env, context)
      end

      def flag_value(predicate, env)
        name = case predicate
        when Prism::LocalVariableReadNode then predicate.name.to_s
        when Prism::CallNode then predicate.name.to_s if predicate.receiver.nil? && predicate.arguments.nil? && predicate.block.nil?
        end
        name && env.flags.key?(name) ? env.flags[name] : nil
      end

      def visit_call(node, env, context)
        @counted << node.receiver if node.name == :count && node.block.nil? && node.receiver.is_a?(Prism::CallNode)
        if COUNTER_READS.include?(node.name) && node.block.nil? && node.arguments.nil? && node.receiver.is_a?(Prism::CallNode)
          @counter_reads << node.receiver
        end
        record_access(node, env, context)

        collection = loop_collection(node, env, context)
        if collection
          visit(node.receiver, env, context) unless jbuilder?(node)
          visit(node.arguments, env, context)
          param = block_param(node)
          inner = param ? Env.new(ivars: env.ivars, locals: env.locals.merge(param => loop_record(collection)), flags: env.flags) : env
          visit(node.block.body, inner, context)
          return
        end

        render(node, env, context)
        node.compact_child_nodes.each { |child| visit(child, env, context) }
      end

      def jbuilder?(node)
        node.receiver.is_a?(Prism::Node) && node.receiver.slice == "json"
      end

      # The collection a block call walks: `@posts.each do |post|`, or jbuilder's `json.array! @posts do |post|`.
      def loop_collection(node, env, context)
        return nil unless node.block.is_a?(Prism::BlockNode)

        walked = if jbuilder?(node) && node.name == :array!
          node.arguments&.arguments&.first
        elsif LOOP_METHODS.include?(node.name)
          node.receiver
        end
        type = walked && type_of(walked, env, context)
        type if type&.collection
      end

      def block_param(node)
        params = node.block.parameters
        params = params.parameters if params.is_a?(Prism::BlockParametersNode)
        first = params.respond_to?(:requireds) ? params.requireds.first : nil
        first.respond_to?(:name) ? first.name.to_s : nil
      end

      def loop_record(collection)
        Type.new(models: collection.models, collection: false, chain: collection.chain, loop: collection, parent: collection.parent)
      end

      # An association call on a record a loop hands out runs once per record.
      def record_access(node, env, context)
        return unless node.receiver

        record = type_of(node.receiver, env, context)
        return unless record&.loop && !record.collection

        read = association_read(record.models, node.name.to_s)
        return unless read && !inverse?(record, read)

        models = record.models.select { |model| association(model, read) || association_read([ model ], node.name.to_s) }
        models = models.reject { |model| cached_counter?(model, read) } if @counter_reads.include?(node)
        models.each do |model|
          add_risk(model, read, record.loop.chain, context, counted: @counted.include?(node))
        end
      end

      # Whether `owner.name.size` reads a counter column, as Rails decides:
      # the has_many's own counter_cache, or a belongs_to on the other side
      # whose counter_cache keeps the column the has_many reads
      # (`#{name}_count` unless it names one).
      def cached_counter?(owner, name)
        assoc = association(owner, name)
        return false unless assoc && assoc[:type].to_s == "has_many" && !assoc[:through]

        own = counter_cache(assoc)
        return own[:active] if own

        target = target_model(owner, assoc) or return false
        Array(@models.dig(target, :associations)).any? do |inverse|
          next false unless inverse.is_a?(Hash) && inverse[:type].to_s == "belongs_to"
          next false unless (kept = counter_cache(inverse)) && kept[:active]

          (kept[:column] || "#{target.demodulize.underscore.pluralize}_count") == "#{name}_count" &&
            (inverse[:polymorphic] || target_model(target, inverse) == owner)
        end
      end

      # A declared counter_cache as { column:, active: }, read off the
      # option's text in either tier; nil when none is declared.
      def counter_cache(assoc)
        text = assoc.dig(:declared_options, "counter_cache")&.to_s
        return nil if text.nil? || text == "false"

        column = text == "true" ? nil : text[/\A:?"?(\w+)"?\z/, 1] || text[/column: :?"?(\w+)/, 1]
        { column: column, active: !text.match?(/active: false/) }
      end

      # Rails sets the inverse of `@product.reviews` on each review, so
      # `review.product` in that loop runs no query.
      def inverse?(record, read)
        parents, through = record.parent
        return false unless parents

        record.models.any? do |model|
          assoc = association(model, read)
          next false unless assoc && assoc[:type].to_s == "belongs_to"

          parents.any? do |parent|
            own = association(parent, through)
            own && !own[:through] && read == parent.demodulize.underscore && target_model(model, assoc) == parent
          end
        end
      end

      def add_risk(model, association, chain, context, counted:)
        risk = counted ? :high : classify(chain, association)
        @risks << {
          model: model, association: association, controller: context[:controller], action: context[:action],
          view: context[:view], risk: risk.to_s, suggestion: suggestion(risk, model, association, counted)
        }.compact
      end

      def classify(chain, association)
        if chain.match?(/\.(?:includes|preload|eager_load)\(.*(?::#{Regexp.escape(association)}\b|\b#{Regexp.escape(association)}:)/m)
          :low
        elsif chain.match?(PRELOAD)
          :medium
        else
          :high
        end
      end

      def suggestion(risk, model, association, counted)
        if counted
          return "`.#{association}.count` runs a COUNT query for each #{model}, preloaded or not: " \
                 "preload with .includes(:#{association}) and call .size, or keep a counter_cache"
        end

        case risk
        when :high then "Add .includes(:#{association}) to the #{model} query to avoid N+1 queries"
        when :medium then "#{model} query has preloading but missing :#{association} - add it to the includes list"
        else "#{association} is preloaded - no action needed"
        end
      end

      # ── Rendering ───────────────────────────────────────────────────────

      # `render @reviews`, `render partial: "reviews/review", collection: @reviews`,
      # `render "line_items/line_item", item: item`, `render review` in a loop,
      # and jbuilder's `json.partial!` and `json.array! @x, partial:, as:`.
      def render(node, env, context)
        return unless (node.receiver.nil? && node.name == :render) || (jbuilder?(node) && %i[partial! array!].include?(node.name))

        args = Array(node.arguments&.arguments)
        options = keyword_options(args.last)
        first = args.first unless args.first.is_a?(Prism::KeywordHashNode)
        name = string_value(options["partial"]) || (string_value(first) unless node.name == :array!)
        # `json.array! @posts, :id, :title` lists attributes; only `partial:` renders one.
        return if node.name == :array! && name.nil?

        collection = node.name == :array! ? first : options["collection"]
        if name && collection
          type = type_of(collection, env, context)
          return unless type&.collection

          local = symbol_value(options["as"]) || name.split("/").last
          return render_partial(name, local, loop_record(type), literal_locals(options["locals"]), env, context)
        end

        if name
          locals = typed_locals(options["locals"], env, context)
          locals.merge!(typed_locals(args.last, env, context)) if first
          return render_partial(name, nil, nil, literal_locals(options["locals"]).merge(literal_locals(args.last)), env, context, locals: locals)
        end

        type = first && type_of(first, env, context)
        return unless type && type.models.one?

        partial = record_partial(type.models.first, context)
        local = partial.split("/").last
        record = type.collection ? loop_record(type) : type
        render_partial(partial, local, record, literal_locals(args.last), env, context)
      end

      def render_partial(name, local, record, flags, env, context, locals: {})
        return if context[:depth] >= MAX_PARTIAL_DEPTH

        locals = locals.merge(local => record) if local && record
        # A partial rendered with no records can still walk one the action
        # loaded: `render "dashboard/list"` over `@posts.each`.
        return if locals.values.none? { |t| t.loop || t.collection } && env.ivars.values.none?(&:collection)

        file, relative = partial_file(name, context)
        tree = file && template_tree(file)
        return unless tree

        defaults = declared_flags(file)
        inner = Env.new(ivars: env.ivars, locals: locals, flags: defaults.merge(flags))
        visit(tree, inner, context.merge(view: relative, format: format_of(file), depth: context[:depth] + 1))
      end

      def keyword_options(node)
        return {} unless node.is_a?(Prism::KeywordHashNode) || node.is_a?(Prism::HashNode)

        node.elements.each_with_object({}) do |element, found|
          next unless element.is_a?(Prism::AssocNode)

          key = element.key
          found[key.unescaped.to_s] = element.value if key.is_a?(Prism::SymbolNode) || key.is_a?(Prism::StringNode)
        end
      end

      def typed_locals(node, env, context)
        keyword_options(node).each_with_object({}) do |(key, value), found|
          next if %w[partial locals collection as object layout formats cached spacer_template].include?(key)

          type = type_of(value, env, context)
          found[key] = type if type
        end
      end

      def literal_locals(node)
        keyword_options(node).each_with_object({}) do |(key, value), found|
          found[key] = true if value.is_a?(Prism::TrueNode)
          found[key] = false if value.is_a?(Prism::FalseNode) || value.is_a?(Prism::NilNode)
        end
      end

      def string_value(node)
        node.unescaped if node.is_a?(Prism::StringNode)
      end

      def symbol_value(node)
        node.unescaped if node.is_a?(Prism::SymbolNode) || node.is_a?(Prism::StringNode)
      end

      # A partial's `locals:` magic comment gives each flag its default.
      def declared_flags(file)
        declared = RailsAiContext::SafeFile.read(file).to_s[STRICT_LOCALS, 1]
        return {} unless declared

        declared.scan(/(\w+):\s*(true|false|nil)\b/).to_h { |name, value| [ name, value == "true" ] }
      end

      # The partial Rails renders for a model's records: its to_partial_path,
      # prefixed with the controller's namespace when that file exists.
      def record_partial(model, context)
        path = RenderedRecord.partial_path(model.underscore, @root, @record_partials)
        return nil unless path

        namespace = File.dirname(context[:path].to_s)
        namespaced = "#{namespace}/#{path}"
        namespace != "." && partial_file(namespaced, context) ? namespaced : path
      end

      # [file, name under its views root] for a partial name, read as Rails
      # reads it: a bare name from the controller's own directory, then application/.
      def partial_file(name, context)
        return nil unless name

        candidates = name.include?("/") ? [ name ] : [ "#{context[:path]}/#{name}", "application/#{name}" ]
        candidates.each do |candidate|
          dir, base = File.split(candidate)
          found = views.select { |_, relative| File.dirname(relative) == dir && File.basename(relative).start_with?("_#{base}.") }
          next if found.empty?

          return found.min_by { |file, _| format_of(file) == context[:format] ? 0 : 1 }
        end
        nil
      end

      # The templates an action renders: its own, in every format, and the ones it names.
      def templates(path, action, action_tree)
        names = [ "#{path}/#{action}" ]
        rendered_names(action_tree).each { |name| names << (name.include?("/") ? name : "#{path}/#{name}") }
        views.select { |_, relative| names.include?(Payload.template_key(relative)) }
      end

      def rendered_names(node, found = [])
        return found unless node.is_a?(Prism::Node)

        if node.is_a?(Prism::CallNode) && node.name == :render && node.receiver.nil?
          args = Array(node.arguments&.arguments)
          options = keyword_options(args.last)
          written = symbol_value(args.first) unless args.first.is_a?(Prism::KeywordHashNode)
          written ||= symbol_value(options["action"]) || symbol_value(options["template"])
          found << written if written && !written.start_with?("_")
        end
        node.compact_child_nodes.each { |child| rendered_names(child, found) }
        found
      end

      # Every ERB and jbuilder file across the views roots, with its name under its root.
      def views
        @views ||= ViewFile.each(@root, "**/*.{erb,jbuilder}")
      end

      def format_of(file)
        File.basename(file).split(".")[1]
      end

      def template_tree(file)
        @trees.fetch(file) do
          @trees[file] = begin
            source = RailsAiContext::SafeFile.read(file)
            ruby = if source.nil? then nil
            elsif file.end_with?(".jbuilder") then source
            else RailsAiContext::ErbSource.tag_bodies(source)
            end
            ruby && AstCache.parse_string(ruby).value
          end
        end
      end
    end
  end
end
