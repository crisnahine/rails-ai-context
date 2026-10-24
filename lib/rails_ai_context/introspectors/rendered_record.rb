# frozen_string_literal: true

module RailsAiContext
  module Introspectors
    # The records a bare `render @post.comments` hands to Rails, and the partial Rails renders for them.
    # A receiver is a model only from the model directories; the models it reaches from any autoload root.
    module RenderedRecord
      LISTENERS = { associations: Listeners::AssociationsListener, methods: Listeners::MethodsListener,
                    mixins: Listeners::MixinsListener, classes: Listeners::ClassDefinitionListener }.freeze
      ASSOCIATION_LISTENERS = LISTENERS.slice(:associations, :mixins).freeze

      # Each association is [model, collection?], a Through or :unknown; `partial_path` is nil when computed.
      Model = Data.define(:associations, :partial_path)
      # `sources`: the names Rails tries for the source on the hop's model.
      Through = Data.define(:hop, :sources, :collection)

      module_function

      # [the model, whether it is a collection] for a chain such as "post.comments.reverse": the
      # receiver, then each association its model declares. A call that is no association keeps a
      # collection's records (`.first`, `.recent`); on a single record it returns who knows what, so nil.
      # A receiver that is no model (`current_user.posts`) is read from the next name, as `render @posts`
      # is; nil when the app holds no model for that either.
      # shortcut: a lone name such as `@pages` reads its model from the name, not from what the action assigns it; read the action's assignment when an app renders records under another name.
      def resolve(chain, root, memo = {})
        segments = chain.split(".")
        return [ segments.first.singularize, segments.first != segments.first.singularize ] if segments.size == 1

        segments = segments.drop(1) unless model?(segments.first.singularize, root, memo)
        model = segments.first.singularize
        return nil unless model?(model, root, memo) && read(model.camelize, root, memo)

        collection = segments.first != model
        segments.drop(1).each do |segment|
          target = across(read(model.camelize, root, memo)&.associations&.[](segment), model, root, memo)
          return nil if target == :unknown || (target.nil? && !collection)
          model, collection = target if target
        end
        [ model, collection ]
      end

      # The class Rails reads off the source on the hop's model; :unknown when the app declares no such hop or source.
      def across(target, model, root, memo)
        return target unless target.is_a?(Through)

        middle = read(model.camelize, root, memo).associations[target.hop]
        return :unknown unless middle.is_a?(Array)

        far = read(middle.first.camelize, root, memo) or return :unknown
        source = far.associations[target.sources.find { |name| far.associations.key?(name) }]
        source.is_a?(Array) ? [ source.first, target.collection ] : :unknown
      end

      # The model's own literal to_partial_path, else ActiveModel's default; nil when it computes one.
      def partial_path(model, root, memo = {})
        found = read(model.camelize, root, memo)
        found ? found.partial_path : default_path(model)
      end

      # The partial `render <chain>` renders from a view in `folder` (standing in for the controller's path), or nil
      # when the chain or a computed to_partial_path cannot be read. A lone name with no model file renders its default
      # partial if that is among `partials` (on disk); else a local keeps its name as the guess at its class, and an
      # ivar names none, since Rails never looks one up by name.
      def rendered_partial(chain, folder, root, memo, booted:, partials:)
        name = chain.delete_prefix("@")
        model, = resolve(name, root, memo)
        if model && !name.include?(".")
          declared = declared_model(model, folder, root, memo)
          guess = model_partial(declared || model, folder, root, memo, booted: booted)
          return guess if declared || partials.include?(guess)

          return chain.start_with?("@") ? nil : name
        end
        model && model_partial(model, folder, root, memo, booted: booted)
      end

      # The partial Rails renders for one of the model's records from a view in `folder`.
      def model_partial(model, folder, root, memo, booted:)
        path = partial_path(model, root, memo)
        return path unless path && prefixed_paths?(root, booted: booted, memo: memo)

        merge_prefix_into_object_path(folder == "." ? "" : folder, path)
      end

      # The model a lone `render @audit_entries` names, in the view folder's namespace first (Admin::AuditEntry
      # under admin/); nil when the model directories hold none.
      # shortcut: the folder stands in for a controller nested in `module Admin`; a compact `class Admin::ItemsController`
      # finds the top-level model, which differs only with the prefix off; read the controller's nesting when that matters.
      def declared_model(model, folder, root, memo)
        namespaces = folder.split("/")[0...-1]
        namespaces.size.downto(0).map { |depth| [ *namespaces.first(depth), model ].join("/") }
                  .find { |candidate| model?(candidate, root, memo) }
      end

      # ActionView::AbstractRenderer#merge_prefix_into_object_path.
      def merge_prefix_into_object_path(prefix, object_path)
        return object_path unless prefix.include?("/") && object_path.include?("/")

        prefixes = []
        object_dirs = object_path.split("/")[0..-3]
        File.dirname(prefix).split("/").each_with_index do |dir, index|
          break if dir == object_dirs[index]

          prefixes << dir
        end
        (prefixes << object_path).join("/")
      end

      # Rails prefixes a record's partial with the controller namespace unless
      # ActionView::Base.prefix_partial_path_with_controller_namespace is false.
      PREFIX_SETTER = :prefix_partial_path_with_controller_namespace=

      def prefixed_paths?(root, booted:, memo:)
        memo.fetch([ :prefixed, booted ]) { memo[[ :prefixed, booted ]] = prefix_setting(root, booted) }
      end

      def prefix_setting(root, booted)
        return ActionView::Base.prefix_partial_path_with_controller_namespace != false if booted && defined?(ActionView::Base)

        prefix = "#{root.to_s.chomp('/')}/"
        files = [ "config/application.rb", "config/environments/#{RailsAiContext.environment_name}.rb" ] +
          PathResolver.initializer_paths(root).map { |path| path.delete_prefix(prefix) }
        last = nil
        # The setter name is ActionView's own, so config.action_view, ActionView::Base and an on_load `self.` all match.
        listener = -> { Listeners::MethodCallListener.new(names: [ PREFIX_SETTER ]) }
        files.each do |relative|
          next unless SafePath.locate(relative, under: root).ok?

          walked = SourceIntrospector.walk(File.join(root, relative), { setting: listener })
          walked[:setting].each { |call| last = call[:arguments].first if [ true, false ].include?(call[:arguments].first) }
        end
        last != false
      rescue => e
        RailsAiContext.debug_fail(e, true, label: "RenderedRecord.prefix_setting")
      end

      # Only a file in the model directories makes a receiver a model: a Cart service holds no records.
      def model?(model, root, memo)
        memo.fetch([ :model, model ]) { memo[[ :model, model ]] = PathResolver.constant_file(PathResolver.model_dirs(root.to_s), model.camelize) }
      end

      def autoload_file(name, root, memo)
        memo.fetch([ :file, name ]) { memo[[ :file, name ]] = PathResolver.file_for_constant(root.to_s, name) }
      end

      def default_path(model)
        "#{model.pluralize}/#{model.split('/').last}"
      end

      # The model in the file Zeitwerk loads `name` from, which may be a camelized guess at the constant.
      def read(name, root, memo)
        memo.fetch(name) do
          # Nil while it is read, so a parent chain that loops back ends.
          memo[name] = nil
          memo[name] = begin
            path = autoload_file(name, root, memo)
            model_file(path, name, root, memo) if path && !PathResolver.linked_out?(path, root.to_s)
          end
        end
      rescue => e
        RailsAiContext.debug_fail(e, nil, label: "RenderedRecord.read")
      end

      def model_file(path, name, root, memo)
        walked = SourceIntrospector.walk(path, LISTENERS)
        name = declared_name(walked[:classes], name)
        own = ActionResolver.own_methods(walked[:methods], name)
                            .find { |m| m[:scope] == :instance && m[:name].to_s == "to_partial_path" }
        Model.new(declared(walked, name, root, memo), own ? literal_return(path, own[:offset]) : default_path(name.underscore))
      end

      # The class the file declares for `name`: a camelized guess loses an acronym only the app's inflector spells.
      def declared_name(classes, name)
        names = Array(classes).map { |klass| [ klass[:nesting].first, klass[:name] ].compact.join("::") }
        names.include?(name) ? name : names.find { |found| PathResolver.loose_key(found) == PathResolver.loose_key(name) } || name
      end

      # What the class declares in its file, its included concerns and its parent model, the nearest winning.
      def declared(walked, name, root, memo)
        classes = Array(walked[:classes])
        mixins = ConcernMembership.owned_by(walked[:mixins], name, others: classes.map { |klass| klass[:name] } - [ name ])
        concerns = ConcernMacros.collect(root.to_s, mixins, keys: %i[associations], prefer: "model", within: name,
                                         listeners: ASSOCIATION_LISTENERS, cache: RunCache.fetch([ :rendered_record_concern_walks ]) { {} })
                                .collected[:associations]
        [ parent(classes, name, root, memo)&.associations, by_name(concerns), by_name(walked[:associations]) ].compact.reduce({}, :merge)
      end

      def by_name(associations) = Array(associations).to_h { |assoc| [ assoc[:name].to_s, target(assoc) ] }

      # The parent model the class's superclass names; nil for a base with no file here.
      def parent(classes, name, root, memo)
        klass = classes.find { |found| name == found[:name] || name.end_with?("::#{found[:name]}") } or return nil
        found = SuperclassChain.resolve_in_scope(name, klass[:superclass], nesting: klass[:nesting]) do |candidate|
          candidate if autoload_file(candidate, root, memo)
        end
        found && read(found, root, memo)
      end

      def target(assoc)
        options = assoc[:options] || {}
        return :unknown if options[:polymorphic]

        collection = AssociationClass::COLLECTION_MACROS.include?(assoc[:type].to_s)
        # Rails reads class_name ahead of a through's source_type.
        name_key = options[:through] && !options.key?(:class_name) && options.key?(:source_type) ? :source_type : :class_name
        class_name = options[name_key]
        return :unknown if options.key?(name_key) && (!class_name.is_a?(String) || class_name == Confidence::INFERRED)

        if options[:through] && !class_name
          # Rails' source_reflection_names: the source, else the name singular, then as written.
          sources = options.key?(:source) ? [ options[:source].to_s ] : [ assoc[:name].to_s.singularize, assoc[:name].to_s ].uniq
          return Through.new(options[:through].to_s, sources, collection)
        end

        model = (class_name&.delete_prefix("::") || AssociationClass.derived_name(assoc)).underscore
        [ model, collection ]
      end

      # The string a one-line `def` at `offset` returns.
      def literal_return(path, offset)
        body = AstWalk.def_at(AstCache.parse(path).value, offset)&.body&.body
        body&.size == 1 && body.first.is_a?(Prism::StringNode) ? body.first.unescaped : nil
      end
    end
  end
end
