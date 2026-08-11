# frozen_string_literal: true

module RailsAiContext
  module Tools
    class GetI18n < BaseTool
      tool_name "rails_get_i18n"
      description "Get I18n setup: default/available locales, backend, locale files with key counts, per-locale coverage vs the default locale, and fallbacks. " \
        "Use when: adding translations, checking locale coverage before shipping, or finding which file defines a locale. " \
        "Filter with locale:\"fr\". Omit for the full picture."

      input_schema(
        properties: {
          locale: {
            type: "string",
            description: "Show only this locale's files and coverage (e.g. \"fr\"). Default: all locales."
          },
          offset: {
            type: "integer",
            description: "Skip this many locale files for pagination. Default: 0."
          },
          limit: {
            type: "integer",
            description: "Max locale files to return. Default: 50."
          }
        }
      )

      guide_row(
        order: 40,
        mcp: "rails_get_i18n(locale:\"fr\")",
        cli_args: "locale=fr",
        summary: "Locales, locale files with key counts, per-locale coverage, fallbacks"
      )

      annotations(read_only_hint: true, destructive_hint: false, idempotent_hint: true, open_world_hint: false)

      def self.call(locale: nil, offset: 0, limit: nil, server_context: nil)
        fetch_section(:i18n, subject: "I18n introspection") do |i18n|
          available = i18n[:available_locales] || []
          if locale
            match = find_closest_match(locale, available)
            return not_found_response("Locale", locale, available, recovery_tool: "omit `locale` for the full I18n picture") unless match

            return render_locale(i18n, match, offset: offset, limit: limit)
          end

          render_overview(i18n, offset: offset, limit: limit)
        end
      end

      class << self
        private

        def render_overview(i18n, offset:, limit:)
          files = i18n[:locale_files] || []
          page = paginate(files.sort_by { |f| f[:file] }, offset: offset, limit: limit, default_limit: 50)

          lines = [ "# I18n" ]
          lines << ""
          lines << "- **Default locale:** #{i18n[:default_locale]}"
          # The backend class is a runtime fact. Printing the I18n gem's own
          # default when no app booted states it as the app's choice.
          lines << "- **Backend:** #{i18n[:backend]}" if i18n[:backend]
          lines << "- **Available locales:** #{available_list(i18n)}"
          lines << "- **Locale files:** #{i18n[:total_locale_files] || files.size}"

          coverage = i18n[:locale_coverage] || {}
          if coverage.any?
            lines << "" << "## Coverage (vs #{i18n[:default_locale]})"
            coverage.sort.each do |loc, data|
              lines << "- **#{loc}**: #{data[:coverage_pct]}% - #{count_phrase(data[:keys], "unique key")}#{coverage_gap(data)}"
            end
          end

          fallbacks = i18n[:fallbacks] || {}
          if fallbacks.any?
            lines << "" << "## Fallbacks"
            fallbacks.sort.each do |from, to|
              lines << "- **#{from}** → #{Array(to).join(', ')}"
            end
          end

          render_file_list(lines, page, "Locale Files", "_No locale files found under config/locales/._")
          text_response(lines.join("\n"))
        end

        def render_locale(i18n, locale, offset:, limit:)
          files = (i18n[:locale_files] || []).select { |f| locale_file_match?(f[:file], locale) }
          page = paginate(files.sort_by { |f| f[:file] }, offset: offset, limit: limit, default_limit: 50)

          lines = [ "# I18n: #{locale}" ]
          coverage = (i18n[:locale_coverage] || {})[locale]
          if coverage
            lines << ""
            lines << "- **Unique keys:** #{coverage[:keys]} (#{coverage[:coverage_pct]}% of #{i18n[:default_locale]})#{coverage_gap(coverage)}"
          end

          fallbacks = i18n[:fallbacks] || {}
          lines << "- **Fallbacks:** #{Array(fallbacks[locale.to_sym] || fallbacks[locale]).join(', ')}" if fallbacks[locale.to_sym] || fallbacks[locale]

          render_file_list(lines, page, "Files for #{locale}", "_No locale files found for '#{locale}'._")
          text_response(lines.join("\n"))
        end

        def coverage_gap(data)
          parts = []
          parts << "#{data[:missing]} missing" if data[:missing].positive?
          parts << "#{data[:extra]} not in default" if data[:extra].positive?
          parts.empty? ? "" : " - #{parts.join(', ')}"
        end

        def render_file_list(lines, page, heading, empty_message)
          lines << "" << "## #{heading}"
          if page[:items].any?
            page[:items].each { |f| lines << file_line(f) }
          else
            lines << empty_message
          end

          lines << "" << page[:hint] unless page[:hint].empty?
        end

        def file_line(file)
          line = "- `#{file[:file]}`"
          line += " - #{count_phrase(file[:key_count], "key")}" if file[:key_count]
          line += " - [parse error]" if file[:parse_error]
          line
        end

        # Mirrors the introspector's locale-file matching: en.yml, devise.en.yml,
        # en/users.yml, admin/en.yml.
        def locale_file_match?(file, locale)
          name = File.basename(file, ".*")
          name == locale || name.end_with?(".#{locale}") ||
            file.start_with?("#{locale}/") || file.include?("/#{locale}/")
        end

        def available_list(i18n)
          available = i18n[:available_locales] || []
          return "none detected" if available.empty?

          "#{available.join(', ')} (#{available.size})"
        end
      end
    end
  end
end
