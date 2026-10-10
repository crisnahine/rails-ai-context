# frozen_string_literal: true

module RailsAiContext
  module Serializers
    # Generates .claude/rules/ files for Claude Code auto-discovery.
    # These provide quick-reference lists without bloating CLAUDE.md.
    class ClaudeRulesSerializer < Base
      include StackOverviewHelper
      include ToolGuideHelper

      RULE_FILES = {
        "rails-context.md" => { renderer: :render_context_overview, reason: "nothing to document" },
        "rails-schema.md" => { renderer: :render_schema_reference, reason: "no schema dump" },
        "rails-models.md" => { renderer: :render_models_reference, reason: "no models" },
        "rails-mcp-tools.md" => { renderer: :render_mcp_tools_reference, reason: "nothing to document" },
        "rails-components.md" => { renderer: :render_components_reference, reason: "no view components" }
      }.freeze

      # Per database; the tools have the rest.
      TABLES_SHOWN = 30

      # @param output_dir [String] Rails root path
      # @return [Hash] { written: [paths], skipped: [paths], not_applicable: { path => reason } }
      def call(output_dir)
        write_rule_table(File.join(output_dir, Install::AiTool.find(:claude).rules_dir), RULE_FILES)
      end

      private

      def render_context_overview
        lines = [
          "# #{context[:app_name] || 'Rails App'} - Overview",
          "",
          "Rails #{context[:rails_version]} | Ruby #{context[:ruby_version]}",
          ""
        ]
        # Gems, architecture, services and jobs are already in the root file
        # (CLAUDE.md/AGENTS.md), so this overview states the rest.
        lines.concat(overview_lines(gems: false, architecture: false, app_dirs: false))

        lines << ""
        lines << "ALWAYS use #{tools_noun} for context - do NOT read reference files directly."
        lines << "Start with `#{param_text("detail", "summary")}`. Read files ONLY when you will Edit them."

        lines.join("\n")
      end

      # Every database's tables, the primary's first. With more than one, each
      # gets a heading, since a table name can be in two of them. A database
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

        lines = [ "---", "paths:", *schema_rule_paths(secondary).map { |path| "  - \"#{path}\"" }, "---", "" ]
        lines << "# Database Tables (#{databases.sum { |_, tables| tables.size }})"
        lines << ""
        lines.concat(SectionFacts.static_notice_lines(context))
        lines << "_Snapshot - may be stale after migrations. Use #{tool_ref("rails_get_schema", 'table:"name"', "table=name")} for live data._"

        databases.each do |name, tables|
          lines << ""
          lines.concat(database_heading_lines(name, tables, secondary)) if secondary.any?
          lines.concat(table_reference_lines(tables, name, schema))
        end

        lines.join("\n")
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
        return [ "## primary (#{SchemaAdapter.label(context)}, #{relations})", "" ] unless name

        db = secondary[name]
        adapter = SchemaAdapter.secondary_label(context, name, db)
        lines = [ "## #{name} (#{[ adapter, relations ].compact.join(', ')})", "" ]
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

        tables.keys.sort.first(TABLES_SHOWN).each do |name|
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
          col_str = col_sample.any? ? " - #{col_sample.join(', ')}" : ""

          # Foreign keys
          fks = (data[:foreign_keys] || []).map { |f| "#{Introspectors::SchemaConventions.key_text(f[:column])}→#{f[:to_table]}" }
          fk_str = fks.any? ? " | FK: #{fks.join(', ')}" : ""

          # Key indexes (unique or composite)
          idxs = (data[:indexes] || []).select { |i| i[:unique] || Array(i[:columns]).size > 1 }
            .map do |i|
              where = Introspectors::SchemaConventions.where_clause(i[:where])
              i[:unique] ? "#{Array(i[:columns]).join('+')}(unique#{where})" : "#{Array(i[:columns]).join('+')}#{where}"
            end
          idx_str = idxs.any? ? " | Idx: #{idxs.join(', ')}" : ""

          lines << "- **#{name}** (#{count_phrase(col_count, 'col')})#{col_str}#{fk_str}#{idx_str}"

          # Include enum values if model has them
          model_data = table_model(models, name, database, schema)
          if model_data.is_a?(Hash) && model_data[:enums]&.any?
            model_data[:enums].each do |attr, values|
              lines << "  #{attr}: #{SectionFacts.enum_values(values)}"
            end
          end
        end

        if tables.size > TABLES_SHOWN
          lines << "- ...#{count_phrase(tables.size - TABLES_SHOWN, "more table")} (use #{tool_named("rails_get_schema")})"
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
          "---",
          "paths:",
          '  - "app/models/**/*.rb"',
          "---",
          "",
          "# ActiveRecord Models (#{models.size})",
          ""
        ]
        lines.concat(SectionFacts.static_notice_lines(context))
        lines << "_Quick reference - use #{tool_ref("rails_get_model_details", 'model:"Name"', "model=Name")} for live data with resolved concerns and callbacks._"
        lines << ""

        models.keys.sort.each do |name|
          data = models[name]
          if (unread = SectionFacts.unread_row("- #{name}", data))
            lines << unread
            next
          end

          assocs = (data[:associations] || []).size
          vals = (data[:validations] || []).size
          table = data[:table_name]
          line = "- #{name}"
          line += " (table: #{table})" if table
          line += " - #{count_phrase(assocs, "assoc")}, #{count_phrase(vals, "validation")}"
          lines << line

          # The rules file names only the concerns the app itself defines; a
          # gem capability module is the gem's story, not a file to read here.
          concerns = ConcernMembership.app_owned(data[:concerns], project_root)
          lines << "  concerns: #{concerns.join(', ')}" if concerns.any?

          # Include scopes so agents know available query methods
          scopes = data[:scopes] || []
          scope_names = scope_names(scopes)
          lines << "  scopes: #{scope_names.join(', ')}" if scopes.any?

          # Instance methods - filter Devise/framework internals that add noise
          devise_noise = %w[after_remembered apply_to_attribute_or_variable clear_reset_password_token
                            clear_reset_password_token? current_password devise_modules devise_modules?
                            devise_respond_to_and_will_save_change_to_attribute?]
          methods = (data[:instance_methods] || [])
            .reject { |m| m.end_with?("=") || devise_noise.include?(m) }
            .first(20)
          lines << "  methods: #{methods.join(', ')}" if methods.any?

          # Include constants (e.g. STATUSES, MODES) so agents know valid values
          constants = data[:constants] || []
          constants.each do |c|
            lines << "  #{c[:name]}: #{c[:values].join(', ')}"
          end

          # Include enums so agents know valid values
          enums = data[:enums] || {}
          enums.each do |attr, values|
            lines << "  #{attr}: #{SectionFacts.enum_values(values)}"
          end
        end

        lines.join("\n")
      end

      def render_components_reference
        comp = Payload.section(context, :components)
        return nil unless comp
        components = comp[:components] || []
        return nil if components.empty?

        lines = [
          "---",
          "paths:",
          '  - "app/components/**/*.rb"',
          '  - "app/views/components/**"',
          "---",
          "",
          "# Components (#{components.size})",
          ""
        ]
        lines.concat(SectionFacts.static_notice_lines(context))
        lines.concat([
          "ViewComponent and Phlex components available for reuse.",
          "Use #{tool_ref("rails_get_component_catalog", 'component:"Name"', "component=Name")} for full details.",
          ""
        ])

        components.each do |c|
          slots = (c[:slots] || []).map { |s| s[:name] }
          props = (c[:props] || []).map { |p| p[:default] ? "#{p[:name]}:#{p[:default]}" : p[:name] }
          lines << "- **#{c[:name]}** (#{c[:type]})"
          lines << "  props: #{props.join(', ')}" if props.any?
          lines << "  slots: #{slots.join(', ')}" if slots.any?
        end

        lines.join("\n")
      end

      # Always loaded beside CLAUDE.md, which carries the guide whenever root
      # files are on; without CLAUDE.md this is the only place for the guide.
      def render_mcp_tools_reference
        guide = RailsAiContext.configuration.generate_root_files ? render_tools_reference("CLAUDE.md") : render_tools_guide
        guide.join("\n")
      end
    end
  end
end
