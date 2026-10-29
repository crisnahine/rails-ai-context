# frozen_string_literal: true

module RailsAiContext
  module Serializers
    # The compact root file's sections. Include in any serializer that has a
    # `context` reader.
    module CompactSerializerHelper
      include CountPhrase
      include StackOverviewHelper
      include ToolGuideHelper

      private

      def render_header
        header_lines(:root, title: "AI Context")
      end

      def render_stack_overview
        lines = [ "## Stack" ]

        if (db_line = SectionFacts.database_line(context))
          lines << db_line
        end
        if (models_line = SectionFacts.models_line(context))
          lines << models_line
        end

        routes = Payload.section(context, :routes)
        lines << "- Routes: #{RouteCoverage.summary(routes)}" if routes

        jobs = Payload.section(context, :jobs)
        if jobs
          job_count = jobs[:jobs]&.size || 0
          worker_count = jobs[:workers]&.size || 0
          mailer_count = jobs[:mailers]&.size || 0
          channel_count = jobs[:channels]&.size || 0
          parts = []
          parts << count_phrase(job_count, "job") if job_count > 0
          parts << count_phrase(worker_count, "Sidekiq worker") if worker_count > 0
          parts << count_phrase(mailer_count, "mailer") if mailer_count > 0
          parts << count_phrase(channel_count, "channel") if channel_count > 0
          lines << "- Async: #{parts.join(', ')}" if parts.any?
        end

        if (migrations_line = SectionFacts.migrations_line(context))
          lines << migrations_line
        end

        lines.concat(full_preset_stack_lines)

        lines << ""
        lines
      end

      def render_key_models
        model_rows(:summary)
      end

      def render_notable_gems
        gems_lines(:summary)
      end

      def render_commands(root = project_root)
        server = AppCommands.server(root)
        migrate = AppCommands.migrate(root)
        lines = [ "## Commands" ]
        lines << "- `#{server}` - #{server == 'bin/dev' ? 'start dev server' : 'start the app'}" if server
        lines << "- `#{detect_test_command}` - run tests"
        lines << "- `#{migrate}` - run pending migrations" if migrate
        lines << ""
      end

      def render_warnings
        SectionFacts.warnings(context)
      end

      # Where the cut detail is: the tools, as the mode reaches them.
      def trim_note
        "_Context trimmed. Use #{tools_noun} for full details._"
      end

      # The data between the title and the how-to-behave sections is what a
      # budget cuts: the tools answer it in full, and the guide is what makes a
      # compact file worth reading. The BEGIN/END markers count against the lines.
      def enforce_max_lines(lines, head: [], keep: [])
        max_lines = RailsAiContext.configuration.claude_max_lines - SectionMarkerWriter::MARKER_LINES
        Budget.fit(head: physical(head), body: physical(lines), keep: physical(keep), kind: :root, note: trim_note, max_lines: max_lines,
                                                                           reserve: SectionMarkerWriter::MARKER_BYTES)
      end

      def physical(lines)
        lines.join("\n").split("\n", -1)
      end

      # Architecture / conventions section.
      # The architecture and pattern lines need the booted conventions; the
      # services and jobs lines are read from files, so every tier has them.
      def render_architecture
        lines = architecture_lines(:summary)

        # The scan decides, so services under a configured extra path show wherever
        # the conventions walk looked.
        names = [ names_line(service_names, "**Services:** "), names_line(job_names, "**Jobs:** ") ].compact

        # The blank line sets the names apart from a pattern list. With no list
        # above them - the static tier reads no conventions - it left the
        # heading standing over nothing.
        lines << "" if lines.any? && names.any?
        lines.concat(names)
        return [] if lines.empty?

        [ "## Architecture", *lines, "" ]
      end

      # Footer rules section.
      def render_footer
        lines = [ "## Rules" ]
        lines << "- Run the tests after changes"

        if Payload.section(context, :conventions)
          arch = Payload.architecture(context)
          lines << "- Follow #{arch.join(' + ')} architecture" if arch.any?
          patterns = Payload.patterns(context)
          lines << "- Use service objects for business logic" if patterns.include?("service_objects")
          lines << "- Use form objects for complex forms" if patterns.include?("form_objects")
          lines << "- Use query objects for complex queries" if patterns.include?("query_objects")
        end

        stimulus = Payload.section(context, :stimulus)
        if Payload.stimulus_controllers(context).any? || stimulus&.dig(:total_controllers)&.positive?
          lines << if stimulus&.dig(:auto_registers)
            "- Stimulus controllers auto-register - no manual import in controllers/index.js needed"
          else
            "- Stimulus controllers are not auto-loaded from `app/javascript/controllers` - register a new one the way the existing ones are"
          end
        end

        lines << before_actions_line("- Global before_actions: ") if detect_before_actions.any?

        lines << ""
        lines
      end

      # The compact pipeline behind CLAUDE.md, AGENTS.md, .cursorrules and copilot-instructions.md.
      def render_compact_rules
        data = render_stack_overview + render_key_models + render_notable_gems + render_architecture
        instructions = render_commands + render_warnings + render_footer + render_tools_guide_compact
        enforce_max_lines(data, head: render_header, keep: instructions)
      end
    end
  end
end
