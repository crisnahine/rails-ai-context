# frozen_string_literal: true

module RailsAiContext
  module Tools
    class GetFrontendStack < BaseTool
      tool_name "rails_get_frontend_stack"
      description "Returns the app's frontend stack: framework, build tool, state management, TypeScript config, " \
        "component directories, and package manager. " \
        "Use when: scaffolding new frontend features, choosing libraries, or understanding the JS/TS build pipeline. " \
        "Key params: detail (summary for one-liner, standard for stack overview, full for config detail)."

      input_schema(
        properties: {
          detail: {
            type: "string",
            enum: %w[summary standard full],
            description: "Level of detail: summary (one-liner), standard (stack overview + component counts), full (+ config details, path aliases, monorepo info)"
          }
        }
      )

      annotations(read_only_hint: true, destructive_hint: false, idempotent_hint: true, open_world_hint: false)

      def self.call(detail: "standard", server_context: nil) # rubocop:disable Metrics
        data = cached_context[:frontend_frameworks]

        unless data.is_a?(Hash) && !data[:error]
          return text_response(
            "No frontend framework data available. Ensure the :frontend_frameworks introspector is enabled in your " \
            "rails_ai_context configuration.\n\n" \
            "Example:\n```ruby\nRailsAiContext.configure do |config|\n  config.introspectors << :frontend_frameworks\nend\n```"
          )
        end

        case detail
        when "summary"
          text_response(build_summary(data))
        when "standard"
          text_response(build_standard(data))
        when "full"
          text_response(build_full(data))
        else
          text_response("Unknown detail level: #{detail}. Use summary, standard, or full.")
        end
      end

      class << self
        private

        def build_summary(data)
          parts = []
          framework = framework_label(data)
          parts << framework if framework
          parts << display_name(data[:mounting_strategy]) if data[:mounting_strategy].present?
          parts << display_name(data[:build_tool]) if data[:build_tool].present?

          if data[:typescript].is_a?(Hash) && data[:typescript][:enabled]
            parts << "TypeScript"
          end

          if data[:state_management].is_a?(String) && data[:state_management].present?
            parts << data[:state_management]
          elsif data[:state_management].is_a?(Array) && data[:state_management].any?
            parts << data[:state_management].join(", ")
          end

          total = total_component_count(data)
          parts << "(#{total} components)" if total > 0

          # If no JS framework data, try building a Hotwire summary from cached context
          if parts.empty?
            hotwire = build_hotwire_summary
            return hotwire if hotwire
          end

          parts.any? ? parts.join(" + ") : "No frontend framework detected."
        end

        def build_hotwire_summary
          stimulus = cached_context[:stimulus]
          gems = cached_context[:gems]

          notable = gems.is_a?(Hash) && !gems[:error] ? (gems[:notable_gems] || []) : []
          has_turbo = notable.any? { |g| g[:name] == "turbo-rails" }
          has_stimulus = notable.any? { |g| g[:name] == "stimulus-rails" }
          has_importmap = notable.any? { |g| g[:name] == "importmap-rails" }
          has_tailwind = notable.any? { |g| g[:name] == "tailwindcss-rails" }

          return nil unless has_turbo || has_stimulus

          parts = []
          parts << "Hotwire (Turbo + Stimulus)" if has_turbo && has_stimulus
          parts << "Hotwire (Turbo)" if has_turbo && !has_stimulus
          parts << "Hotwire (Stimulus)" if !has_turbo && has_stimulus

          parts << "with importmap-rails" if has_importmap

          if stimulus.is_a?(Hash) && !stimulus[:error]
            count = stimulus[:total_controllers] || stimulus[:controllers]&.size || 0
            parts << "#{count} Stimulus controllers" if count > 0
          end

          parts << "Tailwind CSS" if has_tailwind

          parts.join(", ")
        end

        def build_standard(data)
          lines = [ "# Frontend Stack", "" ]

          framework = framework_label(data)
          lines << "- **Framework:** #{framework}" if framework
          lines << "- **Mounting strategy:** #{display_name(data[:mounting_strategy])}" if data[:mounting_strategy]
          lines << "- **Build tool:** #{display_name(data[:build_tool])}" if data[:build_tool]
          # state_management is an array for JS-framework apps and a string for
          # others; an empty array is truthy in Ruby, so guard on presence and
          # join arrays to avoid rendering a literal "[]".
          state_management = data[:state_management]
          state_management = state_management.join(", ") if state_management.is_a?(Array)
          lines << "- **State management:** #{state_management}" if state_management.present?
          lines << "- **Package manager:** #{data[:package_manager]}" if data[:package_manager]

          # TypeScript
          ts_enabled = data[:typescript].is_a?(Hash) && data[:typescript][:enabled]
          if data[:typescript].is_a?(Hash)
            ts = data[:typescript]
            if ts[:enabled]
              strict_label = ts[:strict] ? "strict" : "non-strict"
              lines << "- **TypeScript:** enabled (#{strict_label})"
            else
              lines << "- **TypeScript:** disabled"
            end
          end

          # Testing frameworks
          has_testing = data[:testing].is_a?(Array) && data[:testing].any?
          if has_testing
            lines << "- **Testing:** #{data[:testing].join(', ')}"
          end

          # Hotwire stack - enrich with Stimulus/Turbo data for importmap apps.
          # Built into a separate array first so we can detect its presence
          # before deciding whether there's any frontend stack at all.
          hotwire_lines = []
          enrich_with_hotwire(hotwire_lines)
          has_hotwire = hotwire_lines.any?

          has_frontend_roots = data[:frontend_roots].is_a?(Array) && data[:frontend_roots].any?

          # Nothing detected anywhere: no JS framework, no build tooling, no
          # Hotwire, no frontend directories. Without this check the only
          # line printed would be "TypeScript: disabled," which reads as if
          # a JS frontend exists that simply opted out of TypeScript.
          no_frontend_evidence = !framework && !data[:mounting_strategy] && !data[:build_tool] &&
            !state_management.present? && !data[:package_manager] && !ts_enabled &&
            !has_testing && !has_hotwire && !has_frontend_roots

          if no_frontend_evidence
            return "# Frontend Stack\n\nNo frontend stack detected (API-only app / no app/javascript, no package.json)."
          end

          lines.concat(hotwire_lines)

          # Frontend roots with component counts - skip "0 components" for Hotwire apps
          # where Stimulus controllers ARE the components
          if has_frontend_roots
            roots_with_components = data[:frontend_roots].select { |r| (r[:component_count] || 0) > 0 }
            if roots_with_components.any?
              lines << "" << "## Frontend Roots" << ""
              roots_with_components.each do |root|
                lines << "- `#{root[:path]}` - #{root[:component_count]} components"
              end
            elsif !has_hotwire
              # Only show "0 components" for non-Hotwire apps where it's meaningful
              lines << "" << "## Frontend Roots" << ""
              data[:frontend_roots].each do |root|
                lines << "- `#{root[:path]}` - 0 components"
              end
            end
          end

          lines.join("\n")
        end

        def build_full(data)
          lines = build_standard(data).lines.map(&:chomp)

          # TypeScript path aliases
          if data[:typescript].is_a?(Hash) && data[:typescript][:path_aliases].is_a?(Hash) && data[:typescript][:path_aliases].any?
            lines << "" << "## TypeScript Path Aliases" << ""
            data[:typescript][:path_aliases].each do |alias_name, target|
              lines << "- `#{alias_name}` -> `#{target}`"
            end
          end

          # Monorepo info. The introspector always emits the monorepo hash
          # (with detected:/tool:/workspaces: keys), so key presence alone
          # doesn't mean a monorepo exists - require an actual tool.
          if data[:monorepo].is_a?(Hash) && data[:monorepo][:tool]
            lines << "" << "## Monorepo" << ""
            lines << "- **Tool:** #{data[:monorepo][:tool]}" if data[:monorepo][:tool]
            if data[:monorepo][:workspaces].is_a?(Array) && data[:monorepo][:workspaces].any?
              lines << "- **Workspaces:** #{data[:monorepo][:workspaces].join(', ')}"
            end
          end

          # Component directory breakdown
          if data[:component_dirs].is_a?(Array) && data[:component_dirs].any?
            lines << "" << "## Component Directories" << ""
            data[:component_dirs].each do |dir|
              lines << "- `#{dir[:path]}` - #{dir[:count]} components"
            end
          end

          # Vite/build config plugins
          if data[:build_config].is_a?(Hash) && data[:build_config][:plugins].is_a?(Array) && data[:build_config][:plugins].any?
            lines << "" << "## Build Plugins" << ""
            data[:build_config][:plugins].each do |plugin|
              lines << "- #{plugin}"
            end
          end

          lines.join("\n")
        end

        # The introspector emits frameworks as a hash of framework symbol =>
        # package.json version requirement (e.g. { react: "^19.0.0" }), not a
        # singular framework/version pair. Render the primary (first) entry,
        # stripping range operators from the version.
        def framework_label(data)
          frameworks = data[:frameworks]
          return nil unless frameworks.is_a?(Hash) && frameworks.any?

          sym, version = frameworks.first
          label = display_name(sym)
          clean_version = version.to_s.delete("^0-9.")
          clean_version.empty? ? label : "#{label} #{clean_version}"
        end

        # :vite_rails -> "Vite Rails", "vite" -> "Vite"
        def display_name(value)
          value.to_s.split("_").map(&:capitalize).join(" ")
        end

        def total_component_count(data)
          if data[:frontend_roots].is_a?(Array)
            data[:frontend_roots].sum { |r| r[:component_count] || 0 }
          elsif data[:component_dirs].is_a?(Array)
            data[:component_dirs].sum { |d| d[:count] || 0 }
          else
            0
          end
        end

        # For Hotwire/importmap apps, pull Stimulus and Turbo data from context
        def enrich_with_hotwire(lines)
          stimulus = cached_context[:stimulus]
          turbo = cached_context[:turbo]
          gems = cached_context[:gems]

          # Check if this is a Hotwire app (has turbo-rails or stimulus-rails)
          notable = gems.is_a?(Hash) && !gems[:error] ? (gems[:notable_gems] || []) : []
          has_turbo = notable.any? { |g| g[:name] == "turbo-rails" }
          has_stimulus = notable.any? { |g| g[:name] == "stimulus-rails" }
          has_importmap = notable.any? { |g| g[:name] == "importmap-rails" }

          return unless has_turbo || has_stimulus

          lines << ""
          lines << "## Hotwire Stack"
          lines << ""
          lines << "- **Turbo:** turbo-rails (Drive, Frames, Streams)" if has_turbo
          lines << "- **Stimulus:** stimulus-rails" if has_stimulus
          lines << "- **Asset delivery:** importmap-rails (no JS bundler)" if has_importmap

          if stimulus.is_a?(Hash) && !stimulus[:error]
            count = stimulus[:total_controllers] || stimulus[:controllers]&.size || 0
            if count > 0
              names = (stimulus[:controllers] || []).map { |c| c[:name] || c[:file]&.gsub("_controller.js", "") }.compact.sort
              lines << "- **Stimulus controllers:** #{count} (#{names.first(8).join(', ')}#{count > 8 ? ', ...' : ''})"
            end
          end

          if turbo.is_a?(Hash) && !turbo[:error]
            broadcasts = turbo[:broadcasts]&.size || turbo[:explicit_broadcasts]&.size || 0
            frames = turbo[:frames]&.size || 0
            parts = []
            parts << "#{broadcasts} broadcasts" if broadcasts > 0
            parts << "#{frames} frames" if frames > 0
            lines << "- **Turbo wiring:** #{parts.join(', ')}" if parts.any?
          end
        end
      end
    end
  end
end
