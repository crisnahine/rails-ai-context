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

        if type == "system" && (model || controller)
          generate_system_test(model&.strip, controller&.strip, framework, tests_data)
        elsif model
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
              recovery_tool: "Call rails_get_model_details(detail:\"summary\") to see all models")
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
          file_path, existing = test_path("spec", :model, model_path_stem(name), "spec/models", "_spec.rb")
          factory = find_factory_name(name, tests_data)
          shoulda = shoulda?
          lines = [ *existing_test_lines(existing), "# #{existing || file_path}", "", "```ruby", "# frozen_string_literal: true", "", "require \"rails_helper\"", "" ]
          lines << "RSpec.describe #{name}, type: :model do"

          # Factory/fixture setup
          if factory
            style = rspec_style
            if style[:let]
              lines << "  let(:#{record_name(name)}) { #{factory_bot(style[:factory])}(:#{factory}) }"
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

                if (condition = validation_condition(v))
                  lines.push("    it \"validates #{v[:kind]} of #{attr}\" do", conditional_validation_skip(condition, "      "), "    end")
                  next
                end

                start = lines.size
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
                if (context = validation_context(v)) && lines[start].start_with?("    it { ")
                  lines[start] = lines[start].delete_suffix(" }") + ".on(:#{context}) }"
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
              next if values.is_a?(String) # computed: no literal values to assert

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
          file_path, existing = test_path("test", :model, model_path_stem(name), "test/models", "_test.rb")
          factory = find_factory_name(name, tests_data)
          table = data[:table_name] || model_path_stem(name).split("/").last.pluralize
          lines = [ *existing_test_lines(existing), "# #{existing || file_path}", "", "```ruby", "# frozen_string_literal: true", "", "require \"test_helper\"", "" ]
          lines << "class #{name}Test < ActiveSupport::TestCase"

          setup_var = record_name(name)
          fixture_set, fixture_key = model_fixture(name, table, tests_data)
          # Determine data setup: factory > fixture > inline
          lines << "  setup do"
          if factory
            lines << "    @#{setup_var} = #{factory_bot(:create)}(:#{factory})"
          elsif fixture_key
            lines << "    @#{setup_var} = #{fixture_accessor(fixture_set)}(:#{fixture_key})"
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
                if (condition = validation_condition(v))
                  lines.push(conditional_validation_skip(condition, "    "), "  end", "")
                  next
                end
                if macro_validation?(v)
                  lines << "    skip \"implement #{v[:kind]} validation test\""
                  lines << "  end"
                  lines << ""
                  next
                end
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
                  value = length_breaking_value(v[:options] || {})
                  unless value
                    lines.push("    skip \"set #{attr} to a length the validation rejects\"", "  end", "")
                    next
                  end
                  lines << "    @#{setup_var}.#{attr} = #{value}"
                when "format"
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
                  lines.push("    skip \"implement #{v[:kind]} validation test\"", "  end", "")
                  next
                end
                lines << "    assert_not @#{setup_var}.valid?#{"(:#{validation_context(v)})" if validation_context(v)}"
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
        # (a line_items route serving Spree::LineItem).
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
          table = model_data[:table_name] || singular.pluralize

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
          unique_attrs = (validation_uniques + unique_index_columns(table)).uniq & (no_strong_params ? columns : attrs)
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
          res[:parents] = route_parents(routes, res, tests_data, ref: "@") if res[:factory]

          lines = [ *existing_test_lines(existing), "# #{existing || file_path}", "", "```ruby", "# frozen_string_literal: true", "", "require \"test_helper\"", "" ]
          lines.concat(unimplemented_lines(ctrl_class, res))
          lines << "class #{ctrl_class}Test < #{res[:test_case] ? "ActionController::TestCase" : "ActionDispatch::IntegrationTest"}"

          doorkeeper = doorkeeper_controller?(ctrl_class)
          lines.concat(minitest_auth_lines(ctrl_class, tests_data, doorkeeper, res[:test_case]))

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

          name_by_path = route_names_by_path(routes)
          dedupe_routes(routes).each do |route|
            lines << "" unless lines.last == ""
            lines.concat(minitest_route_test(route, name_by_path, res, tests_data))
          end

          if routes.empty?
            lines << "  test \"#{ctrl_class} responds\" do"
            lines << "    skip \"TODO: #{no_routes_reason(ctrl_class, res, "tests")}\""
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
            "this app's tests define no sign-in helper, so sign a user in first the way the app's login does"
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
          if res[:model] && res[:factory]
            (res[:parents] || {}).each_value { |parent| lines << "#{parent[:ref]} = #{factory_bot(:create)}(:#{parent[:factory]})" }
            lines << "@#{res[:name]} = #{factory_create(res)}"
          elsif res[:model] && res[:fixture_key]
            lines << "@#{res[:name]} = #{fixture_accessor(res[:fixture_set])}(:#{res[:fixture_key]})"
          end
          lines
        end

        def minitest_route_test(route, name_by_path, res, tests_data)
          action = (route[:action] || "index").to_s
          subject = res[:model] && (res[:factory] || res[:fixture_key]) ? "@#{res[:name]}" : nil

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
          return minitest_skip_test(label, "requires a #{res[:table]} fixture") unless subject

          minitest_get_test(route, name_by_path, res, tests_data, label, subject)
        end

        def minitest_create_test(route, name_by_path, res, tests_data, subject)
          label = "should create #{res[:name]}"
          resolved = request_target(route, name_by_path, subject, res, tests_data)
          return minitest_skip_test(label, unresolved_reason(route, res)) unless resolved
          if res[:attrs].empty?
            return minitest_skip_test(label, no_params_reason(res, "POST #{route[:path]}"))
          end

          params = request_params_literal(res, subject ? :fixture : :placeholder)
          minitest_request_test(label, "post", resolved, res,
            response_assertions(route, res, :minitest),
            params_literal: params,
            difference: "\"#{res[:model]}.count\"",
            todos: params_todos(res, params))
        end

        def minitest_update_test(route, name_by_path, res, tests_data, subject)
          label = "should update #{res[:name]}"
          return minitest_skip_test(label, "requires a #{res[:table]} fixture") unless subject

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
          return minitest_skip_test(label, "requires a #{res[:table]} fixture") unless subject

          resolved = request_target(route, name_by_path, res[:name], res, tests_data)
          return minitest_skip_test(label, unresolved_reason(route, res)) unless resolved

          setup_lines = if res[:factory]
            [ "#{res[:name]} = #{factory_create(res)}" ]
          else
            [
              "# Destroy a fresh record: deleting a fixture row can violate foreign keys other fixtures hold on it.",
              "#{res[:name]} = #{res[:model]}.create!(#{subject}.attributes.except(\"id\", \"created_at\", \"updated_at\")#{destroy_attr_overrides(res)})"
            ]
          end
          # String uniques are already randomized by destroy_attr_overrides;
          # only non-string uniques still need a hand-picked fresh value.
          unhandled_uniques = res[:unique_attrs].reject { |a| %w[string text].include?(schema_column_type(res[:table], a)) }
          minitest_request_test(label, "delete", resolved, res,
            response_assertions(route, res, :minitest),
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
          { url: ":#{route[:action] || "index"}", prelude: [], path_params: path_params }
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
          route[:path].to_s.scan(/[:*](\w+)/).flatten - optional - [ "format" ]
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
          [ "  test \"#{label}\" do", "    skip \"TODO: #{reason}\"", "  end" ]
        end

        # A route answering several verbs ("GET|POST", or "ANY" for `via: :all`)
        # is requested with GET when it answers GET.
        def verb_for(route)
          verbs = route[:verb].to_s.downcase.split("|")
          return "get" if verbs.empty? || verbs.include?("get") || verbs.include?("any")

          verbs.first
        end

        def unresolved_reason(route, res = {})
          if res[:test_case] || res[:controller_spec]
            return "pass #{path_params_of(route).map { |param| ":#{param}" }.join(", ")} for #{route[:verb]} #{route[:path]}"
          end

          "resolve the dynamic segments of #{route[:verb]} #{route[:path]} (no matching fixture found)"
        end

        # ── RSpec request generation ─────────────────────────────────────

        def generate_rspec_request(ctrl_class, snake, routes, tests_data, res)
          file_path, existing = test_path("spec", :controller, snake, "spec/requests", "_spec.rb")
          factory = find_factory_name(snake.singularize.camelize, tests_data)
          res = res.merge(factory: factory, parents: factory ? route_parents(routes, res, tests_data, ref: "") : {})
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

          subject_expr = rspec_subject_lines(lines, res, factory)
          attrs_available = rspec_attributes_lines(lines, res, factory)

          name_by_path = route_names_by_path(routes)
          dedupe_routes(routes).each do |route|
            lines << "" unless lines.last == ""
            lines.concat(rspec_route_test(route, name_by_path, res, tests_data, subject_expr, attrs_available))
          end

          if routes.empty?
            lines << "  it \"has tests\" do"
            lines << "    skip \"TODO: #{no_routes_reason(ctrl_class, res, "request specs")}\""
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
        # Names a request or controller spec already gives meaning to: `let(:post)`
        # shadows the `post` the spec sends.
        SPEC_METHOD_NAMES = %w[get post put patch delete head request response params session cookies flash controller].freeze

        def rspec_let_name(name)
          SPEC_METHOD_NAMES.include?(name.to_s) ? "#{name}_record" : name.to_s
        end

        def rspec_subject_lines(lines, res, factory)
          subject = rspec_let_name(res[:name])
          if factory
            res[:parents].each_value { |parent| lines << "  let(:#{parent[:ref]}) { #{factory_bot(:create)}(:#{parent[:factory]}) }" }
            lines << "  let(:#{subject}) { #{factory_create(res)} }"
            return subject
          end
          return nil unless res[:model] && res[:record_attrs].any?

          placeholder = placeholder_attrs_literal(res, res[:record_attrs])
          if res[:non_column_attrs].any?
            lines << "  # TODO: #{res[:non_column_attrs].join(', ')} are permitted params but not columns of " \
              "#{res[:table]}; set them the way the model expects"
          end
          lines << "  # TODO: adjust these attributes if validations reject the placeholder values"
          lines << "  let(:#{subject}) { #{res[:model]}.create!(#{placeholder}) }"
          subject
        end

        def rspec_attributes_lines(lines, res, factory)
          if factory
            lines << "  let(:valid_attributes) { #{factory_bot(:attributes_for)}(:#{factory}) }"
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

        # No permitted attributes to send. A controller that declares no
        # strong params takes none, so the skip says that instead of asking
        # for a params hash the action never reads.
        def no_params_reason(res, request = nil)
          unless res[:no_strong_params]
            return "no permitted attributes detected; fill in valid params#{" for #{request}" if request}"
          end

          "#{res[:controller]} declares no strong params, so the action reads no #{res[:param_key]} params; " \
            "set up what it does read before #{request || "the request"}"
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
          return rspec_skip_body(label, "requires a persisted #{res[:name]} record") unless subject_expr
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
          return rspec_skip_body(label, "requires a persisted #{res[:name]} record") unless subject_expr && res[:model]

          resolved = rspec_target(route, name_by_path, "record", res, tests_data)
          return rspec_skip_body(label, unresolved_reason(route, res)) unless resolved

          json = res[:json_api] ? ", as: :json" : ""
          out = [ "  it \"#{label}\" do" ]
          out << "    record = #{res[:model]}.create!(#{subject_expr}.attributes.except(\"id\", \"created_at\", \"updated_at\")#{destroy_attr_overrides(res)})"
          resolved[:prelude].each { |l| out << "    #{l}" }
          out << "    expect {"
          out << "      #{rspec_request("delete", resolved, nil, json)}"
          out << "    }.to change(#{res[:model]}, :count).by(-1)"
          response_assertions(route, res, :rspec).each { |line| out << "    #{line}" }
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
            { url: url, prelude: [] }
          else
            # A record's id is its key; a column value is already the segment.
            prelude = params.each_with_index.map { |p, i| "#{p} = #{args[i]}#{".id" if p == "id" || p.end_with?("_id")}" }
            path = route[:path] || "/#{res[:table]}"
            path = path.gsub(/\([^()]*\)/, "") while path.match?(/\([^()]*\)/)
            quoted = path.gsub(/[:*](\w+)/, "\#{\\1}")
            { url: "\"#{quoted}\"", prelude: prelude }
          end
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
        # route parent it builds, is that record's attribute: Plots2 routes
        # `graph/file/:uid/:id` to csvfiles, whose rows carry a uid.
        def column_value(param, subject_expr, res)
          return "#{subject_expr}.#{param}" if subject_expr && res[:table] && !schema_column_type(res[:table], param).empty?

          owner = (res[:parents] || {}).values.find do |parent|
            !schema_column_type(parent_table(parent[:name]), param).empty?
          end
          owner && "#{owner[:ref]}.#{param}"
        end

        def parent_table(parent)
          model = (cached_context[:models] || {})[parent.camelize]
          (model.is_a?(Hash) && model[:table_name]) || parent.pluralize
        end

        # Each parent is built once so every request names the same one. `ref` is an ivar in
        # minitest, a let in RSpec.
        def route_parents(routes, res, tests_data, ref:)
          params = Array(routes).flat_map { |route| path_params_of(route) }.uniq.select { |param| param.end_with?("_id") }
          params.filter_map do |param|
            parent = param.delete_suffix("_id")
            factory = find_factory_name(parent.camelize, tests_data) or next
            name = parent.tr("/", "_")
            [ param, { name: parent, ref: ref.empty? ? rspec_let_name(name) : "#{ref}#{name}", factory: factory,
                       assoc: owned_parent(parent, res) } ]
          end.to_h
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
          rspec = framework.to_s.include?("rspec")
          path, existing = conventional_test_path(rspec, "services", class_name)
          header = [ *existing_test_lines(existing), "# #{existing || path}", "", "```ruby", "# frozen_string_literal: true", "" ]

          if rspec
            lines = header + [ "require \"rails_helper\"", "" ]
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
                recovery_tool: "Call rails_get_model_details(detail:\"summary\") to see all models")
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
              lines.concat(rspec ? rspec_skip_body(label, unresolved_reason(route, res)) : minitest_skip_test(label, unresolved_reason(route, res)))
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
            return nil unless res[:model]

            if res[:factory]
              lines << "  let(:#{rspec_let_name(res[:name])}) { #{factory_bot(:create)}(:#{res[:factory]}) }"
              return rspec_let_name(res[:name])
            end
            lines << "  # TODO: build a #{res[:model]} from this app's own test data for the show page"
            return nil
          end

          lines.push("require \"application_system_test_case\"", "", "class #{snake.camelize.delete("::")}Test < ApplicationSystemTestCase", *todo)
          return nil unless res[:model] && res[:fixture_key]

          lines.push("  setup do", "    @#{res[:name]} = #{fixture_accessor(res[:fixture_set])}(:#{res[:fixture_key]})", "  end")
          "@#{res[:name]}"
        end

        # ── Helpers ──────────────────────────────────────────────────────

        # `ActiveInteraction::Base` defines `.run` and `.run!`, never `.call`,
        # and its inputs are the filters the class declares. A subclass of the
        # app's own base interaction is one just the same, so the superclass
        # chain decides this rather than the one `class` line.
        def service_entry_point(file)
          source = read_app_file(file)
          lookup = Introspectors::SuperclassChain.lookup_for(rails_app.root.to_s)
          filters = source && Introspectors::Interaction.interface(source, lookup: lookup)
          return { method: "call", call: "call", expectation: "be_truthy" } unless filters

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

        # Without shoulda-matchers, a reflection check needs no gem at all.
        def reflection_example(assoc)
          "    it { expect(described_class.reflect_on_association(:#{assoc[:name]}).macro).to eq(:#{assoc[:type]}) }"
        end

        # A gem macro (`validates_date`) or `validates_with` is listed under the macro's name, not
        # a kind `validators_on` reports, so no assertion can be written against it.
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
          "#{indent}skip \"TODO: this validation runs only #{condition.tr('"', "'")}\""
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
              "      # TODO: implement #{validation[:kind]} validation test",
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
