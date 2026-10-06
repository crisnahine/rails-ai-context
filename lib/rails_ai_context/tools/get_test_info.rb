# frozen_string_literal: true

module RailsAiContext
  module Tools
    class GetTestInfo < BaseTool
      tool_name "rails_get_test_info"
      description "Get test infrastructure and existing test files: framework, factories, fixtures, CI config, coverage setup. " \
        "Use when: writing new tests, checking what factories/fixtures exist, or finding the test file for a model/controller. " \
        "Use model:\"User\" or controller:\"Posts\" to see existing tests. detail:\"full\" lists factory and fixture names."

      input_schema(
        properties: {
          model: {
            type: "string",
            description: "Show existing tests for a specific model (e.g. 'User'). Looks for model spec/test file."
          },
          controller: {
            type: "string",
            description: "Show existing tests for a specific controller (e.g. 'Posts'). Looks for controller/request spec/test file."
          },
          detail: RailsAiContext::DetailLevel.schema("Detail level. summary: framework + counts. standard: framework + fixtures + CI (default). full: everything including fixture names, factory names, helper setup.")
        }
      )

      guide_row(
        order: 11,
        mcp: "rails_get_test_info(model:\"X\")",
        cli_args: "model=X",
        summary: "Tests + fixture contents + test template"
      )

      annotations(read_only_hint: true, destructive_hint: false, idempotent_hint: true, open_world_hint: false)

      # A candidate whose own resolution left the app root must not have its
      # directory globbed either, or the miss lists a tree outside the app.
      ESCAPING_REFUSALS = %i[traversal outside sensitive].freeze

      def self.call(model: nil, controller: nil, detail: "standard", server_context: nil)
        fetch_section(:tests, subject: "Test introspection") do |data|
          # Specific model tests
          if model
            return find_test_file(model, :model, detail)
          end

          # Specific controller tests
          if controller
            return find_test_file(controller, :controller, detail)
          end

          case detail
          when "summary"
            lines = [ "# Test Infrastructure", "" ]
            lines << "- **Framework:** #{unread_suite_gemfile ? "not read, the engine's suite is not read" : data[:framework]}"
            lines.concat(suite_lines)
            lines << "- **Factories:** #{count_phrase(data[:factories][:count], "file")}" if data[:factories]
            lines << "- **Fabricators:** #{count_phrase(data[:fabricators][:count], "file")}" if data[:fabricators]
            lines << "- **Cucumber:** #{count_phrase(data[:cucumber][:count], "feature file")}" if data[:cucumber]
            lines << "- **Fixtures:** #{RailsAiContext::TestFramework.fixture_phrase(data[:fixtures])}" if data[:fixtures]
            if data[:test_files]&.any?
              total = data[:test_files].values.sum { |v| v[:count] }
              lines << "- **Test files:** #{total} across #{count_phrase(data[:test_files].size, "category")}"
            end
            lines << "- **CI:** #{data[:ci_config].join(', ')}" if data[:ci_config]&.any?
            text_response(lines.join("\n"))

          when "standard"
            lines = [ "# Test Infrastructure", "" ]
            lines << "- **Framework:** #{unread_suite_gemfile ? "not read, the engine's suite is not read" : data[:framework]}"
            lines.concat(suite_lines)
            lines << "- **Factories:** #{data[:factories][:location]} (#{count_phrase(data[:factories][:count], "file")})" if data[:factories]
            lines << "- **Fabricators:** #{data[:fabricators][:location]} (#{count_phrase(data[:fabricators][:count], "file")})" if data[:fabricators]
            lines << cucumber_line(data[:cucumber]) if data[:cucumber]
            lines << "- **Fixtures:** #{data[:fixtures][:location]} (#{RailsAiContext::TestFramework.fixture_phrase(data[:fixtures])})" if data[:fixtures]
            lines << "- **System tests:** #{data[:system_tests][:location]}" if data[:system_tests]
            lines << "- **CI:** #{data[:ci_config].join(', ')}" if data[:ci_config]&.any?
            lines << "- **Coverage:** #{data[:coverage]}" if data[:coverage]
            lines.concat(ci_step_lines(data[:ci_steps]))

            if data[:test_files]&.any?
              lines << "" << "## Test Files"
              data[:test_files].each do |cat, info|
                lines << "- #{cat}: #{count_phrase(info[:count], "file")} (#{info[:location]})"
              end
            end

            lines.concat(trait_lines(data[:factory_traits], 15))

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
            lines << "- **Framework:** #{unread_suite_gemfile ? "not read, the engine's suite is not read" : data[:framework]}"
            lines.concat(suite_lines)
            lines << "- **CI:** #{data[:ci_config].join(', ')}" if data[:ci_config]&.any?
            lines << "- **Coverage:** #{data[:coverage]}" if data[:coverage]
            lines << cucumber_line(data[:cucumber]) if data[:cucumber]
            lines.concat(ci_step_lines(data[:ci_steps]))

            lines.concat(trait_lines(data[:factory_traits], 20))

            if data[:fixture_names]&.any?
              lines << "" << "## Fixtures"
              parsed_fixtures = parse_all_fixture_contents(data[:fixtures])
              data[:fixture_names].each do |set, labels|
                entries = parsed_fixtures[set.to_s]
                unless entries.is_a?(Hash)
                  why = entries == :too_large ? "over the #{max_test_file_size} byte read limit" : "not parsed as YAML"
                  lines << "- **#{set}:** #{Array(labels).join(', ')} _(#{why}; labels only)_"
                  next
                end

                lines << "- **#{set}:**"
                entries.each do |entry_name, attrs|
                  attr_str = attrs.map { |k, v| "#{k}: #{v}" }.join(", ")
                  lines << (attr_str.empty? ? "  - `#{entry_name}`" : "  - `#{entry_name}`: #{attr_str}")
                end
              end

              relationships = extract_fixture_relationships(parsed_fixtures.select { |_, entries| entries.is_a?(Hash) })
              if relationships.any?
                lines << "" << "## Fixture Relationships"
                relationships.each do |parent, children|
                  lines << "- **#{parent}** ← #{children.join(', ')}"
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

            if data[:fabricator_names]&.any?
              lines << "" << "## Fabricators"
              data[:fabricator_names].each { |file, names| lines << "- **#{file}:** #{names.join(', ')}" }
            end

            if data[:test_helper_setup]&.any?
              lines << "" << "## Test Helper Setup"
              data[:test_helper_setup].each { |m| lines << "- `#{m}`" }
            end

            if data[:test_files]&.any?
              lines << "" << "## Test Files"
              data[:test_files].each do |cat, info|
                lines << "- #{cat}: #{count_phrase(info[:count], "file")} (#{info[:location]})"
              end
            end

            if data[:test_helpers]&.any?
              lines << "" << "## Test Helper Files"
              data[:test_helpers].each { |h| lines << "- `#{h}`" }
            end
            text_response(lines.join("\n"))

          end
        end
      end

      def self.max_test_file_size
        RailsAiContext.configuration.max_test_file_size
      end

      # An engine's test/dummy is tested by the engine's suite, which every path here is under.
      private_class_method def self.suite_root
        RailsAiContext::PathResolver.test_root(rails_app.root.to_s)
      end

      private_class_method def self.suite_lines
        app_root = rails_app.root.to_s
        if suite_root == app_root
          outside = unread_suite_gemfile
          return outside ? [ "- **Suite:** not read: config/boot.rb points Bundler at #{outside}, outside the app's git repository; an engine's suite there is not read" ] : []
        end

        [ "- **Suite:** the engine's, at `#{RailsAiContext::PathResolver.suite_relative(app_root, ".")}`; the paths below are under it" ]
      end

      # The Gemfile config/boot.rb names outside the repository, for a dummy with no suite of its
      # own whose engine bundle is not read: the engine's suite is not either.
      private_class_method def self.unread_suite_gemfile
        app_root = rails_app.root.to_s
        return nil unless suite_root == app_root

        outside = RailsAiContext::GemLock.for(app_root).outside_gemfile
        outside unless outside.nil? || %w[test spec].any? { |dir| Dir.exist?(File.join(app_root, dir)) }
      end

      private_class_method def self.find_test_file(name, type, detail = "full")
        # Normalize: accept "Admin::PostsController", "admin/posts", "Posts", "posts" (plural)
        snake = case type
        when :controller
          RailsAiContext::Payload.controller_route_key(cached_context, name)
        when :model
          # The spec mirrors the model's own path, which a pack or an engine
          # moves out from under app/models.
          RailsAiContext::Payload.model_file(cached_context, name)
            .sub(%r{\A.*app/models/}, "").sub(/\.rb\z/, "")
        else
          name.to_s.tr("/", "::").underscore.sub(/_controller$/, "")
        end
        # For models, also try singular form (posts → post)
        # A model or controller name is never a path. Without this the name is
        # interpolated into a spec path, which cannot escape the root but
        # answers "No test file found for /etc/passwd" at exit 0 where every
        # other tool refuses.
        refused = refuse_unsafe_paths([ name ])
        return refused if refused

        candidates = RailsAiContext::TestFramework.candidates(suite_root, type, snake, cached_context)
        exercising = type == :controller ? exercising_tests(snake, candidates) : []

        contained = []
        too_large = nil
        candidates.each do |rel|
          content, resolution = RailsAiContext::SafePath.read(rel, under: suite_root, max_size: max_test_file_size)
          contained << rel unless ESCAPING_REFUSALS.include?(resolution.refusal)
          too_large ||= resolution if resolution.refusal == :too_large
          next unless content

          # Summary/standard: return just test names (saves 2000+ tokens vs full source)
          answer = if names_only?(detail)
            listed = examples(content)
            "# #{rel} (#{count_phrase(listed.size, "test")})\n\n#{listed.join("\n")}"
          else
            "# #{rel}\n\n```ruby\n#{content}\n```"
          end
          return text_response(answer + exercising_section(exercising, "## Also exercised by"))
        end

        if too_large
          return text_response("# #{too_large.relative}\n\n_The test file exists but was not read: #{human_size(File.size(too_large.realpath))} is over " \
                               "`max_test_file_size` (#{human_size(max_test_file_size)})._" +
                               exercising_section(exercising, "## Also exercised by"))
        end

        if exercising.any?
          return text_response("# Tests that exercise #{name}" + exercising_section(exercising, nil, names: true))
        end

        # A refused candidate was never read, so listing it reads as a search
        # that happened. When every one was refused, the name is the answer.
        if contained.empty?
          return error_response("No test file found for #{name}: the name was refused, it leaves the app root " \
                                "or names a sensitive file.")
        end

        unread = unread_suite_gemfile
        unread &&= "\n\nNot searched: the engine's suite at `#{File.dirname(unread)}` is not read, config/boot.rb points Bundler at #{unread}, outside the app's git repository."
        empty_response("No test file found for #{name}. Searched: #{contained.join(', ')}#{nearby_tests_hint(contained)}#{unread}")
      end

      # Where a controller is driven from outside its own test, and what each
      # kind of test is called.
      EXERCISING_DIRS = {
        "spec/system" => "system", "spec/features" => "feature", "spec/requests" => "request",
        "test/system" => "system", "test/integration" => "integration"
      }.freeze
      MAX_EXERCISING = 10

      # System, feature and request tests that exercise a controller: named for
      # its route key, or reaching one of its routes by helper or literal path.
      # Mastodon tests AboutController only through spec/system/about_spec.rb.
      #
      # @return [Array<Array(String, String, String)>] [path, kind, source]
      private_class_method def self.exercising_tests(snake, primary)
        root = suite_root
        real_root = File.realpath(root)
        routes = Array(RouteCoverage.all_by_controller(cached_context[:routes])[snake])
        helpers = routes.filter_map { |route| route[:name] }.uniq
        paths = routes.map { |route| route[:path].to_s.delete_suffix("(.:format)") }.reject { |path| path.include?(":") }.uniq
        reaches = Regexp.union(helpers.map { |helper| /\b#{Regexp.escape(helper)}_(?:path|url)\b/ } +
                               paths.map { |path| /["']#{Regexp.escape(path)}["']/ })

        found = EXERCISING_DIRS.flat_map do |dir, kind|
          safe_glob(File.join(root, dir), "**/*_{spec,test}.rb", real_root).sort.filter_map do |real|
            rel = real.delete_prefix("#{real_root}/")
            next if primary.include?(rel)

            source = RailsAiContext::SafeFile.read(real, max_size: max_test_file_size) or next
            named = rel.delete_prefix("#{dir}/").sub(/_(?:spec|test)\.rb\z/, "") == snake
            [ rel, kind, source, named ] if named || source.match?(reaches)
          end
        end
        # A test named for the controller first, then those reaching its routes.
        found.sort_by { |rel, _kind, _source, named| [ named ? 0 : 1, rel ] }.map { |row| row.first(3) }
      rescue => e
        RailsAiContext.debug_fail(e, [], label: "exercising_tests")
      end

      # One line per exercising test, its kind and size, and its test names
      # when they are the whole answer.
      private_class_method def self.exercising_section(found, heading, names: false)
        return "" if found.empty?

        lines = heading ? [ "", "", heading, "" ] : [ "", "" ]
        found.first(MAX_EXERCISING).each do |rel, kind, source|
          listed = examples(source)
          lines << "- `#{rel}` (#{kind}, #{count_phrase(listed.size, "test")})"
          listed.each { |test| lines << "  #{test}" } if names
        end
        lines << "- ... #{found.size - MAX_EXERCISING} more" if found.size > MAX_EXERCISING
        lines.join("\n")
      end

      private_class_method def self.names_only?(detail)
        RailsAiContext::DetailLevel.summary?(detail) ||
          RailsAiContext::DetailLevel.normalize(detail) == RailsAiContext::DetailLevel::STANDARD
      end

      # The calls that define an example, pending and focused ones included.
      EXAMPLE_METHODS = %i[it specify example scenario its test xit xspecify xexample xscenario fit fspecify fexample fscenario].freeze

      # The examples a test file runs, one line each: `it`, `specify`,
      # `scenario` and the rest, `test "..."` and `def test_*`, one-liners
      # included. The describe and context blocks around them group examples;
      # they are not tests. The count is these lines, so the two agree.
      private_class_method def self.examples(content)
        found = RailsAiContext::Introspectors::SourceIntrospector.walk_source(content, {
          examples: -> { RailsAiContext::Introspectors::Listeners::GenericMacroListener.new(*EXAMPLE_METHODS) },
          methods: -> { RailsAiContext::Introspectors::Listeners::MethodsListener.new }
        })
        lines = content.lines
        numbers = found[:examples].map { |hit| hit[:location] } +
                  found[:methods].select { |method| method[:name].to_s.start_with?("test_") }.map { |method| method[:location] }
        numbers.sort.map { |number| "- #{lines[number - 1].to_s.strip}" }
      rescue => e
        RailsAiContext.debug_fail(e, [], label: "examples")
      end

      # Nearby test files, to help the agent find the right one. The glob base
      # is the realpath, so a symlinked test directory cannot widen it.
      private_class_method def self.nearby_tests_hint(candidates)
        root = suite_root
        real_root = File.realpath(root)

        nearby = candidates.map { |rel| File.dirname(File.join(root, rel)) }.uniq.flat_map do |dir|
          next [] unless File.directory?(dir)

          real_dir = File.realpath(dir)
          next [] unless RailsAiContext::SafePath.contained?(real_dir, real_root)

          Dir.glob(File.join(real_dir, "*")).map { |f| f.delete_prefix("#{real_root}/") }.first(10)
        end

        nearby.any? ? "\n\nFiles in test directory: #{nearby.join(', ')}" : ""
      rescue SystemCallError
        ""
      end

      private_class_method def self.cucumber_line(cucumber)
        "- **Cucumber:** #{cucumber[:location]} (#{count_phrase(cucumber[:count], "feature file")}, " \
          "#{count_phrase(cucumber[:step_definitions].to_i, "step definition file")})"
      end

      private_class_method def self.ci_step_lines(steps)
        return [] unless steps.is_a?(Array) && steps.any?

        [ "", "## CI Steps (`config/ci.rb`, run by `bin/ci`)" ] +
          steps.map { |step| "- #{step[:name]}: `#{step[:command]}`" }
      end

      private_class_method def self.trait_lines(traits, limit)
        return [] unless traits.is_a?(Hash) && traits.any?

        [ "", "## Factory Traits" ] +
          traits.first(limit).map { |file, names| "- **#{file}:** #{Array(names).join(", ")}" }
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
          if data[:factories]
            lines << "      record = create(:model_name)"
          else
            # A template headed "follow this pattern" must not hand factory_bot
            # syntax to an app that has no factories.
            lines << "      # TODO: build the record with this app's own test data"
            lines << "      record = ModelName.new"
          end
          lines << "      expect(record.method_name).to eq(expected)"
          lines << "    end"
          lines << "  end"
          lines << "end"
          lines << "```"
        else
          # Detect Devise + sign_in pattern from existing tests
          has_devise = false
          has_sign_in = false
          test_dir = File.join(suite_root, "test")
          if Dir.exist?(test_dir)
            real_root = File.realpath(suite_root).to_s
            safe_glob(test_dir, "**/*_test.rb", real_root).first(5).each do |path|
              content = RailsAiContext::SafeFile.read(path) or next
              has_devise = true if content.include?("Devise::Test")
              has_sign_in = true if content.match?(/\bsign_in\b/)
            end
          end

          lines << "" << "## Test Template (follow this pattern for new tests)"
          lines << "```ruby"
          lines << "require \"test_helper\""
          lines << ""
          lines << "class ModelNameTest < ActiveSupport::TestCase"
          lines << "  test \"should be valid with required attributes\" do"
          if data[:fixture_names]&.any?
            lines << "    record = model_names(:fixture_name)"
          else
            lines << "    # TODO: build the record with this app's own test data"
            lines << "    record = ModelName.new"
          end
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
            if has_sign_in
              user_key = fixture_key_for("users", data)
              lines << (user_key ? "    sign_in users(:#{user_key})" : "    # TODO: sign in a user built from this app's own test data")
            end
            lines << "    get feature_path"
            lines << "    assert_response :success"
            lines << "  end"
            lines << "end"
            lines << "```"
          end
        end

        lines
      rescue => e
        RailsAiContext.debug_fail(e, [], label: "generate_test_template")
      end

      # Parse factory file to extract attributes and traits
      private_class_method def self.parse_factory_details(relative_path)
        # Try common factory locations
        candidates = [
          File.join(suite_root, "spec/factories/#{relative_path}"),
          File.join(suite_root, "test/factories/#{relative_path}"),
          File.join(suite_root, "spec/factories", relative_path),
          File.join(suite_root, "test/factories", relative_path)
        ]
        path = candidates.find { |p| File.exist?(p) }
        return nil unless path
        return nil if File.size(path) > max_test_file_size

        content = RailsAiContext::SafeFile.read(path)
        return nil unless content
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
        RailsAiContext.debug_fail(e, nil, label: "parse_factory_details")
      end

      FIXTURE_SKIP_KEYS = %w[created_at updated_at id].freeze

      FIXTURE_VALUE_LIMIT = 100

      # A fixture file's labels and their short attributes as text, :too_large
      # past the read limit, or nil when it was not read or does not parse.
      private_class_method def self.parse_fixture_contents(file_path)
        return :too_large if File.size(file_path) > max_test_file_size

        content = RailsAiContext::SafeFile.read(file_path, max_size: max_test_file_size) or return nil
        parsed = RailsAiContext::FixtureKeys.parse(content) or return nil

        parsed.transform_values do |attributes|
          attributes.each_with_object({}) do |(key, value), shown|
            next if FIXTURE_SKIP_KEYS.include?(key.to_s)

            text = short_text(value)
            shown[key] = text if text
          end
        end
      end

      # The value as text when it is short, else nil. A container is sized
      # before to_s runs, since YAML aliases can nest one into an exponential
      # string from a few lines.
      private_class_method def self.short_text(value)
        budget = FIXTURE_VALUE_LIMIT
        pending = [ value ]
        until pending.empty?
          item = pending.pop
          case item
          when Hash then budget -= item.size; pending.concat(item.keys, item.values)
          when Array then budget -= item.size; pending.concat(item)
          else budget -= item.to_s.length
          end
          return nil if budget.negative?
        end
        text = value.to_s
        text if text.length <= FIXTURE_VALUE_LIMIT
      end

      # { set => entries, or nil when unparsed } over the fixture directories
      # the introspector found, each set named by its path under its directory.
      private_class_method def self.parse_all_fixture_contents(fixtures)
        return {} unless fixtures.is_a?(Hash)

        root = suite_root
        real_root = File.realpath(root)
        results = {}
        Array(fixtures[:locations]).each do |rel|
          dir = File.join(root, rel)
          Dir.glob(File.join(dir, "**", "*.yml")).sort.each do |path|
            set = path.delete_prefix("#{dir}/").delete_suffix(".yml")
            next if results.key?(set)

            real = safe_glob_realpath(path, real_root, real_root) or next
            results[set] = parse_fixture_contents(real)
          end
        end
        results
      rescue SystemCallError => e
        RailsAiContext.debug_fail(e, {}, label: "parse_all_fixture_contents")
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
                # Rails fixture reference: e.g. user: one where "user" is a fixture file
                relationships["#{key} (#{str_value})"] << "#{file}.#{entry_name}"
              elsif key.to_s =~ /\A(\w+)_id\z/
                # Foreign key with integer value - note the relationship type
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
