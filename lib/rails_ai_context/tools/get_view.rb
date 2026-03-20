# frozen_string_literal: true

module RailsAiContext
  module Tools
    class GetView < BaseTool
      tool_name "rails_get_view"
      description "Get view template contents, partials, and Stimulus controller references. Filter by controller or specific path. Saves tokens vs reading raw ERB files."

      input_schema(
        properties: {
          controller: {
            type: "string",
            description: "Filter views by controller name (e.g. 'cooks', 'brand_profiles'). Lists all templates for that controller."
          },
          path: {
            type: "string",
            description: "Specific view path relative to app/views (e.g. 'cooks/index.html.erb'). Returns full content."
          },
          detail: {
            type: "string",
            enum: %w[summary standard full],
            description: "Detail level. summary: file list with line counts. standard: file list with partials/stimulus refs (default). full: template content."
          }
        }
      )

      annotations(read_only_hint: true, destructive_hint: false, idempotent_hint: true, open_world_hint: false)

      def self.call(controller: nil, path: nil, detail: "standard", server_context: nil)
        data = cached_context[:view_templates]

        # Fall back to reading from disk if introspector not in preset
        if data.nil? || data[:error]
          return read_from_disk(controller: controller, path: path, detail: detail)
        end

        templates = data[:templates] || {}
        partials = data[:partials] || {}

        # Specific path — return file content
        if path
          return read_view_file(path)
        end

        # Filter by controller
        if controller
          filtered = templates.select { |k, _| k.downcase.start_with?(controller.downcase + "/") }
          return text_response("No views for '#{controller}'. Controllers with views: #{templates.keys.map { |k| k.split('/').first }.uniq.sort.join(', ')}") if filtered.empty?
          templates = filtered
        end

        case detail
        when "summary"
          lines = [ "# Views (#{templates.size} templates, #{partials.size} partials)", "" ]
          templates.keys.map { |k| k.split("/").first }.uniq.sort.each do |ctrl|
            ctrl_templates = templates.select { |k, _| k.start_with?("#{ctrl}/") }
            lines << "## #{ctrl}/ (#{ctrl_templates.size} files)"
            ctrl_templates.sort.each do |name, meta|
              lines << "- #{File.basename(name)} — #{meta[:lines]} lines"
            end
            lines << ""
          end
          text_response(lines.join("\n"))

        when "standard"
          all_partials = data[:partials] || {}
          lines = [ "# Views (#{templates.size} templates, #{all_partials.size} partials)", "" ]
          templates.keys.map { |k| k.split("/").first }.uniq.sort.each do |ctrl|
            ctrl_templates = templates.select { |k, _| k.start_with?("#{ctrl}/") }
            lines << "## #{ctrl}/"
            ctrl_templates.sort.each do |name, meta|
              parts = meta[:partials]&.any? ? " renders: #{meta[:partials].join(', ')}" : ""
              stim = meta[:stimulus]&.any? ? " stimulus: #{meta[:stimulus].join(', ')}" : ""
              lines << "- #{File.basename(name)} (#{meta[:lines]} lines)#{parts}#{stim}"
            end
            # Show partials for this controller with field/helper info
            ctrl_partials = all_partials.select { |k, _| k.start_with?("#{ctrl}/") }
            ctrl_partials.sort.each do |name, meta|
              fields = meta[:fields]&.any? ? " fields: #{meta[:fields].join(', ')}" : ""
              helpers = meta[:helpers]&.any? ? " helpers: #{meta[:helpers].join(', ')}" : ""
              lines << "- #{File.basename(name)} (#{meta[:lines]} lines)#{fields}#{helpers}"
            end
            lines << ""
          end
          # Show shared partials
          shared = all_partials.select { |k, _| k.start_with?("shared/") }
          if shared.any?
            lines << "## shared/"
            shared.sort.each do |name, meta|
              lines << "- #{File.basename(name)} (#{meta[:lines]} lines)"
            end
            lines << ""
          end
          text_response(lines.join("\n"))

        when "full"
          if controller
            lines = [ "# Views: #{controller}/", "" ]
            templates.sort.each do |name, _meta|
              content = read_view_content(name)
              lines << "## #{name}" << "```erb" << content << "```" << ""
            end
            text_response(lines.join("\n"))
          else
            text_response("Use `controller:\"name\"` with `detail:\"full\"` to get template content, or `path:\"cooks/index.html.erb\"` for a specific file.")
          end
        else
          text_response("Unknown detail level: #{detail}. Use summary, standard, or full.")
        end
      end

      MAX_FILE_SIZE = 2_000_000 # 2MB safety limit

      private_class_method def self.read_view_file(path)
        views_dir = Rails.root.join("app", "views")
        full_path = views_dir.join(path)

        # Path traversal protection (resolves symlinks)
        unless File.exist?(full_path)
          return text_response("View not found: #{path}")
        end
        begin
          unless File.realpath(full_path).start_with?(File.realpath(views_dir))
            return text_response("Path not allowed: #{path}")
          end
        rescue Errno::ENOENT
          return text_response("View not found: #{path}")
        end
        if File.size(full_path) > MAX_FILE_SIZE
          return text_response("File too large: #{path} (#{File.size(full_path)} bytes)")
        end

        content = File.read(full_path)
        text_response("# #{path}\n\n```erb\n#{content}\n```")
      end

      private_class_method def self.read_view_content(relative_path)
        full_path = Rails.root.join("app", "views", relative_path)
        File.exist?(full_path) ? File.read(full_path) : "(file not found)"
      rescue
        "(error reading file)"
      end

      private_class_method def self.read_from_disk(controller:, path:, detail:)
        views_dir = Rails.root.join("app", "views")
        return text_response("No app/views directory found.") unless Dir.exist?(views_dir)

        if path
          return read_view_file(path)
        end

        # List views from disk
        templates = Dir.glob(File.join(views_dir, "**", "*"))
          .reject { |f| File.directory?(f) || File.basename(f).start_with?("_") || f.include?("/layouts/") }
          .map { |f| f.sub("#{views_dir}/", "") }
          .sort

        if controller
          templates = templates.select { |t| t.downcase.start_with?(controller.downcase + "/") }
        end

        lines = [ "# Views (#{templates.size} templates)", "" ]
        templates.each { |t| lines << "- #{t}" }
        text_response(lines.join("\n"))
      end
    end
  end
end
