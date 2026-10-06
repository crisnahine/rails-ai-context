# frozen_string_literal: true

require "set"

module RailsAiContext
  module Introspectors
    # Which layout a controller renders in, and the class-level settings it and its ancestors
    # declare. Read from source in both tiers; the chain is walked over the finished listing.
    module ControllerSettings
      MACROS = %i[allow_browser protect_from_forgery add_flash_types default_form_builder wrap_parameters].freeze
      FRAMEWORK = %w[ActionController::Base ActionController::API].freeze

      module_function

      LISTENERS = {
        settings_calls: -> { Listeners::GenericMacroListener.new(:layout, *MACROS, call_source: MACROS) },
        methods: Listeners::MethodsListener,
        mixins: Listeners::MixinsListener
      }.freeze

      # { layout: {...}, settings: ["allow_browser versions: :modern"] } for one class body, with what the
      # app's concerns it includes declare where each `include` stands. A caller already walking the body
      # with LISTENERS passes that walk.
      def from_source(source, walked = nil, root: nil, within: nil)
        return {} if source.nil?

        walked ||= SourceIntrospector.walk_source(source, LISTENERS)
        placed = SourceIntrospector.outside_defs(walked[:settings_calls], walked[:methods]).map { |call| [ call[:location].to_i, -1, 0, call ] }
        placed += concern_calls(walked, root, within) if root
        calls = placed.each_with_index.sort_by { |(line, order, at, _), index| [ line, order, at, index ] }.map { |(_, _, _, call), _| call }
        layout_call, settings = calls.partition { |call| call[:macro] == :layout }
        {
          layout: layout_call.last && layout_of(layout_call.last),
          settings: settings.map { |call| call[:text] }.presence
        }.compact
      rescue => e
        RailsAiContext.debug_fail(e, {}, label: "ControllerSettings.from_source")
      end

      # Each call an included concern's block makes, placed at the `include` that reaches it.
      def concern_calls(walked, root, within)
        mixins = Array(walked[:mixins])
        collected, _, _, _, placement = ConcernMacros.collect(root, mixins, keys: [ :settings_calls ], prefer: "controller", within: within,
                                                              cache: RunCache.fetch([ :controller_concern_walks ]) { {} }, listeners: LISTENERS)
        line_of = mixins.reverse.to_h { |mixin| [ mixin[:name], mixin[:location].to_i ] }
        Array(collected[:settings_calls]).map do |call|
          top, order = placement[call[:from_concern]]
          [ line_of[top].to_i, order.to_i, call[:location].to_i, call ]
        end
      end

      # A literal string is the layout, a literal symbol the method that picks it; `nil`
      # leaves the class to the lookup by name, as if no call were made.
      def layout_of(call)
        value = Array(call[:values]).first
        found = if Array(call[:args]).any?
          value.is_a?(Symbol) ? { method: value.to_s } : { name: value.to_s }
        elsif value == false
          { name: false }
        elsif Array(call[:proc_lines]).any?
          { block: call[:proc_lines].first }
        elsif !value.nil?
          { expression: value.to_s }
        end
        return nil unless found

        options = call[:options] || {}
        %i[only except].each { |key| found[key] = Array(options[key]).map(&:to_s) if options.key?(key) }
        found[:via] = call[:from_concern] if call[:from_concern]
        found
      end

      # { layout: {...}, settings: [{ text:, from: }] } for a controller in the listing, its
      # ancestors' declarations included. An ancestor the app holds no source for ends the
      # walk, and the layout then names it rather than guessing.
      def resolve(ctx, controller_name, root:)
        controllers = Payload.controllers(ctx)
        chain, stop = chain_for(controllers, controller_name, root)
        settings = chain.reverse.flat_map { |name, decl| Array(decl[:settings]).map { |text| { text: text, from: name } } }
        api = controllers.dig(controller_name, :api_controller) || stop == "ActionController::API"
        return { settings: settings } if api

        { layout: layout_for(ctx, chain, stop, root), settings: settings }
      rescue => e
        RailsAiContext.debug_fail(e, { settings: [] }, label: "ControllerSettings.resolve")
      end

      def chain_for(controllers, controller_name, root)
        links, stop = lineage(controllers, controller_name, root)
        [ links.map { |name, entry, source| [ name, entry || from_source(source, root: root, within: name) ] }, stop ]
      end

      # [[name, payload entry, nil] or [name, nil, source of a base the listing leaves out]], the
      # class first, and the framework or unread class the walk stopped at.
      def lineage(controllers, controller_name, root)
        links = []
        seen = Set.new
        name = controller_name
        while name && seen.add?(name)
          return [ links, name ] if FRAMEWORK.include?(name)

          entry = controllers[name]
          if entry.is_a?(Hash)
            links << [ name, entry, nil ]
            parent = entry[:parent_class]
          elsif (source = ActionFilters.base_controller_source(name, root))
            links << [ name, nil, source ]
            parent = DeclaredConstant.parent_declaration(source, name)&.superclass
          else
            base = ActionFilters.gem_controller_base(name, root)
            return [ links, name ] unless base

            name = base
            next
          end
          name = ActionResolver.resolve_entry_name(controllers, parent, name)
        end
        [ links, nil ]
      end

      def layout_for(ctx, chain, stop, root)
        declared_at, decl = chain.find { |_, d| d[:layout] }
        if declared_at
          layout = decl[:layout].merge(from: declared_at)
          layout[:otherwise] = by_name(ctx, chain, stop, root) if layout[:only] || layout[:except]
          return layout
        end

        by_name(ctx, chain, stop, root)
      end

      # Rails looks for layouts/<controller_path> and then asks the superclass, until a class
      # whose layout was declared answers.
      def by_name(ctx, chain, stop, root)
        names = layout_names(root)
        found = chain.map { |name, _| Payload.controller_route_key(ctx, name) }.find { |path| names.include?(path) }
        return { name: found, implied: true } if found
        return { unread: stop } if stop && !FRAMEWORK.include?(stop)

        { name: nil, implied: true }
      end

      def layout_names(root)
        RunCache.fetch([ :layout_names, root.to_s ]) do
          ViewFile.each(root.to_s, "layouts/**/*").filter_map do |path, relative|
            relative.delete_prefix("layouts/").sub(/\.[^\/]*\z/, "") if ViewFile.layout?(path)
          end.to_set
        end
      end

      # One line a reader can take in: what renders, and why.
      def layout_phrase(layout)
        text = if layout[:unread]
          "#{Confidence::UNAVAILABLE} not read: decided by #{layout[:unread]}, which the app holds no source for"
        elsif layout[:implied]
          layout[:name] ? "`#{layout[:name]}` (none declared; found as layouts/#{layout[:name]})" : "none (no layout file matches this controller or its ancestors)"
        else
          what = if layout[:name] == false then "none (`layout false`"
          elsif layout[:method] then "chosen by `#{layout[:method]}` (declared"
          elsif layout[:block] then "chosen by a block (line #{layout[:block]},"
          elsif layout[:expression] then "`#{layout[:expression]}` (declared"
          else "`#{layout[:name]}` (declared"
          end
          conditions = %i[only except].filter_map { |key| "#{key}: #{layout[key].join(', ')}" if layout[key] }
          via = " through #{layout[:via]}" if layout[:via]
          "#{what} in #{layout[:from]}#{via}#{conditions.map { |c| ", #{c}" }.join})"
        end
        layout[:otherwise] ? "#{text}; other actions: #{layout_phrase(layout[:otherwise])}" : text
      end

      private_class_method :layout_of, :concern_calls, :chain_for, :layout_for, :by_name, :layout_names
    end
  end
end
