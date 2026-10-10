# frozen_string_literal: true

module RailsAiContext
  module Serializers
    # Generates per-directory AGENTS.md files for OpenCode's lazy-loading system.
    # When OpenCode's agent reads a file, it walks up the directory tree and
    # auto-loads any AGENTS.md it finds - acting as contextual split rules.
    #
    # Generated files:
    #   app/models/AGENTS.md      - model listing, loaded when editing models
    #   app/controllers/AGENTS.md - controller listing, loaded when editing controllers
    #
    # Teams write these by hand too, so one the gem did not generate keeps
    # its text and gets the gem's listing as a marked block.
    class OpencodeRulesSerializer < Base
      include StackOverviewHelper
      include ToolGuideHelper

      RULE_FILES = {
        "app/models/AGENTS.md" => { renderer: :render_models_reference, reason: "no models" },
        "app/controllers/AGENTS.md" => { renderer: :render_controllers_reference, reason: "no controllers" }
      }.freeze

      # @param output_dir [String] Rails root path
      # @return [Hash] { written: [paths], skipped: [paths], not_applicable: { path => reason } }
      def call(output_dir)
        # The split targets after the root file, per the table's convention.
        entries = Install::AiTool.find(:opencode).context_paths.drop(1).map do |relative|
          rule = RULE_FILES.fetch(relative)
          filepath = File.join(output_dir, relative)
          # A directory the app does not have is reported, not dropped, and
          # nothing renders for it so the directory is never created.
          if Dir.exist?(File.dirname(filepath))
            RuleFile.new(filepath, send(rule[:renderer]), rule[:reason])
          else
            RuleFile.new(filepath, nil, missing_directory_reason(File.dirname(relative), output_dir))
          end
        end

        write_rule_files(entries, shared: true)
      end

      private

      # OpenCode reads these beside the code, so they go only into a
      # directory that exists. Under an output_dir that is not the app, the
      # app's own directory is there; it is the output_dir that lacks one.
      def missing_directory_reason(dir, output_dir)
        elsewhere = File.expand_path(output_dir) != File.expand_path(project_root)
        elsewhere && Dir.exist?(File.join(project_root, dir)) ? "no #{dir} under output_dir" : "#{dir} not present"
      end

      def render_models_reference
        models = Payload.models(context)
        return nil unless models.any?

        lines = [
          "# ActiveRecord Models (#{models.size})",
          "",
          "> #{Install::Cleanup::GENERATED_NOTE}",
          "> #{MODELS_READING}",
          ""
        ]
        if (notice = SectionFacts.static_notice(context))
          lines.insert(-2, "> #{notice}")
        end

        models.keys.sort.first(30).each do |name|
          data = models[name]
          if (unread = SectionFacts.unread_row("- **#{name}**", data))
            lines << unread
            next
          end

          assocs = SectionFacts.associations_list(data).join(", ")
          vals = (data[:validations] || []).size
          line = "- **#{name}**"
          line += " (table: #{data[:table_name]})" if data[:table_name]
          line += " - #{assocs}" unless assocs.empty?
          line += " [#{vals}v]" if vals > 0
          lines << line
          extras = model_extras_line(data)
          lines << extras if extras
        end

        lines << "- _...#{models.size - 30} more_" if models.size > 30
        lines.concat(tool_pointers(
          [ "rails_get_model_details", 'model:"Name"', "model=Name", "for associations, validations, scopes, enums." ],
          [ "rails_get_view", 'controller:"name"', "controller=name", "for view templates." ],
          [ "rails_get_test_info", 'model:"Name"', "model=Name", "for existing model tests." ]
        ))

        lines.join("\n")
      end

      # "Use <tool> for ..." lines under a blank one, for the tools the server serves.
      def tool_pointers(*pointers)
        served = pointers.select { |name, *| served?(name) }
        return [] if served.empty?

        [ "", *served.map { |name, mcp_params, cli_params, purpose| "Use #{tool_ref(name, mcp_params, cli_params)} #{purpose}" } ]
      end

      def render_controllers_reference
        app_controllers = Payload.app_controllers(context)
        return nil if app_controllers.empty?

        lines = [
          "# Controllers (#{app_controllers.size})",
          "",
          "> #{Install::Cleanup::GENERATED_NOTE}",
          "> Read controller files directly when editing. Use #{tools_noun} for reference only.",
          ""
        ]
        if (notice = SectionFacts.static_notice(context))
          lines.insert(-2, "> #{notice}")
        end

        # ApplicationController before_actions
        before_actions = detect_before_actions
        lines << "**Global before_actions:** #{before_actions.join(', ')}" << "" if before_actions.any?

        lines.concat(render_compact_controllers_list(app_controllers, limit: 25, with_actions: true))

        # List service objects
        services = service_names
        lines << "" << "**Services:** #{services.join(', ')}" if services.any?

        # List jobs
        jobs = job_names
        lines << "**Jobs:** #{jobs.join(', ')}" if jobs.any?

        lines.concat(tool_pointers(
          [ "rails_get_controllers", 'controller:"Name", action:"index"', "controller=Name action=index", "for one action's source code." ],
          [ "rails_get_edit_context", 'file:"path", near:"keyword"', "file=path near=keyword", "for surgical edit context." ],
          [ "rails_get_view", 'controller:"name"', "controller=name", "for view templates." ],
          [ "rails_get_test_info", 'controller:"Name"', "controller=Name", "for existing controller tests." ],
          [ "rails_validate", "files:[...]", "files=...", "to check syntax after editing - do NOT re-read files to verify." ]
        ))

        lines.join("\n")
      end
    end
  end
end
