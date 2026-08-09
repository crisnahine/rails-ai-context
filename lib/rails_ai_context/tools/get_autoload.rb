# frozen_string_literal: true

module RailsAiContext
  module Tools
    class GetAutoload < BaseTool
      tool_name "rails_get_autoload"
      description "Get autoloading setup: Zeitwerk vs Classic mode, autoloaders with collapsed/ignored dirs, autoload/eager-load paths, and custom inflections. " \
        "Use when: debugging NameError/unloaded-constant issues, naming a file or class to match Zeitwerk rules, or checking custom inflections."

      # Framework path lists run long; enough rows to cover an app's own paths
      # plus the Rails defaults under them.
      MAX_PATHS_SHOWN = 40

      input_schema(properties: {})

      annotations(read_only_hint: true, destructive_hint: false, idempotent_hint: true, open_world_hint: false)

      def self.call(server_context: nil)
        autoload = cached_context[:autoload]
        return text_response("Autoload introspection not available. Add :autoload to introspectors.") unless autoload
        return text_response("Autoload introspection failed: #{autoload[:error]}") if autoload[:error]
        note = unavailable_note(autoload)
        return text_response(note) if note

        lines = [ "# Autoloading" ]
        lines << ""
        lines << "- **Mode:** #{autoload[:mode]}"
        lines << "- **Eager load (this env):** #{autoload[:eager_load]}"

        loaders = autoload[:autoloaders] || []
        if loaders.any?
          lines << "" << "## Autoloaders"
          loaders.each do |l|
            lines << "- **#{l[:name]}**#{l[:tag] ? " (tag: #{l[:tag]})" : ""}"
            lines << "  - [error: #{l[:error]}]" if l[:error]
            lines << "  - collapsed: #{l[:collapsed].join(', ')}" if l[:collapsed]&.any?
            lines << "  - ignored: #{l[:ignored].join(', ')}" if l[:ignored]&.any?
          end
        end

        render_paths(lines, "Autoload paths", autoload[:autoload_paths])
        render_paths(lines, "Autoload-once paths", autoload[:autoload_once_paths])
        render_paths(lines, "Eager-load paths", autoload[:eager_load_paths])

        inflections = autoload[:custom_inflections] || []
        if inflections.any?
          lines << "" << "## Custom Inflections"
          inflections.each { |i| lines << "- `#{i[:rule]}` (#{i[:file]})" }
        end

        text_response(lines.join("\n"))
      end

      class << self
        private

        # Custom autoload paths (beyond Rails' defaults) matter most, but the
        # full list is what AI needs for "where can this constant live" - cap
        # long framework lists rather than hiding them.
        def render_paths(lines, title, paths)
          paths = Array(paths)
          return if paths.empty?

          lines << "" << "## #{title} (#{paths.size})"
          paths.first(MAX_PATHS_SHOWN).each { |p| lines << "- `#{p}`" }
          lines << "_... #{paths.size - MAX_PATHS_SHOWN} more_" if paths.size > MAX_PATHS_SHOWN
        end
      end
    end
  end
end
