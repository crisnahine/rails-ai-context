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
      split(ctx, controller_name, action.to_s, source, root)
    end

    # The same three lists for the whole controller: every declared filter,
    # whatever actions it constrains itself to.
    def for_controller(ctx, controller_name, source: nil, root: nil)
      split(ctx, controller_name, nil, source, root)
    end

    # The app root a caller that has one need not name. Nil outside a booted
    # app, where nothing can be read anyway: the gem is required on its own
    # by the standalone binary long before `Rails` exists.
    def default_root
      return nil unless RailsAiContext.static_tier? || defined?(Rails)

      RailsAiContext.default_app&.root&.to_s
    end

    def split(ctx, controller_name, action, source, root)
      info = Payload.controllers(ctx)[controller_name.to_s]
      return { own: [], inherited: [], skipped: [] } unless info.is_a?(Hash)

      skipped = skipped_names(ctx, controller_name, action, root, source)
      declared = Array(info[:filters]).grep(Hash)
      applicable = declared.select { |f| applies?(f, action) }
        .reject { |f| skipped.include?(f[:name].to_s) }

      parent = parent_filters(ctx, info[:parent_class], action, skipped, root)
      declared_on = parent.to_h { |f| [ f[:name].to_s, f[:from] ] }
      declared_names = declared.map { |f| f[:name].to_s }.to_set

      {
        own: applicable.reject { |f| declared_on.key?(f[:name].to_s) },
        inherited: parent.reject { |f| declared_names.include?(f[:name].to_s) } +
          applicable.select { |f| declared_on.key?(f[:name].to_s) }
            .map { |f| f.merge(from: declared_on[f[:name].to_s]) },
        skipped: skipped
      }
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
    # with the ancestor they were found on. The runtime tier's list already
    # carries the whole chain, so the dedupe is what keeps it correct; the
    # static tier's holds one class's declarations only, so the walk is what
    # completes it. Each class's skips join the set as the walk passes it, so
    # a filter an intermediate ancestor skipped never reaches the child. An
    # ancestor the payload does not carry ends it: reconstructing a path from
    # a class name breaks on every app inflection.
    def parent_filters(ctx, parent_class, action, skipped, root)
      controllers = Payload.controllers(ctx)
      seen = Set.new
      found = {}
      dropped = skipped.map(&:to_s).to_set
      name = parent_class&.to_s

      while name && !seen.include?(name)
        seen << name
        info = controllers[name]
        break unless info.is_a?(Hash)

        Array(info[:filters]).grep(Hash)
          .select { |f| applies?(f, action) }
          .reject { |f| dropped.include?(f[:name].to_s) }
          .each { |f| found[f[:name].to_s] ||= f.merge(from: name) }

        dropped.merge(skipped_names(ctx, name, action, root))
        name = info[:parent_class]&.to_s
      end

      found.values
    end

    # Skips live only in the class body, so they are read from the file the
    # introspector carried - never a path derived from the class name. A file
    # SafePath refuses (too large, unreadable, gone) skips nothing.
    def skipped_names(ctx, controller_name, action, root, source = nil)
      source ||= carried_source(ctx, controller_name, root)
      return [] unless source

      skip_calls(source).flat_map do |call|
        next [] unless applies?({ only: call.dig(:options, :only), except: call.dig(:options, :except) }, action)

        Array(call[:arguments]).select { |a| a.is_a?(Symbol) || a.is_a?(String) }.map(&:to_s)
      end.uniq
    rescue => e
      $stderr.puts "[rails-ai-context] ActionFilters skipped_names failed: #{e.message}" if ENV["DEBUG"]
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

    private_class_method :default_root, :split, :applies?, :parent_filters, :skipped_names, :carried_source,
                         :skip_calls
  end
end
