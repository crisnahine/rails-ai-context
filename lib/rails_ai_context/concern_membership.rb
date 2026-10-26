# frozen_string_literal: true

module RailsAiContext
  # One answer to "which mixed-in modules count as this class's concerns",
  # in the payload sense CONTEXT.md pins. Five renderers each carried their
  # own filter set and they disagreed: one hid every namespaced concern, one
  # dropped the `excluded_concerns` config, and the two tiers of the
  # controller answer used different rules entirely.
  module ConcernMembership
    STDLIB = %w[Kernel JSON PP Marshal MessagePack ERB].freeze
    # The hooks Ruby runs on the module itself for each way of mixing it in,
    # so what their bodies declare is every includer's.
    HOOKS_BY_MACRO = {
      include: %w[included append_features], prepend: %w[prepended prepend_features], extend: %w[extended]
    }.freeze
    MIXIN_HOOKS = HOOKS_BY_MACRO.values.flatten.freeze
    # The macros that give the class a module's methods as class methods.
    SINGLETON_MACROS = %i[extend singleton_include singleton_prepend].freeze
    # The block ActiveSupport::Concern runs for each.
    CONCERN_BLOCKS = { include: :included, prepend: :prepended }.freeze
    # Rails:: covers the route helpers Rails 8 mixes into every controller
    # (Rails::Engine::LazyRouteSet::MountedHelpers).
    FRAMEWORK_PREFIXES = %w[
      ActiveModel:: ActiveRecord:: ActiveSupport::
      ActionController:: ActionDispatch:: AbstractController:: Rails::
    ].freeze
    # Rails defines these inside the model class itself, so no namespace rule
    # catches them.
    GENERATED = %w[GeneratedAssociationMethods GeneratedAttributeMethods].freeze

    module_function

    # The payload sense: a module in the ancestor chain that is part of the
    # class's story. Framework plumbing and the stdlib are not; a gem
    # capability module (Devise::Models::*, Turbo::Broadcastable) is.
    def payload?(name)
      candidate?(name) && !excluded?(name)
    end

    # The same rule without the configured key: what would be part of the
    # story if the app had not asked to hide it. The walk asks the two halves
    # apart, because a name the key hid is worth counting and framework
    # plumbing never was.
    def candidate?(name)
      return false if name.nil?

      name = name.to_s
      return false if STDLIB.any? { |p| name == p || name.start_with?("#{p}::") }
      return false if FRAMEWORK_PREFIXES.any? { |prefix| name.start_with?(prefix) }

      GENERATED.none? { |g| name == g || name.end_with?("::#{g}") }
    end

    # The `excluded_concerns` patterns alone, for a catalogue whose entries
    # are already known to be concerns. The key hides a concern everywhere,
    # not only where one class's list would have named it.
    def excluded?(name)
      RailsAiContext.configuration.excluded_concerns.any? { |pattern| name.to_s.match?(pattern) }
    end

    def payload(names)
      Array(names).select { |name| payload?(name) }
    end

    # The keys a class reads from its own file by owner, so a module nested in
    # that file is read for them on its own.
    OWNED_KEYS = %i[callbacks macros scopes associations validations enums].freeze

    # Matched on the last segment: `module Shop; module Trackable` and
    # `module Shop::Trackable` both write one constant.
    def owned_by(records, name, others: [])
      return Array(records) if Array(records).none? { |record| record.key?(:owner) }

      own = own_owner(records, name, others: others)
      Array(records).filter_map do |record|
        if record[:receiver]
          mixed_into(record, name, others: others)
        elsif own && Array(record[:owner]).join("::") == own
          record
        end
      end
    end

    # `Note.prepend X` mixes X into Note as `prepend X` in Note's body would. The record is `name`'s
    # when, of `name` and the file's `others`, `name` is the one the receiver's nesting reaches first.
    def mixed_into(record, name, others: [])
      reached = Introspectors::DeclaredConstant.lookup(record[:receiver], nesting: Introspectors::DeclaredConstant.record_nesting(record),
                                                                          exists: ->(candidate) { candidate == name.to_s || others.include?(candidate) })
      return unless reached == name.to_s

      own = record.except(:receiver)
      record.key?(:ancestor) ? own.merge(ancestor: CONCERN_BLOCKS.key?(record[:macro])) : own
    end

    # A class's own records and those of the modules in its file it includes, never
    # another class's. `classes` names the file's classes; `modules` maps its modules to their nodes.
    def owned_with_modules(records, name, classes, mixins, modules)
      own = owned_by(records, name, others: classes - [ name.to_s ])
      included = included_modules(mixins, name, classes, modules)
      own + Array(records).select { |record| included.include?(Array(record[:owner]).join("::")) && !own.include?(record) }
    end

    # The modules from other files the class and its in-file modules mix in; the
    # in-file ones are read where they are written.
    def mixins_with_modules(mixins, name, classes, modules)
      lines = included_lines(mixins, name, classes, modules)
      own = owned_by(mixins, name, others: classes - [ name.to_s ]).reject { |mixin| in_file?(mixin, modules) }
      chained = Array(mixins).filter_map do |mixin|
        owner = Array(mixin[:owner]).join("::")
        mixin if lines.key?(owner) && !in_file?(mixin, modules, line: lines[owner])
      end
      own + chained
    end

    # Whether the mixin reaches a module the file defines, above `line` when one is given.
    def in_file?(mixin, modules, line: mixin[:location])
      node = modules[local_name(mixin, modules, line: line)]
      !node.nil? && (line.nil? || node.location.start_line <= line)
    end

    # The modules in the file a class includes, and the ones those include in turn.
    def included_modules(mixins, name, classes, modules)
      included_lines(mixins, name, classes, modules).keys
    end

    # Each included in-file module with the line of the class's include that brought it
    # in. Only an include or prepend runs a module's `included` block on the class, and
    # a module's own include runs then, so it is read against that line.
    def included_lines(mixins, name, classes, modules)
      ancestors = Array(mixins).select { |mixin| mixin[:ancestor] }
      roots = owned_by(ancestors, name, others: classes - [ name.to_s ]).select { |mixin| in_file?(mixin, modules) }
      # The earliest include runs first, so a module keeps the first line that reaches it.
      roots.sort_by { |mixin| mixin[:location] || Float::INFINITY }.each_with_object({}) do |root, found|
        line = root[:location]
        queue = [ local_name(root, modules) ]
        until queue.empty?
          key = queue.shift
          next if found.key?(key)

          found[key] = line
          ancestors.each do |mixin|
            queue << local_name(mixin, modules, line: line) if Array(mixin[:owner]).join("::") == key && in_file?(mixin, modules, line: line)
          end
        end
      end
    end

    # The constant a mixin names as Ruby reaches it from where it is written: `include
    # Trackable` in Payment's body is Payment::Trackable when the file defines it by `line`,
    # or when `exists` names the module the app has elsewhere, which can differ from the spelling tried.
    def local_name(mixin, modules, line: mixin[:location], exists: nil, later: nil)
      name = mixin[:name].to_s
      in_file = lambda do |candidate|
        node = modules[candidate]
        node && (line.nil? || node.location.start_line <= line)
      end
      Introspectors::DeclaredConstant.reach(mixin[:top_level] ? "::#{name}" : name, nesting: Introspectors::DeclaredConstant.record_nesting(mixin),
                                            exists: ->(candidate) { in_file.call(candidate) ? candidate : named_by(exists&.call(candidate), candidate) },
                                            later_ancestors: later) || name.delete_prefix("::")
    end

    # `exists` answers with the module the app has (a String) or only that it has the spelling tried.
    def named_by(answer, candidate) = answer.is_a?(String) ? answer : (candidate if answer)

    # The full name; else the shortest owner ending in all its segments; else in its last,
    # unless that owner is one of `others`, so Legacy::Payment never reads Payment's.
    def own_owner(records, name, others: [])
      owners = Array(records).map { |record| Array(record[:owner]).join("::") }
      return name.to_s if owners.include?(name.to_s)

      segments = name.to_s.split("::")
      tail = owners.select do |owner|
        parts = owner.split("::").last(segments.size)
        parts.size == segments.size && parts.zip(segments).all? { |own, want| own.casecmp?(want) }
      end.min_by(&:length)
      tail || owners.reject { |owner| others.include?(owner) }
                    .select { |owner| owner.split("::").last.to_s.casecmp?(segments.last.to_s) }.min_by(&:length)
    end

    # Static reading: only the mixins reflection would report, by the
    # listener's ancestor flag, so both tiers name the same modules.
    def mixin_names(mixins)
      Array(mixins).select { |mixin| mixin[:ancestor] }.map { |mixin| mixin[:name] }.uniq
    end

    # Booted reading: the ancestor chain's non-class modules, through the
    # payload rule.
    def from_ancestors(klass)
      payload(klass.ancestors.select { |mod| mod.is_a?(Module) && !mod.is_a?(Class) }.map(&:name).compact)
    end

    def from_mixins(mixins)
      payload(mixin_names(mixins))
    end

    # The narrower display sense: concerns the app itself defines, decided by
    # whether ConcernPaths can name their file.
    def app_owned(names, root)
      payload(names).select { |name| ConcernPaths.find_file(root.to_s, name) }
    end
  end
end
