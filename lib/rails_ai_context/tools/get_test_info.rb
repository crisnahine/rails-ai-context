# frozen_string_literal: true

module RailsAiContext
  module Tools
    class GetTestInfo < BaseTool
      tool_name "rails_get_test_info"
      description "Get test infrastructure and existing test files: framework, factories, fixtures, CI config, coverage setup. " \
        "Use when: writing new tests, checking what factories/fixtures exist, or finding the test file for a model/controller. " \
        "Use model:\"User\" or controller:\"Cooks\" to see existing tests. detail:\"full\" lists factory and fixture names."

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
          return text_response(find_test_file(model, :model, detail))
        end

        # Specific controller tests
        if controller
          return text_response(find_test_file(controller, :controller, detail))
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

          if data[:test_count_by_category].is_a?(Hash) && data[:test_count_by_category].any?
            lines << "" << "## Test Counts by Category"
            data[:test_count_by_category].each do |cat, count|
              lines << "- #{cat}: #{count}"
            end
          end

          if data[:test_files]&.any?
            lines << "" << "## Test Files"
            data[:test_files].each do |cat, info|
              lines << "- #{cat}: #{info[:count]} files (#{info[:location]})"
            end
          end

          if data[:factory_traits]&.any?
            lines << "" << "## Factory Traits"
            data[:factory_traits].first(15).each do |trait|
              lines << "- #{trait}"
            end
          end

          if data[:test_helpers]&.any?
            lines << "" << "## Test Helpers"
            data[:test_helpers].each { |h| lines << "- `#{h}`" }
          end

          # Generate a test template based on app patterns
          template = generate_test_template(data)
          lines.concat(template) if template.any?

          text_response(lines.join("\n"))

        when "full"
          lines = [ "# Test Infrastructure (Full Detail)", "" ]
          lines << "- **Framework:** #{data[:framework]}"
          lines << "- **CI:** #{data[:ci_config].join(', ')}" if data[:ci_config]&.any?
          lines << "- **Coverage:** #{data[:coverage]}" if data[:coverage]

          if data[:test_count_by_category].is_a?(Hash) && data[:test_count_by_category].any?
            lines << "" << "## Test Counts by Category"
            data[:test_count_by_category].each do |cat, count|
              lines << "- #{cat}: #{count}"
            end
          end

          if data[:factory_traits]&.any?
            lines << "" << "## Factory Traits"
            data[:factory_traits].first(20).each do |trait|
              lines << "- #{trait}"
            end
          end

          if data[:fixture_names]&.any?
            lines << "" << "## Fixtures"
            parsed_fixtures = parse_all_fixture_contents
            if parsed_fixtures.any?
              parsed_fixtures.each do |file, entries|
                lines << "- **#{file}:**"
                entries.each do |entry_name, attrs|
                  attr_str = attrs.map { |k, v| "#{k}: #{v}" }.join(", ")
                  lines << "  - `#{entry_name}`: #{attr_str}"
                end
              end

              # Fixture relationships section
              relationships = extract_fixture_relationships(parsed_fixtures)
              if relationships.any?
                lines << "" << "## Fixture Relationships"
                relationships.each do |parent, children|
                  lines << "- **#{parent}** ← #{children.join(', ')}"
                end
              end
            else
              # Fallback to simple names if parsing fails
              data[:fixture_names].each do |file, names|
                lines << "- **#{file}:** #{names.join(', ')}"
              end
            end
          end

          if data[:factory_names]&.any?
            lines << "" << "## Factories"
            data[:factory_names].each do |file, names|
              detail_str = parse_factory_details(file)
              if detail_str
                lines << detail_str
              else
                lines << "- **#{file}:** #{names.join(', ')}"
              end
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

      def self.max_test_file_size
        RailsAiContext.configuration.max_test_file_size
      end

      private_class_method def self.find_test_file(name, type, detail = "full")
        # Normalize: accept "Bonus::CrisesController", "bonus/crises", "Crises", "cooks" (plural)
        snake = name.to_s.tr("/", "::").underscore.sub(/_controller$/, "")
        # For models, also try singular form (cooks → cook)
        snake_singular = snake.singularize
        candidates = case type
        when :model
          base = [
            "spec/models/#{snake}_spec.rb",
            "test/models/#{snake}_test.rb",
            "spec/models/concerns/#{snake}_spec.rb",
            "test/models/concerns/#{snake}_test.rb"
          ]
          if snake != snake_singular
            base += [
              "spec/models/#{snake_singular}_spec.rb",
              "test/models/#{snake_singular}_test.rb",
              "spec/models/concerns/#{snake_singular}_spec.rb",
              "test/models/concerns/#{snake_singular}_test.rb"
            ]
          end
          base
        when :controller
          [
            "spec/controllers/#{snake}_controller_spec.rb",
            "spec/requests/#{snake}_spec.rb",
            "test/controllers/#{snake}_controller_test.rb",
            # Also try without namespace prefix for flat test dirs
            "spec/requests/#{snake.split('/').last}_spec.rb"
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
          next if File.size(path) > max_test_file_size
          content = File.read(path)

          # Summary/standard: return just test names (saves 2000+ tokens vs full source)
          if detail == "summary" || detail == "standard"
            test_names = content.each_line.filter_map do |line|
              if line.match?(/^\s*(test|it|describe|context|specify)\s+["']/)
                "- #{line.strip}"
              elsif line.match?(/^\s*def\s+test_/)
                "- #{line.strip}"
              end
            end
            return "# #{rel} (#{test_names.size} tests)\n\n#{test_names.join("\n")}"
          end

          return "# #{rel}\n\n```ruby\n#{content}\n```"
        end

        # List nearby test files to help the agent find the right one
        test_dirs = candidates.map { |c| File.dirname(Rails.root.join(c)) }.uniq
        nearby = test_dirs.flat_map do |dir|
          Dir.exist?(dir) ? Dir.glob(File.join(dir, "*")).map { |f| f.sub("#{Rails.root}/", "") }.first(10) : []
        end
        hint = nearby.any? ? "\n\nFiles in test directory: #{nearby.join(', ')}" : ""
        "No test file found for #{name}. Searched: #{candidates.join(', ')}#{hint}"
      end

      # Generate a test template based on the app's actual test patterns
      private_class_method def self.generate_test_template(data)
        lines = []
        framework = data[:framework]

        if framework&.include?("RSpec") || framework&.include?("rspec")
          lines << "" << "## Test Template (follow this pattern for new tests)"
          lines << "```ruby"
          lines << "require \"rails_helper\""
          lines << ""
          lines << "RSpec.describe ModelName, type: :model do"
          lines << "  describe \"validations\" do"
          lines << "    it { is_expected.to validate_presence_of(:field) }"
          lines << "  end"
          lines << ""
          lines << "  describe \"#method_name\" do"
          lines << "    it \"does something\" do"
          lines << "      record = create(:model_name)"
          lines << "      expect(record.method_name).to eq(expected)"
          lines << "    end"
          lines << "  end"
          lines << "end"
          lines << "```"
        else
          # Detect Devise + sign_in pattern from existing tests
          has_devise = false
          has_sign_in = false
          test_dir = Rails.root.join("test")
          if Dir.exist?(test_dir)
            Dir.glob(File.join(test_dir, "**/*_test.rb")).first(5).each do |path|
              content = File.read(path, encoding: "UTF-8") rescue next
              has_devise = true if content.include?("Devise::Test")
              has_sign_in = true if content.include?("sign_in")
            end
          end

          lines << "" << "## Test Template (follow this pattern for new tests)"
          lines << "```ruby"
          lines << "require \"test_helper\""
          lines << ""
          lines << "class ModelNameTest < ActiveSupport::TestCase"
          lines << "  test \"should be valid with required attributes\" do"
          lines << "    record = model_names(:fixture_name)"
          lines << "    assert record.valid?"
          lines << "  end"
          lines << ""
          lines << "  test \"should require field\" do"
          lines << "    record = ModelName.new"
          lines << "    assert_not record.valid?"
          lines << "    assert_includes record.errors[:field], \"can't be blank\""
          lines << "  end"
          lines << "end"
          lines << "```"

          if has_devise
            lines << ""
            lines << "```ruby"
            lines << "# Controller test pattern"
            lines << "require \"test_helper\""
            lines << ""
            lines << "class FeatureControllerTest < ActionDispatch::IntegrationTest"
            lines << "  include Devise::Test::IntegrationHelpers" if has_devise
            lines << ""
            lines << "  test \"requires authentication\" do"
            lines << "    get feature_path"
            lines << "    assert_response :redirect"
            lines << "  end"
            lines << ""
            lines << "  test \"shows page for signed in user\" do"
            lines << "    sign_in users(:chef_one)" if has_sign_in
            lines << "    get feature_path"
            lines << "    assert_response :success"
            lines << "  end"
            lines << "end"
            lines << "```"
          end
        end

        lines
      rescue => e
        $stderr.puts "[rails-ai-context] generate_test_template failed: #{e.message}" if ENV["DEBUG"]
        []
      end

      # Parse factory file to extract attributes and traits
      private_class_method def self.parse_factory_details(relative_path)
        # Try common factory locations
        candidates = [
          Rails.root.join("spec/factories/#{relative_path}"),
          Rails.root.join("test/factories/#{relative_path}"),
          Rails.root.join("spec/factories", relative_path),
          Rails.root.join("test/factories", relative_path)
        ]
        path = candidates.find { |p| File.exist?(p) }
        return nil unless path
        return nil if File.size(path) > max_test_file_size

        content = File.read(path, encoding: "UTF-8", invalid: :replace, undef: :replace)
        lines = []
        current_factory = nil

        content.each_line do |line|
          if (match = line.match(/\A\s*factory\s+:(\w+)/))
            current_factory = match[1]
            lines << "- **#{relative_path}** → `:#{current_factory}`"
          elsif current_factory && (match = line.match(/\A\s*trait\s+:(\w+)/))
            lines << "  - trait `:#{match[1]}`"
          elsif current_factory && line.match?(/\A\s+\w+\s*\{/)
            attr = line.strip.sub(/\s*\{.*/, "")
            lines << "  - `#{attr}`" unless attr.empty?
          end
        end

        lines.any? ? lines.join("\n") : nil
      rescue => e
        $stderr.puts "[rails-ai-context] parse_factory_details failed: #{e.message}" if ENV["DEBUG"]
        nil
      end

      # Parse a single fixture YAML file, returning a hash of entry_name => filtered attributes
      private_class_method def self.parse_fixture_contents(file_path)
        return {} unless File.exist?(file_path)
        return {} if File.size(file_path) > max_test_file_size

        require "yaml"
        content = File.read(file_path, encoding: "UTF-8", invalid: :replace, undef: :replace)
        # Handle ERB-templated fixtures: replace "<%=...%>" (with surrounding quotes) and bare <%...%>
        content = content.gsub(/"<%=.*?%>"/, '"erb_value"')
        content = content.gsub(/'<%=.*?%>'/, "'erb_value'")
        content = content.gsub(/<%.*?%>/, "erb_value")
        parsed = YAML.safe_load(content, permitted_classes: [ Date, Time, Symbol ]) rescue nil
        return {} unless parsed.is_a?(Hash)

        skip_keys = %w[created_at updated_at id]
        entries = {}

        parsed.each do |entry_name, attributes|
          next unless attributes.is_a?(Hash)
          filtered = {}
          attributes.each do |key, value|
            next if skip_keys.include?(key.to_s)
            str_value = value.to_s
            next if str_value.length > 100
            filtered[key] = value
          end
          entries[entry_name] = filtered if filtered.any?
        end

        entries
      rescue => e
        {}
      end

      # Parse all fixture files, returning { "fixture_file" => { entry => attrs } }
      private_class_method def self.parse_all_fixture_contents
        fixture_dirs = [
          Rails.root.join("test", "fixtures"),
          Rails.root.join("spec", "fixtures")
        ]

        results = {}
        fixture_dirs.each do |dir|
          next unless Dir.exist?(dir)
          Dir.glob(File.join(dir, "**", "*.yml")).sort.each do |path|
            rel_name = File.basename(path, ".yml")
            entries = parse_fixture_contents(path)
            results[rel_name] = entries if entries.any?
          end
        end

        results
      rescue => e
        {}
      end

      # Extract relationships: find foreign key references between fixtures
      # Returns { "parent_fixture (entry)" => ["child_fixture.entry", ...] }
      private_class_method def self.extract_fixture_relationships(parsed_fixtures)
        # Build a set of all fixture entry names by file for lookup
        entry_lookup = {}
        parsed_fixtures.each do |file, entries|
          entries.each_key { |name| entry_lookup[name] = file }
        end

        relationships = Hash.new { |h, k| h[k] = [] }

        parsed_fixtures.each do |file, entries|
          entries.each do |entry_name, attrs|
            attrs.each do |key, value|
              # Foreign key pattern: key ends with _id and value matches an entry, or
              # key matches a fixture file name and value is a fixture entry reference
              str_value = value.to_s
              if key.to_s.end_with?("_id") && entry_lookup[str_value]
                parent_file = entry_lookup[str_value]
                relationships["#{parent_file} (#{str_value})"] << "#{file}.#{entry_name}"
              elsif parsed_fixtures.key?(key.to_s) && parsed_fixtures[key.to_s].key?(str_value)
                # Rails fixture reference: e.g. user: chef_one where "user" is a fixture file
                relationships["#{key} (#{str_value})"] << "#{file}.#{entry_name}"
              elsif key.to_s =~ /\A(\w+)_id\z/
                # Foreign key with integer value — note the relationship type
                parent_table = $1.pluralize
                if parsed_fixtures.key?(parent_table)
                  relationships["#{parent_table} (id=#{str_value})"] << "#{file}.#{entry_name}"
                end
              end
            end
          end
        end

        relationships
      rescue => e
        {}
      end
    end
  end
end
