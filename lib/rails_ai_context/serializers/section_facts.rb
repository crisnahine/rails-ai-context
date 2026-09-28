# frozen_string_literal: true

module RailsAiContext
  module Serializers
    # The facts every context surface states about a Rails app, each rendered
    # in one place: five serializers and three tools state them, and a section
    # one surface renders while another drops makes a half-failed run look
    # clean on the surface that dropped it.
    module SectionFacts
      extend RailsAiContext::OptionText

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
        # No gem behind it, so it is named as a directory, not a framework.
        parts << "policies in app/policies" if auth.dig(:authorization, :policies)&.any?
        ability = auth.dig(:authorization, :ability_class)
        parts << "Ability class in #{ability}" if ability
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

      # Every bucket is named even when empty, plus the remainder: a total the named buckets
      # do not add up to reads as Phlex, or as nothing.
      def component_buckets(summary)
        buckets = [ "#{summary[:view_component].to_i} ViewComponent", "#{summary[:phlex].to_i} Phlex" ]
        unclassified = summary[:unclassified].to_i
        buckets << "#{unclassified} of no known base class" if unclassified > 0
        buckets
      end

      def associations_list(model_data)
        (model_data[:associations] || [])
          .select { |a| a.is_a?(Hash) }
          .map { |a| "#{a[:type]} #{association_name(a)}" }
      end

      # The validator class a `validates_with` names, else the attributes; never a bare "on ".
      # An enum's values as a reader names them; computed ones as their source.
      def enum_values(values)
        case values
        when Hash then values.keys.join(", ")
        when String then "`#{values}` (computed)"
        else Array(values).join(", ")
        end
      end

      def validation_target(validation)
        attrs = Array(validation[:attributes]).join(", ")
        computed = Array(validation[:computed_attributes]).map { |source| "`#{source}`" }.join(", ")
        attrs = attrs.empty? ? "#{computed} (computed)" : "#{attrs} (from #{computed})" unless computed.empty?
        attrs += " (options computed: `#{validation[:options_source]}`)" if validation[:options_source]
        target = validation[:validator].to_s
        target += " on #{attrs}" if !target.empty? && !attrs.empty?
        target.empty? ? (attrs.empty? ? "" : "on #{attrs}") : target
      end

      # A computed name prints as its source, marked: read as a symbol, `owner_name` names
      # an association no model declares.
      def association_name(association)
        return "`#{association[:name]}` (computed)" if association[:computed_name]

        name = association[:name].to_s
        name.start_with?(":") ? name : ":#{name}"
      end

      # The introspector records each strong-params method as a hash of its
      # permit detail; only the listing surfaces want the method names.
      def strong_param_names(controller_data)
        Array(controller_data[:strong_params]).map { |sp| (sp.is_a?(Hash) ? sp[:name] : sp).to_s }
      end

      # A file the walk could not read carries an error and no facts. Saying
      # nothing there reads as an entry with nothing in it, which is a
      # different answer, so every surface states the error instead, in the
      # one marker Confidence spells.
      def unread_marker(entry)
        error = entry.is_a?(Hash) ? entry[:error] : nil
        error ? Confidence.unavailable(error) : nil
      end

      # Each listing renders the name its own way; what an unread entry says
      # after the name is the same on every surface. The count above the row
      # already includes the entry, so the row says why it is thin rather
      # than leaving the reader to subtract.
      def unread_row(label, entry)
        marker = unread_marker(entry)
        marker ? "#{label} #{marker}" : nil
      end

      # A base controller declares no action of its own. Joining an empty list
      # leaves the listing line ending in a dash, so it says what it found.
      def actions_phrase(controller_data)
        unread = unread_marker(controller_data)
        return unread if unread

        actions = Array(controller_data[:actions])
        actions.any? ? actions.join(", ") : "(no public actions)"
      end

      # A skipped filter is not one the action runs, so the listings say so
      # the way the per-action answer and docs/CONFIGURATION.md do. The line
      # is resolved through ActionFilters, the same source the
      # single-controller answer reads, so the two cannot disagree about what
      # a class inherits or skips.
      def filters_line(ctx, name, root: nil)
        parts = chain_filter_parts(ctx, name, root)
        return nil if parts.empty?

        "- Filters: #{parts.join(', ')}"
      end

      def chain_filter_parts(ctx, name, root)
        chain = ActionFilters.for_controller(ctx, name, root: root)
        (chain[:inherited] + chain[:own]).map { |f| "#{f[:kind]} #{f[:name]}#{filter_condition_tail(f)}" } +
          chain[:skipped].map { |skipped| "~~#{skipped}~~ _(skipped)_" }
      end

      # Where a filter is declared: an ancestor, a concern, or a concern an
      # ancestor includes.
      def filter_origin(filter)
        concern, from = filter.values_at(:from_concern, :from)
        if concern && from then " _(from #{concern} via #{from})_"
        elsif concern || from then " _(from #{concern || from})_"
        elsif filter[:provenance] then " _(#{filter[:provenance]})_"
        else ""
        end
      end

      # A skip carrying if:/unless: or only:/except: leaves the filter in the
      # chain, so the line says where the class takes it out instead of
      # striking it through.
      # The filter's own condition first, then what a skip of it takes out.
      def filter_condition_tail(filter)
        own = +""
        own << " (if: #{option_text(filter[:if])})" if filter[:if]
        own << " (unless: #{option_text(filter[:unless])})" if filter[:unless]
        own + skip_condition_tail(filter)
      end

      def skip_condition_tail(filter)
        tail = +""
        tail << " (skipped if: #{option_text(filter[:skipped_if])})" if filter[:skipped_if]
        tail << " (skipped unless: #{option_text(filter[:skipped_unless])})" if filter[:skipped_unless]
        tail << " (skipped on: #{filter[:skipped_on]})" if filter[:skipped_on]
        tail << " (skipped except: #{filter[:skipped_except]})" if filter[:skipped_except]
        tail
      end

      # What every controller listing states under the name, in one order.
      # `rescue_handlers:` because only the per-controller listing renders
      # them; the compressed group and the generated files do not.
      def controller_summary_lines(controller_data, ctx:, name:, rescue_handlers: false, root: nil)
        unread = unread_marker(controller_data)
        return [ "- #{unread}" ] if unread

        lines = []
        filters = filters_line(ctx, name, root: root)
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
        "- I18n: #{CountPhrase.call(locales.size, "locale")}#{qualifier} " \
          "(#{locales.first(5).join(', ')})#{unread_locale_clause(i18n_data)}"
      end

      # Counts dirs, not files: "N more" beside a locale count reads as N more locales.
      def unread_locale_clause(i18n_data)
        return "" unless i18n_data[:in_repo_locale_files].to_i.positive?

        "; #{CountPhrase.call(i18n_data[:in_repo_locale_dirs], 'in-repo engine locale dir')} not read"
      end

      def locales_from_files?(i18n_data)
        i18n_data[:available_locales_source] == "locale_files"
      end

      # What a locale file count leaves out, for every surface that prints one.
      def unread_locale_note(i18n_data)
        unread = i18n_data[:in_repo_locale_files].to_i
        return "" unless unread.positive?

        " (#{unread} more under #{CountPhrase.call(i18n_data[:in_repo_locale_dirs], 'in-repo engine locale dir')}, " \
          "not read)"
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
