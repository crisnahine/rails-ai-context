# frozen_string_literal: true

module RailsAiContext
  module Introspectors
    # The records a bare `render @post.comments` hands to Rails, and the partial Rails renders for them.
    # Only the conventional model file is read: app/models/<model>.rb.
    module RenderedRecord
      LISTENERS = { associations: Listeners::AssociationsListener, methods: Listeners::MethodsListener }.freeze
      COLLECTIONS = %w[has_many has_and_belongs_to_many].freeze

      # `associations` by name: [model, collection?], or :unknown for a polymorphic or computed class.
      # `partial_path` is nil when the model's own to_partial_path returns no literal.
      Model = Data.define(:associations, :partial_path)

      module_function

      # [the segment naming the records, the model] for a chain such as "post.comments.reverse": the
      # receiver, then each association its model declares. A call that is no association keeps a
      # collection's records (`.first`, `.recent`); on a single record it returns who knows what, so nil.
      # A receiver that is no model (`current_user.posts`) is read from the next name, as `render @posts`
      # is; nil when the app holds no model for that either.
      def resolve(chain, root, memo = {})
        segments = chain.split(".")
        return [ segments.first, segments.first.singularize ] if segments.size == 1

        segments = segments.drop(1) unless read(segments.first.singularize, root, memo)
        name = segments.first
        model = name.singularize
        return nil unless read(model, root, memo)

        collection = name != model
        segments.drop(1).each do |segment|
          target = read(model, root, memo)&.associations&.[](segment)
          return nil if target == :unknown || (target.nil? && !collection)
          next unless target

          name = segment
          model, collection = target
        end
        [ name, model ]
      end

      # The model's own literal to_partial_path, else ActiveModel's default; nil when it computes one.
      def partial_path(model, root, memo = {})
        found = read(model, root, memo)
        found ? found.partial_path : default_path(model)
      end

      def default_path(model)
        "#{model.pluralize}/#{model.split('/').last}"
      end

      def read(model, root, memo)
        memo.fetch(model) do
          memo[model] = begin
            relative = "app/models/#{model}.rb"
            model_file(File.join(root.to_s, relative), model) if SafePath.locate(relative, under: root.to_s).ok?
          end
        end
      rescue => e
        RailsAiContext.debug_fail(e, nil, label: "RenderedRecord.read")
      end

      def model_file(path, model)
        walked = SourceIntrospector.walk(path, LISTENERS)
        associations = Array(walked[:associations]).to_h { |assoc| [ assoc[:name].to_s, target(assoc) ] }
        own = ActionResolver.own_methods(walked[:methods], model.camelize)
                            .find { |m| m[:scope] == :instance && m[:name].to_s == "to_partial_path" }
        Model.new(associations, own ? literal_return(path, own[:offset]) : default_path(model))
      end

      def target(assoc)
        options = assoc[:options] || {}
        return :unknown if options[:polymorphic]

        class_name = options[:class_name]
        return :unknown if options.key?(:class_name) && (!class_name.is_a?(String) || class_name == Confidence::INFERRED)

        model = class_name ? class_name.delete_prefix("::").underscore : assoc[:name].to_s.singularize
        [ model, COLLECTIONS.include?(assoc[:type].to_s) ]
      end

      # The string a one-line `def` at `offset` returns, reached down the nodes that hold it.
      def literal_return(path, offset)
        node = AstCache.parse(path).value
        node = node.compact_child_nodes.find { |child| child.location.start_offset <= offset && offset < child.location.end_offset } until node.nil? || (node.is_a?(Prism::DefNode) && node.location.start_offset == offset)
        body = node&.body&.body
        body&.size == 1 && body.first.is_a?(Prism::StringNode) ? body.first.unescaped : nil
      end
    end
  end
end
