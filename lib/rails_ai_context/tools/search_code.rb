# frozen_string_literal: true

module RailsAiContext
  module Tools
    class SearchCode < BaseTool
      tool_name "rails_search_code"
      description "Search the Rails codebase for a pattern using ripgrep (rg) or Ruby fallback. Returns matching lines with file paths and line numbers. Useful for finding usages, implementations, and patterns."

      input_schema(
        properties: {
          pattern: {
            type: "string",
            description: "Search pattern (regex supported)."
          },
          path: {
            type: "string",
            description: "Subdirectory to search in (e.g. 'app/models', 'config'). Default: entire app."
          },
          file_type: {
            type: "string",
            description: "Filter by file extension (e.g. 'rb', 'js', 'erb'). Default: all files."
          },
          max_results: {
            type: "integer",
            description: "Maximum number of results. Default: 30."
          }
        },
        required: [ "pattern" ]
      )

      annotations(read_only_hint: true, destructive_hint: false, idempotent_hint: true, open_world_hint: false)

      def self.call(pattern:, path: nil, file_type: nil, max_results: 30, server_context: nil)
        root = Rails.root.to_s
        search_path = path ? File.join(root, path) : root

        unless Dir.exist?(search_path)
          return text_response("Path not found: #{path}")
        end

        results = if ripgrep_available?
                    search_with_ripgrep(pattern, search_path, file_type, max_results, root)
        else
                    search_with_ruby(pattern, search_path, file_type, max_results, root)
        end

        if results.empty?
          return text_response("No results found for '#{pattern}' in #{path || 'app'}.")
        end

        output = results.map { |r| "#{r[:file]}:#{r[:line_number]}: #{r[:content].strip}" }.join("\n")
        header = "# Search: `#{pattern}`\n**#{results.size} results**#{" in #{path}" if path}\n\n```\n"
        footer = "\n```"

        text_response("#{header}#{output}#{footer}")
      end

      private_class_method def self.ripgrep_available?
        @rg_available ||= system("which rg > /dev/null 2>&1")
      end

      private_class_method def self.search_with_ripgrep(pattern, search_path, file_type, max_results, root)
        excluded = RailsAiContext.configuration.excluded_paths.map { |p| "--glob=!#{p}" }.join(" ")
        type_flag = file_type ? "--type-add 'custom:*.#{file_type}' --type custom" : ""

        cmd = "rg --no-heading --line-number --max-count #{max_results} #{excluded} #{type_flag} #{Shellwords.escape(pattern)} #{Shellwords.escape(search_path)} 2>/dev/null"

        output = `#{cmd}`
        parse_rg_output(output, root)
      rescue => e
        [ { file: "error", line_number: 0, content: e.message } ]
      end

      private_class_method def self.search_with_ruby(pattern, search_path, file_type, max_results, root)
        results = []
        regex = Regexp.new(pattern, Regexp::IGNORECASE)
        glob = file_type ? "**/*.#{file_type}" : "**/*.{rb,js,erb,yml,yaml,json}"
        excluded = RailsAiContext.configuration.excluded_paths

        Dir.glob(File.join(search_path, glob)).each do |file|
          relative = file.sub("#{root}/", "")
          next if excluded.any? { |ex| relative.start_with?(ex) }

          File.readlines(file).each_with_index do |line, idx|
            if line.match?(regex)
              results << { file: relative, line_number: idx + 1, content: line }
              return results if results.size >= max_results
            end
          end
        rescue => _e
          next # Skip binary/unreadable files
        end

        results
      end

      private_class_method def self.parse_rg_output(output, root)
        output.lines.filter_map do |line|
          match = line.match(/^(.+?):(\d+):(.*)$/)
          next unless match

          {
            file: match[1].sub("#{root}/", ""),
            line_number: match[2].to_i,
            content: match[3]
          }
        end
      end
    end
  end
end
