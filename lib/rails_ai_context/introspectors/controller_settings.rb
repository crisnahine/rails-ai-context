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

      # { layout: {...}, settings: [{ text: "allow_browser versions: :modern", via: }] } for one class body, with
      # what the app's concerns it includes declare where each `include` stands, `via` naming that concern.
      # A caller already walking the body with LISTENERS passes that walk.
      def from_source(source, walked = nil, root: nil, within: nil)
        return {} if source.nil?

        walked ||= SourceIntrospector.walk_source(source, LISTENERS)
        placed = SourceIntrospector.outside_defs(walked[:settings_calls], walked[:methods]).map { |call| [ call[:location].to_i, -1, 0, call ] }
        placed += concern_calls(walked, root, within) if root
        layout_call, settings = ConcernMacros.in_include_order(placed).partition { |call| call[:macro] == :layout }
        {
          layout: layout_call.last && layout_of(layout_call.last),
          settings: settings.map { |call| { text: call[:text], via: call[:from_concern] }.compact }.presence
        }.compact
      rescue => e
        RailsAiContext.debug_fail(e, {}, label: "ControllerSettings.from_source")
      end

      # Each call an included concern's block makes, placed at the `include` that reaches it.
      def concern_calls(walked, root, within)
        mixins = Array(walked[:mixins])
        found = ConcernMacros.collect(root, mixins, keys: [ :settings_calls ], prefer: "controller", within: within,
                                      cache: RunCache.fetch([ :controller_concern_walks ]) { {} }, listeners: LISTENERS)
        ConcernMacros.at_includes(Array(found.collected[:settings_calls]), found.placement, mixins) { |call| call[:location].to_i }
      end

      # A literal string is the layout, a literal symbol the method that picks it; `nil`
      # hands the class back to the lookup by name, starting from its own path.
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
        elsif Array(call[:values]) == [ nil ]
          { by_name: true }
        end
        return nil unless found

        options = call[:options] || {}
        %i[only except].each { |key| found[key] = Array(options[key]).map(&:to_s) if options.key?(key) }
        found[:via] = call[:from_concern] if call[:from_concern]
        found
      end

      # { layout: {...}, settings: [{ text:, from:, via: }] } for a controller in the listing, its
      # ancestors' declarations included. An ancestor the app holds no source for ends the
      # walk, and the layout then names it rather than guessing.
      def resolve(ctx, controller_name, root:)
        controllers = Payload.controllers(ctx)
        chain, stop = chain_for(controllers, controller_name, root)
        settings = chain.reverse.flat_map { |name, decl| Array(decl[:settings]).map { |setting| setting.merge(from: name) } }
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

      # Rails' `_layout`: a class with no `layout` call of its own inherits the nearest one's value and
      # conditions. `layout nil` looks for layouts/<controller_path> of each class up to the declaring one,
      # then runs the `_layout` above it. An action the conditions leave out fails the same inherited
      # conditions in every ancestor's `_layout`, so it only ever gets the name lookup over the whole chain.
      def layout_for(ctx, chain, stop, root)
        at = chain.index { |_, d| d[:layout] }
        return name_lookup(ctx, chain, stop, root) unless at

        declared_at, decl = chain[at]
        if decl[:layout][:by_name]
          found = by_name(ctx, chain.first(at + 1), root) || layout_for(ctx, chain.drop(at + 1), stop, root)
          return found[:implied] ? found.merge(from: declared_at) : found
        end

        layout = decl[:layout].merge(from: declared_at)
        layout[:otherwise] = name_lookup(ctx, chain, stop, root) if layout[:only] || layout[:except]
        layout
      end

      def name_lookup(ctx, chain, stop, root)
        by_name(ctx, chain, root) || (stop && !FRAMEWORK.include?(stop) ? { unread: stop } : { name: nil, implied: true })
      end

      # The first of the classes' layouts/<controller_path> files, nearest first.
      def by_name(ctx, links, root)
        names = layout_names(root)
        found = links.map { |name, _| Payload.controller_route_key(ctx, name) }.find { |path| names.include?(path) }
        { name: found, implied: true } if found
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
          why = layout[:from] ? "`layout nil` in #{layout[:from]}; " : ""
          layout[:name] ? "`#{layout[:name]}` (#{why.presence || 'none declared; '}found as layouts/#{layout[:name]})" : "none (#{why}no layout file matches this controller or its ancestors)"
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

      private_class_method :layout_of, :concern_calls, :chain_for, :layout_for, :name_lookup, :by_name, :layout_names
    end
  end
end
