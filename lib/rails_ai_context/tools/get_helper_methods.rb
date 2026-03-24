# frozen_string_literal: true

module RailsAiContext
  module Tools
    class GetHelperMethods < BaseTool
      tool_name "rails_get_helper_methods"
      description "Get Rails helper modules: method signatures, framework helpers in use, and which views call each helper. " \
        "Use when: finding available view helpers, checking what helper methods exist, or understanding shared view logic. " \
        "Specify helper:\"ApplicationHelper\" for full detail, or omit to list all helpers with method counts."

      # Common framework helpers to detect usage of
      FRAMEWORK_HELPERS = {
        "Devise" => %w[current_user user_signed_in? authenticate_user! current_admin admin_signed_in? authenticate_admin!],
        "Pagy" => %w[pagy_nav pagy_info pagy_nav_js pagy_combo_nav_js pagy_items_selector_js],
        "Turbo" => %w[turbo_stream_from turbo_frame_tag turbo_stream],
        "Pundit" => %w[policy authorize pundit_user],
        "CanCanCan" => %w[can? cannot? authorize!],
        "Kaminari" => %w[paginate page_entries_info],
        "WillPaginate" => %w[will_paginate page_entries_info],
        "SimpleForm" => %w[simple_form_for simple_fields_for],
        "Draper" => %w[decorate decorated?],
        "InlineSvg" => %w[inline_svg_tag inline_svg],
        "MetaTags" => %w[set_meta_tags display_meta_tags]
      }.freeze

      input_schema(
        properties: {
          helper: {
            type: "string",
            description: "Helper module name (e.g. 'ApplicationHelper', 'UsersHelper'). Omit to list all helpers."
          },
          detail: {
            type: "string",
            enum: %w[summary standard full],
            description: "Detail level. summary: names + method counts. standard: names + method signatures (default). full: method signatures + view cross-references + framework helpers."
          }
        }
      )

      annotations(read_only_hint: true, destructive_hint: false, idempotent_hint: true, open_world_hint: false)

      def self.call(helper: nil, detail: "standard", server_context: nil)
        root = rails_app.root.to_s
        helpers_dir = File.join(root, "app", "helpers")
        max_size = RailsAiContext.configuration.max_file_size

        unless Dir.exist?(helpers_dir)
          return text_response("No app/helpers/ directory found.")
        end

        helper_files = Dir.glob(File.join(helpers_dir, "**", "*.rb")).sort

        if helper_files.empty?
          return text_response("No helper files found in app/helpers/.")
        end

        # Specific helper — full detail
        if helper
          return show_helper(helper, helper_files, helpers_dir, root, max_size, detail)
        end

        # List all helpers
        list_helpers(helper_files, helpers_dir, root, max_size, detail)
      end

      private_class_method def self.show_helper(name, helper_files, helpers_dir, root, max_size, detail)
        # Find by module name or file name
        underscore = name.underscore.delete_suffix("_helper")
        file_path = helper_files.find do |f|
          basename = File.basename(f, ".rb")
          basename == "#{underscore}_helper" || basename == underscore || basename == name.underscore
        end

        unless file_path
          available = helper_files.map { |f| File.basename(f, ".rb").camelize }
          return not_found_response("Helper", name, available,
            recovery_tool: "Call rails_get_helper_methods() to see all helpers")
        end

        if File.size(file_path) > max_size
          return text_response("Helper file too large: #{file_path} (#{File.size(file_path)} bytes, max: #{max_size})")
        end

        source = File.read(file_path, encoding: "UTF-8", invalid: :replace, undef: :replace)
        relative_path = file_path.sub("#{root}/", "")
        module_name = File.basename(file_path, ".rb").camelize

        lines = [ "# #{module_name}", "" ]
        lines << "**File:** `#{relative_path}` (#{source.lines.size} lines)"

        # Parse method signatures
        methods = parse_helper_methods(source)
        if methods.any?
          lines << "" << "## Methods (#{methods.size})"
          methods.each { |m| lines << "- `#{m}`" }
        else
          lines << "" << "_No public methods defined._"
        end

        # For standard/full: show included modules
        if detail != "summary"
          included = source.scan(/^\s*include\s+(\S+)/).flatten
          if included.any?
            lines << "" << "## Includes"
            included.each { |i| lines << "- #{i}" }
          end
        end

        # For full detail: cross-reference with views
        if detail == "full"
          method_names = methods.map { |m| m.split("(").first }
          if method_names.any?
            view_refs = find_view_references(method_names, root)
            if view_refs.any?
              lines << "" << "## View References"
              view_refs.each do |method_name, views|
                view_list = views.first(5).join(", ")
                more = views.size > 5 ? " +#{views.size - 5} more" : ""
                lines << "- `#{method_name}` used in: #{view_list}#{more}"
              end
            else
              lines << "" << "_No view references found for these helper methods._"
            end
          end
        end

        # Cross-reference hints
        controller_name = underscore.split("/").last
        lines << ""
        lines << "_Next: `rails_get_view(controller:\"#{controller_name}\")` for views"
        lines << " | `rails_get_controllers(controller:\"#{controller_name.camelize}Controller\")` for controller_"

        text_response(lines.join("\n"))
      end

      private_class_method def self.list_helpers(helper_files, helpers_dir, root, max_size, detail)
        helpers_data = helper_files.filter_map do |file_path|
          relative = file_path.sub("#{root}/", "")
          module_name = File.basename(file_path, ".rb").camelize

          if File.size(file_path) <= max_size
            source = File.read(file_path, encoding: "UTF-8", invalid: :replace, undef: :replace) rescue nil
            methods = source ? parse_helper_methods(source) : []
          else
            methods = []
          end

          {
            name: module_name,
            path: relative,
            methods: methods,
            method_count: methods.size
          }
        end

        lines = [ "# Helpers (#{helpers_data.size})", "" ]

        case detail
        when "summary"
          helpers_data.sort_by { |h| -h[:method_count] }.each do |h|
            lines << "- **#{h[:name]}** — #{h[:method_count]} methods"
          end
          lines << "" << "_Use `helper:\"Name\"` for method signatures._"

        when "standard"
          helpers_data.sort_by { |h| -h[:method_count] }.each do |h|
            lines << "## #{h[:name]} (`#{h[:path]}`)"
            if h[:methods].any?
              h[:methods].each { |m| lines << "- `#{m}`" }
            else
              lines << "- _(no public methods)_"
            end
            lines << ""
          end

        when "full"
          # Include framework helpers detection
          framework = detect_framework_helpers(root, max_size)

          helpers_data.sort_by { |h| -h[:method_count] }.each do |h|
            lines << "## #{h[:name]} (`#{h[:path]}`)"
            if h[:methods].any?
              h[:methods].each { |m| lines << "- `#{m}`" }
            else
              lines << "- _(no public methods)_"
            end
            lines << ""
          end

          if framework.any?
            lines << "## Framework Helpers Detected"
            framework.each do |lib, methods|
              lines << "- **#{lib}:** #{methods.join(', ')}"
            end
            lines << ""
          end

          lines << "_Use `helper:\"Name\"` with `detail:\"full\"` for view cross-references._"

        else
          return text_response("Unknown detail level: #{detail}. Use summary, standard, or full.")
        end

        text_response(lines.join("\n"))
      end

      private_class_method def self.parse_helper_methods(source)
        methods = []
        in_private = false

        source.each_line do |line|
          in_private = true if line.match?(/\A\s*(private|protected)\s*$/)
          in_private = false if line.match?(/\A\s*public\s*$/)
          next if in_private

          if (match = line.match(/\A\s*def\s+([\w?!]+(?:\([^)]*\))?)/))
            method_sig = match[1]
            methods << method_sig unless method_sig.start_with?("_")
          end
        end

        methods
      rescue
        []
      end

      private_class_method def self.find_view_references(method_names, root)
        views_dir = File.join(root, "app", "views")
        return {} unless Dir.exist?(views_dir)

        references = {}
        max_size = RailsAiContext.configuration.max_file_size

        view_files = Dir.glob(File.join(views_dir, "**", "*.{erb,haml,slim}"))

        method_names.each do |method_name|
          matching_views = []

          view_files.each do |view_path|
            next if File.size(view_path) > max_size
            content = File.read(view_path, encoding: "UTF-8", invalid: :replace, undef: :replace) rescue next

            if content.include?(method_name)
              relative = view_path.sub("#{root}/app/views/", "")
              matching_views << relative
            end
          end

          references[method_name] = matching_views if matching_views.any?
        end

        references
      rescue
        {}
      end

      private_class_method def self.detect_framework_helpers(root, max_size)
        detected = {}

        # Check Gemfile for framework gems
        gemfile_path = File.join(root, "Gemfile")
        return detected unless File.exist?(gemfile_path)

        gemfile = File.read(gemfile_path, encoding: "UTF-8", invalid: :replace, undef: :replace) rescue ""

        # Collect all view file content for scanning
        views_dir = File.join(root, "app", "views")
        helpers_dir = File.join(root, "app", "helpers")
        scan_content = ""

        [ views_dir, helpers_dir ].each do |dir|
          next unless Dir.exist?(dir)
          extensions = dir == views_dir ? "*.{erb,haml,slim}" : "*.rb"
          Dir.glob(File.join(dir, "**", extensions)).each do |path|
            next if File.size(path) > max_size
            scan_content += (File.read(path, encoding: "UTF-8", invalid: :replace, undef: :replace) rescue "")
          end
        end

        FRAMEWORK_HELPERS.each do |lib, methods|
          gem_name = lib.downcase
          # Check if the gem is in the Gemfile (case-insensitive, handle common gem names)
          gem_patterns = {
            "Devise" => /gem\s+['"]devise['"]/,
            "Pagy" => /gem\s+['"]pagy['"]/,
            "Turbo" => /gem\s+['"]turbo-rails['"]/,
            "Pundit" => /gem\s+['"]pundit['"]/,
            "CanCanCan" => /gem\s+['"]cancancan['"]/,
            "Kaminari" => /gem\s+['"]kaminari['"]/,
            "WillPaginate" => /gem\s+['"]will_paginate['"]/,
            "SimpleForm" => /gem\s+['"]simple_form['"]/,
            "Draper" => /gem\s+['"]draper['"]/,
            "InlineSvg" => /gem\s+['"]inline_svg['"]/,
            "MetaTags" => /gem\s+['"]meta-tags['"]/
          }

          pattern = gem_patterns[lib] || /gem\s+['"]#{Regexp.escape(gem_name)}['"]/
          next unless gemfile.match?(pattern)

          # Find which framework methods are actually used
          used = methods.select { |m| scan_content.include?(m) }
          detected[lib] = used if used.any?
        end

        detected
      rescue
        {}
      end
    end
  end
end
