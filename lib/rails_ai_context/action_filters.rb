# frozen_string_literal: true

module RailsAiContext
  # Which filters run for one action of one controller. The VFS resource and
  # the controller tool each decided this for themselves, from the same
  # payload plus their own line regexes over the source, and disagreed on
  # `except:`, on multi-name skips, and on whether an inherited filter was
  # listed twice.
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

    # { own: [filter], inherited: [filter], skipped: [name] }.
    def for(ctx, controller_name, action)
      info = Payload.controllers(ctx)[controller_name.to_s]
      return { own: [], inherited: [], skipped: [] } unless info.is_a?(Hash)

      action = action.to_s
      skipped = skipped_names(ctx, controller_name, action)
      declared = Array(info[:filters]).grep(Hash)
      applicable = declared.select { |f| applies?(f, action) }
        .reject { |f| skipped.include?(f[:name].to_s) }

      parent = parent_filters(ctx, info[:parent_class], action, skipped)
      parent_names = parent.map { |f| f[:name].to_s }.to_set
      declared_names = declared.map { |f| f[:name].to_s }.to_set

      {
        own: applicable.reject { |f| parent_names.include?(f[:name].to_s) },
        inherited: parent.reject { |f| declared_names.include?(f[:name].to_s) } +
          applicable.select { |f| parent_names.include?(f[:name].to_s) },
        skipped: skipped
      }
    end

    # `only` wins over `except`; declaring neither means every action.
    def applies?(filter, action)
      only = Array(filter[:only]).map(&:to_s)
      return only.include?(action) if only.any?

      except = Array(filter[:except]).map(&:to_s)
      return !except.include?(action) if except.any?

      true
    end

    # The parent's own filters, for the entries the child's list is missing.
    # A parent the payload does not carry answers none: reconstructing its
    # path from the class name breaks on every app inflection.
    def parent_filters(ctx, parent_class, action, skipped)
      return [] unless parent_class

      info = Payload.controllers(ctx)[parent_class.to_s]
      return [] unless info.is_a?(Hash)

      Array(info[:filters]).grep(Hash)
        .select { |f| applies?(f, action) }
        .reject { |f| skipped.include?(f[:name].to_s) }
    end

    # Skips live only in the class body, so they are read from the file the
    # introspector carried - never a path derived from the class name.
    def skipped_names(ctx, controller_name, action)
      file = Payload.controller_file(ctx, controller_name)
      return [] unless file

      source, = SafePath.read(file, under: RailsAiContext.default_app.root.to_s)
      return [] unless source

      skip_calls(source).flat_map do |call|
        next [] unless applies?({ only: call.dig(:options, :only), except: call.dig(:options, :except) }, action)

        Array(call[:arguments]).grep(Symbol).map(&:to_s)
      end.uniq
    rescue => e
      $stderr.puts "[rails-ai-context] ActionFilters skipped_names failed: #{e.message}" if ENV["DEBUG"]
      []
    end

    def skip_calls(source)
      Introspectors::SourceIntrospector.walk_source(source, {
        skips: -> { Introspectors::Listeners::MethodCallListener.new(names: SKIP_MACROS) }
      })[:skips] || []
    end
  end
end
