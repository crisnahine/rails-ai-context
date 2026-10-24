# frozen_string_literal: true

module RailsAiContext
  module Tools
    class DependencyGraph < BaseTool
      tool_name "rails_dependency_graph"
      description "Generates a dependency graph showing how models connect through their " \
        "associations. Output as Mermaid diagram syntax or plain text. " \
        "Use when: understanding feature architecture, tracing data flow, planning refactors. " \
        "Key params: model (center graph on model), depth (1-3), format (mermaid/text)."

      MAX_NODES = 50

      input_schema(
        properties: {
          model: {
            type: "string",
            description: "Center the graph on this model (e.g., 'User'). Without this, shows every model up to a cap of #{MAX_NODES} nodes."
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

      guide_row(
        order: 24,
        mcp: "rails_dependency_graph(model:\"X\")",
        cli_args: "model=X",
        summary: "Model association graph as Mermaid diagram"
      )

      annotations(read_only_hint: true, destructive_hint: false, idempotent_hint: true, open_world_hint: false)

      def self.call(model: nil, depth: 2, format: "mermaid", show_cycles: false, show_sti: false, server_context: nil)
        note = unavailable_note(cached_context[:models])
        return text_response(note) if note

        models_data = Payload.section(cached_context, :models)
        unless models_data
          return text_response("No model data available. Ensure :models introspector is enabled.")
        end

        model = model.to_s.strip if model
        depth = [ [ depth.to_i, 1 ].max, 3 ].min

        # Build adjacency list from model associations
        graph, unresolved = build_graph(models_data)

        if model
          model_key = fuzzy_find_key(graph.keys, model)
          unless model_key
            return not_found_response("Model", model, graph.keys.sort,
              recovery_tool: "Call rails_dependency_graph() without model to see all models")
          end
          subgraph = extract_subgraph(graph, model_key, depth)
        else
          subgraph = graph
        end

        # Limit nodes. The cut used to be silent, so a 133-model app read as a
        # 50-model app with no edges to the other 83.
        total_nodes = subgraph.size
        # Both numbers in the stats line are taken here, before the cut, so
        # they describe the same models.
        total_edges = subgraph.values.sum { |edges| edges.size }
        # The note about them describes the same models the counts do, or it
        # reads as a different fraction of a different set.
        unresolved = unresolved.select { |name, _| subgraph.key?(name) }
        subgraph = subgraph.first(MAX_NODES).to_h if subgraph.size > MAX_NODES

        # Optional analyses. nil when not asked, so a search that found none can say so.
        cycles = show_cycles ? detect_cycles(graph) : nil
        sti_groups = show_sti ? extract_sti_groups(models_data) : []
        skipped = models_data.select { |_, data| data.is_a?(Hash) && data[:error] }.keys.map(&:to_s)

        case format
        when "mermaid"
          text_response(render_mermaid(subgraph, model, cycles: cycles, sti_groups: sti_groups,
            total_nodes: total_nodes, total_edges: total_edges, skipped: skipped, unresolved: unresolved))
        else
          text_response(render_text(subgraph, model, cycles: cycles, sti_groups: sti_groups,
            total_nodes: total_nodes, total_edges: total_edges, skipped: skipped, unresolved: unresolved))
        end
      end

      class << self
        private

        def build_graph(models_data)
          graph = {}
          unresolved = {}
          polymorphic_interfaces = {} # { [owner_model, interface_name] => [concrete_model, ...] }

          # First pass: collect polymorphic interfaces
          models_data.each do |model_name, data|
            next unless data.is_a?(Hash) && !data[:error]
            (data[:associations] || []).each do |assoc|
              if assoc[:polymorphic]
                polymorphic_interfaces[[ model_name.to_s, assoc[:name].to_s ]] ||= []
              end
            end
          end

          declared = models_data.transform_keys(&:to_s)
          sti_parents = declared.transform_values { |data| data.dig(:sti, :sti_parent)&.to_s if data.is_a?(Hash) }

          # Second pass: a model implements an interface by declaring `as:` on
          # it, toward the model the has_many points at. The key's name says
          # nothing: Tag's `has_many :products, through: :taggings, source:
          # :taggable` reads the key taggable_id and implements nothing.
          models_data.each do |model_name, data|
            next unless data.is_a?(Hash) && !data[:error]
            (data[:associations] || []).each do |assoc|
              type = (assoc[:macro] || assoc[:type]).to_s
              next unless type == "has_many" || type == "has_one"
              next if assoc[:through]

              interface = polymorphic_as(assoc)
              next unless interface

              target = Introspectors::AssociationClass.target(assoc, declared, owner: model_name.to_s)
              next unless target

              sti_family(target, sti_parents).each do |member|
                key = [ member, interface ]
                polymorphic_interfaces[key] |= [ model_name.to_s ] if polymorphic_interfaces.key?(key)
              end
            end
          end

          # Build edges
          models_data.each do |model_name, data|
            next unless data.is_a?(Hash) && !data[:error]
            name = model_name.to_s

            associations = data[:associations] || []
            by_name = Introspectors::AssociationClass.by_name(associations)

            edges = associations.filter_map do |assoc|
              next if assoc[:unavailable]

              case Introspectors::AssociationClass.unresolved(assoc, by_name)
              when :unreadable
                (unresolved[name] ||= []) << assoc[:name].to_s
                next
              when :through
                # A module the walk could not read might declare the hop, and the note says so.
                unread = Array(data[:concerns_unread]) + Array(data[:bases_unread])
                (unresolved[name] ||= []) << { name: assoc[:name].to_s, through: assoc[:through].to_s, unread: unread }
                next
              end

              target = Introspectors::AssociationClass.target(assoc, declared, by_name: by_name, owner: name)
              next unless target

              edge = {
                type: assoc[:macro] || assoc[:type],
                name: assoc[:name].to_s,
                target: target,
                through: assoc[:through],
                through_class: assoc[:through] && Introspectors::AssociationClass.through_class(assoc, by_name, declared, owner: name),
                polymorphic: assoc[:polymorphic]
              }

              # Resolve polymorphic: record concrete targets
              if assoc[:polymorphic]
                edge[:polymorphic_targets] = polymorphic_interfaces[[ name, assoc[:name].to_s ]] || []
              end

              edge
            end

            graph[name] = edges
          end

          [ graph, unresolved ]
        end

        # `as: :commentable` as each tier records it: the option itself
        # statically, and its display text (":commentable") wherever the
        # declaration was read.
        def polymorphic_as(assoc)
          options, declared = assoc.values_at(:options, :declared_options)
          value = (options[:as] if options.is_a?(Hash)) || (declared["as"] if declared.is_a?(Hash))
          value&.to_s&.delete_prefix(":")
        end

        # How many of them the note spells out before it counts the rest.
        UNRESOLVED_NAMED = 10

        def extract_subgraph(graph, center, depth)
          visited = Set.new
          queue = [ [ center, 0 ] ]
          subgraph = {}
          incoming = Hash.new { |hash, key| hash[key] = [] }
          graph.each { |model, model_edges| model_edges.each { |edge| incoming[edge[:target]] << model } }

          while queue.any?
            current, d = queue.shift
            next if visited.include?(current) || d > depth
            visited.add(current)

            edges = graph[current] || []
            subgraph[current] = edges

            edges.each do |edge|
              queue << [ edge[:target], d + 1 ] unless visited.include?(edge[:target])
            end

            incoming[current].each { |model| queue << [ model, d + 1 ] unless visited.include?(model) }
          end

          subgraph
        end

        # A cycle is drawn over foreign keys, one edge per key, from the model
        # whose table holds it to the model it points at. A belongs_to and the
        # has_many on its other end are one key, so a pair of models joined
        # both ways is not a cycle; a key to its own model is a tree, not one
        # either. A through association and a join table hold no key of
        # their own.
        def foreign_key_edges(graph)
          edges = Hash.new { |hash, key| hash[key] = Set.new }
          graph.each do |model, model_edges|
            model_edges.each do |edge|
              next if edge[:through]

              case edge[:type].to_s
              when "belongs_to"
                targets = edge[:polymorphic] ? Array(edge[:polymorphic_targets]) : [ edge[:target] ]
                targets.each { |target| edges[model] << target unless target == model }
              when "has_many", "has_one"
                edges[edge[:target]] << model unless edge[:target] == model
              end
            end
          end
          edges
        end

        # DFS-based cycle detection over the foreign keys. Returns array of cycle paths.
        def detect_cycles(graph)
          keys = foreign_key_edges(graph)
          cycles = []
          visited = Set.new
          in_stack = Set.new
          path = []

          dfs = lambda do |node|
            return if visited.include?(node)
            visited.add(node)
            in_stack.add(node)
            path.push(node)

            keys[node].sort.each do |target|
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

        # A has_many to an STI class holds rows of that class and its subclasses, and each
        # row is also a row of every ancestor: the classes whose belongs_to it can fill.
        def sti_family(name, sti_parents)
          family = [ name ]
          family.each { |member| sti_parents.each { |child, parent| family << child if parent == member && !family.include?(child) } }
          ancestor = sti_parents[name]
          while ancestor && !family.include?(ancestor)
            family << ancestor
            ancestor = sti_parents[ancestor]
          end
          family
        end

        # One group per STI base. Each class lists only its direct subclasses, so the
        # tree is walked down to reach every level: [parent, child, depth] in tree order.
        def extract_sti_groups(models_data)
          by_name = models_data.to_h { |name, data| [ name.to_s, data ] }
          children_of = lambda do |name|
            data = by_name[name]
            data.is_a?(Hash) && !data[:error] && data[:sti] ? Array(data[:sti][:sti_children]).map(&:to_s) : []
          end

          by_name.filter_map do |name, data|
            next unless data.is_a?(Hash) && !data[:error] && data.dig(:sti, :sti_base)

            edges = []
            walk = lambda do |parent, depth, seen|
              children_of.call(parent).each do |child|
                next if seen.include?(child)

                edges << [ parent, child, depth ]
                walk.call(child, depth + 1, seen | [ child ])
              end
            end
            walk.call(name, 1, [ name ])
            { base: name, table: data[:table_name], children: edges }
          end
        end

        CYCLES_NOTE = "_Chains of foreign keys that lead back to the model they start from, through another: a belongs_to, or the " \
                      "has_many or has_one at its other end. An association and its inverse are one key, and a key to the model's own " \
                      "table is a tree, so neither is a cycle._"

        def cycle_lines(cycles)
          return [] if cycles.nil?
          return [ "## Circular Dependencies", "None. #{CYCLES_NOTE}" ] if cycles.empty?

          [ "## Circular Dependencies", CYCLES_NOTE, *cycles.map { |c| "- #{c.join(" → ")} → #{c.first}" } ]
        end

        def render_mermaid(graph, center, cycles: nil, sti_groups: [], total_nodes: nil, total_edges: nil, skipped: [], unresolved: {})
          lines = [ "# Dependency Graph", "" ]
          lines << "```mermaid"
          lines << "graph LR"

          if center
            lines << "  style #{sanitize(center)} fill:#f9f,stroke:#333,stroke-width:2px"
          end

          rendered = Set.new
          arrows = 0
          graph.each do |model, edges|
            # `belongs_to :author` and `belongs_to :owner, class_name: "Author"`
            # are two arrows, each labelled by its association.
            shared = shared_targets(edges)
            edges.each do |edge|
              intermediate = edge[:through_class] || edge[:through].to_s.classify if edge[:through]
              # Two through edges to one target differ by the class they pass through.
              named = shared.include?([ edge[:type].to_s, edge[:target] ]) ? edge[:name] : nil
              key = "#{model}->#{edge[:target]}:#{edge[:type]}:#{intermediate}:#{edge[:polymorphic]}:#{named}"
              next if rendered.include?(key)
              rendered.add(key)

              if edge[:through]
                # Through: two edges with double arrow
                through_key1 = "#{model}->#{intermediate}:through"
                through_key2 = "#{intermediate}->#{edge[:target]}:through"
                unless rendered.include?(through_key1)
                  rendered.add(through_key1)
                  lines << "  #{sanitize(model)} ==>|through| #{sanitize(intermediate)}"
                  arrows += 1
                end
                unless rendered.include?(through_key2)
                  rendered.add(through_key2)
                  lines << "  #{sanitize(intermediate)} ==>|through| #{sanitize(edge[:target])}"
                  arrows += 1
                end
              elsif edge[:polymorphic]
                # Polymorphic: dashed arrow to interface + concrete targets
                lines << "  #{sanitize(model)} -.->|polymorphic| #{sanitize(edge[:target])}"
                arrows += 1
                (edge[:polymorphic_targets] || []).each do |concrete|
                  poly_key = "#{concrete}->#{model}:polymorphic_impl"
                  unless rendered.include?(poly_key)
                    rendered.add(poly_key)
                    lines << "  #{sanitize(concrete)} -.->|implements| #{sanitize(model)}"
                    arrows += 1
                  end
                end
              else
                label = case edge[:type].to_s
                when "has_many", "has_and_belongs_to_many" then "has_many"
                else edge[:type].to_s
                end
                arrow = "-->|#{label}#{" #{named}" if named}|"
                lines << "  #{sanitize(model)} #{arrow} #{sanitize(edge[:target])}"
                arrows += 1
              end
            end
          end

          # STI: dotted lines
          sti_groups.each do |group|
            group[:children].each do |parent, child, _depth|
              sti_key = "#{parent}->#{child}:sti"
              unless rendered.include?(sti_key)
                rendered.add(sti_key)
                lines << "  #{sanitize(parent)} -.-|STI| #{sanitize(child)}"
              end
            end
          end

          lines << "```"
          lines << ""

          stats = [ "**Models:** #{total_nodes || graph.keys.size}",
                    "**Associations:** #{total_edges || graph.values.sum(&:size)}" ]
          stats << "**Cycles:** #{cycles.size}" if cycles
          stats << "**STI hierarchies:** #{sti_groups.size}" if sti_groups.any?
          lines << stats.join(" | ")
          lines.concat(truncation_notes(graph, total_nodes, skipped, total_edges, unresolved, drawn: arrows, focused: !center.nil?))

          # Cycles section
          lines.push("", *cycle_lines(cycles)) if cycles
          lines.join("\n")
        end

        # [macro, class] pairs a model reaches through more than one plain association.
        def shared_targets(edges)
          edges.reject { |e| e[:through] || e[:polymorphic] }
               .group_by { |e| [ e[:type].to_s, e[:target] ] }.select { |_, list| list.size > 1 }.keys
        end

        def render_text(graph, center, cycles: nil, sti_groups: [], total_nodes: nil, total_edges: nil, skipped: [], unresolved: {})
          lines = [ "# Dependency Graph", "" ]
          rows = 0

          if center
            lines << "Centered on: #{center}"
            lines << ""
          end

          graph.each do |model, edges|
            shared = shared_targets(edges)
            lines << "## #{model}"
            if edges.empty?
              lines << "  (no associations)"
            else
              edges.each do |edge|
                if edge[:through]
                  lines << "  #{edge[:type]} → #{edge[:target]} through #{edge[:through]}"
                  rows += 1
                elsif edge[:polymorphic]
                  targets = (edge[:polymorphic_targets] || []).join(", ")
                  impl = targets.empty? ? "" : " [#{targets}]"
                  lines << "  #{edge[:type]} → #{edge[:target]} (polymorphic)#{impl}"
                  rows += 1
                else
                  named = shared.include?([ edge[:type].to_s, edge[:target] ]) ? " (#{edge[:name]})" : ""
                  lines << "  #{edge[:type]} → #{edge[:target]}#{named}"
                  rows += 1
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
              group[:children].each { |_parent, child, depth| lines << "#{"  " * depth}- #{child}" }
            end
            lines << ""
          end

          # Cycles section
          lines.concat(cycle_lines(cycles)) << "" if cycles

          stats = [ "**Models:** #{total_nodes || graph.keys.size}",
                    "**Associations:** #{total_edges || graph.values.sum(&:size)}" ]
          stats << "**Cycles:** #{cycles.size}" if cycles
          stats << "**STI hierarchies:** #{sti_groups.size}" if sti_groups.any?
          lines << stats.join(" | ")
          lines.concat(truncation_notes(graph, total_nodes, skipped, total_edges, unresolved, drawn: rows, focused: !center.nil?))

          lines.join("\n")
        end

        # Both a node cap and a model whose reflections could not be read
        # used to leave the graph looking complete.
        def named_list(listed)
          shown = listed.first(UNRESOLVED_NAMED)
          listed.size > shown.size ? "#{shown.join(', ')} and #{listed.size - shown.size} more" : shown.join(", ")
        end

        def truncation_notes(graph, total_nodes, skipped, total_edges = nil, unresolved = {}, drawn: nil, focused: false)
          notes = []
          computed = unresolved.flat_map { |model, names| names.grep(String).map { |n| "#{model}##{n}" } }.sort
          if computed.any?
            notes << ""
            notes << "_The association count leaves out #{count_phrase(computed.size, "association")} whose `class_name` is a runtime expression: #{named_list(computed)}._"
          end
          # A literal `through: :x` reads as a bare name; anything else is source computed at run time.
          computed_through, broken = unresolved.flat_map { |model, names| names.grep(Hash).map { |b| [ model, b ] } }
                                                .partition { |_model, b| !b[:through].match?(/\A\w+\z/) }
          if computed_through.any?
            notes << ""
            listed = computed_through.map { |model, b| "#{model}##{b[:name]} (through `#{b[:through]}`)" }.sort
            notes << "_Not drawn, a through association whose name is computed at run time: #{named_list(listed)}._"
          end
          broken = broken.map do |model, b|
            unread = Array(b[:unread])
            where = unread.empty? ? "which #{model} does not declare" : "which no file read for #{model} declares; #{unread.join(', ')} unread"
            "#{model}##{b[:name]} (through :#{b[:through]}, #{where})"
          end.sort
          if broken.any?
            notes << ""
            notes << "_Not drawn, a through association naming no association of its model: #{named_list(broken)}._"
          end
          if total_nodes && total_nodes > graph.keys.size
            carried = graph.values.sum(&:size)
            # Three counts in three units, because they are three different
            # things: a reader counting arrows in the block gets the first.
            edges = if drawn && total_edges
              ", drawing #{count_phrase(drawn, "edge")} for #{carried} of #{count_phrase(total_edges, "association")}"
            else
              ""
            end
            notes << ""
            # Told to pass `model:` when it already had, a reader has nothing to do.
            hint = focused ? "" : "; pass `model:` to focus the graph"
            notes << "_Showing #{graph.keys.size} of #{total_nodes} models#{edges}#{hint}._"
          end
          if skipped.any?
            notes << ""
            notes << "_#{count_phrase(skipped.size, "model")} left out, introspection failed: #{skipped.sort.join(", ")}._"
          end
          notes
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
