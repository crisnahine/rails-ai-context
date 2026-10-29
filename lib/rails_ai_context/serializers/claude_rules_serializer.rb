# frozen_string_literal: true

module RailsAiContext
  module Serializers
    # Generates .claude/rules/ files for Claude Code auto-discovery.
    # These provide quick-reference lists without bloating CLAUDE.md.
    class ClaudeRulesSerializer < Base
      include StackOverviewHelper
      include ToolGuideHelper

      RULE_FILES = {
        "rails-context.md" => { renderer: :render_context_overview, reason: :overview_reason,
                                scope: RuleScope.always("Rails project overview") },
        "rails-schema.md" => { renderer: :render_schema_reference, reason: "no schema dump", scope: :schema_scope },
        "rails-models.md" => { renderer: :render_models_reference, reason: "no models",
                               scope: RuleScope.paths("app/models/**/*.rb", description: "ActiveRecord models") },
        "rails-mcp-tools.md" => { renderer: :render_mcp_tools_reference, reason: :overview_reason, kind: :root,
                                  scope: RuleScope.always("Rails tools guide") },
        "rails-components.md" => { renderer: :render_components_reference, reason: "no view components",
                                   scope: RuleScope.paths("app/components/**/*.rb", "app/views/components/**", description: "Components") }
      }.freeze

      # @param output_dir [String] Rails root path
      # @return [Hash] { written:, skipped:, removed:, trimmed: [paths], not_applicable: { path => reason } }
      def call(output_dir)
        write_rule_table(File.join(output_dir, Install::AiTool.find(:claude).rules_dir), RULE_FILES, root: output_dir, tool: :claude)
      end

      private

      def plan
        @plan ||= LoadPlan.new([ :claude ])
      end

      def overview_reason
        plan.root_carries?(:claude) ? in_root_reason : "nothing to document"
      end

      # The root file states the overview whenever it is written.
      def render_context_overview
        return nil if plan.root_carries?(:claude)

        lines = header_lines(:overview, title: "Overview")
        lines.concat(overview_lines)

        lines << ""
        lines << "Use #{tools_noun} for context rather than reading reference files."
        lines << "Start with `#{param_text("detail", "summary")}`, and read a file only to edit it."

        lines.join("\n")
      end

      # Every database's tables, the primary's first. Each gets a heading unless the
      # primary is the only one, since a table name can be in two and a lone other
      # database is not the one a reader assumes. A database
      # a Rails framework keeps to itself (Rails 8's queue, cache and cable)
      # is no part of it: its tables are the framework's, CLAUDE.md names it,
      # and its dump says nothing this listing would help with.
      def render_schema_reference
        schema = Payload.section(context, :schema)
        return nil unless schema

        secondary = Payload.app_databases(schema)
        databases = [ [ nil, schema[:tables] || {} ] ] + secondary.map { |name, db| [ name, db[:tables] ] }
        databases.reject! { |_, tables| tables.empty? }
        return nil if databases.empty?

        lines = [ "# Database Tables (#{databases.sum { |_, tables| tables.size }})", "" ]
        lines.concat(SectionFacts.static_notice_lines(context))
        live = " Use #{tool_ref("rails_get_schema", 'table:"name"', "table=name")} for live data." if served?("rails_get_schema")
        lines << "_Snapshot - may be stale after migrations.#{live}_"

        primary_alone = databases.size == 1 && databases.first.first.nil?
        databases.each do |name, tables|
          lines << ""
          lines.concat(database_heading_lines(name, tables, secondary)) unless primary_alone
          lines.concat(table_reference_lines(tables, name, schema))
        end

        lines.join("\n")
      end

      def schema_scope
        RuleScope.paths(schema_rule_paths(Payload.app_databases(Payload.section(context, :schema))), description: "Database tables")
      end

      # The dumps and migrations the tables are read from, each database's, so
      # opening any of them brings the rule in. The primary's has to name the
      # dump the app committed, or the rule never triggers on a :sql app:
      # db/schema.rb is never opened there.
      def schema_rule_paths(secondary)
        paths = [ schema_dump_path, "db/migrate/**" ]
        secondary.each_value do |db|
          paths << db[:dump] if db[:dump]
          Array(db[:migrations_paths]).each { |dir| paths << "#{dir}/**" }
        end
        paths.uniq
      end

      def database_heading_lines(name, tables, secondary)
        relations = Introspectors::SchemaConventions.relations_phrase(tables)
        return [ "## #{Payload.primary_label(context)} (#{SchemaAdapter.label(context)}, #{relations})", "" ] unless name

        db = secondary[name]
        adapter = SchemaAdapter.secondary_label(context, name, db)
        lines = [ "## #{name} (#{[ Payload.named_scope_words(context, name), adapter, relations ].compact.join(', ')})", "" ]
        # Where the snapshot comes from: a booted run reads the primary live, this from its files.
        lines.push("_#{db[:note]}._", "") if db[:note]
        lines
      end

      def table_reference_lines(tables, database, schema)
        lines = []
        skip_cols = %w[id created_at updated_at]
        keep_cols = %w[type deleted_at discarded_at]
        # Get enum values from models introspection if available
        models = Payload.models(context)

        tables.keys.sort.first(Budget.cap(:listed_rows)).each do |name|
          data = tables[name]
          columns = data[:columns] || []
          col_count = columns.size

          # Show column names WITH types for key columns
          # Skip standard Rails FK columns (like user_id, account_id) but keep
          # external ID columns (like stripe_checkout_id, stripe_payment_id)
          fk_columns = (data[:foreign_keys] || []).map { |f| f[:column] }.to_set
          all_table_names = tables.keys.to_set
          key_cols = columns.select do |c|
            next true if keep_cols.include?(c[:name])
            next true if c[:name].end_with?("_type")
            next false if skip_cols.include?(c[:name])
            if c[:name].end_with?("_id")
              # Skip if it's a known FK or matches a table name (conventional Rails FK)
              ref_table = c[:name].sub(/_id\z/, "").pluralize
              next false if fk_columns.include?(c[:name]) || all_table_names.include?(ref_table)
            end
            true
          end

          col_sample = key_cols.map do |c|
            col_type = c[:array] ? "#{c[:type]}[]" : c[:type].to_s
            entry = c[:type] ? "#{c[:name]}:#{col_type}" : c[:name].to_s
            if c.key?(:default) && !c[:default].nil?
              default_display = c[:default] == "" ? '""' : c[:default]
              entry += "(=#{default_display})"
            end
            entry
          end

          # Foreign keys
          fks = (data[:foreign_keys] || []).map { |f| "#{Introspectors::SchemaConventions.key_text(f[:column])}→#{f[:to_table]}" }

          # Key indexes (unique or composite)
          idxs = (data[:indexes] || []).select { |i| i[:unique] || Array(i[:columns]).size > 1 }
            .map do |i|
              where = Introspectors::SchemaConventions.where_clause(i[:where])
              i[:unique] ? "#{Array(i[:columns]).join('+')}(unique#{where})" : "#{Array(i[:columns]).join('+')}#{where}"
            end

          # A line each, so a wide table costs lines of the width, not one line of kilobytes.
          lead = "- **#{name}** (#{count_phrase(col_count, 'col')})"
          lines << (col_sample.any? ? Budget.list(col_sample, lead: "#{lead} - ") : lead)
          lines << Budget.list(fks, lead: "  FK: ", separator: "; ") if fks.any?
          lines << Budget.list(idxs, lead: "  Idx: ", separator: "; ") if idxs.any?

          # Include enum values if model has them
          model_data = table_model(models, name, database, schema)
          if model_data.is_a?(Hash) && model_data[:enums]&.any?
            model_data[:enums].each do |attr, values|
              lines << Budget.list(SectionFacts.enum_names(values), lead: "  #{attr}: ")
            end
          end
        end

        if tables.size > Budget.cap(:listed_rows)
          use = " (use #{tool_named("rails_get_schema")})" if served?("rails_get_schema")
          lines << "- ...#{count_phrase(tables.size - Budget.cap(:listed_rows), "more table")}#{use}"
        end

        lines
      end

      # The model named after the table. Another database's table of that name
      # is some other model's: the one that reads from that database.
      def table_model(models, table, database, schema)
        named = models[table.classify]
        return named unless database
        return named if named.is_a?(Hash) && Payload.model_databases(schema, named).include?(database)

        models.keys.sort.map { |name| models[name] }.find do |data|
          data.is_a?(Hash) && data[:table_name] == table && Payload.model_databases(schema, data).include?(database)
        end
      end

      def render_models_reference
        models = Payload.models(context)
        return nil if models.empty?

        lines = [
          "# ActiveRecord Models (#{models.size})",
          ""
        ]
        lines.concat(SectionFacts.static_notice_lines(context))
        lines.concat(model_rows(:listing))
        lines.join("\n")
      end

      def render_components_reference
        comp = Payload.section(context, :components)
        return nil unless comp
        components = comp[:components] || []
        return nil if components.empty?

        lines = [
          "# Components (#{components.size})",
          ""
        ]
        lines.concat(SectionFacts.static_notice_lines(context))
        lines << "ViewComponent and Phlex components available for reuse."
        lines.concat(tool_pointers([ "rails_get_component_catalog", 'component:"Name"', "component=Name", "for full detail." ]))
        lines << ""

        components.each do |c|
          slots = (c[:slots] || []).map { |s| s[:name] }
          props = (c[:props] || []).map { |p| p[:default] ? "#{p[:name]}:#{p[:default]}" : p[:name] }
          lines << "- **#{c[:name]}** (#{c[:type]})"
          lines << "  props: #{props.join(', ')}" if props.any?
          lines << "  slots: #{slots.join(', ')}" if slots.any?
        end

        lines.join("\n")
      end

      # The guide, where no root file carries it. The tools list themselves:
      # the MCP client lists them, and `tool --list` on the command line.
      def render_mcp_tools_reference
        plan.root_carries?(:claude) ? nil : render_tools_guide.join("\n")
      end
    end
  end
end
