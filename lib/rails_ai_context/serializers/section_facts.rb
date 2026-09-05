# frozen_string_literal: true

module RailsAiContext
  module Serializers
    # The facts every context surface states about a Rails app, each rendered
    # in one place. Five serializers and three tools carried their own copy
    # of these lines; the copies drifted, and a warnings section that only
    # two of four generated files rendered made a half-failed run look clean
    # in the other two.
    module SectionFacts
      module_function

      # A file generated without booting the app carries different counts from
      # one generated with it. Every surface that renders a header says which
      # it is holding, in these words.
      def static_notice(ctx)
        return nil unless ctx[:tier].to_s == "static"

        "#{Confidence::STATIC} Generated without booting the app: read from source files, " \
          "so counts can differ from a booted run."
      end

      # A rules file opens with frontmatter the editor parses, so the notice
      # goes under the heading instead of at the top of the file.
      def static_notice_lines(ctx)
        notice = static_notice(ctx)
        notice ? [ notice, "" ] : []
      end

      def models_line(ctx)
        models = Payload.models(ctx)
        models.any? ? "- Models: #{models.size}" : nil
      end

      def database_line(ctx)
        schema = Payload.section(ctx, :schema)
        return nil unless schema

        "- Database: #{SchemaAdapter.label(ctx)} - #{CountPhrase.call(schema[:total_tables].to_i, "table")}"
      end

      def auth_line(ctx)
        auth = Payload.section(ctx, :auth)
        return nil unless auth

        parts = []
        parts << "Devise" if auth.dig(:authentication, :devise)&.any?
        parts << "Rails 8 auth" if auth.dig(:authentication, :rails_auth)
        parts << "Pundit" if auth.dig(:authorization, :pundit)&.any?
        parts << "CanCanCan" if auth.dig(:authorization, :cancancan)
        parts.any? ? "- Auth: #{parts.join(' + ')}" : nil
      end

      def assets_line(ctx)
        assets = Payload.section(ctx, :assets)
        return nil unless assets

        # The pipeline introspector says "none" rather than nil, which reads as
        # a pipeline named none once it is joined with the rest.
        parts = [ assets[:pipeline], assets[:js_bundler], assets[:css_framework] ].compact
        parts.delete("none")
        parts.any? ? "- Assets: #{parts.join(', ')}" : nil
      end

      def associations_list(model_data)
        (model_data[:associations] || [])
          .select { |a| a.is_a?(Hash) }
          .map { |a| "#{a[:type]} :#{a[:name]}" }
      end

      # The introspector records each strong-params method as a hash of its
      # permit detail; only the listing surfaces want the method names.
      def strong_param_names(controller_data)
        Array(controller_data[:strong_params]).map { |sp| (sp.is_a?(Hash) ? sp[:name] : sp).to_s }
      end

      # A file the walk could not read carries an error and no facts. Saying
      # nothing there reads as a controller with nothing in it, which is a
      # different answer, so every surface states the error instead.
      def unread_phrase(controller_data)
        error = controller_data.is_a?(Hash) ? controller_data[:error] : nil
        error ? "(could not be read: #{error})" : nil
      end

      # A base controller declares no action of its own. Joining an empty list
      # leaves the listing line ending in a dash, so it says what it found.
      def actions_phrase(controller_data)
        unread = unread_phrase(controller_data)
        return unread if unread

        actions = Array(controller_data[:actions])
        actions.any? ? actions.join(", ") : "(no public actions)"
      end

      # A skipped filter is not one the action runs, so the listings say so
      # the way the per-action answer and docs/CONFIGURATION.md do. With a
      # context the line is resolved through ActionFilters, the same source
      # the single-controller answer reads, so the two cannot disagree about
      # what a class inherits or skips.
      def filters_line(controller_data, ctx: nil, name: nil, root: nil)
        parts = ctx && name ? chain_filter_parts(ctx, name, root) : own_filter_parts(controller_data)
        return nil if parts.empty?

        "- Filters: #{parts.join(', ')}"
      end

      def own_filter_parts(controller_data)
        Array(controller_data[:filters]).grep(Hash).map do |f|
          f[:skipped] ? "~~#{f[:name]}~~ _(skipped)_" : "#{f[:kind]} #{f[:name]}#{skip_condition_tail(f)}"
        end
      end

      def chain_filter_parts(ctx, name, root)
        chain = ActionFilters.for_controller(ctx, name, root: root)
        (chain[:inherited] + chain[:own]).map { |f| "#{f[:kind]} #{f[:name]}#{skip_condition_tail(f)}" } +
          chain[:skipped].map { |skipped| "~~#{skipped}~~ _(skipped)_" }
      end

      # A skip carrying if:/unless: leaves the filter in the chain, so the
      # line says on what the class takes it out instead of striking it
      # through.
      def skip_condition_tail(filter)
        tail = +""
        tail << " (skipped if: #{filter[:skipped_if]})" if filter[:skipped_if]
        tail << " (skipped unless: #{filter[:skipped_unless]})" if filter[:skipped_unless]
        tail
      end

      # What every controller listing states under the name, in one order.
      # `rescue_handlers:` because only the per-controller listing renders
      # them; the compressed group and the generated files do not.
      def controller_summary_lines(controller_data, rescue_handlers: false, ctx: nil, name: nil, root: nil)
        unread = unread_phrase(controller_data)
        return [ "- Could not be read: #{controller_data[:error]}" ] if unread

        lines = []
        filters = filters_line(controller_data, ctx: ctx, name: name, root: root)
        lines << filters if filters
        params = strong_param_names(controller_data)
        lines << "- Strong params: #{params.join(', ')}" if params.any?
        return lines unless rescue_handlers

        rescues = rescue_handler_lines(controller_data)
        lines << "- Rescue from: #{rescues.join(', ')}" if rescues.any?
        lines
      end

      # A block-form rescue_from carries no handler, so the exception name
      # alone is the whole line.
      def rescue_handler_lines(controller_data)
        Array(controller_data[:rescue_from]).map do |entry|
          next entry.to_s unless entry.is_a?(Hash)

          entry[:handler] ? "#{entry[:exception]} -> #{entry[:handler]}" : entry[:exception].to_s
        end
      end

      # "What config/locales holds" and "what the app enables" are different
      # questions with the same name, and only the second one is
      # available_locales. Say which one this answer is.
      def available_locales_label(i18n_data)
        return "Available locales" unless locales_from_files?(i18n_data)

        "Available locales (from locale files)"
      end

      # The stack line the generated files carry makes the same claim the
      # Internationalization section does, so it carries the same qualifier.
      def i18n_line(ctx)
        i18n_data = Payload.section(ctx, :i18n) || {}
        locales = Payload.available_locales(ctx)
        return nil unless locales.size > 1

        qualifier = locales_from_files?(i18n_data) ? " from locale files" : ""
        "- I18n: #{CountPhrase.call(locales.size, "locale")}#{qualifier} (#{locales.first(5).join(', ')})"
      end

      def locales_from_files?(i18n_data)
        i18n_data[:available_locales_source] == "locale_files"
      end

      # Introspector failures, so a half-failed run cannot read as a clean
      # one in any generated file.
      def warnings(ctx)
        list = ctx.is_a?(Hash) ? ctx[:_warnings] : nil
        return [] if list.nil? || list.empty?

        lines = [ "", "## Warnings", "" ]
        list.each { |w| lines << "- **#{w[:introspector]}** skipped: #{w[:error]}" }
        lines
      end
    end
  end
end
