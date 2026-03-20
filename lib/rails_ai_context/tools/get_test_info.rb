# frozen_string_literal: true

module RailsAiContext
  module Tools
    class GetTestInfo < BaseTool
      tool_name "rails_get_test_info"
      description "Get test infrastructure: framework, factories/fixtures with names, CI config, coverage, test file counts, and helper setup. Filter by model or controller to see existing tests."

      input_schema(
        properties: {
          model: {
            type: "string",
            description: "Show existing tests for a specific model (e.g. 'User'). Looks for model spec/test file."
          },
          controller: {
            type: "string",
            description: "Show existing tests for a specific controller (e.g. 'Cooks'). Looks for controller/request spec/test file."
          },
          detail: {
            type: "string",
            enum: %w[summary standard full],
            description: "Detail level. summary: framework + counts. standard: framework + fixtures + CI (default). full: everything including fixture names, factory names, helper setup."
          }
        }
      )

      annotations(read_only_hint: true, destructive_hint: false, idempotent_hint: true, open_world_hint: false)

      def self.call(model: nil, controller: nil, detail: "standard", server_context: nil)
        data = cached_context[:tests]
        return text_response("Test introspection not available. Add :tests to introspectors.") unless data
        return text_response("Test introspection failed: #{data[:error]}") if data[:error]

        # Specific model tests
        if model
          return text_response(find_test_file(model, :model))
        end

        # Specific controller tests
        if controller
          return text_response(find_test_file(controller, :controller))
        end

        case detail
        when "summary"
          lines = [ "# Test Infrastructure", "" ]
          lines << "- **Framework:** #{data[:framework]}"
          lines << "- **Factories:** #{data[:factories][:count]} files" if data[:factories]
          lines << "- **Fixtures:** #{data[:fixtures][:count]} files" if data[:fixtures]
          if data[:test_files]&.any?
            total = data[:test_files].values.sum { |v| v[:count] }
            lines << "- **Test files:** #{total} across #{data[:test_files].size} categories"
          end
          lines << "- **CI:** #{data[:ci_config].join(', ')}" if data[:ci_config]&.any?
          text_response(lines.join("\n"))

        when "standard"
          lines = [ "# Test Infrastructure", "" ]
          lines << "- **Framework:** #{data[:framework]}"
          lines << "- **Factories:** #{data[:factories][:location]} (#{data[:factories][:count]} files)" if data[:factories]
          lines << "- **Fixtures:** #{data[:fixtures][:location]} (#{data[:fixtures][:count]} files)" if data[:fixtures]
          lines << "- **System tests:** #{data[:system_tests][:location]}" if data[:system_tests]
          lines << "- **CI:** #{data[:ci_config].join(', ')}" if data[:ci_config]&.any?
          lines << "- **Coverage:** #{data[:coverage]}" if data[:coverage]

          if data[:test_files]&.any?
            lines << "" << "## Test Files"
            data[:test_files].each do |cat, info|
              lines << "- #{cat}: #{info[:count]} files (#{info[:location]})"
            end
          end

          if data[:test_helpers]&.any?
            lines << "" << "## Test Helpers"
            data[:test_helpers].each { |h| lines << "- `#{h}`" }
          end
          text_response(lines.join("\n"))

        when "full"
          lines = [ "# Test Infrastructure (Full Detail)", "" ]
          lines << "- **Framework:** #{data[:framework]}"
          lines << "- **CI:** #{data[:ci_config].join(', ')}" if data[:ci_config]&.any?
          lines << "- **Coverage:** #{data[:coverage]}" if data[:coverage]

          if data[:fixture_names]&.any?
            lines << "" << "## Fixtures"
            data[:fixture_names].each do |file, names|
              lines << "- **#{file}:** #{names.join(', ')}"
            end
          end

          if data[:factory_names]&.any?
            lines << "" << "## Factories"
            data[:factory_names].each do |file, names|
              lines << "- **#{file}:** #{names.join(', ')}"
            end
          end

          if data[:test_helper_setup]&.any?
            lines << "" << "## Test Helper Setup"
            data[:test_helper_setup].each { |m| lines << "- `#{m}`" }
          end

          if data[:test_files]&.any?
            lines << "" << "## Test Files"
            data[:test_files].each do |cat, info|
              lines << "- #{cat}: #{info[:count]} files (#{info[:location]})"
            end
          end

          if data[:test_helpers]&.any?
            lines << "" << "## Test Helper Files"
            data[:test_helpers].each { |h| lines << "- `#{h}`" }
          end
          text_response(lines.join("\n"))

        else
          text_response("Unknown detail level: #{detail}. Use summary, standard, or full.")
        end
      end

      MAX_TEST_FILE_SIZE = 500_000 # 500KB safety limit

      private_class_method def self.find_test_file(name, type)
        snake = name.to_s.underscore.sub(/_controller$/, "")
        candidates = case type
        when :model
          [
            "spec/models/#{snake}_spec.rb",
            "test/models/#{snake}_test.rb"
          ]
        when :controller
          [
            "spec/controllers/#{snake}_controller_spec.rb",
            "spec/requests/#{snake}_spec.rb",
            "test/controllers/#{snake}_controller_test.rb"
          ]
        end

        candidates.each do |rel|
          path = Rails.root.join(rel)
          next unless File.exist?(path)
          # Path traversal protection
          begin
            real_path = File.realpath(path)
            real_root = File.realpath(Rails.root)
            next unless real_path.start_with?(real_root)
          rescue Errno::ENOENT
            next
          end
          next if File.size(path) > MAX_TEST_FILE_SIZE
          content = File.read(path)
          return "# #{rel}\n\n```ruby\n#{content}\n```"
        end

        "No test file found for #{name}. Searched: #{candidates.join(', ')}"
      end
    end
  end
end
