# frozen_string_literal: true

require "set"

module RailsAiContext
  module Tools
    class GetHelperMethods < BaseTool
      tool_name "rails_get_helper_methods"
      description "Get Rails helper modules: method signatures, the view helpers controllers declare with helper_method, " \
        "framework helpers in use, and which views call each helper. " \
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

      # Only the libraries whose gem is not named after them in lowercase.
      FRAMEWORK_GEMS = {
        "Turbo" => "turbo-rails",
        "WillPaginate" => "will_paginate",
        "SimpleForm" => "simple_form",
        "InlineSvg" => "inline_svg",
        "MetaTags" => "meta-tags"
      }.freeze
      private_constant :FRAMEWORK_GEMS

      input_schema(
        properties: {
          helper: {
            type: "string",
            description: "Helper module name (e.g. 'ApplicationHelper', 'UsersHelper'). Omit to list all helpers."
          },
          detail: RailsAiContext::DetailLevel.schema("Detail level. summary: names + method counts. standard: names + method signatures (default). full: method signatures + view cross-references + framework helpers."),
          offset: {
            type: "integer",
            description: "Skip this many helpers for pagination. Default: 0."
          },
          limit: {
            type: "integer",
            description: "Max helpers to return. Default: 50."
          }
        }
      )

      guide_row(
        order: 20,
        mcp: "rails_get_helper_methods",
        summary: "App + framework helpers with view cross-references"
      )

      annotations(read_only_hint: true, destructive_hint: false, idempotent_hint: true, open_world_hint: false)

      def self.call(helper: nil, detail: "standard", offset: 0, limit: nil, server_context: nil)
        blank = blank_name_response("helper", helper)
        return blank if blank

        root = rails_app.root.to_s
        helper_dirs = PathResolver.dirs_for(root, "app/helpers")
        max_size = RailsAiContext.configuration.max_file_size

        if helper_dirs.empty?
          # "not found" invites an agent to add helpers to an app that chose
          # not to have any.
          note = api_only_note("app/helpers")
          return text_response(note) if note

          return text_response("No helpers directory found. Searched app/helpers/, packs/*/app/helpers/ and engines/*/app/helpers/.")
        end

        real_root = File.realpath(root).to_s
        real_helper_dirs = helper_dirs.map { |d| File.realpath(d).to_s }
        helper_files = helper_dirs.flat_map { |d| safe_glob(d, "**/*.rb", real_root) }.uniq.sort

        if helper_files.empty?
          return text_response("No helper files found in app/helpers/, packs/*/app/helpers/ or engines/*/app/helpers/.")
        end

        # Specific helper - full detail
        if helper
          return show_helper(helper, helper_files, real_helper_dirs, real_root, max_size, detail)
        end

        # List all helpers
        list_helpers(helper_files, real_helper_dirs, real_root, detail, offset: offset, limit: limit)
      end

      # A helper lives under app/helpers, a pack, an in-repo engine or a
      # configured extra path; only its path under whichever one holds it
      # carries the namespace.
      private_class_method def self.relative_under(file_path, helper_dirs)
        dir = helper_dirs.find { |d| file_path.start_with?("#{d}#{File::SEPARATOR}") }
        dir ? file_path.delete_prefix("#{dir}#{File::SEPARATOR}") : File.basename(file_path)
      end

      # Module name from the path under app/helpers, so nested helpers keep
      # their namespace (admin/dashboard_helper.rb => Admin::DashboardHelper).
      # app/helpers/concerns is its own autoload root (railties globs
      # "{*,*/concerns}"), so concerns/formattable.rb defines Formattable,
      # not Concerns::Formattable.
      # The constant the file declares wins over the path, as in a plugin's namespaced helper.rb.
      private_class_method def self.module_name_for(file_path, helper_dirs)
        path_name = relative_under(file_path, helper_dirs).delete_prefix("concerns/").delete_suffix(".rb").camelize
        Introspectors::DeclaredConstant.named(RailsAiContext::SafeFile.read(file_path), path_name)
      end

      private_class_method def self.show_helper(name, helper_files, helper_dirs, root, max_size, detail)
        # Find by module name (with or without namespace) or file name.
        # Exact relative-path matches win before basename fallbacks so a
        # top-level DashboardHelper isn't shadowed by admin/dashboard_helper.
        # The app's acronyms decide the path, and this process has none of
        # them, so paths are compared the way DeclaredConstant compares them.
        underscore = name.underscore.delete_suffix("_helper")
        names = [ name, "#{underscore}_helper" ]
        on_path = ->(path) { names.any? { |n| Introspectors::DeclaredConstant.path_for?(path, n) } }
        matches = helper_files.select { |f| module_name_for(f, helper_dirs).casecmp?(name) }
        matches = helper_files.select { |f| on_path.call(relative_under(f, helper_dirs).delete_suffix(".rb")) } if matches.empty?
        if matches.empty?
          names << underscore
          matches = helper_files.select { |f| on_path.call(File.basename(f, ".rb")) }
        end
        file_path = matches.first

        unless file_path
          available = helper_files.map { |f| module_name_for(f, helper_dirs) }.uniq
          return not_found_response("Helper", name, available,
            recovery_tool: "Call rails_get_helper_methods() to see all helpers")
        end

        if File.size(file_path) > max_size
          return text_response("Helper file too large: #{file_path} (#{File.size(file_path)} bytes, max: #{max_size})")
        end

        source = RailsAiContext::SafeFile.read(file_path)
        return text_response("Could not read helper file: #{file_path}") unless source
        relative_path = file_path.sub("#{root}/", "")
        module_name = module_name_for(file_path, helper_dirs)

        lines = [ "# #{module_name}", "" ]
        lines << "**File:** `#{relative_path}` (#{count_phrase(source.lines.size, "line")})"

        # Two roots can hold the same relative path, so one module name can have
        # more than one file behind it. Everything below is this file only.
        # A basename selector also matches same-named helpers in other
        # namespaces; those declare a different module, so they are named
        # apart rather than counted as this one.
        same_module, other_modules = matches.partition { |f| module_name_for(f, helper_dirs) == module_name }
        if same_module.size > 1
          others = same_module.drop(1).map { |f| "`#{f.sub("#{root}/", "")}`" }
          lines << "**Also defined in:** #{others.join(', ')}"
        end
        if other_modules.any?
          named = other_modules.map { |f| "`#{module_name_for(f, helper_dirs)}` (`#{f.sub("#{root}/", "")}`)" }
          lines << "**Same file name, different module:** #{named.join(', ')}"
        end

        # Parse method signatures
        methods = view_callable(source)
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
        if RailsAiContext::DetailLevel.full?(detail)
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

      private_class_method def self.list_helpers(helper_files, helper_dirs, root, detail, offset: 0, limit: nil)
        helpers_data = helper_files.filter_map do |file_path|
          relative = file_path.sub("#{root}/", "")
          module_name = module_name_for(file_path, helper_dirs)

          source = RailsAiContext::SafeFile.read(file_path)
          methods = source ? view_callable(source) : []

          {
            name: module_name,
            path: relative,
            methods: methods,
            method_count: methods.size
          }
        end

        sorted = helpers_data.sort_by { |h| -h[:method_count] }
        page = paginate(sorted, offset: offset, limit: limit, default_limit: 50)
        declared = controller_helper_methods(root)

        lines = [ "# Helpers (#{helpers_data.size})", "" ]

        case detail
        when "summary"
          page[:items].each do |h|
            lines << "- **#{h[:name]}** - #{count_phrase(h[:method_count], "method")}"
          end
          lines << "- **helper_method in controllers** - #{count_phrase(declared.size, "method")}" if declared.any?
          lines << "" << "_Use `helper:\"Name\"` for method signatures._"

        when "standard"
          page[:items].each do |h|
            lines << "## #{h[:name]} (`#{h[:path]}`)"
            if h[:methods].any?
              h[:methods].each { |m| lines << "- `#{m}`" }
            else
              lines << "- _(no public methods)_"
            end
            lines << ""
          end
          append_declared(lines, declared)

        when "full"
          # Include framework helpers detection
          framework = detect_framework_helpers(root)

          page[:items].each do |h|
            lines << "## #{h[:name]} (`#{h[:path]}`)"
            if h[:methods].any?
              h[:methods].each { |m| lines << "- `#{m}`" }
            else
              lines << "- _(no public methods)_"
            end
            lines << ""
          end
          append_declared(lines, declared)

          if framework.any?
            lines << "## Framework Helpers Detected"
            framework.each do |lib, methods|
              lines << "- **#{lib}:** #{methods.join(', ')}"
            end
            lines << ""
          end

          lines << "_Use `helper:\"Name\"` with `detail:\"full\"` for view cross-references._"

        end

        lines << "" << page[:hint] unless page[:hint].empty?
        text_response(lines.join("\n"))
      end

      private_class_method def self.append_declared(lines, declared)
        return if declared.empty?

        lines << "## Declared in controllers with helper_method (#{declared.size})"
        declared.each { |d| lines << "- `#{d[:name]}` (#{d[:owner]}, `#{d[:path]}`)" }
        lines << ""
      end

      # A module_function method's instance copy is private, but a view calls it like any helper.
      private_class_method def self.view_callable(source)
        Introspectors::ActionResolver.own_methods_in(source, nil)
          .select { |m| m[:scope] == :instance && (m[:visibility] == :public || m[:module_function]) && !m[:name].start_with?("_") }
          .map { |m| Introspectors::ActionResolver.signature(m) }.uniq
      end

      # What `helper_method` in a controller, or in a lib module a controller includes, hands
      # the views that controller renders. Only a file that names the macro is walked, once.
      private_class_method def self.controller_helper_methods(real_root)
        controllers = PathResolver.dirs_for(real_root, "app/controllers").flat_map do |dir|
          real_dir = File.realpath(dir).to_s
          safe_glob(dir, "**/*.rb", real_root).sort.map do |path|
            relative = path.delete_prefix("#{real_dir}/").delete_prefix("concerns/").delete_suffix(".rb")
            [ path, relative.camelize, nil ]
          end
        end
        lib = LibModules.new(real_root)
        declared = controllers.flat_map { |entry| declared_helpers(real_root, entry, lib) }
        declared + lib.found.flat_map { |entry| declared_helpers(real_root, entry, nil) }
      rescue => e
        RailsAiContext.debug_fail(e, [], label: "controller_helper_methods")
      end

      # The helper_method names one file declares; with `lib`, also notes the lib modules it includes.
      # A module kept in its outer constant's file comes with its node's range, and only calls inside it count.
      private_class_method def self.declared_helpers(real_root, (path, name, range), lib)
        source = RailsAiContext::SafeFile.read(path) or return []
        listeners = {}
        listeners[:calls] = -> { Introspectors::Listeners::GenericMacroListener.new(:helper_method, any_receiver: true) } if source.include?("helper_method")
        listeners[:mixins] = Introspectors::Listeners::MixinsListener if lib&.may_include?(source)
        return [] if listeners.empty?

        result = Introspectors::SourceIntrospector.walk(path, listeners)
        lib&.note(result[:mixins])
        calls = Array(result[:calls])
        calls = calls.select { |call| call[:offset] && range.cover?(call[:offset]) } if range
        names = calls.flat_map do |call|
          Array(call[:args]).map(&:to_s) + Array(call[:values]).grep(String).filter_map { |v| v[/\Adef\s+([\w?!]+)/, 1] }
        end.uniq
        owner = range ? name : Introspectors::DeclaredConstant.named(source, name)
        names.map { |helper| { name: helper, owner: owner, path: path.delete_prefix("#{real_root}/") } }
      end

      # The modules in lib the controllers include, as [path, constant, range]: a controller
      # helper module there is required rather than autoloaded, and app/controllers/concerns
      # is read as a controller already.
      # ponytail: one level, lib only; a module those modules include is not followed.
      class LibModules
        attr_reader :found

        def initialize(real_root)
          @real_root = real_root
          @dirs = PathResolver.dirs_for(real_root, "lib")
          @basenames = @dirs.flat_map { |dir| Dir.glob("**/*.rb", base: dir) }.to_set { |file| File.basename(file, ".rb") }
          @lookups = {}
          @found = []
        end

        # Whether a written include names a constant some lib file could hold, as its own file or its outer one's.
        def may_include?(source)
          return false if @basenames.empty?

          source.scan(/\b(?:include|prepend)\s+:*([A-Z][\w:]*)/).flatten.any? do |written|
            written.split("::").any? { |segment| @basenames.include?(segment.underscore) }
          end
        end

        def note(mixins)
          Array(mixins).each do |mixin|
            next unless %i[include prepend].include?(mixin[:macro])

            within = Array(mixin[:owner]).join("::")
            # Controllers share most candidates, so each is looked up once.
            hit = ConcernPaths.candidate_names(mixin[:name], within.empty? ? nil : within).lazy.filter_map do |candidate|
              @lookups.fetch(candidate) { @lookups[candidate] = lookup(candidate) || false }
            end.first
            @found << hit if hit && !@found.include?(hit)
          end
        end

        private

        def lookup(constant)
          own = path_for(constant)
          return [ own, constant, nil ] if own

          outer = constant.rpartition("::").first
          path = !outer.empty? && path_for(outer)
          node = path && Introspectors::DeclaredConstant.module_node(AstCache.parse(path).value, constant)
          node && [ path, constant, node.location.start_offset...node.location.end_offset ]
        end

        def path_for(constant)
          relative = "#{constant.underscore}.rb"
          dir = @dirs.find { |d| File.file?(File.join(d, relative)) }
          path = dir && File.realpath(File.join(dir, relative))
          path if path && RailsAiContext::SafePath.contained?(path, @real_root)
        end
      end
      private_constant :LibModules

      private_class_method def self.find_view_references(method_names, real_root)
        references = {}
        view_files = markup_views(real_root)

        method_names.each do |method_name|
          matching_views = []

          view_files.each do |real, relative|
            content = RailsAiContext::SafeFile.read(real) or next

            matching_views << relative if content.include?(method_name)
          end

          references[method_name] = matching_views if matching_views.any?
        end

        references
      rescue => e
        RailsAiContext.debug_fail(e, {}, label: "find_view_references")
      end

      # Every markup view across the app's views roots, as [realpath, name it renders by].
      private_class_method def self.markup_views(real_root)
        dirs = PathResolver.view_dirs(real_root)
        real_dirs = Hash.new { |cache, dir| cache[dir] = File.realpath(dir) }
        RailsAiContext::ViewFile.each(real_root, RailsAiContext::ViewFile::MARKUP_GLOB).filter_map do |path, relative|
          real = safe_glob_realpath(path, real_dirs[RailsAiContext::ViewFile.root_for(path, dirs)], real_root)
          [ real, relative ] if real
        end
      end

      private_class_method def self.detect_framework_helpers(real_root)
        detected = {}

        declared = RailsAiContext::Introspectors::GemfileGems.names(real_root)
        return detected if declared.empty?

        # Collect all view file content for scanning
        scan_content = ""

        files = markup_views(real_root).map(&:first) +
                PathResolver.dirs_for(real_root, "app/helpers").flat_map { |d| safe_glob(d, "**/*.rb", real_root) }
        files.each { |real| scan_content += (RailsAiContext::SafeFile.read(real) || "") }

        FRAMEWORK_HELPERS.each do |lib, methods|
          gem_name = FRAMEWORK_GEMS.fetch(lib) { lib.downcase }
          next unless declared.include?(gem_name)

          # Find which framework methods are actually used
          used = methods.select { |m| scan_content.include?(m) }
          detected[lib] = used if used.any?
        end

        detected
      rescue => e
        RailsAiContext.debug_fail(e, {}, label: "detect_framework_helpers")
      end
    end
  end
end
