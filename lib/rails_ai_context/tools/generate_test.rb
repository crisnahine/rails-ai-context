# frozen_string_literal: true

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
        order: 34,
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

        if model
          generate_model_test(model.strip, framework, tests_data)
        elsif controller
          generate_controller_test(controller.strip, framework, tests_data)
        elsif file
          generate_file_test(file.strip, framework, tests_data, type)
        end
      rescue => e
        text_response("Generate test error: #{e.message}")
      end

      class << self
        private

        def detect_framework
          if Dir.exist?(File.join(rails_app.root, "spec"))
            "rspec"
          else
            "minitest"
          end
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
              recovery_tool: "Call rails_get_model_details(detail:\"summary\") to see all models")
          end

          data = models[key]
          return text_response("Model #{key} has errors: #{data[:error]}") if data[:error]

          if framework == "rspec"
            generate_rspec_model(key, data, tests_data)
          else
            generate_minitest_model(key, data, tests_data)
          end
        end

        # The model's file, minus the models root and the extension.
        def model_path_stem(name)
          RailsAiContext::Payload.model_file(cached_context, name)
            .sub(%r{\A.*app/models/}, "").sub(/\.rb\z/, "")
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
          file_path = "spec/models/#{model_path_stem(name)}_spec.rb"
          factory = find_factory_name(name, tests_data)
          shoulda = shoulda?
          lines = []
          lines << "# #{file_path}"
          lines << ""
          lines << "```ruby"
          lines << "# frozen_string_literal: true"
          lines << ""
          lines << "require \"rails_helper\""
          lines << ""
          lines << "RSpec.describe #{name}, type: :model do"

          # Factory/fixture setup
          if factory
            style = rspec_style
            if style[:let]
              lines << "  let(:#{name.underscore}) { #{style[:factory]}(:#{factory}) }"
            end
          end

          # Associations
          # An association type with no matcher renders nothing, so the block
          # opens on the rows rather than on the association count.
          rows = (data[:associations] || []).filter_map do |a|
            next reflection_example(a) unless shoulda

            case a[:type]
            when "belongs_to"
              "    it { is_expected.to belong_to(:#{a[:name]}) }"
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
            seen = Set.new
            validations.each do |v|
              v[:attributes].each do |attr|
                key = "#{v[:kind]}:#{attr}"
                next if seen.include?(key)
                seen << key

                unless shoulda
                  lines.concat(plain_validation_example(v, attr))
                  next
                end

                case v[:kind]
                when "presence"
                  lines << "    it { is_expected.to validate_presence_of(:#{attr}) }"
                when "uniqueness"
                  lines << "    it { is_expected.to validate_uniqueness_of(:#{attr}) }"
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
                  if vals
                    lines << "    it { is_expected.to validate_inclusion_of(:#{attr}).in_array(#{vals})#{allow_nil} }"
                  else
                    lines << "    it { is_expected.to validate_inclusion_of(:#{attr})#{allow_nil} }"
                  end
                else
                  lines << "    it \"validates #{v[:kind]} of #{attr}\" do"
                  lines << "      # TODO: implement #{v[:kind]} validation test"
                  lines << "    end"
                end
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
              vals = values.is_a?(Hash) ? values.keys : Array(values)
              lines << if shoulda
                "    it { is_expected.to define_enum_for(:#{attr}).with_values(#{vals.inspect}) }"
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
          file_path = "test/models/#{model_path_stem(name)}_test.rb"
          factory = find_factory_name(name, tests_data)
          table = data[:table_name] || model_path_stem(name).split("/").last.pluralize
          lines = []
          lines << "# #{file_path}"
          lines << ""
          lines << "```ruby"
          lines << "# frozen_string_literal: true"
          lines << ""
          lines << "require \"test_helper\""
          lines << ""
          lines << "class #{name}Test < ActiveSupport::TestCase"

          setup_var = name.underscore
          fixture_key = fixture_key_for(table, tests_data)
          # Determine data setup: factory > fixture > inline
          lines << "  setup do"
          if factory
            lines << "    @#{setup_var} = create(:#{factory})"
          elsif fixture_key
            lines << "    @#{setup_var} = #{table}(:#{fixture_key})"
          else
            lines << "    # TODO: no #{table} fixture found; build a valid record here"
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
                case v[:kind]
                when "presence"
                  lines << "    @#{setup_var}.#{attr} = nil"
                when "inclusion"
                  lines << "    @#{setup_var}.#{attr} = \"__invalid_value__\""
                when "uniqueness"
                  lines << "    duplicate = @#{setup_var}.dup"
                  lines << "    assert_not duplicate.valid?"
                  lines << "  end"
                  lines << ""
                  next
                when "numericality"
                  lines << "    @#{setup_var}.#{attr} = \"not_a_number\""
                when "length"
                  max = v.dig(:options, :maximum)
                  if max
                    lines << "    @#{setup_var}.#{attr} = \"a\" * #{max.to_i + 1}"
                  else
                    lines << "    @#{setup_var}.#{attr} = \"\""
                  end
                when "format"
                  lines << "    @#{setup_var}.#{attr} = \"invalid-format\""
                end
                lines << "    assert_not @#{setup_var}.valid?"
                lines << "  end"
                lines << ""
              end
            end
          end

          # Associations
          assocs = data[:associations] || []
          if assocs.any?
            assocs.each do |a|
              lines << "  test \"#{a[:type]} #{a[:name]}\" do"
              lines << "    assert_respond_to @#{setup_var}, :#{a[:name]}"
              lines << "  end"
              lines << ""
            end
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
            if scope_body&.include?("order")
              lines << "    sql = #{name}.#{scope_name}.to_sql"
              lines << "    assert_match(/ORDER BY/i, sql)"
            elsif scope_body&.include?("where")
              lines << "    results = #{name}.#{scope_name}"
              lines << "    assert_kind_of ActiveRecord::Relation, results"
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
              recovery_tool: "Call rails_get_controllers(detail:\"summary\") to see all controllers")
          end

          ctrl_class ||= ctrl_name.end_with?("Controller") ? ctrl_name : "#{ctrl_name.camelize}Controller"

          snake = RailsAiContext::Payload.controller_route_key(cached_context, ctrl_class)

          routes = cached_context[:routes] || {}
          by_ctrl = routes[:by_controller] || {}
          ctrl_routes = by_ctrl[snake] || by_ctrl[snake.pluralize] || []

          res = resource_info(ctrl_class, snake, tests_data)

          if framework == "rspec"
            generate_rspec_request(ctrl_class, snake, ctrl_routes, tests_data, res)
          else
            generate_minitest_controller(ctrl_class, snake, ctrl_routes, tests_data, res)
          end
        end

        # Everything the request templates need to emit runnable requests:
        # the backing model, its fixture, the strong-params key, and the
        # permitted attributes (from strong params, falling back to schema
        # content columns).
        def resource_info(ctrl_class, snake, tests_data)
          models = cached_context[:models] || {}
          singular = snake.split("/").last.singularize
          model_key = fuzzy_find_key(models.keys, snake.singularize.camelize) ||
            fuzzy_find_key(models.keys, singular.camelize)
          model_data = model_key ? models[model_key] : nil
          model_data = {} unless model_data.is_a?(Hash)
          table = model_data[:table_name] || singular.pluralize

          info = ((cached_context[:controllers] || {})[:controllers] || {})[ctrl_class] || {}
          strong_params = Array(info[:strong_params])
          sp = strong_params.find { |p| p[:name] == "#{singular}_params" } || strong_params.first
          columns = schema_content_columns(table)
          attrs = Array(sp && sp[:permits]).map(&:to_s)
          attrs = columns if attrs.empty?

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
          unique_attrs = (validation_uniques + unique_index_columns(table)).uniq & attrs

          {
            name: singular,
            model: model_key,
            table: table,
            fixture_key: fixture_key_for(table, tests_data),
            param_key: (sp && sp[:requires]) || singular,
            attrs: attrs.sort,
            record_attrs: (attrs - non_columns).sort,
            non_column_attrs: non_columns.sort,
            json_api: info[:api_controller] == true || info[:respond_to_formats] == [ "json" ],
            unique_attrs: unique_attrs
          }
        end

        def generate_minitest_controller(ctrl_class, snake, routes, tests_data, res)
          file_path = "test/controllers/#{snake}_controller_test.rb"
          lines = [ "# #{file_path}", "", "```ruby", "# frozen_string_literal: true", "", "require \"test_helper\"", "" ]
          lines << "class #{ctrl_class}Test < ActionDispatch::IntegrationTest"

          doorkeeper = doorkeeper_controller?(ctrl_class)
          lines.concat(minitest_auth_lines(ctrl_class, tests_data, doorkeeper))

          setup = minitest_setup_lines(res, tests_data, doorkeeper)
          if setup.any?
            lines << "  setup do"
            setup.each { |l| lines << "    #{l}" }
            lines << "  end"
          end

          name_by_path = route_names_by_path(routes)
          dedupe_routes(routes).each do |route|
            lines << ""
            lines.concat(minitest_route_test(route, name_by_path, res, tests_data))
          end

          if routes.empty?
            lines << "  test \"#{ctrl_class} responds\" do"
            lines << "    skip \"TODO: no routes found for #{ctrl_class}; add tests once routes exist\""
            lines << "  end"
          end

          lines << "end"
          lines << "```"
          text_response(lines.join("\n"))
        end

        # The Devise include is a fact about the app; the sign_in is only
        # emitted when the app owns a users fixture to sign in. A Doorkeeper
        # endpoint is not signed in at all, the same as the request-spec side.
        def minitest_auth_lines(ctrl_class, tests_data, doorkeeper)
          if doorkeeper
            return [ "  # TODO: these tests run unauthenticated; #{ctrl_class} authorizes with Doorkeeper, so pass a bearer token" ]
          end
          return [] unless devise_app?(tests_data)

          lines = [ "  include Devise::Test::IntegrationHelpers" ]
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
          if res[:model] && res[:fixture_key]
            lines << "@#{res[:name]} = #{res[:table]}(:#{res[:fixture_key]})"
          end
          lines
        end

        def minitest_route_test(route, name_by_path, res, tests_data)
          action = (route[:action] || "index").to_s
          subject = res[:model] && res[:fixture_key] ? "@#{res[:name]}" : nil

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
          resolved = url_expression(route, name_by_path, subject, res, tests_data)
          return minitest_skip_test(label, unresolved_reason(route)) unless resolved

          minitest_request_test(label, verb_for(route), resolved, res, "assert_response :success")
        end

        def minitest_member_get_test(route, name_by_path, res, tests_data, label, subject)
          return minitest_skip_test(label, "requires a #{res[:table]} fixture") unless subject

          minitest_get_test(route, name_by_path, res, tests_data, label, subject)
        end

        def minitest_create_test(route, name_by_path, res, tests_data, subject)
          label = "should create #{res[:name]}"
          resolved = url_expression(route, name_by_path, subject, res, tests_data)
          return minitest_skip_test(label, unresolved_reason(route)) unless resolved
          if res[:attrs].empty?
            return minitest_skip_test(label, "no permitted attributes detected; fill in valid params for POST #{route[:path]}")
          end

          params = request_params_literal(res, subject ? :fixture : :placeholder)
          minitest_request_test(label, "post", resolved, res,
            res[:json_api] ? "assert_response :success" : "assert_response :redirect",
            params_literal: params,
            difference: "\"#{res[:model]}.count\"",
            todos: params_todos(res, params))
        end

        def minitest_update_test(route, name_by_path, res, tests_data, subject)
          label = "should update #{res[:name]}"
          return minitest_skip_test(label, "requires a #{res[:table]} fixture") unless subject

          resolved = url_expression(route, name_by_path, subject, res, tests_data)
          return minitest_skip_test(label, unresolved_reason(route)) unless resolved
          if res[:attrs].empty?
            return minitest_skip_test(label, "no permitted attributes detected; fill in valid params for #{route[:verb]} #{route[:path]}")
          end

          params = request_params_literal(res, :fixture)
          minitest_request_test(label, verb_for(route), resolved, res,
            res[:json_api] ? "assert_response :success" : "assert_response :redirect",
            params_literal: params,
            todos: params_todos(res, params))
        end

        def minitest_destroy_test(route, name_by_path, res, tests_data, subject)
          label = "should destroy #{res[:name]}"
          return minitest_skip_test(label, "requires a #{res[:table]} fixture") unless subject

          resolved = url_expression(route, name_by_path, res[:name], res, tests_data)
          return minitest_skip_test(label, unresolved_reason(route)) unless resolved

          setup_lines = [
            "# Destroy a fresh record: deleting a fixture row can violate foreign keys other fixtures hold on it.",
            "#{res[:name]} = #{res[:model]}.create!(#{subject}.attributes.except(\"id\", \"created_at\", \"updated_at\")#{destroy_attr_overrides(res)})"
          ]
          # String uniques are already randomized by destroy_attr_overrides;
          # only non-string uniques still need a hand-picked fresh value.
          unhandled_uniques = res[:unique_attrs].reject { |a| %w[string text].include?(schema_column_type(res[:table], a)) }
          minitest_request_test(label, "delete", resolved, res,
            res[:json_api] ? "assert_response :success" : "assert_response :redirect",
            difference: "\"#{res[:model]}.count\", -1",
            setup_lines: setup_lines,
            todos: unhandled_uniques.any? ? [ "confirm the fresh record satisfies uniqueness validations" ] : [])
        end

        def minitest_generic_test(route, name_by_path, res, tests_data, subject)
          action = (route[:action] || "index").to_s
          verb = verb_for(route)
          label = verb == "get" ? "should get #{action}" : "#{route[:verb]} #{route[:path]}"

          if verb != "get"
            return minitest_skip_test(label, "provide params and assertions for #{action}")
          end

          resolved = url_expression(route, name_by_path, subject, res, tests_data)
          return minitest_skip_test(label, unresolved_reason(route)) unless resolved

          minitest_request_test(label, verb, resolved, res, "assert_response :success")
        end

        def minitest_request_test(label, verb, resolved, res, assertion, params_literal: nil, difference: nil, setup_lines: [], todos: [])
          json = res[:json_api] ? ", as: :json" : ""
          params_part = params_literal ? ", params: #{params_literal}" : ""
          request = "#{verb} #{resolved[:url]}#{params_part}#{json}"

          out = [ "  test \"#{label}\" do" ]
          todos.each { |t| out << "    # TODO: #{t}" }
          (resolved[:prelude] + setup_lines).each { |l| out << "    #{l}" }
          if difference
            out << "    assert_difference(#{difference}) do"
            out << "      #{request}"
            out << "    end"
          else
            out << "    #{request}"
          end
          out << "    #{assertion}"
          out << "  end"
          out
        end

        def minitest_skip_test(label, reason)
          [ "  test \"#{label}\" do", "    skip \"TODO: #{reason}\"", "  end" ]
        end

        def verb_for(route)
          (route[:verb] || "GET").downcase
        end

        def unresolved_reason(route)
          "resolve the dynamic segments of #{route[:verb]} #{route[:path]} (no matching fixture found)"
        end

        # ── RSpec request generation ─────────────────────────────────────

        def generate_rspec_request(ctrl_class, snake, routes, tests_data, res)
          file_path = "spec/requests/#{snake}_spec.rb"
          factory = find_factory_name(snake.singularize.camelize, tests_data)

          lines = [ "# #{file_path}", "", "```ruby", "# frozen_string_literal: true", "", "require \"rails_helper\"", "" ]
          lines << "RSpec.describe \"#{ctrl_class}\", type: :request do"

          lines.concat(rspec_auth_lines(ctrl_class, tests_data))

          subject_expr = rspec_subject_lines(lines, res, factory)
          attrs_available = rspec_attributes_lines(lines, res, factory)

          name_by_path = route_names_by_path(routes)
          dedupe_routes(routes).each do |route|
            lines << ""
            lines.concat(rspec_route_test(route, name_by_path, res, tests_data, subject_expr, attrs_available))
          end

          if routes.empty?
            lines << "  it \"has tests\" do"
            lines << "    skip \"TODO: no routes found for #{ctrl_class}; add request specs once routes exist\""
            lines << "  end"
          end

          lines << "end"
          lines << "```"
          text_response(lines.join("\n"))
        end

        # Auth setup for a request spec. sign_in cannot authenticate a
        # Doorkeeper endpoint, and it needs a user the app can actually build,
        # so each missing piece degrades to a TODO instead of a fabricated call.
        def rspec_auth_lines(ctrl_class, tests_data)
          if doorkeeper_controller?(ctrl_class)
            [ "  # TODO: these examples run unauthenticated; #{ctrl_class} authorizes with Doorkeeper, so pass a bearer token", "" ]
          elsif devise_app?(tests_data)
            lines = [ "  include Devise::Test::IntegrationHelpers", "" ]
            if (user_factory = find_factory_name("User", tests_data))
              lines << "  let(:user) { create(:#{user_factory}) }"
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
        def rspec_subject_lines(lines, res, factory)
          if factory
            lines << "  let(:#{res[:name]}) { create(:#{factory}) }"
            return res[:name]
          end
          return nil unless res[:model] && res[:record_attrs].any?

          placeholder = placeholder_attrs_literal(res, res[:record_attrs])
          if res[:non_column_attrs].any?
            lines << "  # TODO: #{res[:non_column_attrs].join(', ')} are permitted params but not columns of " \
              "#{res[:table]}; set them the way the model expects"
          end
          lines << "  # TODO: adjust these attributes if validations reject the placeholder values"
          lines << "  let(:#{res[:name]}) { #{res[:model]}.create!(#{placeholder}) }"
          res[:name]
        end

        def rspec_attributes_lines(lines, res, factory)
          if factory
            lines << "  let(:valid_attributes) { attributes_for(:#{factory}) }"
            true
          elsif res[:attrs].any?
            lines << "  let(:valid_attributes) { #{placeholder_attrs_literal(res)} }"
            true
          else
            false
          end
        end

        def rspec_route_test(route, name_by_path, res, tests_data, subject_expr, attrs_available)
          action = (route[:action] || "index").to_s
          verb = verb_for(route)
          body =
            case action
            when "index", "new"
              rspec_get_body(route, name_by_path, res, tests_data, nil, "returns success")
            when "show", "edit"
              if subject_expr
                rspec_get_body(route, name_by_path, res, tests_data, subject_expr, "returns success")
              else
                rspec_skip_body("returns success", "requires a persisted #{res[:name]} record")
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
          resolved = url_expression(route, name_by_path, subject_expr, res, tests_data, rspec: true)
          return rspec_skip_body(label, unresolved_reason(route)) unless resolved

          json = res[:json_api] ? ", as: :json" : ""
          out = [ "  it \"#{label}\" do" ]
          resolved[:prelude].each { |l| out << "    #{l}" }
          out << "    #{verb_for(route)} #{resolved[:url]}#{json}"
          out << "    expect(response).to have_http_status(:success)"
          out << "  end"
          out
        end

        def rspec_create_body(route, name_by_path, res, tests_data, attrs_available)
          label = "creates a new #{res[:model] || res[:name]}"
          return rspec_skip_body(label, "no permitted attributes detected; fill in valid params") unless attrs_available && res[:model]

          resolved = url_expression(route, name_by_path, nil, res, tests_data, rspec: true)
          return rspec_skip_body(label, unresolved_reason(route)) unless resolved

          json = res[:json_api] ? ", as: :json" : ""
          status = res[:json_api] ? ":success" : ":redirect"
          out = [ "  it \"#{label}\" do" ]
          resolved[:prelude].each { |l| out << "    #{l}" }
          out << "    expect {"
          out << "      post #{resolved[:url]}, params: { #{res[:param_key]}: valid_attributes }#{json}"
          out << "    }.to change(#{res[:model]}, :count).by(1)"
          out << "    expect(response).to have_http_status(#{status})"
          out << "  end"
          out
        end

        def rspec_update_body(route, name_by_path, res, tests_data, subject_expr, attrs_available)
          label = "updates the #{res[:name]}"
          return rspec_skip_body(label, "requires a persisted #{res[:name]} record") unless subject_expr
          return rspec_skip_body(label, "no permitted attributes detected; fill in valid params") unless attrs_available

          resolved = url_expression(route, name_by_path, subject_expr, res, tests_data, rspec: true)
          return rspec_skip_body(label, unresolved_reason(route)) unless resolved

          json = res[:json_api] ? ", as: :json" : ""
          status = res[:json_api] ? ":success" : ":redirect"
          out = [ "  it \"#{label}\" do" ]
          resolved[:prelude].each { |l| out << "    #{l}" }
          out << "    #{verb_for(route)} #{resolved[:url]}, params: { #{res[:param_key]}: valid_attributes }#{json}"
          out << "    expect(response).to have_http_status(#{status})"
          out << "  end"
          out
        end

        def rspec_destroy_body(route, name_by_path, res, tests_data, subject_expr)
          label = "destroys the #{res[:name]}"
          return rspec_skip_body(label, "requires a persisted #{res[:name]} record") unless subject_expr && res[:model]

          resolved = url_expression(route, name_by_path, "record", res, tests_data, rspec: true)
          return rspec_skip_body(label, unresolved_reason(route)) unless resolved

          json = res[:json_api] ? ", as: :json" : ""
          out = [ "  it \"#{label}\" do" ]
          out << "    record = #{res[:model]}.create!(#{subject_expr}.attributes.except(\"id\", \"created_at\", \"updated_at\")#{destroy_attr_overrides(res)})"
          resolved[:prelude].each { |l| out << "    #{l}" }
          out << "    expect {"
          out << "      delete #{resolved[:url]}#{json}"
          out << "    }.to change(#{res[:model]}, :count).by(-1)"
          out << "  end"
          out
        end

        def rspec_skip_body(label, reason)
          [ "  it \"#{label}\" do", "    skip \"TODO: #{reason}\"", "  end" ]
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
        def url_expression(route, name_by_path, subject_expr, res, tests_data, rspec: false)
          params = route[:params] || (route[:path] || "").scan(/:(\w+)/).flatten
          args = params.map do |p|
            expr = path_param_expr(p, subject_expr, tests_data, rspec: rspec)
            return nil unless expr
            expr
          end

          helper = route[:name] || name_by_path[route[:path]]
          if helper
            url = args.empty? ? "#{helper}_url" : "#{helper}_url(#{args.join(', ')})"
            { url: url, prelude: [] }
          else
            prelude = params.each_with_index.map { |p, i| "#{p} = #{args[i]}.id" }
            quoted = (route[:path] || "/#{res[:table]}").gsub(/:(\w+)/, "\#{\\1}")
            { url: "\"#{quoted}\"", prelude: prelude }
          end
        end

        # Dynamic path segments come from the subject record (:id) or a parent
        # record (:parent_id). Minitest reads parents from fixtures; RSpec
        # request specs do not load fixtures, so parents need a factory.
        def path_param_expr(param, subject_expr, tests_data, rspec: false)
          if param == "id"
            subject_expr
          elsif param.end_with?("_id")
            parent = param.delete_suffix("_id")
            if rspec
              factory = find_factory_name(parent.camelize, tests_data)
              factory && "create(:#{factory})"
            else
              key = fixture_key_for(parent.pluralize, tests_data)
              key && "#{parent.pluralize}(:#{key})"
            end
          end
        end

        # Build the params hash literal for create/update, copying attribute
        # values from the fixture record the way Rails scaffold tests do.
        def request_params_literal(res, value_source)
          pairs = res[:attrs].map do |attr|
            "#{attr}: #{attr_value_expr(res, attr, value_source)}"
          end
          "{ #{res[:param_key]}: { #{pairs.join(', ')} } }"
        end

        def attr_value_expr(res, attr, value_source)
          if res[:unique_attrs].include?(attr) && %w[string text].include?(schema_column_type(res[:table], attr))
            # Unique values must differ from every fixture row.
            "\"#{attr}-\#{SecureRandom.hex(4)}\""
          elsif value_source == :fixture
            "@#{res[:name]}.#{attr}"
          else
            PLACEHOLDER_VALUES.fetch(schema_column_type(res[:table], attr).to_s, "nil")
          end
        end

        def params_todos(res, params_literal)
          todos = []
          todos << "replace nil attribute values with valid data" if params_literal.include?(": nil")
          non_string_uniques = res[:unique_attrs].reject { |a| %w[string text].include?(schema_column_type(res[:table], a)) }
          todos << "ensure #{non_string_uniques.join(', ')} differ from existing fixture values (uniqueness validation)" if non_string_uniques.any?
          todos
        end

        def placeholder_attrs_literal(res, attrs = res[:attrs])
          pairs = attrs.map do |attr|
            "#{attr}: #{attr_value_expr(res, attr, :placeholder)}"
          end
          "{ #{pairs.join(', ')} }"
        end

        # Extra create! arguments that keep a copied record from tripping
        # uniqueness validations.
        def destroy_attr_overrides(res)
          overrides = res[:unique_attrs].filter_map do |attr|
            next unless %w[string text].include?(schema_column_type(res[:table], attr))
            "\"#{attr}\" => \"#{attr}-\#{SecureRandom.hex(4)}\""
          end
          overrides.any? ? ".merge(#{overrides.join(', ')})" : ""
        end

        def schema_content_columns(table)
          tables = (cached_context[:schema] || {})[:tables] || {}
          cols = (tables[table] || tables[table.to_sym] || {})[:columns] || []
          cols.map { |c| c[:name].to_s } - %w[id created_at updated_at]
        end

        def schema_column_type(table, column)
          tables = (cached_context[:schema] || {})[:tables] || {}
          cols = (tables[table] || tables[table.to_sym] || {})[:columns] || []
          col = cols.find { |c| c[:name].to_s == column }
          (col && col[:type]).to_s
        end

        # Columns covered by a unique database index. Posting a fixture row's
        # own value for one of these raises RecordNotUnique even when the
        # model declares no uniqueness validation.
        def unique_index_columns(table)
          tables = (cached_context[:schema] || {})[:tables] || {}
          indexes = (tables[table] || tables[table.to_sym] || {})[:indexes] || []
          indexes.select { |i| i[:unique] }.flat_map { |i| Array(i[:columns]).map(&:to_s) }
        end

        def devise_app?(tests_data)
          tests_data[:test_helper_setup]&.any? { |h| h.include?("Devise") } || false
        end

        # ── File-based test generation ───────────────────────────────────

        def generate_file_test(file, framework, tests_data, type)
          case file
          when %r{app/models/(.+)\.rb}
            generate_model_test(declared_name(file, $1.split("/").last.camelize), framework, tests_data)
          when %r{app/controllers/(.+)_controller\.rb}
            path_name = "#{$1.split('/').map(&:camelize).join('::')}Controller"
            generate_controller_test(declared_name(file, path_name), framework, tests_data)
          when %r{app/services/(.+)\.rb}, %r{app/jobs/(.+)\.rb}
            path_name = $1.split("/").map(&:camelize).join("::")
            generate_service_test(declared_name(file, path_name), file, framework)
          else
            text_response("Cannot auto-detect test type for `#{file}`. Use `model:` or `controller:` parameter instead.")
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
          entry = service_entry_point(file)

          if framework == "rspec"
            path = "spec/services/#{class_name.underscore}_spec.rb"
            lines = [ "# #{path}", "", "```ruby", "# frozen_string_literal: true", "", "require \"rails_helper\"", "" ]
            lines << "RSpec.describe #{class_name} do"
            lines << "  describe \".#{entry[:method]}\" do"
            lines << "    it \"performs the expected action\" do"
            lines << "      # TODO: set up input and verify output"
            lines << "      result = described_class.#{entry[:call]}"
            lines << "      expect(result).to #{entry[:expectation]}"
            lines << "    end"
            lines << "  end"
            lines << "end"
            lines << "```"
          else
            path = "test/services/#{class_name.underscore}_test.rb"
            lines = [ "# #{path}", "", "```ruby", "# frozen_string_literal: true", "", "require \"test_helper\"", "" ]
            lines << "class #{class_name}Test < ActiveSupport::TestCase"
            lines << "  test \"performs the expected action\" do"
            lines << "    # TODO: set up input and verify output"
            lines << "  end"
            lines << "end"
            lines << "```"
          end
          text_response(lines.join("\n"))
        end

        # ── Helpers ──────────────────────────────────────────────────────

        # `ActiveInteraction::Base` defines `.run` and `.run!`, never `.call`,
        # and its inputs are the filters the class declares.
        # ActiveInteraction::Base defines .run and .run!, never .call, and a
        # subclass of the app's own base interaction is one just the same, so
        # the superclass chain decides this rather than the one `class` line.
        def service_entry_point(file)
          source = read_app_file(file)
          lookup = Introspectors::Interaction.lookup_for(rails_app.root.to_s)
          filters = source ? Introspectors::Interaction.filters(source, lookup: lookup) : []
          return { method: "call", call: "call", expectation: "be_truthy" } unless
            source && Introspectors::Interaction.interaction?(source, lookup: lookup)

          # Nested filters are keys of the filter that declares them, not
          # keyword arguments: active_interaction drops them without a word.
          args = filters.map { |filter| "#{filter.name}: nil" }.join(", ")
          { method: "run", call: args.empty? ? "run" : "run(#{args})", expectation: "be_valid" }
        end

        def read_app_file(file)
          path = File.join(rails_app.root.to_s, file.to_s.sub(/\A#{Regexp.escape(rails_app.root.to_s)}\/?/, ""))
          return nil unless File.file?(path)
          return nil if File.size(path) > config.max_file_size

          RailsAiContext::SafeFile.read(path)
        rescue StandardError => e
          $stderr.puts "[rails-ai-context] generate_test could not read #{file}: #{e.message}" if ENV["DEBUG"]
          nil
        end

        # FactoryBot names a factory after the model, not after the
        # controller's route key: `:order`, never `:"api/v1/admin/order"`,
        # which Ruby reads as a division. A name no factory carries is nil,
        # because `create(:nothing)` raises where a skipped block does not.
        def find_factory_name(model_name, tests_data)
          factory_names = tests_data[:factory_names] || {}
          candidates = [ model_name.to_s.underscore, model_name.to_s.demodulize.underscore ].uniq
          candidates.each do |candidate|
            factory_names.each_value do |names|
              return candidate.to_sym if names.include?(candidate.to_sym) || names.include?(candidate)
            end
          end
          nil
        end

        # Without shoulda-matchers, a reflection check needs no gem at all.
        def reflection_example(assoc)
          "    it { expect(described_class.reflect_on_association(:#{assoc[:name]}).macro).to eq(:#{assoc[:type]}) }"
        end

        def plain_validation_example(validation, attr)
          [
            "    it \"validates #{validation[:kind]} of #{attr}\" do",
            "      # TODO: set up a record that fails this validation",
            "      expect(described_class.validators_on(:#{attr}).map(&:kind)).to include(:#{validation[:kind]})",
            "    end"
          ]
        end

        # The value an app wrote: an Array literal stays one, and a constant
        # stays code rather than becoming a quoted string.
        def inclusion_list(validation)
          value = validation.dig(:options, :in)
          return nil if value.nil?
          return value.inspect if value.is_a?(Array)

          text = value.to_s
          return text if text.match?(/\A[A-Z][\w:]*\z/) || text.start_with?("[", "%w", "%i")

          text.inspect
        end
      end
    end
  end
end
