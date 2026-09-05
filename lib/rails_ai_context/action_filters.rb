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
      skipped = absolute_names(skips)
      # A record the walk marked as a skip states what does not run, so it is
      # never a filter, on the class that declared it or on a child.
      declared = Array(info[:filters]).grep(Hash).reject { |f| f[:skipped] }
      parent, dropped, inherited_conditions = parent_filters(ctx, info[:parent_class], action, skipped,
                                                             root: root, within: controller_name.to_s)
      conditions = inherited_conditions.merge(conditions_by_name(skips))
      # The runtime tier's list is the whole chain, so an ancestor's skip has
      # to be taken out of this class's list too. What this body declares
      # itself survives an ancestor's skip: Rails re-adds a callback the class
      # declares again. Its own skip binds it either way.
      inherited_skips = dropped - skipped.map(&:to_s)
      applicable = declared.select { |f| applies?(f, action) }
        .reject { |f| skipped.include?(f[:name].to_s) }
        .reject { |f| inherited_skips.include?(f[:name].to_s) && !f[:declared] }
      declared_on = parent.to_h { |f| [ f[:name].to_s, f[:from] ] }
      declared_names = declared.map { |f| f[:name].to_s }.to_set

      own = mark_conditional_skips(applicable.reject { |f| declared_on.key?(f[:name].to_s) }, conditions)
      inherited = mark_conditional_skips(
        parent.reject { |f| declared_names.include?(f[:name].to_s) } +
          applicable.select { |f| declared_on.key?(f[:name].to_s) }
            .map { |f| f.merge(from: declared_on[f[:name].to_s]) }, conditions
      )

      { own: own, inherited: inherited + unplaced_conditional_skips(own + inherited, conditions), skipped: skipped }
    end

    # Nothing can be skipped that the chain does not run, so a conditional
    # skip of a name no ancestor the payload carries declares is still
    # evidence the filter is there. Concerns are the usual reason the walk
    # cannot see the declaration.
    def unplaced_conditional_skips(placed, conditions)
      names = placed.map { |f| f[:name].to_s }.to_set
      conditions.reject { |name, _| names.include?(name) }.map do |name, skip|
        mark_conditional_skips([ { kind: skip[:kind] || "before", name: name } ], conditions).first
      end
    end

    # A skip carrying if:/unless: takes the filter out on some requests and
    # not on others, so it never removes the filter from the chain. The
    # filter keeps its place and carries the condition, which is the only
    # honest answer to "does this run".
    def conditional?(skip)
      !skip[:if].nil? || !skip[:unless].nil?
    end

    def absolute_names(skips)
      skips.reject { |skip| conditional?(skip) }.map { |skip| skip[:name] }
    end

    def conditions_by_name(skips)
      skips.select { |skip| conditional?(skip) }.to_h { |skip| [ skip[:name], skip ] }
    end

    def mark_conditional_skips(filters, conditions)
      return filters if conditions.empty?

      filters.map do |filter|
        skip = conditions[filter[:name].to_s]
        next filter unless skip

        tail = {}
        tail[:skipped_if] = condition_text(skip[:if]) if skip[:if]
        tail[:skipped_unless] = condition_text(skip[:unless]) if skip[:unless]
        filter.merge(tail)
      end
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
      dropped = skipped.map(&:to_s).to_set
      name = Introspectors::ActionResolver.resolve_entry_name(controllers, parent_class, within)

      while name && !seen.include?(name)
        seen << name
        info = controllers[name]
        break unless info.is_a?(Hash)

        # The class that skips a filter must not contribute it either: in the
        # booted tier its own list is the reflection list, which carries every
        # inherited name.
        skips = own_skips(ctx, name, info, action, root: root)
        dropped.merge(absolute_names(skips))
        # The walk runs closest ancestor first, so a nearer class's condition
        # is the one the child inherits.
        conditions = conditions_by_name(skips).merge(conditions)
        Array(info[:filters]).grep(Hash)
          .reject { |f| f[:skipped] }
          .select { |f| applies?(f, action) }
          .reject { |f| dropped.include?(f[:name].to_s) }
          .each { |f| attribute(found, attributed, f, name) }

        name = Introspectors::ActionResolver.resolve_entry_name(controllers, info[:parent_class], name)
      end

      [ found.values, dropped, conditions ]
    end

    # The closest ancestor carrying a filter keeps its constraints, but a
    # booted ancestor carries names it only inherits, so `from:` moves on to
    # the first ancestor whose own body declared it.
    def attribute(found, attributed, filter, name)
      key = filter[:name].to_s
      if found.key?(key)
        found[key] = found[key].merge(from: name) if filter[:declared] && !attributed.include?(key)
      else
        found[key] = filter.merge(from: name)
      end
      attributed << key if filter[:declared]
    end

    # What one class's own body takes out of the chain for this action: the
    # skip records its payload carries plus the skips its file states, minus
    # whatever the same body declares again after the skip. Each entry is
    # { name:, if:, unless: }; the payload's record comes first because the
    # walk that built it already normalized the condition.
    def own_skips(ctx, controller_name, info, action, root:, source: nil)
      redeclared = redeclared_names(info, action)
      (skip_flag_records(info, action) +
        skip_source_records(ctx, controller_name, action, root: root, source: source))
        .reject { |skip| redeclared.include?(skip[:name]) }
        .uniq { |skip| skip[:name] }
    end

    # The static walk marks a skip macro on the record, so a payload that
    # carries no readable file still knows what the class skipped. The record
    # carries the skip's own only:/except:, and a skip covers those actions
    # only.
    def skip_flag_records(info, action)
      last_records(info, action).select { |_, f| f[:skipped] }
        .map { |name, f| { name: name, kind: f[:kind], if: f[:if], unless: f[:unless] } }
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
          .map { |a| { name: a.to_s, kind: kind, if: options[:if], unless: options[:unless] } }
      end.uniq { |skip| skip[:name] }
    rescue => e
      $stderr.puts "[rails-ai-context] ActionFilters skip_source_records failed: #{e.message}" if ENV["DEBUG"]
      []
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
                         :skip_calls, :skip_flag_records, :redeclared_names, :last_records, :own_skips,
                         :attribute, :conditional?, :absolute_names, :conditions_by_name,
                         :mark_conditional_skips, :condition_text
  end
end
