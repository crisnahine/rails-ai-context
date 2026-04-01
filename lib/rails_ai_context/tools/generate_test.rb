# frozen_string_literal: true

module RailsAiContext
  module Tools
    class GenerateTest < BaseTool
      tool_name "rails_generate_test"
      description "Generate test scaffolding that matches your project's actual test patterns — framework, factories, assertion style. " \
        "Use when: adding tests for a model, controller, or service. Generates copy-paste-ready test files. " \
        "Key params: model (e.g. 'User'), controller (e.g. 'CooksController'), file (e.g. 'app/services/foo.rb')."

      input_schema(
        properties: {
          model: {
            type: "string",
            description: "Model name (e.g. 'User'). Generates model spec with validations, associations, scopes, enums."
          },
          controller: {
            type: "string",
            description: "Controller name (e.g. 'CooksController'). Generates request spec with routes and auth."
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

      annotations(read_only_hint: true, destructive_hint: false, idempotent_hint: true, open_world_hint: false)

      def self.call(model: nil, controller: nil, file: nil, type: "unit", server_context: nil)
        unless model || controller || file
          return text_response("Provide at least one of: `model`, `controller`, or `file`.")
        end

        tests_data = cached_context[:tests] || {}
        framework = tests_data[:framework] || detect_framework
        patterns = detect_patterns(framework)

        if model
          generate_model_test(model.strip, framework, patterns, tests_data)
        elsif controller
          generate_controller_test(controller.strip, framework, patterns, tests_data)
        elsif file
          generate_file_test(file.strip, framework, patterns, tests_data, type)
        end
      rescue => e
        text_response("Generate test error: #{e.message}")
      end

      class << self
        private

        def detect_framework
          if Dir.exist?(File.join(Rails.root, "spec"))
            "rspec"
          else
            "minitest"
          end
        end

        # Scan existing tests to learn project patterns
        def detect_patterns(framework) # rubocop:disable Metrics
          root = Rails.root.to_s
          patterns = { factory_style: :create, let_style: true, expect_style: true, described_class: true }

          glob = framework == "rspec" ? "spec/**/*_spec.rb" : "test/**/*_test.rb"
          files = Dir.glob(File.join(root, glob)).first(5)

          expect_count = 0
          should_count = 0
          create_count = 0
          build_count = 0
          let_count = 0
          instance_var_count = 0

          files.each do |f|
            next if File.size(f) > config.max_test_file_size
            source = File.read(f, encoding: "UTF-8", invalid: :replace, undef: :replace) rescue next
            expect_count += source.scan(/expect\(/).size
            should_count += source.scan(/\.should\b/).size
            create_count += source.scan(/create\(:/).size
            build_count += source.scan(/build\(:/).size
            let_count += source.scan(/\blet[!]?\(:/).size
            instance_var_count += source.scan(/@\w+\s*=/).size
          end

          patterns[:expect_style] = expect_count >= should_count
          patterns[:factory_style] = create_count >= build_count ? :create : :build
          patterns[:let_style] = let_count > instance_var_count
          patterns
        end

        # ── Model test generation ────────────────────────────────────────

        def generate_model_test(model_name, framework, patterns, tests_data)
          models = cached_context[:models] || {}
          key = models.keys.find { |k| k.downcase == model_name.downcase } ||
                models.keys.find { |k| k.underscore == model_name.underscore }
          unless key
            return not_found_response("Model", model_name, models.keys.sort,
              recovery_tool: "Call rails_get_model_details(detail:\"summary\") to see all models")
          end

          data = models[key]
          return text_response("Model #{key} has errors: #{data[:error]}") if data[:error]

          if framework == "rspec"
            generate_rspec_model(key, data, patterns, tests_data)
          else
            generate_minitest_model(key, data, patterns, tests_data)
          end
        end

        def generate_rspec_model(name, data, patterns, tests_data)
          file_path = "spec/models/#{name.underscore}_spec.rb"
          factory = find_factory_name(name, tests_data)
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
            style = patterns[:factory_style]
            if patterns[:let_style]
              lines << "  let(:#{name.underscore}) { #{style}(:#{factory}) }"
            end
          end

          # Associations
          assocs = data[:associations] || []
          if assocs.any?
            lines << ""
            lines << "  describe \"associations\" do"
            assocs.each do |a|
              case a[:type]
              when "belongs_to"
                lines << "    it { is_expected.to belong_to(:#{a[:name]}) }"
              when "has_many"
                if a[:through]
                  lines << "    it { is_expected.to have_many(:#{a[:name]}).through(:#{a[:through]}) }"
                else
                  dep = a[:dependent] ? ".dependent(:#{a[:dependent]})" : ""
                  lines << "    it { is_expected.to have_many(:#{a[:name]})#{dep} }"
                end
              when "has_one"
                lines << "    it { is_expected.to have_one(:#{a[:name]}) }"
              end
            end
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
                  vals = v.dig(:options, :in)
                  if vals
                    lines << "    it { is_expected.to validate_inclusion_of(:#{attr}).in_array(#{vals.inspect}) }"
                  else
                    lines << "    it { is_expected.to validate_inclusion_of(:#{attr}) }"
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
              lines << "    it { is_expected.to define_enum_for(:#{attr}).with_values(#{vals.inspect}) }"
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
                lines << "    it \"#{type} calls #{m}\" do"
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

        def generate_minitest_model(name, data, _patterns, tests_data)
          file_path = "test/models/#{name.underscore}_test.rb"
          factory = find_factory_name(name, tests_data)
          lines = []
          lines << "# #{file_path}"
          lines << ""
          lines << "```ruby"
          lines << "# frozen_string_literal: true"
          lines << ""
          lines << "require \"test_helper\""
          lines << ""
          lines << "class #{name}Test < ActiveSupport::TestCase"

          setup_var = factory ? "#{name.underscore}" : "#{name.underscore}"
          if factory
            lines << "  setup do"
            lines << "    @#{setup_var} = create(:#{factory})"
            lines << "  end"
          end

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
                lines << "    @#{setup_var}.#{attr} = nil" if v[:kind] == "presence"
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
            lines << "  test \"scope .#{scope_name} returns expected records\" do"
            lines << "    # TODO: create test data and verify"
            lines << "  end"
            lines << ""
          end

          lines << "end"
          lines << "```"

          text_response(lines.join("\n"))
        end

        # ── Controller test generation ───────────────────────────────────

        def generate_controller_test(ctrl_name, framework, patterns, tests_data)
          ctrl_name = ctrl_name.strip
          # Normalize: "cooks" → "CooksController", "CooksController" stays
          ctrl_class = ctrl_name.end_with?("Controller") ? ctrl_name : "#{ctrl_name.camelize}Controller"
          snake = ctrl_class.underscore.delete_suffix("_controller")

          routes = cached_context[:routes] || {}
          by_ctrl = routes[:by_controller] || {}
          ctrl_routes = by_ctrl[snake] || by_ctrl[snake.pluralize] || []

          if framework == "rspec"
            generate_rspec_request(ctrl_class, snake, ctrl_routes, patterns, tests_data)
          else
            generate_minitest_controller(ctrl_class, snake, ctrl_routes, tests_data)
          end
        end

        def generate_rspec_request(ctrl_class, snake, routes, patterns, tests_data)
          file_path = "spec/requests/#{snake}_spec.rb"
          factory = find_factory_name(snake.singularize.camelize, tests_data)
          has_devise = tests_data[:test_helper_setup]&.any? { |h| h.include?("Devise") }

          lines = [ "# #{file_path}", "", "```ruby", "# frozen_string_literal: true", "", "require \"rails_helper\"", "" ]
          lines << "RSpec.describe \"#{ctrl_class}\", type: :request do"

          if has_devise
            lines << "  include Devise::Test::IntegrationHelpers"
            lines << ""
            lines << "  let(:user) { create(:user) }"
            lines << "  before { sign_in user }"
          end

          if factory
            lines << "  let(:#{snake.singularize}) { create(:#{factory}) }"
          end

          routes.each do |r|
            verb = (r[:verb] || "GET").downcase
            path = r[:path] || "/#{snake}"
            action = r[:action] || "index"
            helper = r[:name] ? "#{r[:name]}_path" : "\"#{path}\""

            lines << ""
            lines << "  describe \"#{r[:verb]} #{r[:path]}\" do"

            case action
            when "index"
              lines << "    it \"returns success\" do"
              lines << "      get #{helper}"
              lines << "      expect(response).to have_http_status(:ok)"
              lines << "    end"
            when "show"
              lines << "    it \"returns the #{snake.singularize}\" do"
              lines << "      get #{helper}#{"(id: #{snake.singularize}.id)" if r[:name]}"
              lines << "      expect(response).to have_http_status(:ok)"
              lines << "    end"
            when "create"
              lines << "    context \"with valid params\" do"
              lines << "      it \"creates a new #{snake.singularize}\" do"
              lines << "        expect {"
              lines << "          post #{helper}, params: { #{snake.singularize}: valid_attributes }"
              lines << "        }.to change(#{snake.singularize.camelize}, :count).by(1)"
              lines << "      end"
              lines << "    end"
              lines << ""
              lines << "    context \"with invalid params\" do"
              lines << "      it \"does not create\" do"
              lines << "        expect {"
              lines << "          post #{helper}, params: { #{snake.singularize}: invalid_attributes }"
              lines << "        }.not_to change(#{snake.singularize.camelize}, :count)"
              lines << "      end"
              lines << "    end"
            when "update"
              lines << "    it \"updates the #{snake.singularize}\" do"
              lines << "      patch #{helper}#{"(id: #{snake.singularize}.id)" if r[:name]}, params: { #{snake.singularize}: { name: \"Updated\" } }"
              lines << "      expect(response).to redirect_to(#{snake.singularize})"
              lines << "    end"
            when "destroy"
              lines << "    it \"destroys the #{snake.singularize}\" do"
              lines << "      #{snake.singularize} # ensure exists"
              lines << "      expect {"
              lines << "        delete #{helper}#{"(id: #{snake.singularize}.id)" if r[:name]}"
              lines << "      }.to change(#{snake.singularize.camelize}, :count).by(-1)"
              lines << "    end"
            else
              lines << "    it \"returns success\" do"
              lines << "      #{verb} #{helper}"
              lines << "      expect(response).to have_http_status(:ok)"
              lines << "    end"
            end

            lines << "  end"
          end

          if routes.empty?
            lines << "  it \"has tests\" do"
            lines << "    # No routes found for #{ctrl_class}. Add route-specific tests here."
            lines << "  end"
          end

          lines << "end"
          lines << "```"
          text_response(lines.join("\n"))
        end

        def generate_minitest_controller(ctrl_class, snake, routes, tests_data)
          file_path = "test/controllers/#{snake}_controller_test.rb"
          lines = [ "# #{file_path}", "", "```ruby", "# frozen_string_literal: true", "", "require \"test_helper\"", "" ]
          lines << "class #{ctrl_class}Test < ActionDispatch::IntegrationTest"

          has_devise = tests_data[:test_helper_setup]&.any? { |h| h.include?("Devise") }
          if has_devise
            lines << "  include Devise::Test::IntegrationHelpers"
            lines << ""
            lines << "  setup do"
            lines << "    @user = users(:one)"
            lines << "    sign_in @user"
            lines << "  end"
          end

          routes.each do |r|
            action = r[:action] || "index"
            path = r[:path] || "/#{snake}"
            verb = (r[:verb] || "GET").downcase

            lines << ""
            lines << "  test \"#{r[:verb]} #{r[:path]} works\" do"
            lines << "    #{verb} #{path.gsub(/:(\w+)/, '#{\\1}')}"
            lines << "    assert_response :success"
            lines << "  end"
          end

          lines << "end"
          lines << "```"
          text_response(lines.join("\n"))
        end

        # ── File-based test generation ───────────────────────────────────

        def generate_file_test(file, framework, patterns, tests_data, type)
          case file
          when %r{app/models/(.+)\.rb}
            model_name = $1.split("/").last.camelize
            generate_model_test(model_name, framework, patterns, tests_data)
          when %r{app/controllers/(.+)_controller\.rb}
            ctrl_name = "#{$1.split('/').map(&:camelize).join('::')}Controller"
            generate_controller_test(ctrl_name, framework, patterns, tests_data)
          when %r{app/services/(.+)\.rb}, %r{app/jobs/(.+)\.rb}
            class_name = $1.split("/").map(&:camelize).join("::")
            generate_service_test(class_name, file, framework)
          else
            text_response("Cannot auto-detect test type for `#{file}`. Use `model:` or `controller:` parameter instead.")
          end
        end

        def generate_service_test(class_name, file, framework)
          if framework == "rspec"
            path = "spec/services/#{class_name.underscore}_spec.rb"
            lines = [ "# #{path}", "", "```ruby", "# frozen_string_literal: true", "", "require \"rails_helper\"", "" ]
            lines << "RSpec.describe #{class_name} do"
            lines << "  describe \".call\" do"
            lines << "    it \"performs the expected action\" do"
            lines << "      # TODO: set up input and verify output"
            lines << "      result = described_class.call"
            lines << "      expect(result).to be_truthy"
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

        def find_factory_name(model_name, tests_data)
          factory_names = tests_data[:factory_names] || {}
          underscore = model_name.underscore
          # Look for a factory matching the model name
          factory_names.each_value do |names|
            return underscore.to_sym if names.include?(underscore.to_sym) || names.include?(underscore)
          end
          # Check if factories directory exists at all
          tests_data[:factories] ? underscore.to_sym : nil
        end
      end
    end
  end
end
