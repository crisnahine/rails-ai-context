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
      TOOLS = %i[opencode codex].freeze

      include StackOverviewHelper
      include ToolGuideHelper

      RULE_FILES = {
        "app/models/AGENTS.md" => { renderer: :render_models_reference, reason: "no models" },
        "app/controllers/AGENTS.md" => { renderer: :render_controllers_reference, reason: "no controllers" }
      }.freeze

      # @param output_dir [String] Rails root path
      # @return [Hash] { written:, skipped:, removed:, trimmed: [paths], not_applicable: { path => reason } }
      def call(output_dir)
        # The split targets after the root file, per the table's convention.
        entries = Install::AiTool.find(:opencode).context_paths.drop(1).map do |relative|
          rule = RULE_FILES.fetch(relative)
          filepath = File.join(output_dir, relative)
          # A directory the app does not have is reported, not dropped, and
          # nothing renders for it so the directory is never created.
          if Dir.exist?(File.dirname(filepath))
            RuleFile.new(filepath, fit_rule([], send(rule[:renderer]), :rule), rule[:reason])
          else
            RuleFile.new(filepath, nil, missing_directory_reason(File.dirname(relative), output_dir))
          end
        end

        write_rule_files(entries, shared: true, root: output_dir)
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

        lines.concat(model_rows(:listing))
        lines.concat(tool_pointers(
          [ "rails_get_view", 'controller:"name"', "controller=name", "for view templates." ],
          [ "rails_get_test_info", 'model:"Name"', "model=Name", "for existing model tests." ]
        ))

        lines.join("\n")
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

        filters = before_actions_line("**Global before_actions:** ") unless rooted?
        lines.push(filters, "") if filters

        lines.concat(render_compact_controllers_list(app_controllers, with_actions: true))

        names = rooted? ? [] : [ services_line("**Services:** "), jobs_line("**Jobs:** ") ].compact
        lines.push("", *names) if names.any?

        lines.concat(tool_pointers(
          [ "rails_get_controllers", 'controller:"Name", action:"index"', "controller=Name action=index", "for one action's source code." ],
          [ "rails_get_edit_context", 'file:"path", near:"keyword"', "file=path near=keyword", "for surgical edit context." ],
          [ "rails_get_view", 'controller:"name"', "controller=name", "for view templates." ],
          [ "rails_get_test_info", 'controller:"Name"', "controller=Name", "for existing controller tests." ],
          [ "rails_validate", "files:[...]", "files=...", "to check syntax after an edit, rather than re-reading the file." ]
        ))

        lines.join("\n")
      end
    end
  end
end
