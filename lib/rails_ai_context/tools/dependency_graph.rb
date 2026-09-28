# frozen_string_literal: true

module RailsAiContext
  module Tools
    class DependencyGraph < BaseTool
      tool_name "rails_dependency_graph"
      description "Generates a dependency graph showing how models, services, and controllers " \
        "connect. Output as Mermaid diagram syntax or plain text. " \
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
        order: 27,
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

        # Optional analyses
        cycles = show_cycles ? detect_cycles(graph) : []
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

          # The declared model names, so a derived one can be corrected to the
          # spelling the app uses. Camelizing in this process knows none of the
          # app's acronyms, so `ai_match_result` comes out `AiMatchResult`
          # while the node the graph draws is `AIMatchResult`.
          declared = models_data.each_with_object({}) do |(model_name, model_data), acc|
            acc[model_name.to_s.downcase] = { name: model_name.to_s, data: model_data }
          end

          # Build edges
          models_data.each do |model_name, data|
            next unless data.is_a?(Hash) && !data[:error]
            name = model_name.to_s

            associations = data[:associations] || []
            by_name = associations.each_with_object({}) { |a, acc| acc[a[:name].to_s] = a }

            edges = associations.filter_map do |assoc|
              next if assoc[:unavailable]

              # An unreadable class_name names no class; camelizing the association instead
              # draws a node the app does not define.
              if (assoc[:class_name] && !readable_class?(assoc[:class_name])) ||
                 (assoc[:class_name].nil? && assoc[:computed_name])
                (unresolved[name] ||= []) << assoc[:name].to_s
                next
              end

              # `has_many :x, through: :buyer` with no `buyer` association fails
              # when Rails reads it; it names no class to draw. A module the
              # walk could not read might declare it, and the note says so.
              if assoc[:through] && !by_name.key?(assoc[:through].to_s)
                unread = Array(data[:concerns_unread]) + Array(data[:bases_unread])
                (unresolved[name] ||= []) << { name: assoc[:name].to_s, through: assoc[:through].to_s, unread: unread }
                next
              end

              target = resolve_target(assoc, models_data, by_name, declared, owner: name)
              next unless target

              edge = {
                type: assoc[:macro] || assoc[:type],
                name: assoc[:name].to_s,
                target: target,
                through: assoc[:through],
                through_class: assoc[:through] && through_class(assoc, by_name, declared, owner: name),
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

          [ graph, unresolved ]
        end

        # How many of them the note spells out before it counts the rest.
        UNRESOLVED_NAMED = 10

        COLLECTION_MACROS = %w[has_many has_and_belongs_to_many embeds_many].freeze

        # A class name a node can be drawn from, rather than the expression a
        # file wrote in place of one.
        CLASS_SHAPED = /\A(::)?[A-Z][A-Za-z0-9_]*(::[A-Z][A-Za-z0-9_]*)*\z/

        def readable_class?(value)
          value.to_s.match?(CLASS_SHAPED)
        end

        # Rails singularizes an association name only for a collection
        # (`derive_class_name`), so `belongs_to :search_criteria` is
        # `SearchCriteria` and never `SearchCriterium`. A computed name
        # (`belongs_to owner_name`) camelizes into a class no app defines.
        def derive_class(assoc, declared, owner: nil)
          name = assoc[:name].to_s
          return nil if name.empty? || assoc[:computed_name]

          base = COLLECTION_MACROS.include?((assoc[:macro] || assoc[:type]).to_s) ? name.singularize : name
          declared_spelling(base.camelize, declared, owner: owner)
        end

        def declared_spelling(candidate, declared, owner: nil)
          Introspectors::TableName.resolve_class(candidate, owner) { |name| declared.dig(name.downcase, :name) }
        end

        # The class the `through:` association points at - its own
        # `class_name` when one is declared, never the association name
        # camelized, which drew `PrimaryBuyer` and `InvoicePdfAttachment` as
        # nodes no app defines.
        def through_class(assoc, by_name, declared, owner: nil)
          hop = by_name[assoc[:through].to_s]
          return declared_spelling(assoc[:through].to_s.singularize.camelize, declared, owner: owner) unless hop

          named = hop[:class_name] if readable_class?(hop[:class_name])
          named ? declared_spelling(named, declared, owner: owner) : derive_class(hop, declared, owner: owner)
        end

        # Booted, a through reflection's `class_name` already follows
        # `source:`. Static records none, so the far side is read off the
        # source association on the class the through hop lands on.
        def resolve_target(assoc, _models_data, by_name, declared, owner: nil)
          # A polymorphic source names no class; `source_type:` does, in both
          # tiers, ahead of a class_name reflection derived from the name.
          source_type = assoc.dig(:options, :source_type) || assoc[:source_type]
          return declared_spelling(source_type, declared, owner: owner) if assoc[:through] && readable_class?(source_type)
          return declared_spelling(assoc[:class_name], declared, owner: owner) if assoc[:class_name]
          return derive_class(assoc, declared, owner: owner) unless assoc[:through]

          middle = through_class(assoc, by_name, declared, owner: owner)
          source_name = (assoc.dig(:options, :source) || assoc[:source] || assoc[:name]).to_s
          middle_data = declared.dig(middle.to_s.downcase, :data)
          source_assoc = Array(middle_data.is_a?(Hash) ? middle_data[:associations] : nil)
                           .find { |a| a[:name].to_s == source_name }

          # The far side belongs to the middle class, and resolves from there.
          if source_assoc
            named = source_assoc[:class_name] if readable_class?(source_assoc[:class_name])
            named ? declared_spelling(named, declared, owner: middle) : derive_class(source_assoc, declared, owner: middle)
          else
            derive_class(assoc, declared, owner: owner)
          end
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

        def render_mermaid(graph, center, cycles: [], sti_groups: [], total_nodes: nil, total_edges: nil, skipped: [], unresolved: {})
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

          stats = [ "**Models:** #{total_nodes || graph.keys.size}",
                    "**Associations:** #{total_edges || graph.values.sum(&:size)}" ]
          stats << "**Cycles:** #{cycles.size}" if cycles.any?
          stats << "**STI hierarchies:** #{sti_groups.size}" if sti_groups.any?
          lines << stats.join(" | ")
          lines.concat(truncation_notes(graph, total_nodes, skipped, total_edges, unresolved, drawn: arrows, focused: !center.nil?))

          # Cycles section
          if cycles.any?
            lines << ""
            lines << "## Circular Dependencies"
            cycles.each { |c| lines << "- #{c.join(" → ")} → #{c.first}" }
          end

          lines.join("\n")
        end

        # [macro, class] pairs a model reaches through more than one plain association.
        def shared_targets(edges)
          edges.reject { |e| e[:through] || e[:polymorphic] }
               .group_by { |e| [ e[:type].to_s, e[:target] ] }.select { |_, list| list.size > 1 }.keys
        end

        def render_text(graph, center, cycles: [], sti_groups: [], total_nodes: nil, total_edges: nil, skipped: [], unresolved: {})
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

          stats = [ "**Models:** #{total_nodes || graph.keys.size}",
                    "**Associations:** #{total_edges || graph.values.sum(&:size)}" ]
          stats << "**Cycles:** #{cycles.size}" if cycles.any?
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
          broken = unresolved.flat_map do |model, names|
            names.grep(Hash).map do |b|
              unread = Array(b[:unread])
              where = unread.empty? ? "which #{model} does not declare" : "which no file read for #{model} declares; #{unread.join(', ')} unread"
              "#{model}##{b[:name]} (through :#{b[:through]}, #{where})"
            end
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
