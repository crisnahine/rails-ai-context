# frozen_string_literal: true

require "open3"

module RailsAiContext
  module Tools
    class SearchCode < BaseTool
      tool_name "rails_search_code"
      description "Search the Rails codebase for a pattern using ripgrep (rg) or Ruby fallback. Returns matching lines with file paths and line numbers. Useful for finding usages, implementations, and patterns."

      MAX_RESULTS_CAP = 100

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
            description: "Maximum number of results. Default: 30, max: 100."
          }
        },
        required: [ "pattern" ]
      )

      annotations(read_only_hint: true, destructive_hint: false, idempotent_hint: true, open_world_hint: false)

      def self.call(pattern:, path: nil, file_type: nil, max_results: 30, server_context: nil)
        root = Rails.root.to_s

        # Validate file_type to prevent injection
        if file_type && !file_type.match?(/\A[a-zA-Z0-9]+\z/)
          return text_response("Invalid file_type: must contain only alphanumeric characters.")
        end

        # Cap max_results
        max_results = [ max_results.to_i, MAX_RESULTS_CAP ].min
        max_results = 30 if max_results < 1

        search_path = path ? File.join(root, path) : root

        # Path traversal protection
        unless Dir.exist?(search_path)
          return text_response("Path not found: #{path}")
        end

        begin
          real_search = File.realpath(search_path)
          real_root = File.realpath(root)
          unless real_search.start_with?(real_root)
            return text_response("Path not allowed: #{path}")
          end
        rescue Errno::ENOENT
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
        cmd = [ "rg", "--no-heading", "--line-number", "--max-count", max_results.to_s ]

        RailsAiContext.configuration.excluded_paths.each do |p|
          cmd << "--glob=!#{p}"
        end

        if file_type
          cmd.push("--type-add", "custom:*.#{file_type}", "--type", "custom")
        end

        cmd << "--" # Prevent pattern from being parsed as flags
        cmd << pattern
        cmd << search_path

        output, _status = Open3.capture2(*cmd, err: File::NULL)
        parse_rg_output(output, root).first(max_results)
      rescue => e
        [ { file: "error", line_number: 0, content: e.message } ]
      end

      private_class_method def self.search_with_ruby(pattern, search_path, file_type, max_results, root)
        results = []
        begin
          regex = Regexp.new(pattern, Regexp::IGNORECASE, timeout: 2)
        rescue RegexpError => e
          return [ { file: "error", line_number: 0, content: "Invalid regex: #{e.message}" } ]
        end
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
