# frozen_string_literal: true

module RailsAiContext
  module Tools
    class DependencyGraph < BaseTool
      tool_name "rails_dependency_graph"
      description "Generates a dependency graph showing how models, services, and controllers " \
        "connect. Output as Mermaid diagram syntax or plain text. " \
        "Use when: understanding feature architecture, tracing data flow, planning refactors. " \
        "Key params: model (center graph on model), depth (1-3), format (mermaid/text)."

      input_schema(
        properties: {
          model: {
            type: "string",
            description: "Center the graph on this model (e.g., 'User'). Without this, shows all models."
          },
          depth: {
            type: "integer",
            description: "How many hops from the center model (1-3, default: 2)"
          },
          format: {
            type: "string",
            enum: %w[mermaid text],
            description: "Output format: mermaid (diagram syntax) or text (plain)"
          },
          show_cycles: {
            type: "boolean",
            description: "Detect and display circular dependency cycles (default: false)"
          },
          show_sti: {
            type: "boolean",
            description: "Show Single Table Inheritance hierarchies (default: false)"
          }
        }
      )

      annotations(read_only_hint: true, destructive_hint: false, idempotent_hint: true, open_world_hint: false)

      MAX_NODES = 50

      def self.call(model: nil, depth: 2, format: "mermaid", show_cycles: false, show_sti: false, server_context: nil)
        models_data = cached_context[:models]

        unless models_data.is_a?(Hash) && !models_data[:error]
          return text_response("No model data available. Ensure :models introspector is enabled.")
        end

        model = model.to_s.strip if model
        depth = [ [ depth.to_i, 1 ].max, 3 ].min

        set_call_params(model: model, depth: depth, format: format, show_cycles: show_cycles, show_sti: show_sti)

        # Build adjacency list from model associations
        graph = build_graph(models_data)

        if model
          model_key = find_model_key(model, graph.keys)
          unless model_key
            return not_found_response("Model", model, graph.keys.sort,
              recovery_tool: "Call rails_dependency_graph() without model to see all models")
          end
          subgraph = extract_subgraph(graph, model_key, depth)
        else
          subgraph = graph
        end

        # Limit nodes
        if subgraph.size > MAX_NODES
          subgraph = subgraph.first(MAX_NODES).to_h
        end

        # Optional analyses
        cycles = show_cycles ? detect_cycles(graph) : []
        sti_groups = show_sti ? extract_sti_groups(models_data) : []

        case format
        when "mermaid"
          text_response(render_mermaid(subgraph, model, cycles: cycles, sti_groups: sti_groups))
        else
          text_response(render_text(subgraph, model, cycles: cycles, sti_groups: sti_groups))
        end
      end

      class << self
        private

        def build_graph(models_data)
          graph = {}
          polymorphic_interfaces = {} # { interface_name => [concrete_model, ...] }

          # First pass: collect polymorphic interfaces
          models_data.each do |model_name, data|
            next unless data.is_a?(Hash) && !data[:error]
            (data[:associations] || []).each do |assoc|
              if assoc[:polymorphic]
                polymorphic_interfaces[assoc[:name].to_s] ||= []
              end
            end
          end

          # Second pass: find concrete types for each polymorphic interface
          models_data.each do |model_name, data|
            next unless data.is_a?(Hash) && !data[:error]
            (data[:associations] || []).each do |assoc|
              type = (assoc[:macro] || assoc[:type]).to_s
              next unless type == "has_many" || type == "has_one"
              # has_many :comments, as: :commentable → options[:as] stored as foreign_key pattern
              # The association's foreign_key will be "commentable_id" for `as: :commentable`
              fk = assoc[:foreign_key].to_s
              interface = fk.sub(/_id\z/, "")
              if polymorphic_interfaces.key?(interface)
                polymorphic_interfaces[interface] << model_name.to_s
              end
            end
          end

          # Build edges
          models_data.each do |model_name, data|
            next unless data.is_a?(Hash) && !data[:error]
            name = model_name.to_s

            associations = data[:associations] || []
            edges = associations.filter_map do |assoc|
              target = assoc[:class_name] || assoc[:name]&.to_s&.classify
              next unless target

              edge = {
                type: assoc[:macro] || assoc[:type],
                target: target,
                through: assoc[:through],
                polymorphic: assoc[:polymorphic]
              }

              # Resolve polymorphic: record concrete targets
              if assoc[:polymorphic]
                interface = assoc[:name].to_s
                edge[:polymorphic_targets] = polymorphic_interfaces[interface] || []
              end

              edge
            end

            graph[name] = edges
          end

          graph
        end

        def find_model_key(query, keys)
          keys.find { |k| k.downcase == query.downcase } ||
            keys.find { |k| k.underscore.downcase == query.downcase }
        end

        def extract_subgraph(graph, center, depth)
          visited = Set.new
          queue = [ [ center, 0 ] ]
          subgraph = {}

          while queue.any?
            current, d = queue.shift
            next if visited.include?(current) || d > depth
            visited.add(current)

            edges = graph[current] || []
            subgraph[current] = edges

            edges.each do |edge|
              queue << [ edge[:target], d + 1 ] unless visited.include?(edge[:target])
            end

            # Also find reverse associations pointing to current
            graph.each do |model, model_edges|
              next if visited.include?(model)
              if model_edges.any? { |e| e[:target] == current }
                queue << [ model, d + 1 ]
              end
            end
          end

          subgraph
        end

        # DFS-based cycle detection. Returns array of cycle paths.
        def detect_cycles(graph)
          cycles = []
          visited = Set.new
          in_stack = Set.new
          path = []

          dfs = lambda do |node|
            return if visited.include?(node)
            visited.add(node)
            in_stack.add(node)
            path.push(node)

            (graph[node] || []).each do |edge|
              target = edge[:target]
              if in_stack.include?(target)
                # Found cycle: extract from target's position in path
                cycle_start = path.index(target)
                cycles << path[cycle_start..].dup if cycle_start
              elsif !visited.include?(target)
                dfs.call(target)
              end
            end

            path.pop
            in_stack.delete(node)
          end

          graph.keys.each { |node| dfs.call(node) }
          cycles.uniq { |c| c.sort }
        end

        # Extract STI hierarchies from models data.
        # Groups models that share the same table_name with sti info.
        def extract_sti_groups(models_data)
          groups = []

          models_data.each do |model_name, data|
            next unless data.is_a?(Hash) && !data[:error]
            sti = data[:sti]
            next unless sti

            if sti[:sti_base]
              children = sti[:sti_children] || []
              groups << {
                base: model_name.to_s,
                table: data[:table_name],
                children: children.map(&:to_s)
              }
            end
          end

          groups
        end

        def render_mermaid(graph, center, cycles: [], sti_groups: [])
          lines = [ "# Dependency Graph", "" ]
          lines << "```mermaid"
          lines << "graph LR"

          if center
            lines << "  style #{sanitize(center)} fill:#f9f,stroke:#333,stroke-width:2px"
          end

          rendered = Set.new
          graph.each do |model, edges|
            edges.each do |edge|
              key = "#{model}->#{edge[:target]}:#{edge[:type]}"
              next if rendered.include?(key)
              rendered.add(key)

              if edge[:through]
                # Through: two edges with double arrow
                intermediate = edge[:through].to_s.classify
                through_key1 = "#{model}->#{intermediate}:through"
                through_key2 = "#{intermediate}->#{edge[:target]}:through"
                unless rendered.include?(through_key1)
                  rendered.add(through_key1)
                  lines << "  #{sanitize(model)} ==>|through| #{sanitize(intermediate)}"
                end
                unless rendered.include?(through_key2)
                  rendered.add(through_key2)
                  lines << "  #{sanitize(intermediate)} ==>|through| #{sanitize(edge[:target])}"
                end
              elsif edge[:polymorphic]
                # Polymorphic: dashed arrow to interface + concrete targets
                lines << "  #{sanitize(model)} -.->|polymorphic| #{sanitize(edge[:target])}"
                (edge[:polymorphic_targets] || []).each do |concrete|
                  poly_key = "#{concrete}->#{model}:polymorphic_impl"
                  unless rendered.include?(poly_key)
                    rendered.add(poly_key)
                    lines << "  #{sanitize(concrete)} -.->|implements| #{sanitize(model)}"
                  end
                end
              else
                arrow = case edge[:type].to_s
                when "has_many", "has_and_belongs_to_many" then "-->|has_many|"
                when "belongs_to" then "-->|belongs_to|"
                when "has_one" then "-->|has_one|"
                else "-->|#{edge[:type]}|"
                end
                lines << "  #{sanitize(model)} #{arrow} #{sanitize(edge[:target])}"
              end
            end
          end

          # STI: dotted lines
          sti_groups.each do |group|
            group[:children].each do |child|
              sti_key = "#{group[:base]}->#{child}:sti"
              unless rendered.include?(sti_key)
                rendered.add(sti_key)
                lines << "  #{sanitize(group[:base])} -.-|STI| #{sanitize(child)}"
              end
            end
          end

          lines << "```"
          lines << ""

          stats = [ "**Models:** #{graph.keys.size}", "**Associations:** #{graph.values.sum(&:size)}" ]
          stats << "**Cycles:** #{cycles.size}" if cycles.any?
          stats << "**STI hierarchies:** #{sti_groups.size}" if sti_groups.any?
          lines << stats.join(" | ")

          # Cycles section
          if cycles.any?
            lines << ""
            lines << "## Circular Dependencies"
            cycles.each { |c| lines << "- #{c.join(" → ")} → #{c.first}" }
          end

          lines.join("\n")
        end

        def render_text(graph, center, cycles: [], sti_groups: [])
          lines = [ "# Dependency Graph", "" ]

          if center
            lines << "Centered on: #{center}"
            lines << ""
          end

          graph.each do |model, edges|
            lines << "## #{model}"
            if edges.empty?
              lines << "  (no associations)"
            else
              edges.each do |edge|
                if edge[:through]
                  lines << "  #{edge[:type]} → #{edge[:target]} through #{edge[:through]}"
                elsif edge[:polymorphic]
                  targets = (edge[:polymorphic_targets] || []).join(", ")
                  impl = targets.empty? ? "" : " [#{targets}]"
                  lines << "  #{edge[:type]} → #{edge[:target]} (polymorphic)#{impl}"
                else
                  lines << "  #{edge[:type]} → #{edge[:target]}"
                end
              end
            end
            lines << ""
          end

          # STI section
          if sti_groups.any?
            lines << "## STI Hierarchies"
            sti_groups.each do |group|
              lines << "- **#{group[:base]}** (table: #{group[:table]})"
              group[:children].each { |child| lines << "  - #{child}" }
            end
            lines << ""
          end

          # Cycles section
          if cycles.any?
            lines << "## Circular Dependencies"
            cycles.each { |c| lines << "- #{c.join(" → ")} → #{c.first}" }
            lines << ""
          end

          stats = [ "**Models:** #{graph.keys.size}", "**Associations:** #{graph.values.sum(&:size)}" ]
          stats << "**Cycles:** #{cycles.size}" if cycles.any?
          stats << "**STI hierarchies:** #{sti_groups.size}" if sti_groups.any?
          lines << stats.join(" | ")

          lines.join("\n")
        end

        def sanitize(name)
          sanitized = name.to_s.gsub(/[^a-zA-Z0-9_]/, "_")
          # Mermaid node IDs must start with a letter
          sanitized = "M#{sanitized}" if sanitized.match?(/\A\d/)
          sanitized
        end
      end
    end
  end
end
