# frozen_string_literal: true

module RailsAiContext
  module Introspectors
    # The table a model reads, for the static tier and for every reader that
    # only has a model name in hand.
    #
    # Rails builds it as prefix + demodulized name + suffix, unless the class
    # assigns one itself or inherits its parent's table as an STI child. The
    # prefix and the suffix are declared by an enclosing scope or inherited as
    # class attributes, in files that are not the model's. `declarations` reads
    # one class body; `for_class` walks the namespace and the superclass chain
    # over every body the caller read, once, and answers the table, the key and,
    # when the source computes a setting the table depends on, who sets it.
    #
    # It reads table_name, table_name_prefix, table_name_suffix,
    # pluralize_table_names and a literal `self.primary_key =`.
    module TableName
      module_function

      NONE = { table_name: nil, table_name_prefix: nil, table_name_suffix: nil, pluralize_table_names: nil, primary_key: nil }.freeze
      TABLE_SETTINGS = %i[table_name table_name_prefix table_name_suffix pluralize_table_names].freeze

      # {"RssPolling" => "rss_polling_"}: the engine prefix no model file says.
      # ponytail: reads `lib/**/engine.rb` only; walk lib wholesale if an app needs more.
      def namespace_prefixes(root)
        root = File.expand_path(root.to_s)
        RunCache.fetch([ :namespace_prefixes, root ]) { read_namespace_prefixes(root) }
      end

      # A table an option writes as that source (a habtm join_table), read the
      # way a table_name assignment is; nil for any other expression.
      def affixed(expression, own, root)
        statements = AstCache.parse_string(expression.to_s)&.value&.statements&.body
        parts = statements&.size == 1 ? affix_parts(statements.first) : nil
        parts && fill(parts, own, root)
      end

      # Every declaration of one class body, read in one walk.
      #
      # @param source [String] the file's source
      # @param name [String] the qualified name of the class or module
      # @return [Hash] the five, each nil when this scope declares none, and under `unread_settings`
      #   the table settings it declares with a value only the running app computes, and under
      #   `table_name_parts` the strings and affix names of a table name that interpolates the class's
      #   own affix, which `for_class` fills from the superclass chain
      # @param root [String, nil] the app, whose configured affixes a table
      #   name interpolating table_name_prefix or table_name_suffix reads
      def declarations(source, name, root = nil)
        read(source, name) do |body|
          own = { table_name_prefix: affix(body, :table_name_prefix), table_name_suffix: affix(body, :table_name_suffix) }
          literal = assigned(body, :table_name=)
          parts = interpolated(body) unless literal
          read = { table_name: literal || (fill(parts, own, root) if parts) }.merge(own)
                 .merge(pluralize_table_names: boolean_assigned(body, :pluralize_table_names=), primary_key: primary_key_assigned(body))
          unread = TABLE_SETTINGS.select { |setting| read[setting].nil? && declares?(body, setting) }
          read = read.merge(table_name_parts: parts) if parts
          unread.any? ? read.merge(unread_settings: unread) : read
        end || NONE
      end

      # @return [String, nil] the table the class assigns itself, nil when it
      #   assigns none or computes one
      def explicit(source, class_name, root = nil)
        declarations(source, class_name, root)[:table_name]
      end

      # Rails derives the table through the app's own inflector, and the file's
      # name already carries that inflection - Zeitwerk resolved the constant
      # from it. Underscoring the constant instead turns OAuthClientConfig into
      # o_auth_client_configs, a table no app has.
      def stem(path, pluralize = true)
        base = File.basename(path.to_s, ".rb")
        pluralize ? base.pluralize : base
      end

      # The table a model name alone implies. The namespace is not part of it:
      # Rails demodulizes the name and lets table_name_prefix carry the
      # namespace, so `Admin::ActionLog` is `action_logs` until a prefix says
      # otherwise - never `admin/action_logs`.
      def derive(model_name)
        model_name.to_s.split("::").last.to_s.underscore.pluralize
      end

      # The class an association names, read as Rails' compute_type reads it:
      # a leading `::` is top level; otherwise the owner's own namespace, each
      # enclosing one, then top level. The block answers a candidate with the
      # model's spelling, or nil when no model has that name.
      def resolve_class(candidate, owner)
        name = candidate.to_s.delete_prefix("::")
        scope = candidate.to_s.start_with?("::") ? [] : owner.to_s.split("::")
        until scope.empty?
          hit = yield("#{scope.join('::')}::#{name}")
          return hit if hit

          scope.pop
        end
        yield(name) || name
      end

      # The model a derived name means, as the app spells it (HtmlPage is HTMLPage).
      # An exact spelling at any depth wins, so Checkin and CheckIn stay apart.
      def model_for(candidate, owner, models)
        names = model_names(models)
        found = resolve_class(candidate, owner) { |name| names[name] }
        found = resolve_class(candidate, owner) { |name| names[name.downcase] } unless names.key?(found)
        found if names.key?(found)
      end

      # Names and downcased names, which never collide. Cached per hash for the
      # run, so a caller must not edit models in place mid-run.
      def model_names(models)
        RunCache.fetch([ :model_names, models.object_id, models.size ]) do
          models.keys.each_with_object({}) do |key, names|
            name = key.to_s
            names[name.downcase] = name
            names[name] = name
          end
        end
      end

      # A model's table and key. `table` is nil when the source computes a setting the table depends on, and then
      # `set_by` names it ("Archive.table_name", "Legacy.table_name_prefix"): no reader can name that table.
      Answer = Struct.new(:table, :set_by, :primary_key, keyword_init: true) do
        def self.of(record)
          record.is_a?(Hash) ? new(table: record[:table_name], set_by: record[:table_set_by], primary_key: record[:primary_key]) : new
        end
      end

      # What `for_class` reads about the app: `records` maps each class and module to its `declarations` plus
      # `superclass`, `superclass_nesting`, `abstract`, `path` and `stem`; `settings`, `unread_settings` and
      # `isolated_prefixes` are the app's and the engines'; `model` and `dump_tables` are callables.
      class Lookup
        attr_reader :records, :settings, :unread_settings, :isolated_prefixes

        def initialize(records, settings: {}, unread_settings: [], isolated_prefixes: {}, model: nil, dump_tables: nil)
          @records = records
          @settings = settings
          @unread_settings = unread_settings
          @isolated_prefixes = isolated_prefixes
          @model = model || ->(name) { !records.dig(name, :superclass).nil? }
          @dump_tables = dump_tables || ->(_names) { [] }
          @superclasses = {}
        end

        # The class the walk holds that `name`'s superclass resolves to, as Ruby reads it where it is written.
        def superclass(name)
          @superclasses.fetch(name) do
            written = records.dig(name, :superclass)
            @superclasses[name] = written && SuperclassChain.resolve_in_scope(name, written, nesting: records.dig(name, :superclass_nesting)) do |qualified|
              qualified if records.key?(qualified)
            end
          end
        end

        # The model this one inherits its table from. A model base ends the chain, and so does an abstract
        # base: a child of one has a table of its own.
        def sti_parent(name)
          written = records.dig(name, :superclass)
          return nil if written.nil? || TableName.model_base?(written)

          parent = superclass(name)
          parent unless parent.nil? || records.dig(parent, :abstract)
        end

        # A concrete parent the app does not define (`ActsAsTaggableOn::Tag`), as written.
        def outside_parent(name)
          written = records.dig(name, :superclass)
          return nil if written.nil? || TableName.model_base?(written) || superclass(name)

          written.delete_prefix("::")
        end

        def model?(name)
          @model.call(name)
        end

        def dump_tables(names)
          @dump_tables.call(names)
        end
      end

      # @return [Answer] the table `class_name` reads, from one walk over `lookup`'s records
      def for_class(class_name, lookup)
        Walk.new(lookup).answer(class_name)
      end

      # The prefix and suffix the class reads, through its superclass chain and the app's settings.
      def affixes(class_name, lookup)
        Walk.new(lookup).affixes(class_name)
      end

      # The tables a gem parent may give the class, as Rails would name each, then the class's own.
      def outside_names(class_name, lookup)
        Walk.new(lookup).outside_names(class_name)
      end

      # ApplicationRecord, or a namespaced base such as Billing::ApplicationRecord.
      def model_base?(name)
        name == "ActiveRecord::Base" || name.split("::").last.end_with?("ApplicationRecord")
      end

      # The answer the model tier recorded for a model name, its spelling first and then any case; the
      # convention only for a name no model answers to. A model recorded with no table has none.
      #
      # @param models [Hash] the payload's models section
      # @return [Answer]
      def of_model(name, models = {})
        record = models[name.to_s]
        record = models.find { |model_name, details| model_name.to_s.casecmp?(name.to_s) && details.is_a?(Hash) }&.last unless record.is_a?(Hash)
        answer = Answer.of(record)
        record.is_a?(Hash) || answer.table || answer.set_by ? answer : Answer.new(table: derive(name))
      end

      # Each step answers [table, set_by], set_by naming the setting the source computes where the table depends on one.
      class Walk
        def initialize(lookup)
          @lookup = lookup
          @records = lookup.records
        end

        def answer(name)
          table, set_by = table(name, [])
          Answer.new(table: table, set_by: set_by, primary_key: primary_key(name, []))
        end

        def affixes(name)
          { table_name_prefix: class_setting(name, :table_name_prefix).first, table_name_suffix: class_setting(name, :table_name_suffix).first }
        end

        def outside_names(name)
          parent = @lookup.outside_parent(name) or return []

          names = [ TableName.derive(parent), parent.underscore.tr("/", "_").pluralize ]
          names = names.map(&:singularize) unless pluralize?(name)
          [ *names, @records.dig(name, :table_name) || own_table(name, []).first ].compact.uniq
        end

        private

        # Rails' order: what the class assigns itself, an STI child's parent's table, a gem parent's, and
        # otherwise the affixes around the stem the file name already carries.
        def table(name, seen)
          record = @records[name]
          # An entry the walk recorded as an error carries no path, and a table derived from no path is "".
          return [ nil, nil ] unless record && record[:path]
          return [ record[:table_name], nil ] if record[:table_name] && !record[:table_name_parts]
          return from_parts(name, record[:table_name_parts]) if record[:table_name_parts]
          return [ nil, "#{name}.table_name" ] if unread?(name, :table_name)

          parent = !seen.include?(name) && @lookup.sti_parent(name)
          inherited = parent ? table(parent, seen + [ name ]) : []
          return inherited if inherited.any?

          own, set_by = own_table(name, seen)
          return [ nil, set_by ] if set_by

          outside = @lookup.outside_parent(name) or return [ own, nil ]

          found = @lookup.dump_tables(outside_names(name))
          found.one? ? [ found.first, nil ] : [ nil, outside ]
        end

        # A table name that interpolates `table_name_prefix` reads the class attribute: the class's, else its superclasses'.
        def from_parts(name, parts)
          filled = parts.map { |part| part.is_a?(Symbol) ? class_setting(name, part) : [ part, nil ] }
          set_by = filled.filter_map(&:last).first
          set_by ? [ nil, set_by ] : [ filled.map { |text, _| text.to_s }.join, nil ]
        end

        def own_table(name, seen)
          prefix, by = affix(name, :table_name_prefix)
          suffix, by = affix(name, :table_name_suffix) unless by
          pluralize, by = class_setting(name, :pluralize_table_names) unless by
          contained, by = contained_prefix(name, seen) unless by
          return [ nil, by ] if by

          [ "#{prefix}#{contained}#{stem(@records[name], pluralize != false)}#{suffix}", nil ]
        end

        # Rails' full_table_name_prefix: the innermost enclosing scope that answers - a model class by its
        # class attribute, a module by what it declares or `isolate_namespace` gives it - else the class's own.
        def affix(name, key)
          scope = name.split("::")[0..-2]
          while scope.any?
            namespace = scope.join("::")
            return [ nil, "#{namespace}.#{key}" ] if unread?(namespace, key)
            return class_setting(namespace, key) if @records.dig(namespace, :superclass) && @lookup.model?(namespace)

            declared = @records.dig(namespace, key) || (key == :table_name_prefix ? @lookup.isolated_prefixes[namespace] : nil)
            return [ declared, nil ] if declared

            scope.pop
          end
          class_setting(name, key)
        end

        # A class attribute: the class's own, else its superclass chain's, else the app's.
        def class_setting(name, key, seen = [])
          return [ nil, "#{name}.#{key}" ] if unread?(name, key)

          own = @records.dig(name, key)
          return [ own, nil ] unless own.nil?

          parent = !seen.include?(name) && @lookup.superclass(name)
          return class_setting(parent, key, seen + [ name ]) if parent
          return [ nil, "ActiveRecord::Base.#{key}" ] if @lookup.unread_settings.include?(key)

          [ @lookup.settings[key], nil ]
        end

        def pluralize?(name)
          class_setting(name, :pluralize_table_names).first != false
        end

        # compute_table_name (7.0 and 8.1): a class nested in a concrete model
        # takes that model's singular table as a prefix (Project::Phase, project_phases).
        def contained_prefix(name, seen)
          parent = name.split("::")[0..-2].join("::")
          return [ "", nil ] if parent.empty? || seen.include?(parent) || @records.dig(parent, :abstract) || !@lookup.model?(parent)

          table, set_by = table(parent, seen + [ name ])
          return [ nil, set_by ] if set_by
          return [ "", nil ] if table.to_s.empty?

          [ "#{pluralize?(parent) ? table.singularize : table}_", nil ]
        end

        # Rails reads an STI child's key off its base class; an abstract base's assignment reaches no model.
        def primary_key(name, seen)
          own = @records.dig(name, :primary_key)
          return own if own

          parent = !seen.include?(name) && @lookup.sti_parent(name)
          parent ? primary_key(parent, seen + [ name ]) : nil
        end

        # A class that shares another's file has no file name of its own to read the stem off.
        def stem(record, pluralize)
          return TableName.stem(record[:path], pluralize) unless record[:stem]

          pluralize ? record[:stem].pluralize : record[:stem]
        end

        def unread?(scope, key)
          Array(@records.dig(scope, :unread_settings)).include?(key)
        end
      end

      def read_namespace_prefixes(root)
        engine_files(root).each_with_object({}) do |path, found|
          source = SafeFile.read(path, max_size: RailsAiContext.configuration.max_file_size)
          next unless source&.include?("isolate_namespace")

          isolated_namespaces(source).each do |namespace|
            found[namespace] ||= declarations(source, namespace)[:table_name_prefix] ||
                                 "#{namespace.underscore.tr('/', '_')}_"
          end
        end
      rescue StandardError, ScriptError => e
        RailsAiContext.debug_fail(e, {}, label: "namespace_prefixes")
      end

      def engine_files(root)
        roots = [ root ] + PathResolver.code_roots(root)
        roots.flat_map { |dir| PathResolver.glob(dir, "lib/**/engine.rb") }.uniq.sort
      end

      # Every `isolate_namespace Foo::Bar` in the file, by the constant's own
      # spelling. A computed argument names nothing readable and is skipped.
      def isolated_namespaces(source)
        root = AstCache.parse_string(source)&.value
        return [] unless root

        calls = []
        collect_isolate_calls(root, calls)
        calls
      end

      def collect_isolate_calls(node, found)
        if node.is_a?(Prism::CallNode) && node.name == :isolate_namespace
          argument = node.arguments&.arguments&.first
          if argument.is_a?(Prism::ConstantReadNode) || argument.is_a?(Prism::ConstantPathNode)
            found << argument.slice.delete_prefix("::")
          end
        end
        node.child_nodes.compact.each { |child| collect_isolate_calls(child, found) }
      end

      def affix(body, name)
        assigned(body, :"#{name}=") || returned(body, name)
      end

      def read(source, name)
        return nil unless source && name

        root = AstCache.parse_string(source)&.value
        return nil unless root

        body = body_of(root, name.to_s)
        body && yield(body)
      rescue StandardError, ScriptError => e
        RailsAiContext.debug_fail(e, nil, label: "TableName")
      end

      # The statements of the class or module declared under this exact qualified name, named the
      # way Ruby names it where it is written, nil when the file declares no such scope.
      def body_of(root, name)
        DeclaredConstant.constants(root, assignments: true) do |found, node, _nesting|
          next unless found == name
          return statements(node) if node.is_a?(Prism::ClassNode) || node.is_a?(Prism::ModuleNode)

          return built_body(node.value)
        end
        nil
      end

      # `Name = Class.new(Base) do ... end` runs the block as Name's body.
      def built_body(value)
        return [] unless value.is_a?(Prism::CallNode) && value.name == :new && value.receiver&.slice == "Class"

        block = value.block
        block.is_a?(Prism::BlockNode) && block.body.is_a?(Prism::StatementsNode) ? block.body.body : []
      end

      def statements(node)
        node.body.is_a?(Prism::StatementsNode) ? node.body.body : []
      end

      # `self.table_name = "x"`, only in this scope's own body.
      def assigned(body, name)
        call = body.find do |node|
          node.is_a?(Prism::CallNode) && node.name == name && node.receiver.is_a?(Prism::SelfNode)
        end
        call && literal(call.arguments&.arguments)
      end

      # A name, or a composite key's names; nil for anything computed.
      def primary_key_assigned(body)
        call = body.find { |node| node.is_a?(Prism::CallNode) && node.name == :primary_key= && node.receiver.is_a?(Prism::SelfNode) }
        args = call&.arguments&.arguments
        return literal(args) unless args&.size == 1 && args.first.is_a?(Prism::ArrayNode)

        names = args.first.elements.map { |element| literal([ element ]) }
        names if names.all?
      end

      def declares?(body, setting)
        body.any? do |node|
          ((node.is_a?(Prism::CallNode) && node.name == :"#{setting}=") || (node.is_a?(Prism::DefNode) && node.name == setting)) &&
            node.receiver.is_a?(Prism::SelfNode)
        end
      end

      def boolean_assigned(body, name)
        call = body.find do |node|
          node.is_a?(Prism::CallNode) && node.name == name && node.receiver.is_a?(Prism::SelfNode)
        end
        args = call&.arguments&.arguments
        return nil unless args&.size == 1

        { Prism::TrueNode => true, Prism::FalseNode => false }[args.first.class]
      end

      # `self.table_name = "#{table_name_prefix}users#{table_name_suffix}"`: the class's
      # own affix, else the app's configured one.
      def interpolated(body)
        call = body.find do |node|
          node.is_a?(Prism::CallNode) && node.name == :table_name= && node.receiver.is_a?(Prism::SelfNode)
        end
        args = call&.arguments&.arguments
        args&.size == 1 ? affix_parts(args.first) : nil
      end

      # The literal strings and the affix names (`:table_name_prefix`) the string is built from; nil when it holds anything else.
      def affix_parts(string)
        return nil unless string.is_a?(Prism::InterpolatedStringNode)

        string.parts.map do |part|
          next part.unescaped if part.is_a?(Prism::StringNode)

          affix_read(part) or return nil
        end
      end

      def fill(parts, own, root)
        parts.map { |part| part.is_a?(Symbol) ? own[part] || ActiveRecordSettings.for(root)[part] || "" : part }.join
      end

      def affix_read(part)
        return nil unless part.is_a?(Prism::EmbeddedStatementsNode) && part.statements&.body&.size == 1

        call = part.statements.body.first
        return nil unless call.is_a?(Prism::CallNode) && call.arguments.nil? && call.block.nil?
        return nil unless call.receiver.nil? || call.receiver.is_a?(Prism::SelfNode)

        call.name if %i[table_name_prefix table_name_suffix].include?(call.name)
      end

      # `def self.table_name_prefix; "x"; end` - the form Rails documents and
      # the one apps write. A method that computes its value answers nothing.
      def returned(body, name)
        node = body.find do |child|
          child.is_a?(Prism::DefNode) && child.name == name && child.receiver.is_a?(Prism::SelfNode)
        end
        node && literal(node.body.is_a?(Prism::StatementsNode) ? node.body.body : nil)
      end

      def literal(nodes)
        return nil unless nodes.is_a?(Array) && nodes.size == 1

        case (node = nodes.first)
        when Prism::StringNode, Prism::SymbolNode then node.unescaped
        end
      end

      private_class_method :affix, :read, :body_of, :built_body, :statements,
                           :assigned, :declares?, :boolean_assigned, :primary_key_assigned, :returned, :literal, :read_namespace_prefixes,
                           :interpolated, :affix_parts, :fill, :affix_read,
                           :engine_files, :collect_isolate_calls
    end
  end
end
