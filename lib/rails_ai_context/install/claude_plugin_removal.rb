# frozen_string_literal: true

require_relative "../claude_code_settings"
require_relative "../cli/app_root"
require_relative "../safe_path"

module RailsAiContext
  module Install
    # What turns the Claude Code plugin off before the gem goes, since the plugin runs the installed
    # gem. Printed for Claude Code to run, never run here: its settings are its own to change.
    module ClaudePluginRemoval
      module_function

      # One line per distinct step. In a folder of apps that each run the plugin, one line covers
      # them all; where only some do, each names its app. A command runs from `cwd` unless it says.
      def lines(app_roots, cwd:, workspace: false)
        return [ relative_config_line ] if ClaudeCodeSettings.relative_config_dir?

        apps = app_roots.map { |app| [ app, ClaudeCodeSettings.new(app) ] }
        return apps.filter_map { |app| line([ app ], "this app", cwd) } unless workspace && apps.size > 1

        each = apps.map { |app| line([ app ], "the apps here", cwd) }
        return [ line(apps, "the apps here", cwd) ] if each.all?

        apps.zip(each).filter_map { |app, said| said && line([ app ], CLI::AppRoot.display(app.first, cwd).delete_suffix("/"), cwd) }
      end

      # One sentence per id the plugin runs these apps under, or managed-mcp.json's own server where that file decides.
      def line(apps, whom, cwd)
        settings = apps.first.last
        if settings.managed_mcp
          name = apps.filter_map { |app, each| each.managed_server(app) }.first or return nil
          return "managed-mcp.json runs the gem's server `#{name}`: ask whoever manages it to take it out before you remove the gem."
        end
        return nil if settings.absent?

        ids = apps.flat_map { |_, each| each.enabled_plugin_ids }.uniq
        said = ids.filter_map { |id| id_line(apps, id, whom, cwd) }.uniq.join(" ")
        said unless said.empty?
      rescue StandardError
        nil
      end

      # A local disable wins over the user's and the project's settings, and is written per
      # project from a session that enables the plugin; an uninstall goes by the install's own
      # scope, run in its project.
      def id_line(apps, id, whom, cwd)
        if apps.any? { |_, settings| settings.enabled_scope(id) == :managed }
          return "Managed Claude Code settings turn on the rails-ai-context plugin, which runs the installed gem: " \
                 "ask whoever manages them to turn it off before you remove the gem."
        end
        sessions = apps.flat_map { |_, settings| settings.enabled_sessions(id) }.uniq
        return nil if sessions.empty?

        root, settings = apps.first
        groups = sessions.group_by { |folder| settings.local_settings_dir(folder) }
        places = groups.map { |_, group| run_there(group.first, cwd) }.uniq
        where = places.all?(&:empty?) ? "" : " run #{places.map { |place| place.empty? ? "here" : place.delete_prefix(" run ") }.join(" and ")}"
        reach = groups.map { |dir, group| reach_of(dir, group, apps, whom, cwd) }.uniq.join(" and ")
        "The rails-ai-context Claude Code plugin runs the installed gem; take it out before the gem: " \
          "`claude plugin disable #{id} --scope local`#{where} turns it off for #{reach}#{uninstall(apps, id, root, cwd)}."
      end

      # Who reads the local file in `dir`: the app's own sessions, every session in the repository whose
      # main checkout holds it, or only sessions started in that very folder.
      def reach_of(dir, group, apps, whom, cwd)
        return whom if apps.any? { |app, _| SafePath.canonical(app) == SafePath.canonical(dir) }

        unless group.all? { |folder| SafePath.canonical(folder) == SafePath.canonical(dir) }
          shown = CLI::AppRoot.display(dir, cwd).delete_suffix("/")
          return shown == "." ? "every session in this git repository" : "every session in the git repository at #{shown}"
        end
        "sessions started #{run_there(dir, cwd).empty? ? "here" : "there"}"
      end

      # The uninstall that takes the one install out, none where a local marketplace runs the plugin with no install at all.
      def uninstall(apps, id, root, cwd)
        installs = apps.flat_map { |_, settings| settings.installs_for(id) }.uniq
        return "" unless installs.one? && apps.none? { |app, settings| settings.local_marketplace?(id, app) }

        install = installs.first
        case install.scope
        when "user" then ", or `claude plugin uninstall #{id} --scope user` takes it out everywhere"
        when "project"
          ", or `claude plugin uninstall #{id} --scope project`#{run_there(install.path || root, cwd)} takes it out of .claude/settings.json for everyone"
        else ", or `claude plugin uninstall #{id} --scope #{install.scope}`#{run_there(install.path || root, cwd)} takes it out"
        end
      end

      def relative_config_line
        value, source = ClaudeCodeSettings.config_dir_setting
        where = source ? " in the env block of #{source}" : ""
        named = value.empty? ? "CLAUDE_CONFIG_DIR#{where} is set but empty" : "CLAUDE_CONFIG_DIR (`#{value}`)#{where} is not an absolute path"
        "#{named}, so each Claude Code session reads its plugins under the folder it starts in: where one turns on the " \
          "rails-ai-context plugin, which runs the installed gem, `claude plugin disable rails-ai-context@rails-ai-context --scope local` " \
          "run where that session starts turns it off before you remove the gem."
      end

      # Where a command has to run, when that is not where this one was typed.
      def run_there(folder, cwd)
        return "" if SafePath.canonical(folder) == SafePath.canonical(cwd)

        " run in #{CLI::AppRoot.display(folder, cwd)}"
      end
    end
  end
end
