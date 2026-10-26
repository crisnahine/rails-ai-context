# frozen_string_literal: true

require "uri"

module RailsAiContext
  module Tools
    class GenerateTest < BaseTool
      tool_name "rails_generate_test"
      description "Generate test scaffolding that matches your project's actual test patterns - framework, factories, assertion style. " \
        "Use when: adding tests for a model, controller, or service. Generates copy-paste-ready test files. " \
        "Key params: model (e.g. 'User'), controller (e.g. 'PostsController'), file (e.g. 'app/services/foo.rb')."

      input_schema(
        properties: {
          model: {
            type: "string",
            description: "Model name (e.g. 'User'). Generates model spec with validations, associations, scopes, enums."
          },
          controller: {
            type: "string",
            description: "Controller name (e.g. 'PostsController'). Generates request spec with routes and auth."
          },
          file: {
            type: "string",
            description: "File path relative to Rails root (e.g. 'app/services/payment_service.rb'). Auto-detects type."
          },
          type: {
            type: "string",
            enum: %w[unit request system],
            description: "Test type: unit (model/service, default), request (controller), system (browser/Capybara)."
          }
        }
      )

      guide_row(
        order: 29,
        mcp: "rails_generate_test(model:\"X\")",
        cli_args: "model=X",
        summary: "Generate test scaffolding matching project patterns (framework, factories, style)"
      )

      annotations(read_only_hint: true, destructive_hint: false, idempotent_hint: true, open_world_hint: false)

      MAX_ANCESTRY_WALK = 5

      def self.call(model: nil, controller: nil, file: nil, type: "unit", server_context: nil)
        unless model || controller || file
          return error_response("Provide at least one of: `model`, `controller`, or `file`.")
        end

        refused = refuse_unsafe_paths([ file ])
        return refused if refused

        tests_data = cached_context[:tests] || {}
        framework = tests_data[:framework] || detect_framework

        if type == "system" && (model || controller)
          generate_system_test(model&.strip, controller&.strip, framework, tests_data)
        elsif model
          generate_model_test(model.strip, framework, tests_data)
        elsif controller
          generate_controller_test(controller.strip, framework, tests_data)
        elsif file
          generate_file_test(file.strip, framework, tests_data, type)
        end
      end

      class << self
        private

        def detect_framework
          RailsAiContext::TestFramework.for(rails_app.root)
        end

        # The setup line follows the app's own specs: whether they name their
        # subject with let or an instance variable, and whether they create or
        # build it.
        def rspec_style
          root = rails_app.root.to_s
          files = safe_glob(File.join(root, "spec"), "**/*_spec.rb", File.realpath(root).to_s).first(5)
          create_count = build_count = let_count = instance_var_count = 0

          files.each do |f|
            next if File.size(f) > config.max_test_file_size
            source = RailsAiContext::SafeFile.read(f) or next
            create_count += source.scan(/create\(:/).size
            build_count += source.scan(/build\(:/).size
            let_count += source.scan(/\blet[!]?\(:/).size
            instance_var_count += source.scan(/@\w+\s*=/).size
          end

          { factory: create_count >= build_count ? :create : :build, let: let_count > instance_var_count }
        end

        # Every one-liner the model generator writes for an association, a
        # validation or an enum is a shoulda-matchers matcher. Written into an
        # app that does not bundle it, each one fails with NoMethodError.
        def shoulda?
          RailsAiContext::GemLock.for(rails_app.root.to_s).present?("shoulda-matchers")
        end

        # ── Model test generation ────────────────────────────────────────

        def generate_model_test(model_name, framework, tests_data)
          models = cached_context[:models] || {}
          key = fuzzy_find_key(models.keys, model_name)
          unless key
            return not_found_response("Model", model_name, models.keys.sort,
              recovery_tool: call_pointer("rails_get_model_details", %(detail:"summary"), "to see all models"))
          end

          data = models[key]
          return text_response("Model #{key} has errors: #{data[:error]}") if data[:error]

          if framework.to_s.include?("rspec")
            generate_rspec_model(key, data, tests_data)
          else
            generate_minitest_model(key, data, tests_data)
          end
        end

        # Where the app already files tests of this kind, else the convention. The second value is
        # the subject's existing test, so the answer can point there instead of a new file.
        def test_path(base, kind, stem, fallback_dir, fallback_suffix)
          framework = RailsAiContext::TestFramework
          root = RailsAiContext::PathResolver.test_root(rails_app.root.to_s)
          dir, suffix = framework.layout(root, base, kind, framework.subject_stems(cached_context, kind))
          dir ||= fallback_dir
          suffix ||= fallback_suffix
          # Same lookup as rails_get_test_info, this base first.
          existing = framework.candidates(root, kind, stem, cached_context)
                              .partition { |rel| rel.start_with?("#{base}/") }.flatten.find do |rel|
            full = File.expand_path(rel, root)
            RailsAiContext::SafePath.contained?(full, root) && File.file?(full)
          end
          app_root = rails_app.root.to_s
          [ RailsAiContext::PathResolver.suite_relative(app_root, "#{dir}/#{stem}#{suffix}"),
            existing && RailsAiContext::PathResolver.suite_relative(app_root, existing), dir ]
        rescue => e
          RailsAiContext.debug_fail(e, [ "#{fallback_dir}/#{stem}#{fallback_suffix}", nil, fallback_dir ], label: "test_path")
        end

        # The subject's test is often there already (`rails g model` writes
        # one), and "it exists, add to it" alone gave nothing to add. The
        # cases come anyway, addressed to that file, which holds tests of its own.
        def existing_test_lines(existing)
          return [] unless existing

          [ "#{existing} already exists. Add the cases below that it lacks to it, " \
            "rather than replacing it or writing a second test file for the same subject.", "" ]
        end

        # Namespaced names join with an underscore: Admin::User is admin_user, and
        # test/fixtures/admin/users.yml is read through admin_users.
        def record_name(model_name)
          model_name.to_s.underscore.tr("/", "_")
        end

        def fixture_accessor(set)
          set.to_s.tr("/", "_")
        end

        # The example name ships inside a file the user pastes, so it names a
        # block as a block instead of printing this gem's own marker.
        def callback_example_subject(target)
          if target.to_s == RailsAiContext::Introspectors::Listeners::CallbacksListener::INLINE_BLOCK
            "runs its inline block"
          else
            "calls #{callback_target(target.to_s)}"
          end
        end

        def generate_rspec_model(name, data, tests_data)
          # The spec mirrors the model's own path, and underscoring the name
          # does not reproduce it: OAuthClientConfig is oauth_client_config.rb.
          file_path, existing = test_path("spec", :model, RailsAiContext::Payload.model_stem(cached_context, name), "spec/models", "_spec.rb")
          factory = find_factory_name(name, tests_data)
          shoulda = shoulda?
          lines = [ *existing_test_lines(existing), "# #{existing || file_path}", "", "```ruby", "# frozen_string_literal: true", "", "require \"rails_helper\"", "" ]
          lines << "RSpec.describe #{name}, type: :model do"

          # Factory/fixture setup
          if factory
            style = rspec_style
            if style[:let]
              lines << "  let(:#{model_let_name(record_name(name))}) { #{factory_bot(style[:factory])}(:#{factory}) }"
            end
          end

          # Associations
          # An association type with no matcher renders nothing, so the block
          # opens on the rows rather than on the association count.
          rows = (data[:associations] || []).filter_map do |a|
            # A computed name is not a symbol a matcher can take: the spec
            # either fails to parse or checks an association no model has.
            next if a[:computed_name]
            next reflection_example(a) unless shoulda

            case a[:type]
            when "belongs_to"
              case a[:optional]
              when true then "    it { is_expected.to belong_to(:#{a[:name]}).optional }"
              when nil, false then "    it { is_expected.to belong_to(:#{a[:name]}) }"
              else reflection_example(a)
              end
            when "has_many"
              if a[:through]
                "    it { is_expected.to have_many(:#{a[:name]}).through(:#{a[:through]}) }"
              else
                dep = a[:dependent] ? ".dependent(:#{a[:dependent]})" : ""
                "    it { is_expected.to have_many(:#{a[:name]})#{dep} }"
              end
            when "has_one"
              "    it { is_expected.to have_one(:#{a[:name]}) }"
            when "has_and_belongs_to_many"
              "    it { is_expected.to have_and_belong_to_many(:#{a[:name]}) }"
            end
          end
          if rows.any?
            lines << ""
            lines << "  describe \"associations\" do"
            lines.concat(rows)
            lines << "  end"
          end

          # Validations
          validations = data[:validations] || []
          if validations.any?
            lines << ""
            lines << "  describe \"validations\" do"
            opened = lines.size
            seen = Set.new
            validations.each do |v|
              # Rails writes "must exist" for a required belongs_to, which
              # validate_presence_of never accepts; belong_to checks it.
              next if shoulda && v[:implicit]

              v[:attributes].each do |attr|
                key = "#{v[:kind]}:#{attr}"
                next if seen.include?(key)
                seen << key

                unless shoulda
                  lines.concat(plain_validation_example(v, attr))
                  next
                end

                if (condition = validation_condition(v))
                  lines.push("    it \"validates #{v[:kind]} of #{attr}\" do", conditional_validation_skip(condition, "      "), "    end")
                  next
                end

                start = lines.size
                case v[:kind]
                when "presence"
                  lines << "    it { is_expected.to validate_presence_of(:#{attr}) }"
                when "uniqueness"
                  matcher = uniqueness_matcher(attr, v)
                  matcher ? lines << "    it { is_expected.to #{matcher} }" : lines.concat(plain_validation_example(v, attr))
                when "length"
                  opts = v[:options] || {}
                  matcher = "validate_length_of(:#{attr})"
                  matcher += ".is_at_most(#{opts[:maximum]})" if opts[:maximum]
                  matcher += ".is_at_least(#{opts[:minimum]})" if opts[:minimum]
                  lines << "    it { is_expected.to #{matcher} }"
                when "numericality"
                  lines << "    it { is_expected.to validate_numericality_of(:#{attr}) }"
                when "inclusion"
                  vals = inclusion_list(v)
                  allow_nil = v.dig(:options, :allow_nil) ? ".allow_nil" : ""
                  # The matcher raises without in_array, and an enum raises on the value outside it.
                  if vals && !enum_attribute?(data, attr)
                    lines << "    it { is_expected.to validate_inclusion_of(:#{attr}).in_array(#{vals})#{allow_nil} }"
                  else
                    lines.push("    it \"validates inclusion of #{attr}\" do", "      skip \"TODO: set #{attr} to a value outside the inclusion list\"", "    end")
                  end
                when "acceptance"
                  lines << "    it { is_expected.to validate_acceptance_of(:#{attr}) }"
                when "confirmation"
                  lines << "    it { is_expected.to validate_confirmation_of(:#{attr}) }"
                when "format"
                  lines.push("    it \"validates format of #{attr}\" do", "      skip \"TODO: set #{attr} to a value the format rejects and one it accepts\"", "    end")
                when "absence"
                  lines << "    it { is_expected.to validate_absence_of(:#{attr}) }"
                else
                  lines.push("    it \"validates #{v[:kind]} of #{attr}\" do", "      skip #{"TODO: #{rule_assertion_hint(v, attr)}".inspect}", "    end")
                end
                if (context = validation_context(v)) && lines[start].start_with?("    it { ")
                  lines[start] = lines[start].delete_suffix(" }") + ".on(:#{context}) }"
                end
              end
            end
            # The uniqueness matcher saves a copy of its subject, and described_class.new leaves every attribute nil.
            dropped = []
            if lines[opened..].any? { |line| line.include?("validate_uniqueness_of(") }
              if factory
                lines.insert(opened, "    subject { #{factory_bot(:build)}(:#{factory}) }", "")
              elsif (record = placeholder_record(name, [], dropped))
                lines.insert(opened, *unknown_enum_todos(dropped, name, "    "), "    subject { described_class.new(#{record}) }", "")
              end
            end
            lines << "  end"
          end

          # Scopes
          scopes = data[:scopes] || []
          if scopes.any?
            lines << ""
            lines << "  describe \"scopes\" do"
            scopes.each do |s|
              scope_name = s.is_a?(Hash) ? s[:name] : s
              lines << "    describe \".#{scope_name}\" do"
              lines << "      it \"returns expected records\" do"
              lines << "        # TODO: create test data and verify scope behavior"
              lines << "      end"
              lines << "    end"
            end
            lines << "  end"
          end

          # Enums
          enums = data[:enums] || {}
          if enums.any?
            lines << ""
            lines << "  describe \"enums\" do"
            enums.each do |attr, values|
              next if values.is_a?(String) # computed: no literal values to assert

              vals = values.is_a?(Hash) ? values.keys : Array(values)
              matcher = enum_matcher(attr, values, data) if shoulda
              lines << if matcher
                "    it { is_expected.to #{matcher} }"
              else
                "    it { expect(described_class.defined_enums[\"#{attr}\"].keys).to match_array(#{vals.map(&:to_s).inspect}) }"
              end
            end
            lines << "  end"
          end

          # Callbacks
          callbacks = data[:callbacks] || {}
          if callbacks.any?
            lines << ""
            lines << "  describe \"callbacks\" do"
            callbacks.each do |type, methods|
              Array(methods).each do |m|
                lines << "    it \"#{type} #{callback_example_subject(m)}\" do"
                lines << "      # TODO: verify callback behavior"
                lines << "    end"
              end
            end
            lines << "  end"
          end

          lines << "end"
          lines << "```"

          text_response(lines.join("\n"))
        end

        def generate_minitest_model(name, data, tests_data)
          file_path, existing = test_path("test", :model, RailsAiContext::Payload.model_stem(cached_context, name), "test/models", "_test.rb")
          factory = find_factory_name(name, tests_data)
          table = RailsAiContext::Payload.model_table(cached_context, name).table
          lines = [ *existing_test_lines(existing), "# #{existing || file_path}", "", "```ruby", "# frozen_string_literal: true", "", "require \"test_helper\"", "" ]
          lines << "class #{name}Test < ActiveSupport::TestCase"

          setup_var = record_name(name)
          setup_var += "_record" if TEST_CASE_IVARS.include?(setup_var)
          fixture_set, fixture_key = model_fixture(name, table, tests_data)
          # Determine data setup: factory > fixture > inline
          lines << "  setup do"
          if factory
            lines << "    @#{setup_var} = #{factory_bot(:create)}(:#{factory})"
          elsif fixture_key
            lines << "    @#{setup_var} = #{fixture_accessor(fixture_set)}(:#{fixture_key})"
          else
            lines << "    # TODO: no #{table || name} fixture found; build a valid record here"
            lines << "    @#{setup_var} = #{name}.new"
          end
          lines << "  end"

          # Validations
          validations = data[:validations] || []
          if validations.any?
            lines << ""
            seen = Set.new
            validations.each do |v|
              v[:attributes].each do |attr|
                key = "#{v[:kind]}:#{attr}"
                next if seen.include?(key)
                seen << key
                lines << "  test \"validates #{v[:kind]} of #{attr}\" do"
                if (condition = validation_condition(v))
                  lines.push(conditional_validation_skip(condition, "    "), "  end", "")
                  next
                end
                if macro_validation?(v)
                  lines << "    skip #{"TODO: #{rule_assertion_hint(v, attr)}".inspect}"
                  lines << "  end"
                  lines << ""
                  next
                end
                case v[:kind]
                when "presence"
                  lines << "    @#{setup_var}.#{attr} = nil"
                when "inclusion"
                  # The made-up value casts to true on a boolean and raises on an enum.
                  if enum_attribute?(data, attr) || !%w[string text].include?(schema_column_type(table, attr.to_s).presence || "string")
                    lines.push("    skip \"TODO: set #{attr} to a value outside the inclusion list\"", "  end", "")
                    next
                  end
                  lines << "    @#{setup_var}.#{attr} = \"__invalid_value__\""
                when "uniqueness"
                  dropped = []
                  if factory || fixture_key
                    lines << "    duplicate = @#{setup_var}.dup"
                  elsif (record = placeholder_record(name, [], dropped))
                    lines.push(*unknown_enum_todos(dropped, name, "    "), "    # TODO: adjust these attributes if validations reject the placeholder values",
                               "    duplicate = #{name}.create!(#{record}).dup")
                  else
                    lines << "    skip #{"TODO: #{unbuildable_reason(name) || "no #{name} can be made up from placeholders"}".inspect}"
                    lines.push("  end", "")
                    next
                  end
                  lines << "    assert_not duplicate.valid?"
                  lines << "  end"
                  lines << ""
                  next
                when "numericality"
                  lines << "    @#{setup_var}.#{attr} = \"not_a_number\""
                when "length"
                  value = length_breaking_value(v[:options] || {})
                  unless value
                    lines.push("    skip \"set #{attr} to a length the validation rejects\"", "  end", "")
                    next
                  end
                  lines << "    @#{setup_var}.#{attr} = #{value}"
                when "format"
                  if format_accepts?(v[:options] || {}, "invalid-format")
                    lines.push("    skip \"TODO: set #{attr} to a value the format rejects\"", "  end", "")
                    next
                  end
                  lines << "    @#{setup_var}.#{attr} = \"invalid-format\""
                when "absence"
                  lines << "    @#{setup_var}.#{attr} = \"present\""
                when "confirmation"
                  lines << "    @#{setup_var}.#{attr} = \"secret\""
                  lines << "    @#{setup_var}.#{attr}_confirmation = \"different\""
                when "acceptance"
                  lines << "    @#{setup_var}.#{attr} = \"0\""
                when "exclusion"
                  excluded = v.dig(:options, :in)
                  if excluded.is_a?(Array) && excluded.any?
                    lines << "    @#{setup_var}.#{attr} = #{excluded.first.inspect}"
                  else
                    lines.push("    skip \"set #{attr} to a value the exclusion list holds\"", "  end", "")
                    next
                  end
                else
                  # With no value known to break it, the assert would run on a valid record.
                  lines.push("    skip #{"TODO: #{rule_assertion_hint(v, attr)}".inspect}", "  end", "")
                  next
                end
                lines << "    assert_not @#{setup_var}.valid?#{"(:#{validation_context(v)})" if validation_context(v)}"
                lines << "  end"
                lines << ""
              end
            end
          end

          # Associations
          # A computed name is no symbol the test can call.
          (data[:associations] || []).reject { |a| a[:computed_name] }.each do |a|
            lines << "  test \"#{a[:type]} #{a[:name]}\" do"
            lines << "    assert_respond_to @#{setup_var}, :#{a[:name]}"
            lines << "  end"
            lines << ""
          end

          # Scopes
          scopes = data[:scopes] || []
          scopes.each do |s|
            scope_name = s.is_a?(Hash) ? s[:name] : s
            scope_body = s.is_a?(Hash) ? s[:body] : nil
            required_params = (s.is_a?(Hash) && s[:required_params]) || []
            if required_params.any?
              # Calling an arg-taking scope bare raises ArgumentError, and the
              # right argument value can't be guessed - assert it exists and
              # leave a runnable call site for the developer to fill in.
              lines << "  test \"scope .#{scope_name} is defined\" do"
              lines << "    assert_respond_to #{name}, :#{scope_name}"
              lines << "    # #{name}.#{scope_name}(#{required_params.join(', ')}) - fill in real values to assert results"
              lines << "  end"
              lines << ""
              next
            end
            lines << "  test \"scope .#{scope_name} returns expected records\" do"
            if sorting_scope?(scope_body)
              lines << "    sql = #{name}.#{scope_name}.to_sql"
              lines << "    assert_match(/ORDER BY/i, sql)"
            else
              lines << "    results = #{name}.#{scope_name}"
              lines << "    assert_kind_of ActiveRecord::Relation, results"
            end
            lines << "  end"
            lines << ""
          end

          lines.pop if lines.last == ""
          lines << "end"
          lines << "```"

          text_response(lines.join("\n"))
        end

        # ── Controller test generation ───────────────────────────────────

        RESTFUL_ACTION_ORDER = %w[index new create show edit update destroy].freeze

        # Literal attribute values by schema column type, used when there is
        # no fixture record to copy values from.
        PLACEHOLDER_VALUES = {
          "string" => "\"MyString\"",
          "text" => "\"MyText\"",
          "integer" => "1",
          "bigint" => "1",
          "float" => "1.5",
          "decimal" => "\"9.99\"",
          "boolean" => "false",
          "date" => "Date.current",
          "datetime" => "Time.current",
          "time" => "Time.current",
          "json" => "{}",
          "jsonb" => "{}",
          "uuid" => "SecureRandom.uuid"
        }.freeze

        def generate_controller_test(ctrl_name, framework, tests_data)
          ctrl_name = ctrl_name.strip

          # A spec for a controller the app does not have is a file nothing
          # can run. "No routes found" read as "add routes", not "this class
          # does not exist". Payload owns the name-to-key rule, so this tool
          # resolves "gift_cards" to the same controller every other surface
          # does.
          known = RailsAiContext::Payload.controllers(cached_context)
          ctrl_class = RailsAiContext::Payload.find_controller(cached_context, ctrl_name)
          if known.any? && ctrl_class.nil?
            return not_found_response("Controller", ctrl_name, known.keys.sort,
              recovery_tool: call_pointer("rails_get_controllers", %(detail:"summary"), "to see all controllers"))
          end

          ctrl_class ||= ctrl_name.end_with?("Controller") ? ctrl_name : "#{ctrl_name.camelize}Controller"

          snake = RailsAiContext::Payload.controller_route_key(cached_context, ctrl_class)

          routes = cached_context[:routes] || {}
          by_ctrl = RouteCoverage.all_by_controller(routes)
          ctrl_routes = by_ctrl[snake] || by_ctrl[snake.pluralize] || []
          chain = action_chain(ctrl_class, snake)
          ctrl_routes, unimplemented = implemented_routes(ctrl_class, chain, ctrl_routes)

          res = resource_info(ctrl_class, snake, tests_data).merge(unimplemented: unimplemented, controller: ctrl_class,
                                                                   route_key: snake, outcomes: {}, chain: chain,
                                                                   route_names: RouteCoverage.by_controller(routes).values.flatten.filter_map { |r| r[:name] })
          # Devise and Doorkeeper have their own sign-in lines; any other login
          # filter is named, and signed past with the app's own sign-in helper
          # only where that helper is known to get a request past it.
          unless devise_app?(tests_data) || doorkeeper_controller?(ctrl_class)
            res[:login] = login_filters(ctrl_class, ctrl_routes)
            if res[:login].any?
              res[:helper] = app_sign_in_helper
              res[:sign_in] = res[:helper] if signs_past?(res[:helper], res)
            end
          end

          if framework.to_s.include?("rspec")
            generate_rspec_request(ctrl_class, snake, ctrl_routes, tests_data, res)
          else
            generate_minitest_controller(ctrl_class, snake, ctrl_routes, tests_data, res)
          end
        end

        # Everything the request templates need to emit runnable requests:
        # the backing model, its fixture, the strong-params key, and the
        # permitted attributes (from strong params, falling back to schema
        # content columns).
        # The model a route key names without its namespace: from the
        # controller's namespace outward, else the one model of that own name
        # (a line_items route serving Shop::LineItem).
        def resource_model(keys, ctrl_class, name)
          found = RailsAiContext::Introspectors::TableName.resolve_class(name, ctrl_class) { |candidate| fuzzy_find_key(keys, candidate) }
          return found if keys.include?(found)

          same = keys.select { |key| key.to_s.demodulize.casecmp?(name) }
          same.first if same.one?
        end

        def resource_info(ctrl_class, snake, tests_data)
          models = cached_context[:models] || {}
          singular = snake.split("/").last.singularize
          model_key = fuzzy_find_key(models.keys, snake.singularize.camelize) || resource_model(models.keys, ctrl_class, singular.camelize)
          model_data = model_key ? models[model_key] : nil
          model_data = {} unless model_data.is_a?(Hash)
          table = RailsAiContext::Payload.model_table(cached_context, model_key || singular.camelize).table

          info = ((cached_context[:controllers] || {})[:controllers] || {})[ctrl_class] || {}
          strong_params = Array(info[:strong_params])
          sp = strong_params.find { |p| p[:name] == "#{singular}_params" } || strong_params.first
          columns = schema_content_columns(table)
          attrs = Array(sp && sp[:permits]).map(&:to_s)
          # A controller read whole that declares no *_params method takes no
          # model params: bazaar's OrdersController#create reads the session
          # cart, and a POST of every orders column sent nothing it reads.
          no_strong_params = info.key?(:strong_params) && strong_params.empty?
          attrs = columns if attrs.empty? && !no_strong_params

          # A permitted param need not be a column: nested attributes, virtual
          # writers, a password a model stores as a digest. create! raises
          # UnknownAttributeError on one, so the record is built from columns
          # only while the request params keep every permitted name.
          non_columns = columns.any? ? attrs - columns : []

          # Uniqueness constraints come from two places: model validations and
          # unique database indexes. A column with only a unique index (no
          # validation) still rejects duplicate inserts, so treat both alike.
          validation_uniques = Array(model_data[:validations])
            .select { |v| v[:kind] == "uniqueness" }
            .flat_map { |v| Array(v[:attributes]).map(&:to_s) }
          table_uniques = (validation_uniques + unique_index_columns(table)).uniq & columns
          unique_attrs = table_uniques & (no_strong_params ? columns : attrs)
          fixture = model_key ? model_fixture(model_key, table, tests_data) : fixture_key_for(table, tests_data)&.then { |key| [ table, key ] }

          {
            name: singular,
            model: model_key,
            table: table,
            fixture_set: fixture&.first,
            fixture_key: fixture&.last,
            param_key: (sp && sp[:requires]) || singular,
            attrs: attrs.sort,
            record_attrs: ((no_strong_params ? columns : attrs) - non_columns).sort,
            non_column_attrs: non_columns.sort,
            api: info[:api_controller] == true,
            json_api: info[:api_controller] == true || info[:respond_to_formats] == [ "json" ],
            unique_attrs: unique_attrs,
            table_uniques: table_uniques,
            dropped: [],
            no_strong_params: no_strong_params
          }
        end

        # The routes whose action the controller really has: one of the
        # actions rails_get_controllers lists, one its chain defines, or a view
        # template Rails renders without one. `resources` routes all seven
        # actions whatever the controller defines, and a test for one it lacks
        # fails with ActionNotFound. When the action list is unknown, every
        # route stays; the note on a skipped one names what was not read.
        #
        # @return [Array(Array<Hash>, Array<String>)] the routes kept, and the
        #   actions skipped
        def implemented_routes(ctrl_class, chain, routes)
          info = RailsAiContext::Payload.controllers(cached_context)[ctrl_class]
          actions = info.is_a?(Hash) && !info[:error] ? info[:actions] : nil
          # A gem's controller above this one (Devise::SessionsController) may define any action.
          return [ routes, [] ] unless actions.is_a?(Array) && chain && chain.unread_parent.nil?

          root = rails_app.root.to_s
          known = actions.map(&:to_s)
          kept, skipped = routes.partition do |route|
            action = (route[:action] || "index").to_s
            known.include?(action) || chain.defines?(action) ||
              RailsAiContext::Introspectors::ActionPresence.template?(root, chain, action)
          end
          [ kept, skipped.map { |route| route[:action].to_s }.uniq ]
        end

        # The controller's chain, read once for the routes and the outcomes.
        def action_chain(ctrl_class, snake)
          root = rails_app.root.to_s
          lookup = RailsAiContext::Introspectors::ActionPresence.lookup(root, RailsAiContext::Payload.controllers(cached_context))
          RailsAiContext::Introspectors::ActionPresence.read(root, ctrl_class, lookup.call(ctrl_class), prefix: snake, lookup: lookup)
        rescue => e
          RailsAiContext.debug_fail(e, nil, label: "action_chain")
        end

        def no_routes_reason(ctrl_class, res, kind)
          skipped = Array(res[:unimplemented])
          return "no routes found for #{ctrl_class}; add #{kind} once routes exist" if skipped.empty?

          "none of the routed actions (#{skipped.join(", ")}) is implemented by #{ctrl_class}"
        end

        def unimplemented_lines(ctrl_class, res)
          unread = Array(res[:chain]&.unread)
          Array(res[:unimplemented]).map do |action|
            next "# Not tested: #{action} is routed, but #{ctrl_class} defines no #{action} method or template." if unread.empty?

            "# Not tested: #{action} is routed, and no source read here defines it or a template " \
              "(#{unread.join(', ')} not read)."
          end
        end

        def generate_minitest_controller(ctrl_class, snake, routes, tests_data, res)
          file_path, existing, dir = test_path("test", :controller, snake, "test/controllers", "_controller_test.rb")

          style = RailsAiContext::TestFramework.test_style(RailsAiContext::PathResolver.test_root(rails_app.root.to_s), dir)
          res = res.merge(test_case: style[:test_case] == true)
          res[:factory] = find_factory_name(res[:model], tests_data) if style[:factories] && res[:model]
          # With neither a factory nor a fixture, the parents and the record are made up from placeholders.
          placeholders = !res[:factory] && !res[:fixture_key]
          res[:parents] = route_parents(routes, res, tests_data, ref: "@", placeholders: placeholders) if res[:factory] || placeholders
          res[:unbuildable] = unbuildable_reason(res[:model]) if placeholders
          res[:placeholder_subject] = placeholders && !placeholder_subject_literal(res).nil?
          res[:lazy_subject] = res[:placeholder_subject]

          lines = [ *existing_test_lines(existing), "# #{existing || file_path}", "", "```ruby", "# frozen_string_literal: true", "", "require \"test_helper\"", "" ]
          lines.concat(unimplemented_lines(ctrl_class, res))
          lines << "class #{ctrl_class}Test < #{res[:test_case] ? "ActionController::TestCase" : "ActionDispatch::IntegrationTest"}"

          doorkeeper = doorkeeper_controller?(ctrl_class)
          lines.concat(minitest_auth_lines(ctrl_class, tests_data, doorkeeper, res[:test_case]))

          todo_at = lines.size
          setup = minitest_setup_lines(res, tests_data, doorkeeper)
          user_key = res[:sign_in] && fixture_key_for("users", tests_data)
          setup.unshift("#{res[:sign_in]} users(:#{user_key})") if user_key
          lines.concat(login_todo_lines(ctrl_class, res)) unless user_key
          setup.unshift(devise_mapping(res, routes)) if res[:test_case]
          setup.compact!
          if setup.any?
            lines << "  setup do"
            setup.each { |l| lines << "    #{l}" }
            lines << "  end"
          end
          made_up = minitest_made_up_lines(res)
          lines << "" if made_up.any?
          made_up.each { |l| lines << (l.empty? ? l : "  #{l}") }

          name_by_path = route_names_by_path(routes)
          dedupe_routes(routes).each do |route|
            lines << "" unless lines.last == ""
            lines.concat(minitest_route_test(route, name_by_path, res, tests_data))
          end
          lines.insert(todo_at, *unknown_enum_todos(res[:dropped], res[:model]))

          if routes.empty?
            lines << "  test \"#{ctrl_class} responds\" do"
            lines << "    skip #{"TODO: #{no_routes_reason(ctrl_class, res, "tests")}".inspect}"
            lines << "  end"
          end

          lines << "end"
          lines << "```"
          lines.concat(login_note(ctrl_class, res, signed_in: user_key))
          text_response(lines.join("\n"))
        end

        # A before filter that keeps a request out until someone signs in.
        # Nothing marks one as such, so the name decides: authenticate_user!,
        # Rails 8's require_authentication, a hand-written require_login.
        LOGIN_FILTER = /\A(?:authenticate\w*|require_(?:authentication|user)|\w*(?:login|logged_in|signed_in|sign_in)\w*)[!?]?\z/

        # The login filters that run on the actions the test requests, each
        # with those actions: bazaar's OrdersController inherits require_login,
        # and every request its generated test sent came back a 302.
        def login_filters(ctrl_class, routes)
          root = rails_app.root.to_s
          found = {}
          routes.map { |route| (route[:action] || "index").to_s }.uniq.each do |action|
            RailsAiContext::ActionFilters.for(cached_context, ctrl_class, action, root: root)[:chain].each do |filter|
              next unless filter[:kind].to_s == "before" && filter[:name].to_s.match?(LOGIN_FILTER)

              (found[filter[:name].to_s] ||= { filter: filter, actions: [] })[:actions] << action
            end
          end
          found.values
        rescue => e
          RailsAiContext.debug_fail(e, [], label: "login_filters")
        end

        SIGN_IN_HELPER = /^\s*def\s+((?:sign|log)_?in(?:_as)?|login(?:_as)?)\b/

        # The sign-in helper the app's own tests define: Rails 8's generator
        # writes sign_in_as into test/test_helpers, and a hand-rolled suite
        # keeps a log_in_as in its test helper or spec/support.
        def app_sign_in_helper
          root = RailsAiContext::PathResolver.test_root(rails_app.root.to_s)
          real_root = File.realpath(root).to_s
          files = %w[test spec].flat_map do |base|
            dir = File.join(root, base)
            safe_glob(dir, "*_helper.rb", real_root) + safe_glob(dir, "{test_helpers,support}/**/*.rb", real_root)
          end
          files.first(50).each do |path|
            name = RailsAiContext::SafeFile.read(path).to_s[SIGN_IN_HELPER, 1]
            return name if name
          end
          nil
        rescue => e
          RailsAiContext.debug_fail(e, nil, label: "app_sign_in_helper")
        end

        # Whether the helper gets a request past every login filter it meets.
        # Each auth system's helper answers its own filter: the Rails 8
        # generator's sign_in_as sets the session cookie its
        # require_authentication reads, and Devise's sign_in the scope its
        # authenticate_<scope>! checks. A token check or a hand-written filter
        # it is not known to satisfy, and an ActionController::API reads no
        # session cookie at all: those get the TODO instead of a sign-in
        # every request would ignore.
        def signs_past?(helper, res)
          return false if helper.nil? || res[:api]

          models = RailsAiContext::Payload.models(cached_context)
          res[:login].all? do |login|
            name = login[:filter][:name].to_s
            case helper
            when "sign_in_as" then name == "require_authentication"
            when "sign_in" then (scope = name[/\Aauthenticate_(\w+)!\z/, 1]) && models.key?(scope.camelize)
            else false
            end
          end
        end

        def login_phrase(ctrl_class, res)
          filters = res[:login].map do |login|
            origin = login[:filter][:from_concern] || login[:filter][:from]
            "#{login[:filter][:name]}#{" (from #{origin})" if origin}"
          end
          actions = res[:login].flat_map { |login| login[:actions] }.uniq
          "#{ctrl_class} runs #{filters.join(" and ")} before #{actions.join(", ")}"
        end

        # What the test has to do that it cannot: without a signed-in user each
        # request below is redirected or refused, and the test fails for a
        # reason it does not state.
        def login_todo_lines(ctrl_class, res)
          return [] if Array(res[:login]).empty?

          how = if res[:sign_in]
            "sign in with #{res[:sign_in]} and a user from this app's own test data"
          elsif res[:helper]
            names = res[:login].map { |login| login[:filter][:name] }.join(" and ")
            "this app's #{res[:helper]} is not known to get a request past #{names}, so send what #{names} checks"
          else
            "no `sign_in` or `log_in` helper in this app's test helpers, so sign a user in first the way the app's login does"
          end
          [ "  # TODO: #{login_phrase(ctrl_class, res)}, so each request here is redirected or refused until the test signs in: #{how}." ]
        end

        def login_note(ctrl_class, res, signed_in:)
          return [] if Array(res[:login]).empty?

          signed = signed_in ? "the setup signs in with #{res[:sign_in]}" : "the requests are redirected or refused until the test signs in (see the TODO)"
          [ "", "_#{login_phrase(ctrl_class, res)}; #{signed}._" ]
        end

        # The Devise include is a fact about the app; the sign_in is only
        # emitted when the app owns a users fixture to sign in. A Doorkeeper
        # endpoint is not signed in at all, the same as the request-spec side.
        def minitest_auth_lines(ctrl_class, tests_data, doorkeeper, test_case = false)
          if doorkeeper
            return [ "  # TODO: these tests run unauthenticated; #{ctrl_class} authorizes with Doorkeeper, so pass a bearer token" ]
          end
          return [] unless devise_app?(tests_data)

          lines = [ "  include #{devise_helpers(test_case)}" ]
          unless fixture_key_for("users", tests_data)
            lines << "  # TODO: these tests run unauthenticated; sign_in a user built from this app's own test data"
          end
          lines
        end

        def minitest_setup_lines(res, tests_data, doorkeeper)
          lines = []
          if !doorkeeper && devise_app?(tests_data) && (user_key = fixture_key_for("users", tests_data))
            lines << "@user = users(:#{user_key})"
            lines << "sign_in @user"
          end
          (res[:parents] || {}).each_value { |parent| lines << "#{parent[:ref]} = #{route_parent_build(parent)}" if parent[:factory] }
          if res[:model] && res[:factory]
            lines << "#{minitest_ivar(res[:name])} = #{factory_create(res)}"
          elsif res[:model] && res[:fixture_key]
            lines << "#{minitest_ivar(res[:name])} = #{fixture_accessor(res[:fixture_set])}(:#{res[:fixture_key]})"
          end
          lines
        end

        # The test case's record: a fixture or factory ivar, or the method that makes a record up from placeholders.
        def minitest_subject(res)
          res[:placeholder_subject] ? minitest_made_up(res[:name]) : minitest_ivar(res[:name])
        end

        # A record made up from placeholders is built by the first test that asks, so one the model rejects
        # fails only the tests that need it.
        def minitest_made_up(name)
          "#{name}_record"
        end

        def minitest_made_up_lines(res)
          made = (res[:parents] || {}).values.select { |parent| parent[:record] }.map { |parent| [ parent[:ref], route_parent_build(parent) ] }
          made << [ minitest_subject(res), "#{res[:model]}.create!(#{placeholder_subject_literal(res)})" ] if res[:placeholder_subject]
          made.flat_map do |ref, build|
            [ "", "def #{ref}", "  @#{ref} ||= #{build}", "end" ]
          end.then { |lines| lines.any? ? [ "# TODO: adjust these attributes if validations reject the placeholder values", *lines.drop(1) ] : lines }
        end

        def minitest_route_test(route, name_by_path, res, tests_data)
          action = (route[:action] || "index").to_s
          subject = res[:model] && (res[:factory] || res[:fixture_key] || res[:placeholder_subject]) ? minitest_subject(res) : nil

          return minitest_generic_test(route, name_by_path, res, tests_data, subject) unless res[:model]

          case action
          when "index", "new"
            minitest_get_test(route, name_by_path, res, tests_data, "should get #{action}", subject)
          when "show"
            minitest_member_get_test(route, name_by_path, res, tests_data, "should show #{res[:name]}", subject)
          when "edit"
            minitest_member_get_test(route, name_by_path, res, tests_data, "should get edit", subject)
          when "create"
            minitest_create_test(route, name_by_path, res, tests_data, subject)
          when "update"
            minitest_update_test(route, name_by_path, res, tests_data, subject)
          when "destroy"
            minitest_destroy_test(route, name_by_path, res, tests_data, subject)
          else
            minitest_generic_test(route, name_by_path, res, tests_data, subject)
          end
        end

        def minitest_get_test(route, name_by_path, res, tests_data, label, subject)
          resolved = request_target(route, name_by_path, subject, res, tests_data)
          return minitest_skip_test(label, unresolved_reason(route, res)) unless resolved

          minitest_request_test(label, verb_for(route), resolved, res, response_assertions(route, res, :minitest))
        end

        def minitest_member_get_test(route, name_by_path, res, tests_data, label, subject)
          return minitest_skip_test(label, res[:unbuildable] || "requires a fixture for #{table_label(res)}") unless subject

          minitest_get_test(route, name_by_path, res, tests_data, label, subject)
        end

        def minitest_create_test(route, name_by_path, res, tests_data, subject)
          label = "should create #{res[:name]}"
          resolved = request_target(route, name_by_path, subject, res, tests_data)
          return minitest_skip_test(label, unresolved_reason(route, res)) unless resolved
          if res[:attrs].empty? || (!subject && unbuildable_params(res))
            return minitest_skip_test(label, no_params_reason(res, "POST #{route[:path]}"))
          end

          # A record made up from placeholders is built by the first test that asks; create must not be that test.
          copy = subject && !res[:placeholder_subject]
          if copy && (stuck = unfreshable_uniques_reason(res, res[:unique_attrs]))
            return minitest_skip_test(label, stuck)
          end

          params = request_params_literal(res, copy ? :fixture : :placeholder)
          minitest_request_test(label, "post", resolved, res,
            response_assertions(route, res, :minitest),
            params_literal: params,
            difference: "\"#{res[:model]}.count\"",
            todos: params_todos(res, params))
        end

        def minitest_update_test(route, name_by_path, res, tests_data, subject)
          label = "should update #{res[:name]}"
          return minitest_skip_test(label, res[:unbuildable] || "requires a fixture for #{table_label(res)}") unless subject

          resolved = request_target(route, name_by_path, subject, res, tests_data)
          return minitest_skip_test(label, unresolved_reason(route, res)) unless resolved
          if res[:attrs].empty?
            return minitest_skip_test(label, no_params_reason(res, "#{route[:verb]} #{route[:path]}"))
          end

          params = request_params_literal(res, :fixture)
          minitest_request_test(label, verb_for(route), resolved, res,
            response_assertions(route, res, :minitest),
            params_literal: params,
            todos: params_todos(res, params))
        end

        def minitest_destroy_test(route, name_by_path, res, tests_data, subject)
          label = "should destroy #{res[:name]}"
          return minitest_skip_test(label, res[:unbuildable] || "requires a fixture for #{table_label(res)}") unless subject

          # The test case's own record method for a made-up record is named name_record, so the local cannot be.
          local = SPEC_METHOD_NAMES.include?(res[:name]) ? "#{res[:name]}_copy" : res[:name]
          resolved = request_target(route, name_by_path, local, res, tests_data)
          return minitest_skip_test(label, unresolved_reason(route, res)) unless resolved

          if !res[:factory] && (stuck = unfreshable_uniques_reason(res, res[:table_uniques]))
            return minitest_skip_test(label, stuck)
          end

          setup_lines = if res[:factory]
            [ "#{local} = #{factory_create(res)}" ]
          else
            [
              *("# Destroy a fresh record: deleting a fixture row can violate foreign keys other fixtures hold on it." if res[:fixture_key]),
              "#{local} = #{res[:model]}.create!(#{subject}.attributes.except(\"id\", \"created_at\", \"updated_at\")#{destroy_attr_overrides(res, subject)})"
            ]
          end
          minitest_request_test(label, "delete", resolved, res,
            response_assertions(route, res, :minitest),
            difference: "\"#{res[:model]}.count\", -1",
            setup_lines: setup_lines)
        end

        def minitest_generic_test(route, name_by_path, res, tests_data, subject)
          action = (route[:action] || "index").to_s
          verb = verb_for(route)
          label = verb == "get" ? "should get #{action}" : "#{route[:verb]} #{route[:path]}"

          if verb != "get"
            return minitest_skip_test(label, "provide params and assertions for #{action}")
          end

          resolved = request_target(route, name_by_path, subject, res, tests_data)
          return minitest_skip_test(label, unresolved_reason(route, res)) unless resolved

          minitest_request_test(label, verb, resolved, res, response_assertions(route, res, :minitest))
        end

        def minitest_request_test(label, verb, resolved, res, assertion, params_literal: nil, difference: nil, setup_lines: [], todos: [])
          json = res[:json_api] ? ", as: :json" : ""
          segments = Array(resolved[:path_params]).map { |param, expr| "#{param}: #{expr}" }.join(", ")
          params = if segments.empty? then params_literal
          elsif params_literal then params_literal.sub(/\A\{ /, "{ #{segments}, ")
          else "{ #{segments} }"
          end
          params_part = params ? ", params: #{params}" : ""
          request = "#{verb} #{resolved[:url]}#{params_part}#{json}"

          out = [ "  test \"#{label}\" do" ]
          todos.each { |t| out << "    # TODO: #{t}" }
          # The record comes first: the URL prelude may read its id.
          (setup_lines + resolved[:prelude]).each { |l| out << "    #{l}" }
          if difference
            out << "    assert_difference(#{difference}) do"
            out << "      #{request}"
            out << "    end"
          else
            out << "    #{request}"
          end
          Array(assertion).each { |line| out << "    #{line}" }
          out << "  end"
          out
        end

        # A URL helper for an integration test; the action itself for an ActionController::TestCase,
        # which needs no route resolved.
        def request_target(route, name_by_path, subject, res, tests_data)
          factories = res[:factory].present?
          return url_expression(route, name_by_path, subject, res, tests_data, factories: factories) unless res[:test_case]

          action_target(route, subject, res, tests_data, factories: factories)
        end

        # The action is named, so every dynamic segment is a param: :id alone raises
        # UrlGenerationError on a nested route.
        def action_target(route, subject, res, tests_data, factories:)
          path_params = path_params_of(route).map do |param|
            expr = path_param_expr(param, subject, tests_data, factories: factories, res: res) or return nil
            [ param, expr ]
          end
          { url: ":#{route[:action] || "index"}", prelude: singular_record_prelude(route, path_params_of(route), subject, res), path_params: path_params }
        end

        def rspec_target(route, name_by_path, subject, res, tests_data)
          return action_target(route, subject, res, tests_data, factories: true) if res[:controller_spec]

          url_expression(route, name_by_path, subject, res, tests_data, factories: true)
        end

        def rspec_request(verb, resolved, body_params, json)
          pairs = Array(resolved[:path_params]).map { |param, expr| "#{param}: #{expr}" }
          pairs << body_params if body_params
          params = pairs.empty? ? "" : ", params: { #{pairs.join(", ")} }"
          "#{verb} #{resolved[:url]}#{params}#{json}"
        end

        # The segments a route requires: one inside parentheses is optional,
        # and a request that leaves it out still routes.
        def path_params_of(route)
          depth = 0
          optional = []
          route[:path].to_s.scan(/[()]|[:*]\w+/) do |token|
            case token
            when "(" then depth += 1
            when ")" then depth -= 1
            else optional << token[1..] if depth.positive?
            end
          end
          # A glob segment (*path) is required the same as a named one.
          RouteCoverage.path_params(route[:path]) - optional - [ "format" ]
        end

        OUTCOME_REASONS = {
          conditional: "The action answers differently depending on a condition, so only a server error fails this.",
          unknown: "The action is defined outside the controller's own source, so only a server error fails this."
        }.freeze

        # The assertions for what the action answers, read from its body: a
        # redirect is not a success, and neither is `head :no_content`.
        def response_assertions(route, res, framework)
          verb = verb_for(route).split("|").first
          outcome = res[:controller] ? action_outcome((route[:action] || "index").to_s, verb, res) : { kind: :render }
          rspec = framework == :rspec
          status = ->(default) { literal = outcome[:status] || default; literal.is_a?(Symbol) ? ":#{literal}" : literal.to_s }
          expect_status = ->(value) { rspec ? "expect(response).to have_http_status(#{value})" : "assert_response #{value}" }
          media = ->(type) { rspec ? "expect(response.media_type).to eq(\"#{type}\")" : "assert_equal \"#{type}\", response.media_type" }

          lines = case outcome[:kind]
          when :render, :json, :plain
            type = outcome[:content_type]
            [ expect_status.call(status.call(:success)), (media.call(type) if type.is_a?(String)) ].compact
          when :head then [ expect_status.call(status.call(:success)) ]
          when :redirect
            target = outcome[:target]
            # A bare *_path call can be a private method of the controller, which a test cannot call.
            target = nil if target && !target.start_with?('"', "'") && !Array(res[:route_names]).include?(target.sub(/_(path|url)\z/, ""))
            target &&= rspec ? "expect(response).to redirect_to(#{target})" : "assert_redirected_to #{target}"
            [ expect_status.call(status.call(:redirect)), target ].compact
          else
            [ "# #{OUTCOME_REASONS.fetch(outcome[:kind], OUTCOME_REASONS[:conditional])}",
              rspec ? "expect(response.status).to be < 500" : "assert_operator response.status, :<, 500" ]
          end
          outcome[:assumed_valid] ? [ "# Asserts the branch valid params take." ] + lines : lines
        end

        # What the action answers: read from its def in the controller's file
        # or an ancestor's, the implicit render for a template-only action,
        # and unknown for one defined somewhere else (a concern, define_method).
        def action_outcome(action, verb, res)
          res[:outcomes][[ action, verb ]] ||= begin
            methods = res[:chain]&.defs || {}
            def_node = methods[action.to_sym]
            if def_node
              RailsAiContext::ActionOutcome.of(def_node, methods, format: res[:json_api] ? :json : :html, verb: verb)
            elsif res[:chain] && RailsAiContext::Introspectors::ActionPresence.template?(rails_app.root.to_s, res[:chain], action)
              { kind: :render }
            else
              { kind: :unknown }
            end
          end
        rescue => e
          RailsAiContext.debug_fail(e, { kind: :unknown }, label: "action_outcome")
        end

        # A Devise controller reached without the router raises for want of a
        # mapping. Devise names its routes <scope>_<kind> (new_user_session),
        # whatever the controller is called.
        #
        # @return [String, nil] the statement that sets the mapping, a TODO when
        #   the scope cannot be read, nil for any other controller
        def devise_mapping(res, routes)
          stop = res[:chain]&.unread_parent
          return nil unless stop&.delete_prefix("::")&.match?(/\ADevise(Controller\z|::)/)

          scope = routes.filter_map do |route|
            route[:name]&.sub(/\A(new|edit|cancel|destroy)_/, "")&.[](/\A(\w+)_(?:session|registration|password|confirmation|unlock)\z/, 1)
          end.tally.max_by { |_, count| count }&.first
          if scope
            "@request.env[\"devise.mapping\"] = Devise.mappings[:#{scope}]"
          else
            "# TODO: set @request.env[\"devise.mapping\"] to the Devise mapping this controller serves"
          end
        end

        def minitest_skip_test(label, reason)
          [ "  test \"#{label}\" do", "    skip #{"TODO: #{reason}".inspect}", "  end" ]
        end

        # A route answering several verbs ("GET|POST", or "ANY" for `via: :all`)
        # is requested with GET when it answers GET.
        def verb_for(route)
          verbs = route[:verb].to_s.downcase.split("|")
          return "get" if verbs.empty? || verbs.include?("get") || verbs.include?("any")

          verbs.first
        end

        def unresolved_reason(route, res = {})
          stuck = path_params_of(route).filter_map { |param| (res[:parent_reasons] || {})[param] }.first
          return stuck if stuck
          if res[:test_case] || res[:controller_spec]
            return "pass #{path_params_of(route).map { |param| ":#{param}" }.join(", ")} for #{route[:verb]} #{route[:path]}"
          end

          "resolve the dynamic segments of #{route[:verb]} #{route[:path]} (no matching fixture found)"
        end

        # ── RSpec request generation ─────────────────────────────────────

        def generate_rspec_request(ctrl_class, snake, routes, tests_data, res)
          file_path, existing = test_path("spec", :controller, snake, "spec/requests", "_spec.rb")
          factory = find_factory_name(snake.singularize.camelize, tests_data)
          res = res.merge(factory: factory, lazy_subject: true)
          res[:parents] = route_parents(routes, res, tests_data, ref: "", placeholders: !factory)
          # Among the app's controller specs a new one is a controller spec
          # too, naming the action; elsewhere it is a request spec.
          res[:controller_spec] = file_path.end_with?("_controller_spec.rb")

          lines = [ *existing_test_lines(existing), "# #{existing || file_path}", "", "```ruby", "# frozen_string_literal: true", "", "require \"rails_helper\"", "" ]
          lines.concat(unimplemented_lines(ctrl_class, res))
          lines << (res[:controller_spec] ? "RSpec.describe #{ctrl_class}, type: :controller do" : "RSpec.describe \"#{ctrl_class}\", type: :request do")

          lines.concat(rspec_auth_lines(ctrl_class, tests_data, res[:controller_spec]))
          if res[:controller_spec] && (mapping = devise_mapping(res, routes))
            lines.push(mapping.start_with?("#") ? "  #{mapping}" : "  before { #{mapping} }", "")
          end
          user_factory = res[:sign_in] && find_factory_name("User", tests_data)
          if user_factory
            lines.push("  let(:user) { #{factory_bot(:create)}(:#{user_factory}) }", "  before { #{res[:sign_in]}(user) }", "")
          elsif (todo = login_todo_lines(ctrl_class, res)).any?
            lines.push(*todo, "")
          end

          res[:unbuildable] = unbuildable_reason(res[:model]) unless factory
          todo_at = lines.size
          subject_expr = rspec_subject_lines(lines, res, factory)
          attrs_available = rspec_attributes_lines(lines, res, factory)

          name_by_path = route_names_by_path(routes)
          dedupe_routes(routes).each do |route|
            lines << "" unless lines.last == ""
            lines.concat(rspec_route_test(route, name_by_path, res, tests_data, subject_expr, attrs_available))
          end
          lines.insert(todo_at, *unknown_enum_todos(res[:dropped], res[:model]))

          if routes.empty?
            lines << "  it \"has tests\" do"
            lines << "    skip #{"TODO: #{no_routes_reason(ctrl_class, res, "request specs")}".inspect}"
            lines << "  end"
          end

          lines << "end"
          lines << "```"
          lines.concat(login_note(ctrl_class, res, signed_in: user_factory))
          text_response(lines.join("\n"))
        end

        # Auth setup for a request spec. sign_in cannot authenticate a
        # Doorkeeper endpoint, and it needs a user the app can actually build,
        # so each missing piece degrades to a TODO instead of a fabricated call.
        # A test that drives the action itself (ActionController::TestCase, a
        # controller spec) signs in through Devise's ControllerHelpers; one that
        # sends a request, through IntegrationHelpers. The other one's sign_in
        # does nothing there, and every signed-in test gets a redirect.
        def devise_helpers(by_action)
          "Devise::Test::#{by_action ? "ControllerHelpers" : "IntegrationHelpers"}"
        end

        def rspec_auth_lines(ctrl_class, tests_data, controller_spec = false)
          if doorkeeper_controller?(ctrl_class)
            [ "  # TODO: these examples run unauthenticated; #{ctrl_class} authorizes with Doorkeeper, so pass a bearer token", "" ]
          elsif devise_app?(tests_data)
            lines = [ "  include #{devise_helpers(controller_spec)}", "" ]
            if (user_factory = find_factory_name("User", tests_data))
              lines << "  let(:user) { #{factory_bot(:create)}(:#{user_factory}) }"
              lines << "  before { sign_in user }"
            else
              lines << "  # TODO: these examples run unauthenticated; build a user from this app's own test data and sign_in it"
            end
            lines << ""
          else
            []
          end
        end

        # Doorkeeper is usually authorized from a lambda filter, which the
        # controller payload drops, so the class bodies are read instead.
        # The call commonly lives in an API base class, hence the walk up.
        def doorkeeper_controller?(ctrl_class)
          controllers = ((cached_context[:controllers] || {})[:controllers] || {})
          name = ctrl_class
          MAX_ANCESTRY_WALK.times do
            info = controllers[name]
            return false unless info.is_a?(Hash)
            source = info[:file] && RailsAiContext::SafeFile.read(File.join(rails_app.root, info[:file]))
            return true if source&.include?("doorkeeper_authorize!")

            name = info[:parent_class]
          end
          false
        end

        # Emits the subject let and returns the expression tests use to
        # reference a persisted record (nil when one cannot be built).
        # Methods an example calls, or rspec-rails, actionpack and Capybara call on it: a let or local of the same
        # name replaces the method, and a model called Change, Page or Response is such a name.
        SPEC_METHOD_NAMES = %w[
          get post put patch delete head request response params session cookies flash controller app record
          aggregate_failures assert assert_redirected_to assert_response assertion_delegator be before_setup change
          create_session driven_by enqueued_jobs eq expect generate_response_message have_current_path have_http_status
          integration_session method_missing page performed_jobs queue_adapter_changed_jobs redirect_to setup_fixtures visit
          skip pending include send is_expected create build build_stubbed attributes_for create_list build_list sign_in sign_out
          assert_difference assert_equal assert_kind_of assert_match assert_operator assert_respond_to assert_current_path assert_not match_array
        ].freeze

        # A model spec sends no request, so only the names its own examples and factory calls use are taken.
        MODEL_SPEC_CALLS = %w[skip pending expect is_expected eq be change create build build_stubbed attributes_for include send assert_not assert_respond_to
                              assert_kind_of match_array].freeze

        def model_let_name(name)
          MODEL_SPEC_CALLS.include?(name.to_s) ? "#{name}_record" : name.to_s
        end

        def rspec_let_name(name)
          SPEC_METHOD_NAMES.include?(name.to_s) ? "#{name}_record" : name.to_s
        end

        # Instance variables Minitest, ActiveSupport::TestCase, ActionDispatch::IntegrationTest and
        # ActionController::TestCase keep for themselves.
        TEST_CASE_IVARS = %w[
          after_run app assertions code connection_subscriber controller cookie_jar cookies diff encoders failures
          fixture_cache_key fixture_connection_pools html_document integration_session mailer mime name object
          old_perform_deliveries options parallel_executor parallelize_with passed request request_count response
          root_session routes run_cleanup_hooks saved_pool_configs simple_stubs store tagged_logger time uses_transaction view_context_class
        ].freeze

        def minitest_ivar(name)
          TEST_CASE_IVARS.include?(name.to_s) ? "@#{name}_record" : "@#{name}"
        end

        def rspec_subject_lines(lines, res, factory)
          subject = rspec_let_name(res[:name])
          if factory
            res[:parents].each_value { |parent| lines << "  let(:#{parent[:ref]}) { #{factory_bot(:create)}(:#{parent[:factory]}) }" }
            lines << "  let(:#{subject}) { #{factory_create(res)} }"
            return subject
          end
          placeholder = placeholder_subject_literal(res)
          lines << "  # TODO: adjust these attributes if validations reject the placeholder values" if placeholder || res[:parents].values.any? { |parent| parent[:record] }
          res[:parents].each_value { |parent| lines << "  let(:#{parent[:ref]}) { #{route_parent_build(parent)} }" }
          return nil unless placeholder

          if res[:non_column_attrs].any?
            lines << "  # TODO: #{res[:non_column_attrs].join(', ')} are permitted params but not columns of " \
              "#{table_label(res)}; set them the way the model expects"
          end
          lines << "  let(:#{subject}) { #{res[:model]}.create!(#{placeholder}) }"
          subject
        end

        # One TODO for each enum a made-up record, its parents or its owners left out.
        def unknown_enum_todos(dropped, model, indent = "  ")
          Array(dropped).uniq.sort.map do |key, attr|
            "#{indent}# TODO: #{key == model ? attr : "#{key}##{attr}"} is an enum whose values the source computes; set one it maps"
          end
        end

        def route_parent_build(parent)
          parent[:factory] ? "#{factory_bot(:create)}(:#{parent[:factory]})" : "#{parent[:model]}.create!(#{parent[:record]})"
        end

        # The record's attributes made up from placeholders, with every parent it requires whether or not the
        # controller permits its key; nil when no record can be made up.
        def placeholder_subject_literal(res)
          return nil unless res[:model] && res[:record_attrs].any? && !res[:unbuildable]

          passwords = password_pairs(res[:model])
          required = required_parents(res[:model]).keys + required_roles(res[:model]).values.flat_map { |id, type, _| [ id, type ] }
          attrs = (res[:record_attrs] | required | validated_attrs(res[:model])).sort - password_columns(res[:model])
          pairs = value_pairs(res, made_up(res, attrs), :placeholder)
          "{ #{(pairs + passwords).join(', ')} }"
        end

        def rspec_attributes_lines(lines, res, factory)
          if factory
            lines << "  let(:valid_attributes) { #{factory_bot(:attributes_for)}(:#{factory})#{required_parent_ids(res)} }"
            true
          elsif res[:attrs].any? && !unbuildable_params(res)
            lines << "  let(:valid_attributes) { #{placeholder_attrs_literal(res)} }"
            true
          else
            false
          end
        end

        # attributes_for leaves out every association, so a record whose
        # required parent the controller may permit by id is never saved without it.
        def required_parent_ids(res)
          pairs = required_parents(res[:model]).filter_map do |key, parent|
            next unless res[:no_strong_params] || res[:attrs].include?(key)

            factory = find_factory_name(parent, cached_context[:tests] || {})
            factory && "#{key}: #{factory_bot(:create)}(:#{factory}).id"
          end
          pairs.any? ? ".merge(#{pairs.join(', ')})" : ""
        end

        # foreign key => parent class, for each non-polymorphic belongs_to the model cannot be saved without.
        def required_parents(model_name)
          model = model_name && (cached_context[:models] || {})[model_name]
          return {} unless model.is_a?(Hash)

          required = Array(model[:validations]).select { |v| v[:implicit] && !v[:implicit_if] }.flat_map { |v| v[:attributes] }.map(&:to_s)
          Array(model[:associations]).each_with_object({}) do |a, parents|
            next unless a[:type].to_s == "belongs_to" && !a[:polymorphic] && required.include?(a[:name].to_s)

            parents[(a[:foreign_key].presence || "#{a[:name]}_id").to_s] = a[:class_name].presence || a[:name].to_s.camelize
          end
        end

        # The id of a parent created from placeholders of its own; nil for an unknown model or one already being built.
        def placeholder_parent(res, attr)
          parent = required_parents(res[:model])[attr] or return nil
          key = fuzzy_find_key((cached_context[:models] || {}).keys, parent) or return nil
          record = placeholder_record(key, Array(res[:seen]) + [ res[:model] ], res[:dropped]) or return nil
          "#{key}.create!(#{record}).id"
        end

        # role => [id key, type key, the model a has_many or has_one names it on with `as:`] for each required
        # polymorphic belongs_to; the first by name when several fill the role, an STI base before its subclasses.
        # Every placeholder asks, so the run keeps the answer.
        def required_roles(model_name)
          RailsAiContext::RunCache.fetch([ :required_roles, model_name ]) { scan_required_roles(model_name) }
        end

        def scan_required_roles(model_name)
          model = model_name && (cached_context[:models] || {})[model_name]
          return {} unless model.is_a?(Hash)

          required = Array(model[:validations]).select { |v| v[:implicit] && !v[:implicit_if] }.flat_map { |v| v[:attributes] }.map(&:to_s)
          models = cached_context[:models] || {}
          Array(model[:associations]).each_with_object({}) do |a, roles|
            next unless a[:type].to_s == "belongs_to" && a[:polymorphic] && required.include?(a[:name].to_s)

            role = a[:name].to_s
            owners = models.keys.sort.select do |key|
              models[key].is_a?(Hash) && Array(models[key][:associations]).any? { |o| %w[has_many has_one].include?(o[:type].to_s) && o[:as].to_s == role }
            end
            owner = owners.find { |key| !owners.include?(sti_parent(key)) }
            roles[role] = [ (a[:foreign_key].presence || "#{role}_id").to_s, (a[:foreign_type].presence || "#{role}_type").to_s, owner ]
          end
        end

        def sti_parent(key)
          model = (cached_context[:models] || {})[key]
          model.is_a?(Hash) ? (model[:sti] || {})[:sti_parent] : nil
        end

        # The class Rails stores as a polymorphic type: the top of the STI chain the app's models show.
        def sti_base(key, seen = [])
          parent = sti_parent(key)
          parent && (cached_context[:models] || {}).key?(parent) && !seen.include?(parent) ? sti_base(parent, seen + [ key ]) : key
        end

        # Why no record can be made up: a required polymorphic role no model fills, on the model or on a parent or
        # owner it cannot be saved without.
        def unbuildable_reason(model_name, seen = [])
          return nil if seen.include?(model_name)

          roles = required_roles(model_name)
          role, = roles.find { |_, (_, _, owner)| owner.nil? }
          return "#{model_name} belongs_to :#{role}, polymorphic: true, and no model declares has_many or has_one ..., as: :#{role}" if role

          own = model_block(model_name) || attr_blocks(model_name).values.first
          return own if own

          models = cached_context[:models] || {}
          upstream = required_parents(model_name).values.filter_map { |parent| fuzzy_find_key(models.keys, parent) } + roles.values.filter_map(&:last)
          upstream.each do |key|
            reason = unbuildable_reason(key, seen + [ model_name ]) and return reason
          end
          nil
        end

        # A reason that holds for every attribute: a table whose columns are unknown, or a validation written as code.
        def model_block(model_name)
          model = (cached_context[:models] || {})[model_name]
          return nil unless model.is_a?(Hash)

          if RailsAiContext::Payload.model_table(cached_context, model_name).then { |answer| answer.table.nil? && answer.set_by }
            return "#{model_name} has a table name the source computes, so its columns are unknown here; supply the attributes it needs"
          end

          custom = Array(model[:custom_validates]).map(&:to_s)
          custom << "block" if Array(model[:custom_validate_blocks]).any?
          return "#{model_name} runs the custom validation #{custom.join(', ')}; supply a record that passes it" if custom.any?

          unread_rule(model_name)
        end

        RULE_OPTIONS = {
          "presence" => [], "absence" => [], "uniqueness" => %i[scope case_sensitive], "inclusion" => %i[in within], "exclusion" => %i[in within],
          "length" => %i[minimum maximum is in within too_short too_long wrong_length],
          "numericality" => %i[greater_than greater_than_or_equal_to less_than less_than_or_equal_to equal_to only_integer in other_than not_a_number not_an_integer],
          "acceptance" => %i[accept], "confirmation" => %i[case_sensitive], "format" => %i[with without multiline]
        }.freeze
        COMMON_RULE_OPTIONS = %i[message on if unless strict allow_nil allow_blank].freeze
        PROC_SOURCE = /\A\(proc\)\z|\A\s*(?:->|lambda\b|proc\b|Proc\.new)/

        # The first create-time rule of the model the gem does not read completely: a kind it does not know, a validator
        # class, an option it does not honor, a lambda or proc anywhere in the rule, a list it cannot read.
        def unread_rule(model_name)
          model = (cached_context[:models] || {})[model_name]
          Array(model[:validations]).each do |v|
            next if v[:implicit] || !runs_on_create?(v)

            reason = unread_reason(model_name, model, v) and return reason
          end
          nil
        end

        def runs_on_create?(rule)
          on = rule.dig(:options, :on)
          on.nil? || Array(on).map(&:to_s).include?("create")
        end

        def unread_reason(model_name, model, rule)
          kind = rule[:kind].to_s
          options = rule[:options] || {}
          attrs = Array(rule[:attributes]).map(&:to_s)
          return "#{model_name} runs validates_with #{rule[:validator]}".strip + "; supply a record that passes it" if kind == "validates_with"
          return "#{model_name} validates #{kind} of #{attrs.join(', ')}, which the gem cannot evaluate; supply a record that passes it" unless RULE_OPTIONS.key?(kind)

          proc_key, = options.find { |_, value| Array(value).any? { |item| item.is_a?(Proc) || item.to_s.match?(PROC_SOURCE) } }
          return "#{model_name} validates #{kind} of #{attrs.join(', ')} with a lambda or proc in the #{proc_key} option; supply a record that passes it" if proc_key

          other = (options.keys.map(&:to_sym) - COMMON_RULE_OPTIONS - RULE_OPTIONS[kind]).first
          return "#{model_name} validates #{kind} of #{attrs.join(', ')} with the option #{other}, which the gem does not honor; supply a value that passes it" if other

          list = options[:in] || options[:within]
          return nil unless %w[inclusion exclusion].include?(kind) && !readable_list?(list)
          return nil if kind == "inclusion" && (options[:allow_nil] || options[:allow_blank] || attrs.any? { |attr| (model[:enums] || {}).key?(attr) || (model[:enums] || {}).key?(attr.to_sym) })

          "#{model_name} validates #{kind} of #{attrs.join(', ')} against a list the gem cannot read; supply a value that passes it"
        end

        def readable_list?(list)
          list.is_a?(Array) || list.is_a?(Range) || !range_of(list).nil?
        end

        # A Range of numbers from a Range, or from the "1..5" the model payload carries.
        def range_of(value)
          return value if value.is_a?(Range)

          found = value.to_s.match(/\A\(?\s*(-?\d+(?:\.\d+)?)\s*(\.\.\.?)\s*(-?\d+(?:\.\d+)?)\s*\)?\z/) or return nil
          to_number = ->(text) { text.include?(".") ? text.to_f : text.to_i }
          Range.new(to_number.(found[1]), to_number.(found[3]), found[2] == "...")
        end

        # attribute => reason, for each attribute some validation of the model allows no value the gem can make up.
        def attr_blocks(model_name)
          RailsAiContext::RunCache.fetch([ :attr_blocks, model_name ]) do
            attrs = validated_attrs(model_name, all: true)
            attrs.to_h { |attr| [ attr, validity(model_name, attr) ] }.select { |_, found| found&.first == :stuck }.transform_values(&:last)
          end
        end

        # The id and type keys of the roles, the keys of the parents and the attributes the record cannot be given.
        def unbuildable_keys(model_name)
          models = cached_context[:models] || {}
          roles = required_roles(model_name).values
          parents = required_parents(model_name).select { |_, parent| (key = fuzzy_find_key(models.keys, parent)) && unbuildable_reason(key, [ model_name ]) }.keys
          stuck = roles.select { |(_, _, owner)| owner.nil? || unbuildable_reason(owner, [ model_name ]) }
          stuck.flat_map { |id, type, _| [ id, type ] } + parents + attr_blocks(model_name).keys
        end

        # The reason params cannot be made up: they send a key the record cannot be given, or the model cannot be
        # saved from any. A controller that sets the owner itself permits neither.
        def unbuildable_params(res)
          res[:unbuildable] if res[:model] && (model_block(res[:model]) || (res[:attrs] & unbuildable_keys(res[:model])).any?)
        end

        # The owner's id for a role's id key, its class name for the type key.
        def placeholder_role(res, attr)
          _, (id_key, type_key, owner) = required_roles(res[:model]).find { |_, (id, type, found)| found && [ id, type ].include?(attr) }
          return nil unless owner
          return sti_base(owner).inspect if attr == type_key

          record = attr == id_key && placeholder_record(owner, Array(res[:seen]) + [ res[:model] ], res[:dropped])
          record && "#{owner}.create!(#{record}).id"
        end

        PLACEHOLDER_PASSWORD = "\"password123\""

        # The attributes literal a `key` record saves with when made up from nothing; nil for one already being built.
        # An STI subclass names itself in the type column, which the base class leaves to Rails.
        def placeholder_record(key, seen = [], dropped = nil)
          return nil if seen.include?(key) || unbuildable_reason(key)

          model = (cached_context[:models] || {})[key]
          model = {} unless model.is_a?(Hash)
          table = RailsAiContext::Payload.model_table(cached_context, key).table
          columns = schema_content_columns(table)
          type_column = ((model[:sti] || {})[:type_column] || "type").to_s
          typed = columns.include?(type_column) && (model[:sti] || {})[:sti_parent]
          columns -= [ type_column, *password_columns(key) ]
          uniques = Array(model[:validations]).select { |v| v[:kind] == "uniqueness" }.flat_map { |v| Array(v[:attributes]).map(&:to_s) }
          record = { model: key, table: table, unique_attrs: (uniques + unique_index_columns(table)).uniq & columns, seen: seen, dropped: dropped }
          pairs = value_pairs(record, made_up(record, columns).sort, :placeholder)
          pairs << "#{type_column}: #{key.inspect}" if typed
          pairs.concat(password_pairs(key))
          "{ #{pairs.join(', ')} }"
        end

        # The password and its confirmation a made-up record is saved with.
        def password_pairs(model_name)
          password_attributes(model_name).flat_map { |name| [ "#{name}: #{PLACEHOLDER_PASSWORD}", "#{name}_confirmation: #{PLACEHOLDER_PASSWORD}" ] }
        end

        # The columns that hold a password's digest, which a made-up record leaves to the password.
        def password_columns(model_name)
          password_attributes(model_name).empty? ? [] : [ "encrypted_password", *password_attributes(model_name).map { |name| "#{name}_digest" } ]
        end

        # The password attributes has_secure_password or Devise's database authentication validates on create.
        def password_attributes(model_name)
          model = (cached_context[:models] || {})[model_name]
          model = {} unless model.is_a?(Hash)
          names = Array(model[:secure_passwords]).map { |pw| (pw[:attribute] || "password").to_s }
          names << "password" if names.empty? && model[:has_secure_password]
          names << "password" if Array(model[:concerns]).include?("Devise::Models::DatabaseAuthenticatable")
          names.uniq
        end

        def rspec_route_test(route, name_by_path, res, tests_data, subject_expr, attrs_available)
          action = (route[:action] || "index").to_s
          verb = verb_for(route)
          body =
            case action
            when "index", "new"
              rspec_get_body(route, name_by_path, res, tests_data, nil, "returns success")
            when "show", "edit"
              if subject_expr || recordless?(route, res)
                rspec_get_body(route, name_by_path, res, tests_data, subject_expr, "returns success")
              else
                rspec_skip_body("returns success", no_record_reason(res))
              end
            when "create"
              rspec_create_body(route, name_by_path, res, tests_data, attrs_available)
            when "update"
              rspec_update_body(route, name_by_path, res, tests_data, subject_expr, attrs_available)
            when "destroy"
              rspec_destroy_body(route, name_by_path, res, tests_data, subject_expr)
            else
              if verb == "get"
                rspec_get_body(route, name_by_path, res, tests_data, subject_expr, "returns success")
              else
                rspec_skip_body("handles #{action}", "provide params and assertions for #{action}")
              end
            end

          out = [ "  describe \"#{route[:verb]} #{route[:path]}\" do" ]
          out.concat(body.map { |l| l.empty? ? l : "  #{l}" })
          out << "  end"
          out
        end

        # The route's own verb: `post 'orders/edit' => 'orders#edit'` is an
        # edit action reached with POST, and the example sent a GET.
        def rspec_get_body(route, name_by_path, res, tests_data, subject_expr, label)
          resolved = rspec_target(route, name_by_path, subject_expr, res, tests_data)
          return rspec_skip_body(label, unresolved_reason(route, res)) unless resolved

          json = res[:json_api] ? ", as: :json" : ""
          out = [ "  it \"#{label}\" do" ]
          resolved[:prelude].each { |l| out << "    #{l}" }
          out << "    #{rspec_request(verb_for(route), resolved, nil, json)}"
          response_assertions(route, res, :rspec).each { |line| out << "    #{line}" }
          out << "  end"
          out
        end

        # No permitted attributes to send. A controller with no *_params
        # method may still permit inline in the action, or read none at all.
        def no_record_reason(res)
          return res[:unbuildable] if res[:unbuildable]
          return "requires a persisted #{res[:name]} record, and #{res[:controller]} has no model of its own to build one from" unless res[:model]

          "requires a persisted #{res[:name]} record"
        end

        # A page of a controller with no model and no :id (a singular dashboard) needs no record.
        def recordless?(route, res)
          !res[:model] && !path_params_of(route).include?("id")
        end

        def no_params_reason(res, request = nil)
          return unbuildable_params(res) if unbuildable_params(res)

          unless res[:no_strong_params]
            return "no permitted attributes detected; fill in valid params#{" for #{request}" if request}"
          end

          "#{res[:controller]} has no *_params method; send the #{res[:param_key]} params the action permits, if any, " \
            "before #{request || "the request"}"
        end

        def rspec_create_body(route, name_by_path, res, tests_data, attrs_available)
          label = "creates a new #{res[:model] || res[:name]}"
          return rspec_skip_body(label, no_params_reason(res)) unless attrs_available && res[:model]

          resolved = rspec_target(route, name_by_path, nil, res, tests_data)
          return rspec_skip_body(label, unresolved_reason(route, res)) unless resolved

          json = res[:json_api] ? ", as: :json" : ""
          out = [ "  it \"#{label}\" do" ]
          resolved[:prelude].each { |l| out << "    #{l}" }
          out << "    expect {"
          out << "      #{rspec_request("post", resolved, "#{res[:param_key]}: valid_attributes", json)}"
          out << "    }.to change(#{res[:model]}, :count).by(1)"
          response_assertions(route, res, :rspec).each { |line| out << "    #{line}" }
          out << "  end"
          out
        end

        def rspec_update_body(route, name_by_path, res, tests_data, subject_expr, attrs_available)
          label = "updates the #{res[:name]}"
          return rspec_skip_body(label, no_record_reason(res)) unless subject_expr
          return rspec_skip_body(label, no_params_reason(res)) unless attrs_available

          resolved = rspec_target(route, name_by_path, subject_expr, res, tests_data)
          return rspec_skip_body(label, unresolved_reason(route, res)) unless resolved

          json = res[:json_api] ? ", as: :json" : ""
          out = [ "  it \"#{label}\" do" ]
          resolved[:prelude].each { |l| out << "    #{l}" }
          out << "    #{rspec_request(verb_for(route), resolved, "#{res[:param_key]}: valid_attributes", json)}"
          response_assertions(route, res, :rspec).each { |line| out << "    #{line}" }
          out << "  end"
          out
        end

        def rspec_destroy_body(route, name_by_path, res, tests_data, subject_expr)
          label = "destroys the #{res[:name]}"
          return rspec_skip_body(label, no_record_reason(res)) unless subject_expr && res[:model]

          resolved = rspec_target(route, name_by_path, "record", res, tests_data)
          return rspec_skip_body(label, unresolved_reason(route, res)) unless resolved
          if (stuck = unfreshable_uniques_reason(res, res[:table_uniques]))
            return rspec_skip_body(label, stuck)
          end

          json = res[:json_api] ? ", as: :json" : ""
          out = [ "  it \"#{label}\" do" ]
          out << "    record = #{res[:model]}.create!(#{subject_expr}.attributes.except(\"id\", \"created_at\", \"updated_at\")#{destroy_attr_overrides(res, subject_expr)})"
          resolved[:prelude].each { |l| out << "    #{l}" }
          out << "    expect {"
          out << "      #{rspec_request("delete", resolved, nil, json)}"
          out << "    }.to change(#{res[:model]}, :count).by(-1)"
          response_assertions(route, res, :rspec).each { |line| out << "    #{line}" }
          out << "  end"
          out
        end

        def rspec_skip_body(label, reason)
          [ "  it \"#{label}\" do", "    skip #{"TODO: #{reason}".inspect}", "  end" ]
        end

        # ── Route and params helpers ─────────────────────────────────────

        # Scaffolds test each action once; keep one route per action (PATCH
        # wins over PUT for update).
        def dedupe_routes(routes)
          chosen = {}
          routes.each do |r|
            action = (r[:action] || "index").to_s
            existing = chosen[action]
            chosen[action] = r if existing.nil? || (existing[:verb] == "PUT" && r[:verb] == "PATCH")
          end
          chosen.values.sort_by.with_index do |r, i|
            [ RESTFUL_ACTION_ORDER.index((r[:action] || "").to_s) || RESTFUL_ACTION_ORDER.size, i ]
          end
        end

        # Unnamed routes (POST/PATCH/DELETE in a resources block) share their
        # path with a named sibling; borrow that sibling's helper name.
        def route_names_by_path(routes)
          routes.each_with_object({}) do |r, map|
            map[r[:path]] ||= r[:name] if r[:name]
          end
        end

        # Resolve a route to a helper call (articles_url, article_url(@article))
        # or an interpolated path string when the route has no helper name.
        # Returns { url:, prelude: } or nil when a dynamic segment cannot be
        # satisfied from test data.
        def url_expression(route, name_by_path, subject_expr, res, tests_data, factories: false)
          params = path_params_of(route)
          args = params.map do |p|
            expr = path_param_expr(p, subject_expr, tests_data, factories: factories, res: res)
            return nil unless expr
            expr
          end

          helper = route[:name] || name_by_path[route[:path]]
          if helper
            url = args.empty? ? "#{helper}_url" : "#{helper}_url(#{args.join(', ')})"
            { url: url, prelude: singular_record_prelude(route, params, subject_expr, res) }
          else
            # A record's id is its key; a column value is already the segment.
            prelude = singular_record_prelude(route, params, subject_expr, res) + params.each_with_index.map { |p, i| "#{p} = #{args[i]}#{".id" if p == "id" || p.end_with?("_id")}" }
            path = route[:path] || "/#{res[:table] || res[:name].pluralize}"
            path = path.gsub(/\([^()]*\)/, "") while path.match?(/\([^()]*\)/)
            quoted = path.gsub(RouteCoverage::PATH_PARAM, "\#{\\1}")
            { url: "\"#{quoted}\"", prelude: prelude }
          end
        end

        # A singular resource has no :id, so nothing in its request builds the record its action reads: a let
        # or a made-up record's method is called first.
        def singular_record_prelude(route, params, subject_expr, res)
          member = %w[show edit update].include?(route[:action].to_s)
          member && res[:lazy_subject] && subject_expr && !params.include?("id") ? [ subject_expr ] : []
        end

        # Dynamic path segments come from the subject record (:id) or a parent
        # record (:parent_id), built by factory or fixture, whichever the test uses.
        def path_param_expr(param, subject_expr, tests_data, factories: false, res: {})
          if param == "id"
            subject_expr
          elsif param.end_with?("_id")
            parent = param.delete_suffix("_id")
            built = (res[:parents] || {})[param]
            owned = owned_parent(parent, res)
            if built
              built[:ref]
            elsif subject_expr && owned && !factories
              "#{subject_expr}.#{owned}"
            elsif factories
              factory = find_factory_name(parent.camelize, tests_data)
              factory && "#{factory_bot(:create)}(:#{factory})"
            else
              key = fixture_key_for(parent.pluralize, tests_data)
              key && "#{parent.pluralize}(:#{key})"
            end
          else
            column_value(param, subject_expr, res)
          end
        end

        # A segment that names a column of the record the test builds, or of a
        # route parent it builds, is that record's attribute: an app may route
        # `graph/file/:uid/:id` to csvfiles, whose rows carry a uid.
        def column_value(param, subject_expr, res)
          return "#{subject_expr}.#{param}" if subject_expr && res[:table] && !schema_column_type(res[:table], param).empty?

          owner = (res[:parents] || {}).values.find do |parent|
            !schema_column_type(parent_table(parent[:name]), param).empty?
          end
          owner && "#{owner[:ref]}.#{param}"
        end

        # A table the source computes is unknown here; the model names it instead, as the model test's TODO does.
        def table_label(res)
          res[:table] || res[:model] || res[:name].camelize
        end

        def parent_table(parent)
          RailsAiContext::Payload.model_table(cached_context, parent.camelize).table
        end

        # Each parent is built once so every request names the same one. `ref` is an ivar in
        # minitest, a let in RSpec.
        # With `placeholders`, a parent no factory builds is created from placeholders of its own.
        def route_parents(routes, res, tests_data, ref:, placeholders: false)
          params = Array(routes).flat_map { |route| path_params_of(route) }.uniq.select { |param| param.end_with?("_id") }
          params.filter_map do |param|
            parent = param.delete_suffix("_id")
            factory = find_factory_name(parent.camelize, tests_data)
            fixture = !factory && !ref.empty? && fixture_key_for(parent.pluralize, tests_data)
            model = !factory && !fixture && placeholders && fuzzy_find_key((cached_context[:models] || {}).keys, parent.camelize)
            record = model && placeholder_record(model, [ res[:model] ], res[:dropped])
            (res[:parent_reasons] ||= {})[param] = unbuildable_reason(model) if model && !record && unbuildable_reason(model)
            next unless factory || fixture || record

            name = parent.tr("/", "_")
            [ param, { name: parent, ref: parent_ref(name, ref, factory, fixture),
                       factory: factory, fixture: fixture.presence, model: model, record: record, assoc: owned_parent(parent, res) } ]
          end.to_h
        end

        # A fixture is read as it is; a factory's record is an ivar of the minitest setup, a made-up one a method.
        def parent_ref(name, ref, factory, fixture)
          return "#{name.pluralize}(:#{fixture})" if fixture
          return rspec_let_name(name) if ref.empty?

          factory ? minitest_ivar(name) : minitest_made_up(name)
        end

        # The route parent's id for the key of the association the record is found through, its class for a
        # polymorphic one's type key.
        def route_parent_value(res, attr)
          model = res[:model] && (cached_context[:models] || {})[res[:model]]
          return nil unless model.is_a?(Hash)

          (res[:parents] || {}).each_value do |parent|
            assoc = Array(model[:associations]).find { |a| a[:type].to_s == "belongs_to" && a[:name].to_s == parent[:assoc].to_s } or next
            return "#{parent[:ref]}.id" if attr == (assoc[:foreign_key].presence || "#{assoc[:name]}_id").to_s

            owner = parent[:model] || fuzzy_find_key((cached_context[:models] || {}).keys, parent[:name].camelize)
            return sti_base(owner).inspect if assoc[:polymorphic] && owner && attr == (assoc[:foreign_type].presence || "#{assoc[:name]}_type").to_s
          end
          nil
        end

        # The record's factory call, attached to each route parent it is found
        # through, so a controller that scopes by the parent finds it.
        def factory_create(res)
          attach = (res[:parents] || {}).values.select { |parent| parent[:assoc] }
                                         .map { |parent| ", #{parent[:assoc]}: #{parent[:ref]}" }.join
          "#{factory_bot(:create)}(:#{res[:factory]}#{attach})"
        end

        # One named for the parent, else the record's only polymorphic owner. A controller that
        # finds the record through its parent 404s on any other parent.
        def owned_parent(parent, res)
          model = res[:model] && (cached_context[:models] || {})[res[:model]]
          belongs = Array(model.is_a?(Hash) ? model[:associations] : nil).select { |a| a[:type].to_s == "belongs_to" }
          named = belongs.find { |a| a[:name].to_s == parent || a[:foreign_key].to_s == "#{parent}_id" }
          return named[:name].to_s if named

          polymorphic = belongs.select { |a| a[:polymorphic] }
          polymorphic.one? ? polymorphic.first[:name].to_s : nil
        end

        # Build the params hash literal for create/update, copying attribute
        # values from the fixture record the way Rails scaffold tests do.
        def request_params_literal(res, value_source)
          attrs = value_source == :placeholder || res[:placeholder_subject] ? made_up(res, res[:attrs]) : res[:attrs]
          "{ #{res[:param_key]}: { #{value_pairs(res, attrs, value_source).join(', ')} } }"
        end

        def attr_value_expr(res, attr, value_source)
          if password_param?(res, attr)
            PLACEHOLDER_PASSWORD
          elsif value_source == :fixture && res[:unique_attrs].include?(attr) && (fresh = fresh_unique_value(res, minitest_subject(res), attr))
            # Unique values must differ from every fixture row; a prefix on the
            # fixture's own value keeps a format validation passing.
            fresh
          elsif res[:unique_attrs].include?(attr) && %w[string text].include?(schema_column_type(res[:table], attr))
            # An email column made up from nothing is an address, so an email format passes.
            "\"#{attr}-\#{SecureRandom.hex(4)}#{"@example.com" if attr.end_with?("email")}\""
          elsif value_source == :fixture
            "#{minitest_subject(res)}.#{attr}"
          else
            route_parent_value(res, attr) || placeholder_parent(res, attr) || placeholder_role(res, attr) || valid_value(res, attr) ||
              listed_value(res, attr) || placeholder_for_type(res, attr)
          end
        end

        # What the model's validations say, or what the confirmation rule it is the field of says.
        def valid_value(res, attr)
          found = res[:model] && validity(res[:model], attr)
          return found.last if found&.first == :value

          base = confirmed_attr(res, attr) and (value = attr_value_expr(res, base, :placeholder)) && !value.include?("SecureRandom") ? value : nil
        end

        # The type's placeholder; nil for an attribute that is no column, which is left out rather than written as nil.
        def placeholder_for_type(res, attr)
          type = schema_column_type(res[:table], attr).to_s
          type.empty? && res[:table] ? nil : PLACEHOLDER_VALUES.fetch(type, "nil")
        end

        # attribute: value pairs for the attributes that have a value.
        def value_pairs(res, attrs, value_source)
          attrs.filter_map do |attr|
            value = attr_value_expr(res, attr, value_source)
            "#{attr}: #{value}" if value
          end
        end

        # A fixture holds a password's digest only, so the password a request sends is made up.
        def password_param?(res, attr)
          names = password_attributes(res[:model])
          names.include?(attr) || names.map { |name| "#{name}_confirmation" }.include?(attr)
        end

        VALUE_RULES = %w[presence uniqueness inclusion exclusion length numericality acceptance confirmation format absence].freeze
        FORMAT_SAMPLES = [ "a@example.com", "1", "123", "https://example.com", "a1", "abc" ].freeze

        # The attributes the model's validations name, apart from a required belongs_to and a password.
        def validated_attrs(model_name, all: false)
          model = (cached_context[:models] || {})[model_name]
          return [] unless model.is_a?(Hash)

          names = Array(model[:validations]).reject { |v| v[:implicit] || (!all && !%w[presence length numericality acceptance format absence].include?(v[:kind].to_s)) }
                                            .flat_map { |v| Array(v[:attributes]).map(&:to_s) }.uniq
          names - password_attributes(model_name).flat_map { |name| [ name, "#{name}_confirmation" ] } - belongs_names(model_name)
        end

        def belongs_names(model_name)
          model = (cached_context[:models] || {})[model_name]
          Array(model.is_a?(Hash) ? model[:associations] : nil).select { |a| a[:type].to_s == "belongs_to" }.map { |a| a[:name].to_s }
        end

        # How the model's validations say an attribute is made up: [:value, literal], [:omit] to leave it out,
        # [:stuck, reason] when no value the gem can make up passes them, nil when they leave it free.
        def validity(model_name, attr)
          RailsAiContext::RunCache.fetch([ :validity, model_name, attr ]) { scan_validity(model_name, attr) }
        end

        def scan_validity(model_name, attr)
          model = (cached_context[:models] || {})[model_name]
          rules = Array(model.is_a?(Hash) ? model[:validations] : nil).select do |v|
            !v[:implicit] && Array(v[:attributes]).map(&:to_s).include?(attr) && v.dig(:options, :on).to_s != "update"
          end
          return nil if rules.empty? || (password_attributes(model_name) + belongs_names(model_name)).include?(attr)

          kinds = rules.map { |v| v[:kind].to_s }
          table = RailsAiContext::Payload.model_table(cached_context, model_name).table
          type = schema_column_type(table, attr)
          unknown = (kinds - VALUE_RULES).first
          return [ :stuck, "#{model_name} validates #{unknown} of #{attr}, which the gem cannot evaluate; supply a record that passes it" ] if unknown
          return [ :omit ] if kinds.include?("absence")
          return [ :value, acceptance_value(rules, type) ] if kinds.include?("acceptance")

          if type.empty?
            return nil if (kinds - %w[confirmation uniqueness inclusion exclusion]).empty?

            return [ :stuck, "#{model_name} validates #{(kinds - %w[uniqueness]).first} of #{attr}, which is not a column; supply it (an attachment, for one)" ]
          end

          options = ->(kind) { rules.select { |v| v[:kind].to_s == kind }.map { |v| v[:options] || {} } }
          inclusion = options.("inclusion").find { |o| !readable_list?(o[:in] || o[:within]) && !(model[:enums] || {}).key?(attr) }
          return [ :omit ] if inclusion

          if %w[string text].include?(type)
            string_validity(model_name, attr, type, options.("length"), options.("format"), options.("numericality"), table)
          elsif kinds.include?("numericality")
            numeric_validity(model_name, attr, type, options.("numericality"))
          end
        end

        def acceptance_value(rules, type)
          accepted = rules.filter_map { |v| v.dig(:options, :accept) }.first
          return Array(accepted).first.inspect if accepted && !(type == "boolean" && Array(accepted).include?(true))

          type == "boolean" ? "true" : '"1"'
        end

        # [minimum, maximum] a length rule allows; `in` and `within` give a range.
        def length_bounds(lengths)
          bounds = lengths.map do |o|
            range = range_of(o[:in] || o[:within])
            [ o[:minimum] || o[:is] || range&.begin, o[:maximum] || o[:is] || (range && (range.exclude_end? ? range.end - 1 : range.end)) ]
          end
          [ bounds.filter_map(&:first).select { |n| n.is_a?(Integer) }.max, bounds.filter_map(&:last).select { |n| n.is_a?(Integer) }.min ]
        end

        def string_validity(model_name, attr, type, lengths, formats, numerics, table)
          min, max = length_bounds(lengths)
          fits = ->(text) { (min.nil? || text.length >= min) && (max.nil? || text.length <= max) }
          unique = unique_columns(model_name, table).include?(attr)
          return nil if lengths.empty? && formats.empty? && numerics.empty?

          base = type == "text" ? "MyText" : "MyString"
          matchers = formats.map { |o| format_matcher(attr, o) }
          numeric = numerics.any? ? numeric_bounds(numerics) : nil
          samples =
            if unique then [ "#{attr}-0a1b2c3d#{'@example.com' if attr.end_with?('email')}" ]
            elsif numeric then numeric_strings(numerics, numeric, min)
            elsif formats.empty? then [ (base + "x" * [ (min || 0) - base.length, 0 ].max)[0, max || 1_000] ]
            else [ base, *FORMAT_SAMPLES ]
            end
          found = samples.find do |text|
            fits.(text) && matchers.all? { |match| match&.call(text) } && (numeric.nil? || (Float(text, exception: false) && numeric[:ok].(Float(text))))
          end
          return unique ? nil : [ :value, found.inspect ] if found

          return [ :omit ] if !unique && numerics.empty? && formats.any? && formats.all? { |o| o[:allow_blank] || o[:allow_nil] }

          pattern = formats.map { |o| o[:with] || o[:without] }.compact.join(", ")
          return [ :stuck, "#{model_name} validates format of #{attr}#{" (#{pattern})" unless pattern.empty?}; supply a value it accepts" ] if formats.any?

          [ :stuck, "#{model_name} validates numericality and length of #{attr} together, and no value the gem can make up meets both; supply a value it accepts" ]
        end

        # A callable that tells whether a text passes one format rule, nil where the pattern cannot be read.
        def format_matcher(attr, options)
          source = (options[:with] || options[:without]).to_s
          pattern = if source == "URI::MailTo::EMAIL_REGEXP" then URI::MailTo::EMAIL_REGEXP
          elsif source.start_with?("/") && (body = source[%r{\A/(.*)/([imx]*)\z}m, 1])
            Regexp.new(body, source[%r{/([imx]*)\z}, 1].to_s.each_char.sum { |flag| { "i" => 1, "x" => 2, "m" => 4 }[flag] })
          elsif source.empty? && attr.end_with?("email") then URI::MailTo::EMAIL_REGEXP
          end
          return nil unless pattern

          options[:without] ? ->(text) { !pattern.match?(text) } : ->(text) { pattern.match?(text) }
        rescue RegexpError
          nil
        end

        # The bounds a numericality rule sets and a test of a number against them, nil where a bound is no number.
        def numeric_bounds(rules)
          integer = rules.any? { |o| o[:only_integer] }
          pairs = rules.flat_map do |o|
            range = range_of(o[:in])
            ranged = range ? [ [ :greater_than_or_equal_to, range.begin ], [ range.exclude_end? ? :less_than : :less_than_or_equal_to, range.end ] ] : []
            o.slice(:greater_than, :greater_than_or_equal_to, :less_than, :less_than_or_equal_to, :equal_to, :other_than).to_a + ranged
          end
          return nil unless pairs.all? { |_, v| v.is_a?(Numeric) }

          ok = lambda do |n|
            (!integer || n == n.to_i) && pairs.all? do |key, v|
              { greater_than: n > v, greater_than_or_equal_to: n >= v, less_than: n < v, less_than_or_equal_to: n <= v, equal_to: n == v, other_than: n != v }[key]
            end
          end
          { integer: integer, pairs: pairs, ok: ok }
        end

        # Numbers inside the bounds, each as a string at least `min` long (zeros after it, then before it).
        def numeric_strings(rules, numeric, min)
          candidates = [ 1, *numeric[:pairs].flat_map { |key, v| %i[greater_than less_than].include?(key) ? [ key == :greater_than ? v + 1 : v - 1 ] : [ v, v + 1 ] } ]
          candidates.map { |n| n.to_i }.uniq.flat_map do |n|
            text = n.to_s
            short = min && text.length < min ? min - text.length : 0
            short.positive? ? [ text + "0" * short, "0" * short + text ] : [ text ]
          end
        end

        def numeric_validity(model_name, attr, type, rules)
          numeric = numeric_bounds(rules)
          integer = %w[integer bigint].include?(type) || rules.any? { |o| o[:only_integer] }
          return [ :stuck, "#{model_name} validates numericality of #{attr} against a bound the gem cannot read; supply a value it accepts" ] unless numeric
          return nil if numeric[:pairs].empty? && !integer

          default = { "float" => 1.5, "decimal" => 9.99 }.fetch(type, 1)
          candidates = [ default, *numeric[:pairs].flat_map { |key, v| %i[greater_than less_than].include?(key) ? [ key == :greater_than ? v + 1 : v - 1 ] : [ v ] } ]
          candidates = candidates.map { |n| integer ? n.to_i : n }.uniq
          found = candidates.find { |n| numeric[:ok].(n) }
          return nil if found == default
          return [ :stuck, "#{model_name} validates numericality of #{attr} within bounds the gem cannot satisfy; supply a value it accepts" ] unless found

          [ :value, type == "decimal" ? found.to_s.inspect : found.to_s ]
        end

        def unique_columns(model_name, table)
          model = (cached_context[:models] || {})[model_name]
          uniques = Array(model.is_a?(Hash) ? model[:validations] : nil).select { |v| v[:kind] == "uniqueness" }.flat_map { |v| Array(v[:attributes]).map(&:to_s) }
          (uniques + unique_index_columns(table)).uniq
        end

        # The attribute a confirmation rule checks this field against, when the field is `<attribute>_confirmation`.
        def confirmed_attr(res, attr)
          base = attr.delete_suffix("_confirmation")
          base if base != attr && Array((cached_context[:models] || {})[res[:model]]&.dig(:validations)).any? { |v| v[:kind] == "confirmation" && Array(v[:attributes]).map(&:to_s).include?(base) }
        end

        LITERAL_LISTED = [ String, Symbol, Integer, Float, TrueClass, FalseClass ].freeze

        # An enum's first key, or the first value an inclusion validation lists or its range starts at: a placeholder like
        # "MyString" is neither. A list the source computes (a lambda, a constant) keeps the type's placeholder.
        def listed_value(res, attr)
          model = res[:model] && (cached_context[:models] || {})[res[:model]]
          return nil unless model.is_a?(Hash)

          enum = (model[:enums] || {}).then { |enums| enums[attr] || enums[attr.to_sym] }
          list = enum.is_a?(Hash) ? enum.keys.map(&:to_s) : (enum if enum.is_a?(Array))
          list ||= Array(model[:validations]).find { |v| v[:kind] == "inclusion" && Array(v[:attributes]).map(&:to_s).include?(attr) }&.dig(:options, :in)
          first =
            case list
            when Array then list.first
            when Range then list.begin
            when String then list[/\A\(?\s*(-?\d+)\s*\.\.\.?\s*-?\d+\s*\)?\z/, 1]&.to_i
            end
          return nil unless LITERAL_LISTED.any? { |type| first.is_a?(type) }

          # A string column holds the symbol as its string.
          first.is_a?(Symbol) && %w[string text].include?(schema_column_type(res[:table], attr)) ? first.to_s.inspect : first.inspect
        end

        # The attributes a placeholder can stand for: an enum whose mapping the source computes has no value
        # Rails accepts here, so the column keeps its default.
        def made_up(res, attrs)
          attrs.reject do |attr|
            (res[:model] && validity(res[:model], attr) == [ :omit ]) ||
            unknown_enum?(res, attr).tap { |unknown| res[:dropped] << [ res[:model], attr ] if unknown && res[:dropped] }
          end
        end

        def unknown_enum?(res, attr)
          model = res[:model] && (cached_context[:models] || {})[res[:model]]
          return false unless model.is_a?(Hash)

          enum = (model[:enums] || {}).then { |enums| enums[attr] || enums[attr.to_sym] }
          !enum.nil? && !enum.is_a?(Hash) && !enum.is_a?(Array) && listed_value(res, attr).nil?
        end

        def params_todos(res, params_literal)
          todos = []
          todos << "replace nil attribute values with valid data" if params_literal.include?(": nil")
          todos
        end

        def placeholder_attrs_literal(res, attrs = res[:attrs])
          "{ #{value_pairs(res, made_up(res, attrs), :placeholder).join(', ')} }"
        end

        # Extra create! arguments that keep a copied record from tripping a uniqueness validation or index,
        # whether or not the controller permits the column.
        def destroy_attr_overrides(res, subject)
          overrides = res[:table_uniques].filter_map do |attr|
            fresh = fresh_unique_value(res, subject, attr) and "\"#{attr}\" => #{fresh}"
          end
          overrides.any? ? ".merge(#{overrides.join(', ')})" : ""
        end

        FRESH_BY_ONE_TYPES = %w[integer bigint float decimal date datetime time timestamp].freeze

        # A value that differs from the record's own: a prefix for text, one more for a number, a date or a time.
        # nil for a type with no such value.
        def fresh_unique_value(res, record, attr)
          type = schema_column_type(res[:table], attr)
          if %w[string text].include?(type)
            "\"\#{SecureRandom.hex(4)}\#{#{record}.#{attr}}\""
          elsif FRESH_BY_ONE_TYPES.include?(type)
            "#{record}.#{attr} + 1"
          end
        end

        # Why a record cannot be copied: it holds a unique column no other value can be made for.
        def unfreshable_uniques_reason(res, attrs)
          stuck = attrs.reject { |attr| fresh_unique_value(res, "record", attr) }
          return nil if stuck.empty?

          "#{stuck.join(', ')} #{stuck.one? ? 'is a' : 'are'} unique #{stuck.map { |attr| schema_column_type(res[:table], attr) }.uniq.join('/')} " \
            "column#{'s' unless stuck.one?}; no fresh value can be made up for #{stuck.one? ? 'it' : 'them'}"
        end

        def schema_content_columns(table)
          cols = (RailsAiContext::Payload.schema_table(cached_context[:schema], table) || {})[:columns] || []
          cols.map { |c| c[:name].to_s } - %w[id created_at updated_at]
        end

        def schema_column_type(table, column)
          cols = (RailsAiContext::Payload.schema_table(cached_context[:schema], table) || {})[:columns] || []
          col = cols.find { |c| c[:name].to_s == column }
          (col && col[:type]).to_s
        end

        # Columns covered by a unique database index. Posting a fixture row's
        # own value for one of these raises RecordNotUnique even when the
        # model declares no uniqueness validation.
        def unique_index_columns(table)
          indexes = (RailsAiContext::Payload.schema_table(cached_context[:schema], table) || {})[:indexes] || []
          indexes.select { |i| i[:unique] }.flat_map { |i| Array(i[:columns]).map(&:to_s) }
        end

        def devise_app?(tests_data)
          tests_data[:test_helper_setup]&.any? { |h| h.include?("Devise") } || false
        end

        # ── File-based test generation ───────────────────────────────────

        def generate_file_test(file, framework, tests_data, type)
          case file
          when %r{app/models/(.+)\.rb}
            # The whole path, not its last segment: the declaration that names
            # this file is the one equal to the path name ignoring case, and a
            # basename carries no namespace to match a namespaced class
            # against.
            generate_model_test(declared_name(file, $1.split("/").map(&:camelize).join("::")), framework, tests_data)
          when %r{app/controllers/(.+)_controller\.rb}
            path_name = "#{$1.split('/').map(&:camelize).join('::')}Controller"
            generate_controller_test(declared_name(file, path_name), framework, tests_data)
          when %r{app/services/(.+)\.rb}
            path_name = $1.split("/").map(&:camelize).join("::")
            generate_service_test(declared_name(file, path_name), file, framework)
          when %r{app/jobs/(.+)\.rb}
            path_name = $1.split("/").map(&:camelize).join("::")
            generate_job_test(declared_name(file, path_name), framework)
          else
            text_response("Cannot auto-detect test type for `#{echo_input(file)}`. Use `model:` or `controller:` parameter instead.")
          end
        end

        # A path camelizes through Ruby's inflector, which has never read the
        # app's config/initializers/inflections.rb on the static tier, so
        # `ai_reports/build.rb` gives AiReports::Build where the app declares
        # AIReports::Build - a constant that does not exist, in a spec that
        # dies on load. The declaration is the one spelling that is right in
        # both tiers.
        def declared_name(file, path_name)
          source = read_app_file(file)
          return path_name unless source

          Introspectors::DeclaredConstant.resolve(source, path_name)
        end

        def generate_service_test(class_name, file, framework)
          entry = service_entry_point(file, class_name)
          rspec = framework.to_s.include?("rspec")
          path, existing = conventional_test_path(rspec, "services", class_name)
          header = [ *existing_test_lines(existing), "# #{existing || path}", "", "```ruby", "# frozen_string_literal: true", "" ]

          if rspec
            lines = header + [ "require \"rails_helper\"", "" ]
            lines << "RSpec.describe #{class_name} do"
            lines << "  describe \"#{entry[:describe]}\" do"
            lines << "    it \"performs the expected action\" do"
            if entry[:skip]
              lines << "      skip #{"TODO: #{entry[:skip]}".inspect}"
              lines << "      # result = described_class.#{entry[:call]}" if entry[:call]
            else
              lines << "      # TODO: set up input and verify output"
              lines << "      result = described_class.#{entry[:call]}"
              lines << "      expect(result).to #{entry[:expectation]}"
            end
            lines << "    end"
            lines << "  end"
            lines << "end"
            lines << "```"
          else
            lines = header + [ "require \"test_helper\"", "" ]
            lines << "class #{class_name}Test < ActiveSupport::TestCase"
            lines << "  test \"performs the expected action\" do"
            lines << "    # TODO: set up input and verify output"
            lines << "  end"
            lines << "end"
            lines << "```"
          end
          text_response(lines.join("\n"))
        end

        # A job's test is filed with jobs and runs the job: test/jobs with
        # ActiveJob::TestCase, or a `type: :job` spec. Under the service
        # template it went to test/services as an ActiveSupport::TestCase. A
        # Sidekiq job has no perform_now, so its test calls perform itself.
        def generate_job_test(class_name, framework)
          rspec = framework.to_s.include?("rspec")
          path, existing = conventional_test_path(rspec, "jobs", class_name)
          worker = RailsAiContext::Payload.workers(cached_context).find { |w| w.is_a?(Hash) && w[:name] == class_name }
          job = worker || RailsAiContext::Payload.jobs(cached_context).find { |j| j.is_a?(Hash) && j[:name] == class_name } || {}
          signature = job[:perform_signature].to_s
          args = signature.empty? ? "" : "(#{signature})"
          call = worker ? "new.#{worker[:entry_point] || "perform"}#{args}" : "perform_now#{args}"

          lines = [ *existing_test_lines(existing), "# #{existing || path}", "", "```ruby", "# frozen_string_literal: true", "" ]
          if rspec
            lines.push("require \"rails_helper\"", "", "RSpec.describe #{class_name}#{", type: :job" unless worker} do")
            lines << "  it \"performs the expected work\" do"
            lines << "    # TODO: call described_class.#{call} with real arguments, then expect what it changed"
          else
            lines.push("require \"test_helper\"", "", "class #{class_name}Test < #{worker ? "ActiveSupport::TestCase" : "ActiveJob::TestCase"}")
            lines << "  test \"performs the expected work\" do"
            lines << "    # TODO: call #{class_name}.#{call} with real arguments, then assert what it changed"
          end
          lines.push("  end", "end", "```")
          text_response(lines.join("\n"))
        end

        # Where Rails files a test of this kind, and the file when the app has
        # it already: a second test beside it splits one subject's cases.
        def conventional_test_path(rspec, dir, class_name)
          path = rspec ? "spec/#{dir}/#{class_name.underscore}_spec.rb" : "test/#{dir}/#{class_name.underscore}_test.rb"
          test_root = RailsAiContext::PathResolver.test_root(rails_app.root.to_s)
          full = File.expand_path(path, test_root)
          relative = RailsAiContext::PathResolver.suite_relative(rails_app.root.to_s, path)
          [ relative, (relative if RailsAiContext::SafePath.contained?(full, test_root) && File.file?(full)) ]
        end

        # A system test walks the subject's pages in a browser: its index and
        # one record's page, from the routes its controller answers. `type`
        # was never read, so a model's system test came back as its model test.
        def generate_system_test(model_name, ctrl_name, framework, tests_data)
          ctrl_class = if ctrl_name
            RailsAiContext::Payload.find_controller(cached_context, ctrl_name)
          else
            models = cached_context[:models] || {}
            key = fuzzy_find_key(models.keys, model_name)
            unless key
              return not_found_response("Model", model_name, models.keys.sort,
                recovery_tool: call_pointer("rails_get_model_details", %(detail:"summary"), "to see all models"))
            end
            RailsAiContext::Payload.controller_for_route_key(cached_context, key.to_s.underscore.pluralize)&.first
          end
          unless ctrl_class
            return text_response("No controller serves #{ctrl_name || model_name}'s pages, so a system test has none to visit. " \
              "Use `type:\"unit\"` for the model's own test.")
          end

          snake = RailsAiContext::Payload.controller_route_key(cached_context, ctrl_class)
          routes = RouteCoverage.all_by_controller(cached_context[:routes] || {})[snake] || []
          pages = dedupe_routes(routes).select { |route| route[:verb] == "GET" && %w[index show].include?(route[:action].to_s) }
          rspec = framework.to_s.include?("rspec")
          path, existing = conventional_test_path(rspec, "system", snake.camelize)
          res = resource_info(ctrl_class, snake, tests_data)
          res[:factory] = find_factory_name(res[:model], tests_data) if rspec && res[:model]
          res[:login] = login_filters(ctrl_class, pages)
          if rspec
            # The visit and the path assertion name one parent, so each is a let.
            res[:parents] = route_parents(pages, res, tests_data, ref: "", placeholders: true)
            res[:lazy_subject] = true
            res[:unbuildable] = unbuildable_reason(res[:model]) if res[:model] && !res[:factory]
          end

          lines = [ *existing_test_lines(existing), "# #{existing || path}", "", "```ruby", "# frozen_string_literal: true", "" ]
          todo = if res[:login].any?
            "  # TODO: #{login_phrase(ctrl_class, res)}; a browser signs in the way a user does, through the app's login page, before these visits."
          end
          subject = system_subject_lines(lines, res, rspec, snake, todo)

          name_by_path = route_names_by_path(routes)
          pages.each do |route|
            show = route[:action].to_s == "show"
            resolved = url_expression(route, name_by_path, show ? subject : nil, res, tests_data, factories: rspec)
            label = show ? "showing a #{res[:name]}" : "visiting the index"
            lines << "" unless lines.last == ""
            if resolved.nil?
              reason = rspec && show && res[:model] && !res[:parent_reasons]&.any? ? no_record_reason(res) : unresolved_reason(route, res)
              lines.concat(rspec ? rspec_skip_body(label, reason) : minitest_skip_test(label, reason))
              next
            end

            # The current path is compared without the host, so the assertion names the path.
            path_expr = resolved[:url].sub(/_url\b/, "_path")
            lines << (rspec ? "  it \"#{label}\" do" : "  test \"#{label}\" do")
            resolved[:prelude].each { |l| lines << "    #{l}" }
            lines << "    visit #{rspec ? path_expr : resolved[:url]}"
            lines << (rspec ? "    expect(page).to have_current_path(#{path_expr})" : "    assert_current_path #{path_expr}")
            lines << "  end"
          end
          if pages.empty?
            lines << "  # TODO: #{ctrl_class} answers no GET index or show route to visit."
          end
          lines.push("end", "```")

          if !rspec && !File.file?(File.join(RailsAiContext::PathResolver.test_root(rails_app.root.to_s), "test", "application_system_test_case.rb"))
            lines.push("", "_This app has no test/application_system_test_case.rb, which the test inherits from: " \
                           "`bin/rails generate system_test #{snake}` writes one._")
          end
          text_response(lines.join("\n"))
        end

        # The test's opening and the record a show page needs: a fixture, a
        # factory, or a TODO when the app has neither.
        def system_subject_lines(lines, res, rspec, snake, todo)
          if rspec
            lines.push("require \"rails_helper\"", "", "RSpec.describe \"#{snake.camelize}\", type: :system do", *todo)
            literal = !res[:factory] && res[:model] && placeholder_subject_literal(res)
            made_up = res[:parents].values.any? { |parent| parent[:record] } || literal
            lines << "  # TODO: adjust these attributes if validations reject the placeholder values" if made_up
            res[:parents].each_value { |parent| lines << "  let(:#{parent[:ref]}) { #{route_parent_build(parent)} }" }
            return nil unless res[:model]

            subject = rspec_let_name(res[:name])
            if res[:factory]
              lines << "  let(:#{subject}) { #{factory_create(res)} }"
              return subject
            end
            unless literal
              lines << "  # TODO: build a #{res[:model]} from this app's own test data for the show page"
              return nil
            end

            lines << "  let(:#{subject}) { #{res[:model]}.create!(#{literal}) }"
            return subject
          end

          lines.push("require \"application_system_test_case\"", "", "class #{snake.camelize.delete("::")}Test < ApplicationSystemTestCase", *todo)
          return nil unless res[:model] && res[:fixture_key]

          lines.push("  setup do", "    #{minitest_ivar(res[:name])} = #{fixture_accessor(res[:fixture_set])}(:#{res[:fixture_key]})", "  end")
          minitest_ivar(res[:name])
        end

        # ── Helpers ──────────────────────────────────────────────────────

        # `ActiveInteraction::Base` defines `.run` and `.run!`, never `.call`,
        # and its inputs are the filters the class declares. A subclass of the
        # app's own base interaction is one just the same, so the superclass
        # chain decides this rather than the one `class` line.
        def service_entry_point(file, class_name)
          source = read_app_file(file)
          lookup = Introspectors::SuperclassChain.lookup_for(rails_app.root.to_s)
          filters = source && Introspectors::Interaction.interface(source, lookup: lookup)
          return plain_service_entry_point(source, class_name) unless filters

          # Nested filters are keys of the filter that declares them, not
          # keyword arguments: active_interaction drops them without a word.
          args = filters.map { |filter| "#{filter.name}: nil" }.join(", ")
          { describe: ".run", call: args.empty? ? "run" : "run(#{args})", expectation: "be_valid" }
        end

        # `.call` where the class defines one, `new(...).call` for an instance
        # call, a skip where either needs arguments no test data can supply.
        # shortcut: reads only the class's own defs, so a call inherited from a base service is a skip.
        def plain_service_entry_point(source, class_name)
          defs = own_defs(source, class_name)
          class_call = defs.find { |node, on_class| node.name == :call && on_class }&.first
          instance_call = defs.find { |node, on_class| node.name == :call && !on_class }&.first
          initialize = defs.find { |node, on_class| node.name == :initialize && !on_class }&.first

          if class_call
            args = required_args(class_call)
            call = args.empty? ? "call" : "call(#{args.join(', ')})"
            return { describe: ".call", call: call, expectation: "be_truthy", skip: ("build what #{class_name}.call takes, then call it" if args.any?) }
          end
          return { describe: "#call", skip: "#{class_name} defines no call; test the method it exposes" } unless instance_call

          new_args = initialize ? required_args(initialize) : []
          call_args = required_args(instance_call)
          call = "#{new_args.empty? ? "new" : "new(#{new_args.join(', ')})"}.#{call_args.empty? ? "call" : "call(#{call_args.join(', ')})"}"
          skip = if new_args.any? then "build what #{class_name}.new takes, then call it"
          elsif call_args.any? then "build what #{class_name}#call takes, then call it"
          end
          { describe: "#call", call: call, expectation: "be_truthy", skip: skip }
        end

        # Each def in the class's own bodies with whether it defines a class method;
        # a class or module it nests is a scope of its own.
        def own_defs(source, class_name)
          tree = source && RailsAiContext::AstCache.parse_string(source)&.value or return []
          found = []
          walk = lambda do |node, on_class|
            case node
            when Prism::DefNode then found << [ node, on_class || node.receiver.is_a?(Prism::SelfNode) ]
            when Prism::ClassNode, Prism::ModuleNode then nil
            when Prism::SingletonClassNode then walk.call(node.body, true)
            when Prism::Node then node.compact_child_nodes.each { |child| walk.call(child, on_class) }
            end
          end
          Introspectors::DeclaredConstant.class_bodies(tree, class_name).each { |body| walk.call(body, false) }
          found
        end

        def required_args(def_node)
          params = def_node.parameters or return []
          params.requireds.grep(Prism::RequiredParameterNode).map { |param| param.name.to_s } +
            params.keywords.grep(Prism::RequiredKeywordParameterNode).map { |param| "#{param.name}: #{param.name}" }
        end

        def read_app_file(file)
          path = File.join(rails_app.root.to_s, file.to_s.sub(/\A#{Regexp.escape(rails_app.root.to_s)}\/?/, ""))
          return nil unless File.file?(path)
          return nil if File.size(path) > config.max_file_size

          RailsAiContext::SafeFile.read(path)
        rescue StandardError => e
          RailsAiContext.debug_fail(e, nil, label: "generate_test read of #{file}")
        end

        # FactoryBot names a factory after the model, not after the
        # controller's route key: `:order`, never `:"api/v1/admin/order"`,
        # which Ruby reads as a division. A name no factory carries is nil,
        # because `create(:nothing)` raises where a skipped block does not.
        def find_factory_name(model_name, tests_data)
          factory_names = tests_data[:factory_names] || {}
          candidates = [ record_name(model_name), model_name.to_s.demodulize.underscore ].uniq
          candidates.each do |candidate|
            factory_names.each_value do |names|
              return candidate.to_sym if names.include?(candidate.to_sym) || names.include?(candidate)
            end
          end
          nil
        end

        SORT_CALLS = %i[order reorder in_order_of].freeze

        # Whether a scope body calls a method that writes ORDER BY.
        def sorting_scope?(body)
          return false unless body

          RailsAiContext::Introspectors::AstWalk.each(RailsAiContext::AstCache.parse_string(body).value)
            .any? { |node| node.is_a?(Prism::CallNode) && SORT_CALLS.include?(node.name) }
        end

        UNIQUENESS_MATCHED_OPTIONS = %i[scope case_sensitive on if unless allow_nil allow_blank].freeze

        # nil when an option is one the matcher cannot be told, or a value the walk could not read.
        def uniqueness_matcher(attr, validation)
          return nil if validation[:options_source]

          options = validation[:options] || {}
          scopes = Array(options[:scope])
          return nil unless (options.keys - UNIQUENESS_MATCHED_OPTIONS).empty? && scopes.all?(Symbol) &&
            [ nil, true, false ].include?(options[:case_sensitive])

          matcher = "validate_uniqueness_of(:#{attr})"
          matcher += ".scoped_to(#{scopes.map(&:inspect).join(', ')})" if scopes.any?
          matcher += ".case_insensitive" if options[:case_sensitive] == false
          matcher
        end

        # An array asserts the values 0, 1, ... and an integer column, so a mapping is passed whole.
        # nil when a value is a constant the walk named but could not read.
        def enum_matcher(attr, values, data)
          if values.is_a?(Hash)
            return nil if values.each_value.any? { |value| value.is_a?(String) && (value == Confidence::INFERRED || value.match?(/\A[A-Z][\w:]*\z/)) }

            pairs = values.map { |key, value| "#{key.to_s.match?(/\A[a-z_]\w*\z/) ? "#{key}:" : "#{key.to_s.inspect} =>"} #{value.inspect}" }
            matcher = "define_enum_for(:#{attr}).with_values(#{pairs.join(', ')})"
            matcher += ".backed_by_column_of_type(:#{schema_column_type(data[:table_name], attr.to_s).presence || "string"})" unless values.each_value.all?(Integer)
          else
            matcher = "define_enum_for(:#{attr}).with_values(#{Array(values).map(&:to_s).inspect})"
          end
          options = (data[:enum_options] || {}).then { |all| all[attr.to_s] || all[attr.to_sym] || {} }
          %i[prefix suffix].each do |key|
            next unless (affix = options[key])
            return nil unless affix == true || affix.to_s.match?(/\A\w+\z/)

            matcher += affix == true ? ".with_#{key}" : ".with_#{key}(:#{affix})"
          end
          %i[scopes instance_methods].each do |key|
            next unless options.key?(key)
            return nil unless options[key] == false

            matcher += ".without_#{key}"
          end
          matcher
        end

        # Without shoulda-matchers, a reflection check needs no gem at all.
        def reflection_example(assoc)
          "    it { expect(described_class.reflect_on_association(:#{assoc[:name]}).macro).to eq(:#{assoc[:type]}) }"
        end

        # A gem macro (`validates_date`) or `validates_with` is listed under the macro's name, not
        # a kind `validators_on` reports, so no assertion can be written against it.
        # What a test of a rule with no matcher must assert.
        def rule_assertion_hint(validation, attr)
          options = (validation[:options] || {}).except(:message, :on, :if, :unless).map { |key, value| "#{key}: #{value}" }.join(", ")
          "assert that a record breaking #{validation[:kind]} on #{attr}#{" (#{options})" unless options.empty?} is invalid and one meeting it is valid"
        end

        def macro_validation?(validation)
          validation[:kind].to_s.start_with?("validates_")
        end

        # The if:/unless: a validation runs under, nil for one that always runs.
        def validation_condition(validation)
          options = validation[:options] || {}
          conditions = options.slice(:if, :unless).map { |key, value| "#{key}: #{value.is_a?(Symbol) ? value.inspect : value}" }
          conditions << "if: #{validation[:implicit_if]}" if validation[:implicit_if]
          conditions.join(", ").presence
        end

        # The context an on: rule runs in (a saved record validates as :update).
        def validation_context(validation)
          validation.dig(:options, :on)&.to_s&.scan(/\w+/)&.first
        end

        def conditional_validation_skip(condition, indent)
          "#{indent}skip #{"TODO: this validation runs only #{condition}".inspect}"
        end

        # A FactoryBot method as the suite can call it: bare where rails_helper,
        # a support file or test_helper includes FactoryBot::Syntax::Methods,
        # else on FactoryBot, since a bare `create(:post)` without the include
        # is a NoMethodError.
        def factory_bot(method)
          setup = Array((cached_context[:tests] || {})[:test_helper_setup])
          setup.include?("FactoryBot::Syntax::Methods") ? method.to_s : "FactoryBot.#{method}"
        end

        # A string the length validation rejects: one past the maximum, else
        # one short of the minimum. An empty string is short only where
        # blanks are not allowed, so `length: { minimum: 10 }, allow_blank:
        # true` takes nine characters, and a minimum of 1 that allows blanks
        # has no value that fails, so nil.
        def length_breaking_value(options)
          count = ->(value) { value.is_a?(Integer) ? value : (value.to_i if value.to_s.match?(/\A\d+\z/)) }
          range = options[:in] || options[:within]
          bounds = if range.is_a?(Range) then [ range.min, range.max ]
          elsif (m = range.to_s.match(/\A(\d+)\.\.(\.?)(\d+)\z/)) then [ m[1].to_i, m[3].to_i - (m[2].empty? ? 0 : 1) ]
          end
          max = count.call(options[:maximum] || options[:is] || bounds&.last)
          min = count.call(options[:minimum] || options[:is] || bounds&.first)
          return "\"a\" * #{max + 1}" if max
          return "\"a\" * #{min - 1}" if min.to_i > 1
          return "\"\"" if min == 1 && !options[:allow_blank]

          nil
        end

        def plain_validation_example(validation, attr)
          if macro_validation?(validation)
            return [
              "    it \"validates #{validation[:kind]} of #{attr}\" do",
              "      skip #{"TODO: #{rule_assertion_hint(validation, attr)}".inspect}",
              "    end"
            ]
          end

          [
            "    it \"validates #{validation[:kind]} of #{attr}\" do",
            "      # TODO: set up a record that fails this validation",
            "      expect(described_class.validators_on(:#{attr}).map(&:kind)).to include(:#{validation[:kind]})",
            "    end"
          ]
        end

        def enum_attribute?(data, attr)
          enums = data[:enums] || {}
          enums.key?(attr.to_s) || enums.key?(attr.to_sym)
        end

        # Whether a value passes the format, as far as the source shows: a
        # `without:` rule or a literal pattern the value matches. A constant
        # pattern cannot be read, and an invalid value is the likely answer.
        def format_accepts?(options, value)
          return true if options[:without]

          pattern = options[:with]
          return pattern.match?(value) if pattern.is_a?(Regexp)

          literal = pattern.to_s.match(%r{\A/(.*)/([mix]*)\z}m)
          return false unless literal && !literal[1].include?("\#{")

          flags = (literal[2].include?("i") ? Regexp::IGNORECASE : 0) | (literal[2].include?("x") ? Regexp::EXTENDED : 0) |
                  (literal[2].include?("m") ? Regexp::MULTILINE : 0)
          Regexp.new(literal[1], flags).match?(value)
        rescue RegexpError
          false
        end

        # The value an app wrote: an Array literal stays one, and a constant
        # stays code. Anything else (`roles.keys`) is code in_array cannot take.
        def inclusion_list(validation)
          value = validation.dig(:options, :in)
          return nil if value.nil?
          return value.inspect if value.is_a?(Array)

          text = value.to_s
          text if text.match?(/\A[A-Z][\w:]*\z/) || text.start_with?("[", "%w", "%i")
        end
      end
    end
  end
end
