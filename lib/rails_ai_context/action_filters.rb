# frozen_string_literal: true

module RailsAiContext
  # Which filters run for a controller, and for one of its actions.
  #
  # A compiled callback keeps `only:`/`except:` in private ivars, so
  # reflection cannot recover them: the per-filter constraints the
  # ControllerIntrospector reads from source are the only answer. That same
  # reflection list already carries the whole inheritance chain and already
  # excludes what the class skipped, so the parent's filters are separated by
  # name rather than added.
  module ActionFilters
    SKIP_MACROS = %i[skip_before_action skip_after_action skip_around_action].freeze

    module_function

    # { own: [filter], inherited: [filter], skipped: [name] } for one action.
    # `source:` is the controller's source when the caller already has it.
    def for(ctx, controller_name, action, source: nil, root: nil)
      split(ctx, controller_name, action.to_s, source: source, root: root)
    end

    # The same three lists for the whole controller: every declared filter,
    # whatever actions it constrains itself to.
    def for_controller(ctx, controller_name, source: nil, root: nil)
      split(ctx, controller_name, nil, source: source, root: root)
    end

    # The app root a caller that has one need not name. Nil outside a booted
    # app, where nothing can be read anyway: the gem is required on its own
    # by the standalone binary long before `Rails` exists.
    def default_root
      return nil unless RailsAiContext.static_tier? || defined?(Rails)

      RailsAiContext.default_app&.root&.to_s
    end

    def split(ctx, controller_name, action, source:, root:)
      info = Payload.controllers(ctx)[controller_name.to_s]
      return { own: [], inherited: [], skipped: [] } unless info.is_a?(Hash)

      skips = own_skips(ctx, controller_name, info, action, root: root, source: source)
      skipped = absolute_names(skips, action)
      # A skip record states what does not run, so it is never a filter.
      declared = Array(info[:filters]).grep(Hash).reject { |f| f[:skipped] }
      parent, dropped, inherited_conditions, declares = parent_filters(ctx, info[:parent_class], action, skipped,
                                                                       root: root, within: controller_name.to_s)
      conditions = merge_conditions(inherited_conditions, conditions_by_name(skips, action))
      # The runtime tier's list is the whole chain, so an ancestor's skip
      # applies here too - except to what this body declares again, which
      # Rails re-adds.
      inherited_skips = dropped - skipped.map(&:to_s)
      applicable = declared.select { |f| applies?(f, action) }
        .reject { |f| skipped.include?(f[:name].to_s) }
        .reject { |f| inherited_skips.include?(f[:name].to_s) && !f[:declared] }
      # Keyed by kind and name: `after_action :audit` and `before_action :audit`
      # are two entries in the chain and Rails runs both.
      # The whole ancestor entry, not only its `from:`: an entry the walk
      # could not attribute carries `provenance` instead, and merging only
      # `from` dropped that on the tier the label exists for.
      attribution_of = parent.to_h { |f| [ entry_key(f), f.slice(:from, :provenance) ] }
      declared_on = attribution_of
      declared_names = declared.map { |f| entry_key(f) }.to_set

      # A filter this body declares is its own, whatever an ancestor declares
      # as well. The runtime tier's list also carries names it only inherits,
      # and those are the ones that move: they carry no `declared` mark.
      inherited_here = ->(f) { declared_on.key?(entry_key(f)) && !f[:declared] }
      own = mark_conditional_skips(applicable.reject(&inherited_here), conditions, action)
      inherited = mark_conditional_skips(
        parent.reject { |f| declared_names.include?(entry_key(f)) } +
          applicable.select(&inherited_here)
            .map { |f| f.except(:from, :provenance).merge(attribution_of[entry_key(f)]) }, conditions, action
      )

      { own: own,
        inherited: inherited + unplaced_conditional_skips(own + inherited, conditions, action,
                                                          declares | declared.map { |f| f[:name].to_s }.to_set),
        skipped: skipped }
    end

    # A skip of a name no ancestor in the payload declares is the only
    # evidence the filter is in the chain, usually because a concern declared
    # it. `known` keeps a filter the walk saw and took out from coming back.
    def unplaced_conditional_skips(placed, conditions, action, known = Set.new)
      names = placed.map { |f| f[:name].to_s }.to_set | known
      conditions.reject { |name, _| names.include?(name) }.map do |name, skip|
        mark_conditional_skips([ { kind: skip[:kind] || "before", name: name } ], conditions, action).first
      end
    end

    # A conditional skip never removes the filter; the record carries the
    # condition. See CONTEXT.md, "Filter chain".
    def conditional?(skip, action)
      !skip[:if].nil? || !skip[:unless].nil? || partial?(skip, action)
    end

    # Partial only where the answer covers every action: a per-action answer
    # has already put the skip through `applies?`.
    def partial?(skip, action)
      action.nil? && (Array(skip[:only]).any? || Array(skip[:except]).any?)
    end

    def absolute_names(skips, action)
      skips.reject { |skip| skip[:evidence] || conditional?(skip, action) }.map { |skip| skip[:name] }
    end

    def conditions_by_name(skips, action)
      skips.select { |skip| skip[:evidence] || conditional?(skip, action) }
        .to_h { |skip| [ skip[:name], skip ] }
    end

    # A real condition always outranks an evidence record, however close the
    # class carrying the evidence.
    def merge_conditions(weaker, stronger)
      weaker.merge(stronger) { |_name, weak, strong| strong[:evidence] ? weak : strong }
    end

    def mark_conditional_skips(filters, conditions, action)
      return filters if conditions.empty?

      filters.map do |filter|
        skip = conditions[filter[:name].to_s]
        next filter unless skip

        filter.merge(skip_tail(skip, action))
      end
    end

    def skip_tail(skip, action)
      tail = {}
      return tail if skip[:evidence]

      tail[:skipped_if] = condition_text(skip[:if]) if skip[:if]
      tail[:skipped_unless] = condition_text(skip[:unless]) if skip[:unless]
      return tail unless partial?(skip, action)

      tail[:skipped_on] = action_names(skip[:only]) if Array(skip[:only]).any?
      tail[:skipped_except] = action_names(skip[:except]) if Array(skip[:except]).any?
      tail
    end

    def action_names(value)
      Array(value).map(&:to_s).join(", ")
    end

    # A lambda has no name to print, and the filter records already spell
    # that "[INFERRED]".
    def condition_text(value)
      text = Array(value).map(&:to_s).join(", ")
      text.match?(/\A[A-Za-z_][A-Za-z0-9_]*[?!]?\z/) ? text : "[INFERRED]"
    end

    # `only` wins over `except`; declaring neither means every action. A nil
    # action asks about the controller, where every filter counts.
    def applies?(filter, action)
      return true unless action

      only = Array(filter[:only]).map(&:to_s)
      return only.include?(action) if only.any?

      except = Array(filter[:except]).map(&:to_s)
      return !except.include?(action) if except.any?

      true
    end

    # Every ancestor's filters, closest first, deduped by name and tagged
    # with the ancestor they were found on, plus the set of names the walk
    # dropped. The runtime tier's list already carries the whole chain, so the
    # dedupe is what keeps it correct; the static tier's holds one class's
    # declarations only, so the walk is what completes it. Each class's skips
    # join the set as the walk reaches it, so a filter an intermediate ancestor
    # skipped never reaches the child. An ancestor the payload does not carry
    # ends it: reconstructing a path from a class name breaks on every app
    # inflection. A bare superclass is resolved against the enclosing namespace
    # first, the way Ruby does.
    def parent_filters(ctx, parent_class, action, skipped, root:, within: nil)
      controllers = Payload.controllers(ctx)
      seen = Set.new
      found = {}
      attributed = Set.new
      conditions = {}
      declares = Set.new
      # Where in the walk each entry was first seen, so the list can be
      # emitted root first while the order inside one class is kept.
      positions = {}
      evidence = {}
      depth = 0
      dropped = skipped.map(&:to_s).to_set
      name = Introspectors::ActionResolver.resolve_entry_name(controllers, parent_class, within)

      while name && !seen.include?(name)
        seen << name
        depth += 1
        info = controllers[name]
        source = info.is_a?(Hash) ? nil : base_controller_source(name, root)
        info ||= { filters: Introspectors::ControllerFilters.from_source(source) } if source
        break unless info.is_a?(Hash)

        # The class that skips a filter must not contribute it either: in the
        # booted tier its own list is the reflection list, which carries every
        # inherited name.
        skips = own_skips(ctx, name, info, action, root: root, source: source)
        dropped.merge(absolute_names(skips, action))
        # The walk runs closest ancestor first, so a nearer class's condition
        # is the one the child inherits.
        conditions = merge_conditions(conditions_by_name(skips, action), conditions)
        carried = Array(info[:filters]).grep(Hash).reject { |f| f[:skipped] }
        # Counted before the rejects below, so a conditional skip of a name
        # the walk did see is never mistaken for a skip of a declaration it
        # could not. A skip record is not a sighting, hence the reject above.
        declares.merge(carried.map { |f| f[:name].to_s })
        # Whether this class's own body was read at all. Without that, an
        # unmarked filter is a filter nobody could check, not one a gem
        # installed - an engine's ApplicationController and a concern-only
        # payload both land there, and dropping their attribution would lose
        # the answer rather than correct it.
        body_known = carried.any? { |f| f[:declared] }
        carried.select { |f| applies?(f, action) }
          .reject { |f| dropped.include?(f[:name].to_s) }
          .each { |f| record_attribution(found, attributed, f, name, positions, depth, evidence, body_known) }

        name = Introspectors::ActionResolver.resolve_entry_name(controllers, info[:parent_class], name)
      end

      [ run_order(found, attributed, positions, evidence), dropped, conditions, declares ]
    end

    # The closest ancestor carrying a filter keeps its constraints, but a
    # booted ancestor carries names it only inherits, so `from:` moves on to
    # the first ancestor whose own body declared it.
    def record_attribution(found, attributed, filter, ancestor, positions = {}, depth = 0,
                           evidence = {}, body_known = false)
      key = entry_key(filter)
      if found.key?(key)
        found[key] = found[key].merge(from: ancestor) if filter[:declared] && !attributed.include?(key)
      else
        found[key] = filter.merge(from: ancestor)
        positions[key] = depth
        evidence[key] = body_known
      end
      attributed << key if filter[:declared]
    end

    # Rails runs the root's callbacks first, so the inherited list reads that
    # way: the walk's class order reversed, each class's own order kept. A
    # filter no ancestor's body declares is installed from somewhere else -
    # a gem's `on_load :action_controller` block, the framework, a concern -
    # and crediting it to the nearest app class sent an agent to a file that
    # never mentions it.
    def run_order(found, attributed, positions, evidence = {})
      found.keys
        .each_with_index
        .sort_by { |key, index| [ -positions.fetch(key, 0), index ] }
        .map do |key, _|
          entry = found[key]
          next entry if attributed.include?(key) || !evidence[key]

          entry.merge(from: nil, provenance: "not declared in the controller chain").compact
        end
    end

    # One entry in the chain. A skip names a filter by name, and a chain entry
    # is a kind and a name: a class can declare both `before_action :audit` and
    # `after_action :audit`, and both run.
    def entry_key(filter)
      [ filter[:kind].to_s, filter[:name].to_s ]
    end

    # What one class's own body takes out of the chain for this action: the
    # skip records its payload carries plus the skips its file states, minus
    # whatever the same body declares again after the skip. Each entry is
    # { name:, if:, unless: }; the payload's record comes first because the
    # walk that built it already normalized the condition.
    def own_skips(ctx, controller_name, info, action, root:, source: nil)
      redeclared = redeclared_names(info, action)
      (skip_flag_records(info, action) +
        skip_source_records(ctx, controller_name, action, root: root, source: source) +
        evidence_skips(ctx, controller_name, info, action, root: root, source: source))
        .reject { |skip| redeclared.include?(skip[:name]) }
        .uniq { |skip| skip[:name] }
    end

    # A skip whose only:/except: leaves this action alone takes nothing out
    # here, but nothing can be skipped that the chain does not run, so it is
    # still the only evidence the filter is there. Marked so it never reads
    # as a skip of this action.
    def evidence_skips(ctx, controller_name, info, action, root:, source: nil)
      return [] unless action

      (skip_flag_records(info, nil) +
        skip_source_records(ctx, controller_name, nil, root: root, source: source))
        .reject { |skip| applies?(skip, action) }
        .map { |skip| skip.merge(evidence: true) }
    end

    # The static walk marks a skip macro on the record, so a payload that
    # carries no readable file still knows what the class skipped. The record
    # carries the skip's own only:/except:, and a skip covers those actions
    # only.
    def skip_flag_records(info, action)
      last_records(info, action).select { |_, f| f[:skipped] }
        .map do |name, f|
          { name: name, kind: f[:kind], if: f[:if], unless: f[:unless], only: f[:only], except: f[:except] }
        end
    end

    # A class body can skip a filter and then declare it again. Rails runs
    # whichever came last, so the later record decides, and the name is no
    # longer skipped for this class or for its children.
    def redeclared_names(info, action)
      last = last_records(info, action)
      Array(info[:filters]).grep(Hash)
        .select { |f| f[:skipped] }
        .map { |f| f[:name].to_s }
        .select { |name| last[name] && !last[name][:skipped] }
        .uniq
    end

    # The last record for each name that covers this action, in declaration
    # order.
    def last_records(info, action)
      Array(info[:filters]).grep(Hash).each_with_object({}) do |f, acc|
        acc[f[:name].to_s] = f if applies?(f, action)
      end
    end

    # Skips live only in the class body, so they are read from the file the
    # introspector carried - never a path derived from the class name. A file
    # SafePath refuses (too large, unreadable, gone) skips nothing.
    def skip_source_records(ctx, controller_name, action, root: nil, source: nil)
      source ||= carried_source(ctx, controller_name, root)
      return [] unless source

      skip_calls(source).flat_map do |call|
        options = call[:options] || {}
        next [] unless applies?({ only: options[:only], except: options[:except] }, action)

        kind = call[:name].to_s.sub(/\Askip_/, "").sub(/_action\z/, "")
        Array(call[:arguments]).select { |a| a.is_a?(Symbol) || a.is_a?(String) }
          .map do |a|
            { name: a.to_s, kind: kind, if: options[:if], unless: options[:unless],
              only: options[:only], except: options[:except] }
          end
      end.uniq { |skip| skip[:name] }
    rescue => e
      RailsAiContext.debug_fail(e, [], label: "ActionFilters skip_source_records")
    end

    # ApplicationController is deliberately not in the listing: it would sit in
    # every chain, and a walk that ended there would miss a filter every
    # controller runs while the generated overview, reading the same file,
    # printed it. Only a name the app has a file for is read,
    # so a gem-owned parent, or one an inflection renames, still ends the walk.
    def base_controller_source(name, root)
      root ||= default_root
      return nil unless root

      relative = "#{name.to_s.underscore}.rb"
      path = PathResolver.controller_dirs(root.to_s).map { |dir| File.join(dir, relative) }
                         .find { |candidate| File.exist?(candidate) }
      path && SafeFile.read(path)
    end

    # A carried path came from the gem's own walk, and that walk keeps the
    # spelling the app uses, so realpath containment would refuse a
    # symlinked pack. The size cap still applies.
    def carried_source(ctx, controller_name, root)
      file = Payload.controller_file(ctx, controller_name)
      return nil unless file

      root ||= default_root
      return nil unless root

      SafeFile.read(File.join(root.to_s, file))
    end

    def skip_calls(source)
      Introspectors::SourceIntrospector.walk_source(source, {
        skips: -> { Introspectors::Listeners::MethodCallListener.new(names: SKIP_MACROS) }
      })[:skips] || []
    end

    private_class_method :default_root, :split, :applies?, :parent_filters, :skip_source_records, :carried_source,
                         :entry_key,

                         :skip_calls, :skip_flag_records, :redeclared_names, :last_records, :own_skips,
                         :record_attribution, :conditional?, :partial?, :absolute_names, :conditions_by_name,
                         :merge_conditions, :mark_conditional_skips, :skip_tail, :action_names, :condition_text,
                         :unplaced_conditional_skips, :evidence_skips
  end
end
