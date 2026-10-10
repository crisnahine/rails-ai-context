# frozen_string_literal: true

require "open3"

module RailsAiContext
  module Tools
    class Diagnose < BaseTool
      tool_name "rails_diagnose"
      description "One-call error diagnosis: parses the error, classifies it, gathers controller/model/schema context, " \
        "shows recent git changes, pulls relevant logs, and suggests a fix. " \
        "Use when: you hit an error and need to understand why. " \
        "Key params: error (required - paste the error message), file, line, action (controller#action)."

      input_schema(
        properties: {
          error: {
            type: "string",
            description: "Error message or exception (e.g. 'NoMethodError: undefined method `foo` for nil:NilClass')."
          },
          file: {
            type: "string",
            description: "File where error occurs, relative to Rails root (e.g. 'app/controllers/posts_controller.rb')."
          },
          line: {
            type: "integer",
            description: "Line number where the error occurs."
          },
          action: {
            type: "string",
            description: "Controller#action format (e.g. 'posts#create'). Pulls full action context."
          }
        },
        required: %w[error]
      )

      guide_row(
        order: 35,
        mcp: "rails_diagnose(error:\"X\")",
        cli_args: "error=\"X\"",
        summary: "One-call error diagnosis: context + git changes + logs + fix suggestions"
      )

      annotations(read_only_hint: true, destructive_hint: false, idempotent_hint: false, open_world_hint: true)

      # ── Error classification ──────────────────────────────────────────

      # Section size limits for output truncation
      MAX_TOTAL_OUTPUT = 20_000
      MAX_SECTION_CHARS = {
        controller_context: 3_000,
        model_context: 3_000,
        code_context: 3_000,
        schema_context: 3_000,
        method_trace: 3_000,
        git_changes: 2_000,
        logs: 2_000
      }.freeze

      ERROR_CLASSIFICATIONS = {
        /NameError.*uninitialized constant/ => {
          type: :name_error,
          likely: "A class or module constant could not be found. This usually means a typo in the class/module name, a missing require, or an autoload issue.",
          fix: "1. Check for typo in class/module name, missing require, or autoload issue\n2. Verify the file is in the correct autoload path (e.g. app/models, app/services)\n3. Run `rails_search_code(pattern:\"ClassName\", match_type:\"trace\")` to find where the constant is defined"
        },
        /NoMethodError/ => {
          type: :nil_reference,
          likely: "A method was called on nil or an undefined name was referenced. Check for: missing association, unfetched record, typo in method name.",
          fix: "1. Check the variable/object is not nil before calling the method\n2. Verify the association or attribute exists on the model\n3. Use `&.` safe navigation if the value can legitimately be nil"
        },
        /NameError/ => {
          type: :name_error,
          likely: "An undefined name was referenced. This could be a typo in a variable, method, or constant name, or a missing require/autoload.",
          fix: "1. Check for typo in class/module name, missing require, or autoload issue\n2. Verify the name is defined and accessible in the current scope\n3. Use `rails_search_code(pattern:\"name\", match_type:\"trace\")` to find where it is defined"
        },
        /RecordNotFound/ => {
          type: :record_not_found,
          likely: "A `.find()` or `.find_by!()` call failed because the record doesn't exist. Common causes: stale URL, deleted record, wrong ID parameter.",
          fix: "1. Use `.find_by` (returns nil) instead of `.find` (raises)\n2. Add a rescue handler or `before_action :set_record` with proper error handling\n3. Check the route parameter name matches what the controller expects"
        },
        /RecordInvalid|RecordNotSaved/ => {
          type: :validation_failure,
          likely: "A `.save!`, `.create!`, or `.update!` call failed validation. The model has validations that the submitted data doesn't satisfy.",
          fix: "1. Use `.save` (returns false) instead of `.save!` (raises) for user-facing flows\n2. Check model validations against the params being submitted\n3. Verify required associations exist before saving"
        },
        /RoutingError/ => {
          type: :routing,
          likely: "No route matches the request. The URL or HTTP verb doesn't match any defined route.",
          fix: "1. Run `rails_get_routes` to see all defined routes\n2. Check the HTTP verb (GET vs POST vs PATCH) matches\n3. Verify the route is not restricted by constraints"
        },
        /ParameterMissing/ => {
          type: :strong_params,
          likely: "A required parameter is missing from the request. The `params.require(:key)` call didn't find the expected key.",
          fix: "1. Check the form field names match what strong params expects\n2. Verify the parameter nesting (e.g., `params[:user][:name]` vs `params[:name]`)\n3. Check the controller's `*_params` method"
        },
        /StatementInvalid|UndefinedColumn|UndefinedTable/ => {
          type: :schema_mismatch,
          likely: "A database query references a column or table that doesn't exist. Common after migrations or in stale schema.",
          fix: "1. Run `rails db:migrate` to apply pending migrations\n2. Check `rails_get_schema(table:\"...\")` for actual column names\n3. Verify the migration was generated correctly"
        },
        /Template::Error|ActionView/ => {
          type: :view_error,
          likely: "An error occurred while rendering a view template. The underlying error is usually a NoMethodError or missing local variable.",
          fix: "1. Check the instance variables set in the controller action\n2. Verify partial locals are passed correctly\n3. Use `rails_get_view(controller:\"...\")` to see template structure"
        },
        /ArgumentError/ => {
          type: :argument_error,
          likely: "A method received wrong number or type of arguments.",
          fix: "1. Check the method signature matches the call site\n2. Use `rails_search_code(pattern:\"method_name\", match_type:\"trace\")` to see definition and callers"
        },
        # The authorization gems' two failures, by the words their class names share.
        /AuthorizationNotPerformed|PolicyScopingNotPerformed/ => {
          type: :authorization_not_performed,
          likely: "The action finished without authorizing, and a check that every action does raised: Pundit's `after_action :verify_authorized` (or `verify_policy_scoped`). The message names the controller.",
          fix: "1. Call `authorize record` (or `policy_scope(Model)`) in the action\n2. If the action is meant to be open, leave it out of the check: `skip_after_action :verify_authorized, only: :action_name`\n3. Use `rails_get_controllers(controller:\"...\", action:\"...\")` to see the filters that run on the action"
        },
        /NotAuthorized|AccessDenied/ => {
          type: :authorization_denied,
          likely: "An authorization rule refused the current user this action on this record. Pundit's message names the policy method that returned false; CanCanCan's the action and subject.",
          fix: "1. Read the policy method or ability rule the message names\n2. Check which user and record the request carried\n3. If refusing is expected, rescue it (`rescue_from`) and answer 403 instead of 500"
        }
      }.freeze

      def self.call(error:, file: nil, line: nil, action: nil, server_context: nil)
        return text_response("The `error` parameter is required.") if error.nil? || error.strip.empty?

        parsed = parse_error(error)
        classification = classify_error(parsed)
        # A refused path is said once and then read, traced and suggested nowhere.
        refusal = file && unsafe_path_message(file)
        file = nil if refusal

        lines = [ "# Error Diagnosis", "" ]
        lines << "**Error:** `#{parsed[:exception_class] || 'Unknown'}`"
        lines << "**Message:** #{parsed[:message]}"
        lines << "**Classification:** #{classification[:type]}"
        lines << ""

        # Likely cause - enriched with specific inference when possible
        lines << "## Likely Cause"
        lines << classification[:likely]
        specific = infer_specific_cause(parsed, classification, file, action)
        lines << "" << "**Specific:** #{specific}" if specific
        lines << ""

        # Suggested fix
        lines << "## Suggested Fix"
        lines << classification[:fix]
        lines << ""

        # Gather context based on parameters and error type
        context_sections = gather_context(parsed, classification, file, line, action)
        context_sections = [ "## Code Context", refusal, "" ] + context_sections if refusal

        # Recent git changes
        git_section = gather_git_context(file, parsed[:file_refs])

        # Recent error logs
        log_section = gather_log_context(parsed)

        # Truncate large sections before assembling final output
        context_sections = truncate_section(context_sections, "Controller Context", MAX_SECTION_CHARS[:controller_context])
        context_sections = truncate_section(context_sections, "Code Context", MAX_SECTION_CHARS[:code_context])
        context_sections = truncate_section(context_sections, "Schema Context", MAX_SECTION_CHARS[:schema_context])
        context_sections = truncate_section(context_sections, "Model Context", MAX_SECTION_CHARS[:model_context])
        context_sections = truncate_section(context_sections, "Method Trace", MAX_SECTION_CHARS[:method_trace])
        git_section = truncate_section(git_section, "Recent Git Changes", MAX_SECTION_CHARS[:git_changes])
        log_section = truncate_section(log_section, "Recent Error Logs", MAX_SECTION_CHARS[:logs])

        lines.concat(context_sections)
        lines.concat(git_section) if git_section.any?
        lines.concat(log_section) if log_section.any?

        # Next steps
        next_steps = []
        if file
          next_steps << "_Use `rails_get_edit_context(file:\"#{file}\", near:\"#{parsed[:method_name] || line || parsed[:exception_class]}\")` to see the code._"
        end
        if parsed[:method_name]
          next_steps << "_Use `rails_search_code(pattern:\"#{parsed[:method_name]}\", match_type:\"trace\")` to trace the method._"
        end
        if next_steps.any?
          lines << "## Next Steps"
          lines.concat(next_steps)
        end

        output = lines.join("\n")

        # Final safety cap: if total output still exceeds limit, hard-truncate
        if output.length > MAX_TOTAL_OUTPUT
          output = output[0, MAX_TOTAL_OUTPUT] + "\n\n_... output truncated (#{output.length} chars exceeded #{MAX_TOTAL_OUTPUT} limit)._"
        end

        text_response(output)
      rescue => e
        text_response("Diagnosis error: #{e.message}")
      end

      # A name an error message gives its exception: a class ending the way
      # exceptions are named, or any namespaced constant.
      EXCEPTION_CLASS = /[A-Z][\w:]*(?:Error|Exception|Invalid|NotFound|NotSaved|Missing)|[A-Z]\w*(?:::[A-Z]\w*)+/

      class << self
        private

        def parse_error(error_string)
          result = { exception_class: nil, message: error_string.strip, file_refs: [], method_name: nil }

          # Extract exception class: "NoMethodError: ..." or "ActiveRecord::RecordNotFound ..."
          first_line = error_string.strip.lines.first.to_s.strip
          if (m = error_string.match(/\A([\w:]+(?:Error|Exception|Invalid|NotFound|NotSaved|Missing))\s*[:—]\s*(.*)/m))
            result[:exception_class] = m[1]
            result[:message] = m[2].strip
          elsif (m = error_string.match(/\A([\w:]+::\w+)\s*[:—]\s*(.*)/m))
            result[:exception_class] = m[1]
            result[:message] = m[2].strip
          elsif (m = first_line.match(/\A(#{EXCEPTION_CLASS}) \((.*)\):?\z/o))
            # As a Rails log writes it: "Pundit::NotAuthorizedError (not allowed to ...):".
            result[:exception_class] = m[1]
            result[:message] = m[2].strip
          elsif first_line.match?(/\A#{EXCEPTION_CLASS}\z/o)
            result[:exception_class] = first_line
          end

          # Extract file:line references
          error_string.scan(%r{(app/\S+\.rb):(\d+)}).each do |file, line|
            result[:file_refs] << { file: file, line: line.to_i }
          end

          # Extract method name from "undefined method `foo`" or "undefined method 'foo'"
          if (m = result[:message].match(/undefined method [`'](\w+[?!]?)[`']/))
            result[:method_name] = m[1]
          end

          # When the error is a bare message with no "ClassName:" prefix - e.g. a
          # line copied from a browser error page, or Ruby 3.4+'s
          # "undefined method 'x' for an instance of Y" phrasing that drops the
          # trailing "(NoMethodError)" - infer the class from the message
          # signature. classify_error matches on "exception_class message", so a
          # recovered class name resolves both the header and the classification.
          result[:exception_class] ||= infer_exception_class(result[:message])

          result
        end

        # Map a raw error message (no class prefix) to its Ruby/Rails exception
        # class by signature. Returns nil when nothing matches so the caller
        # keeps the "Unknown" fallback. Order matters: the NameError
        # "undefined local variable or method" phrasing is checked before the
        # NoMethodError "undefined method" phrasing it shares a prefix with.
        EXCEPTION_SIGNATURES = [
          [ /undefined local variable or method\b/, "NameError" ],
          [ /uninitialized constant\b/, "NameError" ],
          [ /undefined method\b/, "NoMethodError" ],
          [ /wrong number of arguments|missing keywords?:|unknown keywords?:/, "ArgumentError" ],
          [ /couldn't find .+ with/i, "ActiveRecord::RecordNotFound" ],
          [ /param is missing or the value is empty/i, "ActionController::ParameterMissing" ],
          [ /no route matches/i, "ActionController::RoutingError" ],
          [ /no such column|no such table|relation ".+" does not exist|column .+ does not exist/i, "ActiveRecord::StatementInvalid" ]
        ].freeze

        def infer_exception_class(message)
          return nil if message.nil? || message.empty?

          EXCEPTION_SIGNATURES.each do |pattern, klass|
            return klass if message.match?(pattern)
          end
          nil
        end

        def classify_error(parsed)
          model_specific = classify_undefined_method_on_model(parsed)
          return model_specific if model_specific

          on_receiver = classify_method_on_receiver(parsed)
          return on_receiver if on_receiver

          error_str = "#{parsed[:exception_class]} #{parsed[:message]}"

          ERROR_CLASSIFICATIONS.each do |pattern, info|
            return info if error_str.match?(pattern)
          end

          unclassified(parsed[:exception_class])
        end

        # No rule here covers the class, so the answer says what it is and
        # where it comes from, which is where reading starts.
        def unclassified(exception_class)
          origin = exception_origin(exception_class)
          likely = if origin
            "No rule here covers `#{exception_class}`, which #{origin}. Its message says what failed; " \
              "what raises it, and why, is in that code."
          else
            "Unable to automatically classify this error. Review the full error message and stack trace."
          end
          {
            type: :unknown,
            likely: likely,
            fix: "1. Check the error message for clues about what went wrong\n" \
                 "2. Use `rails_search_code(pattern:\"#{exception_class&.split("::")&.last || "ErrorName"}\")` to find where the app raises or rescues it\n" \
                 "3. Use `rails_read_logs(level:\"ERROR\")` for the backtrace"
          }
        end

        # The Rails namespaces that ship in a gem named for none of them.
        ACTIONPACK_NAMESPACES = %w[action_controller action_dispatch abstract_controller].to_h { |top| [ top, "actionpack" ] }.freeze

        # Booted, Ruby knows the file that defines the class; statically, or
        # for a class nothing has loaded yet, a locked gem named after the
        # class's top namespace is the likely one.
        def exception_origin(name)
          return nil if name.to_s.empty?

          unless RailsAiContext.static_tier?
            # Resolved first: a constant still waiting on its autoload has no location yet.
            path = name.safe_constantize && (Object.const_source_location(name) rescue nil)&.first
            if path
              spec = Gem.loaded_specs.values.find { |s| path.start_with?("#{s.full_gem_path}/") }
              return "the #{spec.name} gem (#{spec.version}) defines" if spec

              root = "#{rails_app.root}/"
              return "this app defines in `#{path.delete_prefix(root)}`" if path.start_with?(root)
            end
          end

          top = name.split("::").first.to_s.underscore
          lock = RailsAiContext::GemLock.for(rails_app.root.to_s)
          gem = [ ACTIONPACK_NAMESPACES[top], top, top.delete("_"), top.dasherize ].compact.uniq.find { |candidate| lock.present?(candidate) }
          "is likely the #{gem} gem's (the app's bundle locks #{gem} #{lock.version(gem)})" if gem
        rescue StandardError => e
          RailsAiContext.debug_fail(e, nil, label: "exception_origin")
        end

        # Only a nil receiver makes a NoMethodError a nil reference. On any
        # other object the method is missing from it - a typo, or the wrong
        # object - and `&.` would hide the error rather than fix it.
        NIL_RECEIVER = /\bfor nil\b/
        VISIBILITY = /\A(private|protected) method [`'](\w+[?!=]?)['`] called for/

        def classify_method_on_receiver(parsed)
          message = parsed[:message].to_s
          receiver = extract_receiver_class(message)
          if (m = message.match(VISIBILITY))
            return {
              type: :non_public_method,
              likely: "`#{m[2]}` is #{m[1]} on #{receiver ? "`#{receiver}`" : "the receiver"}, so it cannot be called from outside the object.",
              fix: "1. Call it from inside the class, or make it public if it is part of the interface\n" \
                   "2. Use `rails_search_code(pattern:\"#{m[2]}\", match_type:\"definition\")` to see where it is defined and under which visibility"
            }
          end

          name = parsed[:method_name]
          return nil unless name && message.match?(/undefined method/) && message.match?(/ for /) && !message.match?(NIL_RECEIVER)

          defined, suggestion = receiver_methods(receiver, name, class_receiver: message.match?(/for class |:Class\b/))
          subject = receiver ? "`#{receiver}`" : "The receiver"
          likely = if defined
            "#{subject} defines `#{name}` in this process, so the object that raised was not the one you expect, " \
              "or it ran on code loaded before the method was added: restart a long-running server."
          else
            "#{subject} has no method `#{name}`. The receiver is not nil, so this is no nil reference: " \
              "the name is misspelled, or the method belongs to another object.#{" Did you mean `#{suggestion}`?" if suggestion}"
          end
          {
            type: :undefined_method,
            likely: likely,
            fix: "1. #{suggestion ? "Call `#{suggestion}`, the method #{subject} has" : "Check the name against the methods #{subject} defines"}\n" \
                 "2. Check the call goes to the object you think: an association or a presenter can hand back another class\n" \
                 "3. Use `rails_search_code(pattern:\"#{name}\", match_type:\"trace\")` to find its definition and its callers"
          }
        end

        # Booted, the loaded class answers whether it has the method, and the
        # name it has that is closest to the one called. Statically there is
        # no class to ask.
        def receiver_methods(receiver, name, class_receiver:)
          return [ false, nil ] if receiver.nil? || RailsAiContext.static_tier?

          klass = receiver.safe_constantize
          return [ false, nil ] unless klass.is_a?(Module)

          names = (class_receiver ? klass.public_methods : klass.public_instance_methods).map(&:to_s)
          return [ true, nil ] if names.include?(name)

          [ false, ::DidYouMean::SpellChecker.new(dictionary: names).correct(name).first ]
        rescue StandardError, ScriptError => e
          RailsAiContext.debug_fail(e, [ false, nil ], label: "receiver_methods")
        end

        # Patterns that name the receiver of a NoMethodError:
        #   "undefined method 'x' for an instance of Article"  (Ruby 3.3+)
        #   "undefined method `x' for #<Article id: 1>"        (Ruby <= 3.2)
        #   "undefined method `x' for #<struct Summary ...>"   (a Struct, <= 3.2)
        #   "undefined method 'x' for class Article"           (class receiver, 3.3+)
        #   "undefined method `x' for Article:Class"           (class receiver, <= 3.2)
        RECEIVER_PATTERNS = [
          /for an instance of ([A-Z]\w*(?:::\w+)*)/,
          /for #<(?:struct )?([A-Z]\w*(?:::\w+)*)/,
          /for class ([A-Z]\w*(?:::\w+)*)/,
          /for ([A-Z]\w*(?:::\w+)*):Class/
        ].freeze

        # An undefined method on an ActiveRecord model deserves a schema-aware
        # diagnosis instead of the generic nil-receiver advice: check the
        # method against the model's real associations, columns, and declared
        # methods, and say directly when none of them define it. Returns nil
        # (falling through to the generic classifications) when the receiver
        # is not a known model or the method does exist on it.
        def classify_undefined_method_on_model(parsed)
          method_name = parsed[:method_name]
          return nil unless method_name
          return nil unless parsed[:message].to_s.match?(/undefined method/)

          receiver = extract_receiver_class(parsed[:message].to_s)
          return nil unless receiver

          models = cached_context[:models]
          return nil unless models.is_a?(Hash)
          model_data = models[receiver]
          return nil unless model_data.is_a?(Hash) && !model_data[:error]

          # Booted, the loaded class is the whole answer: it carries a
          # concern's methods and a gem's, which no payload list does.
          live = live_method_defined?(receiver, method_name)
          return nil if live == true

          # Otherwise a negative claim cannot be read off a partial list: a
          # method past the display cap was reported as not existing in the
          # same answer that printed its definition.
          return nil if live.nil? && source_methods_missing?(model_data)

          known = known_model_methods(model_data)
          # "published?" / "save!" resolve through the bare attribute name, so
          # compare without the trailing punctuation too.
          base_name = method_name.to_s.sub(/[?!]\z/, "")
          return nil if known.include?(base_name) || known.include?(method_name.to_s)

          suggestion = find_closest_match(base_name, known)
          likely = "No association/column named `#{base_name}` on #{receiver}. " \
                   "The model defines neither an association nor an attribute with that name, " \
                   "so the method does not exist."
          likely += " Did you mean `#{suggestion}`?" if suggestion

          {
            type: :undefined_method_on_model,
            likely: likely,
            fix: "1. Run `rails_get_model_details(model:\"#{receiver}\")` to see #{receiver}'s real associations and columns\n" \
                 "2. Check for a typo in the method name or a missing association declaration (has_many/belongs_to)\n" \
                 "3. If the data lives on another model, add the association or a delegate"
          }
        end

        def extract_receiver_class(message)
          RECEIVER_PATTERNS.each do |pattern|
            if (m = message.match(pattern))
              return m[1]
            end
          end
          nil
        end

        # True when the names the model carries cannot answer whether a method
        # exists: a method a concern or a parent defines is reflection's to
        # report, and reflection's list is the capped one.
        def source_methods_missing?(model_data)
          return false unless reflection_list_truncated?(model_data)
          return true unless model_data[:source_instance_methods].is_a?(Array)

          Array(model_data[:concerns]).any? || !model_data[:sti].nil? || Array(model_data[:inherited_from]).any?
        end

        # Never the count alone: it is reflection's, and ActiveRecord defines
        # an attribute method per column the first time a model is
        # instantiated, so it passes the cap on an ordinary model as soon as
        # the app is warm.
        def reflection_list_truncated?(model_data)
          count = model_data[:instance_method_count]
          count.is_a?(Integer) && count > Array(model_data[:instance_methods]).size
        end

        # Everything legitimately callable on the model that introspection
        # knows about: associations, table columns, and declared methods.
        def known_model_methods(model_data)
          names = Array(model_data[:associations]).filter_map { |a| (a[:name] || a["name"])&.to_s }
          names += Array(model_data[:instance_methods]).map(&:to_s)
          # Uncapped, and the half of the set a display cap must never decide.
          names += Array(model_data[:source_instance_methods]).map(&:to_s)
          names += Array(model_data[:class_methods]).map(&:to_s)
          names += Array(model_data[:scopes]).filter_map { |s| s.is_a?(Hash) ? (s[:name] || s["name"])&.to_s : s.to_s }

          table = model_data[:table_name].to_s
          columns = RailsAiContext::Payload.schema_table(cached_context[:schema], table)&.dig(:columns)
          names += Array(columns).filter_map { |c| (c[:name] || c["name"])&.to_s }

          names.uniq
        end

        def gather_context(parsed, classification, file, line, action)
          lines = []

          ctrl, act = action.split("#", 2) if action
          if ctrl && act
            add_section(lines, "Controller Context", report_error: true) do
              ctrl_class = ctrl.end_with?("Controller") ? ctrl : "#{ctrl.camelize}Controller"
              GetControllers.call(controller: ctrl_class, action: act)
            end
          end

          if file && line
            add_section(lines, "Code Context", report_error: true) do
              GetEditContext.call(file: file, near: parsed[:method_name] || line.to_s)
            end
          end

          if classification[:type] == :schema_mismatch
            table = parsed[:message].match(/(?:table|relation)\s+["']?(\w+)["']?/i)&.[](1)
            add_section(lines, "Schema Context") { GetSchema.call(table: table) } if table
          end

          if classification[:type] == :validation_failure
            model_name = file&.match(%r{app/models/(.+)\.rb})&.[](1)&.camelize
            add_section(lines, "Model Context") { GetModelDetails.call(model: model_name) } if model_name
          end

          if parsed[:method_name] && lines.none? { |l| l.include?("Code Context") }
            add_section(lines, "Method Trace") do
              result = SearchCode.call(pattern: parsed[:method_name], match_type: "trace")
              # A trace that found callers but no `def` is still not the
              # method's definition, which is what this section promises.
              definition_missing?(result) ? nil : result
            end
          end

          lines
        end

        # A sub-tool's answer as a titled section. An empty answer adds nothing;
        # a raise either says why in the section or is dropped under DEBUG.
        def add_section(lines, title, report_error: false)
          result = yield
          return if result.nil? || empty?(result)

          lines << "## #{title}" << response_text(result) << ""
        rescue => e
          return RailsAiContext.debug_fail(e, nil, label: "diagnose #{title}") unless report_error

          lines << "## #{title}" << "_Could not load: #{e.message}_" << ""
        end

        # Infer a specific diagnosis from the error + context
        def infer_specific_cause(parsed, classification, file, action)
          msg = parsed[:message].to_s
          method = parsed[:method_name]

          # "undefined method X for nil" - identify WHAT is nil
          if classification[:type] == :nil_reference && msg.include?("for nil")
            # Check if calling on current_user (common: auth not running)
            if file&.include?("controller") && msg.match?(/current_user/)
              return "`current_user` is nil - the `authenticate_user!` before_action may not be running for this route. " \
                     "Check if this action is excluded via `unless:` or `skip_before_action`."
            end
            # Check if calling on an association
            if method && file
              begin
                ctx = GetEditContext.call(file: file, near: method)
                code = response_text(ctx)
                # Find the receiver: something.method_name
                receiver_match = code.match(/(\w+)\.#{Regexp.escape(method)}/)
                if receiver_match
                  receiver = receiver_match[1]
                  return "`#{receiver}` is nil when `.#{method}` is called. " \
                         "This variable may not be set in all code paths - check if it's assigned before use, " \
                         "or use `#{receiver}&.#{method}` for safe navigation."
                end
              rescue => e; RailsAiContext.debug_fail(e, nil, label: "diagnose specific cause"); end
            end
          end

          # RecordNotFound - check if there's a set_* before_action
          if classification[:type] == :record_not_found && action
            ctrl, act = action.split("#", 2)
            if ctrl && act
              begin
                ctrl_class = ctrl.end_with?("Controller") ? ctrl : "#{ctrl.camelize}Controller"
                result = GetControllers.call(controller: ctrl_class, action: act)
                text = response_text(result)
                if text.include?("set_") && text.include?("find")
                  return "The `set_*` before_action uses `.find` which raises RecordNotFound. " \
                         "The record with the given ID doesn't exist or doesn't belong to the current user. " \
                         "Check if the record was deleted or if the user is authorized to access it."
                end
              rescue => e; RailsAiContext.debug_fail(e, nil, label: "diagnose specific cause"); end
            end
          end

          nil
        end

        def gather_git_context(file, file_refs)
          lines = []
          root = rails_app.root.to_s

          files_to_check = [ file, *file_refs.map { |r| r[:file] } ].compact.uniq.first(3)
          return lines if files_to_check.empty?
          return lines unless git_repository?(root)

          git_output = []
          files_to_check.each do |f|
            full = File.join(root, f)
            next unless File.exist?(full)
            output, status = Open3.capture2("git", "log", "--oneline", "-5", "--", f, chdir: root, err: File::NULL)
            if status.success? && !output.strip.empty?
              git_output << "**#{f}:**\n#{output.strip}"
            end
          end

          if git_output.any?
            lines << "## Recent Git Changes"
            lines.concat(git_output)
            lines << ""
          end

          lines
        rescue => e
          RailsAiContext.debug_fail(e, [], label: "gather_git_context")
        end

        # A `.git` entry is a file in a worktree and a submodule, so ask git
        # rather than stat the path. Child stderr goes to File::NULL: git's
        # "fatal: not a git repository" would otherwise land on the server
        # terminal for an app that simply is not in one.
        def git_repository?(root)
          _, status = Open3.capture2("git", "rev-parse", "--git-dir", chdir: root, err: File::NULL)
          status.success?
        end

        # The window rails_read_logs reads: the log's last megabyte. Fifteen
        # lines, as this read before, rarely reached back to the error at all.
        LOG_WINDOW = ReadLogs::MAX_READ_BYTES
        # How far either side of the error line its request is looked for.
        ENTRY_SPAN = 400
        FRAMES_SHOWN = 5
        LOG_TAG = /\A(\[[^\]]+\]) /
        ANSI = /\e\[[\d;]*m/
        REQUEST_LINE = /\A\s*(?:Started [A-Z]+ "|Processing by |Parameters: |Completed \d{3} )/
        BACKTRACE_FRAME = /\S:\d+:in /

        # The request that raised it: the log entry carrying the error, with
        # the request's own lines (path, action, parameters, status) and the
        # first frames of its backtrace, redacted.
        def gather_log_context(parsed)
          exception_class = parsed[:exception_class]
          return [] unless exception_class

          located = RailsAiContext::SafePath.locate(File.join("log", "#{rails_env_name}.log"), under: rails_app.root.to_s, max_size: Float::INFINITY)
          return [] unless located.ok?

          lines = log_tail(located.realpath)
          hit = lines.rindex { |line| log_match?(line, parsed) }
          where = "the last #{count_phrase(lines.size, "line")} of `#{located.relative}`"
          return [ "## Recent Error Logs", "_No entry for `#{exception_class}` in #{where}._", "" ] unless hit

          tag, entry = log_entry(lines, hit)
          request = tag ? ", request `#{tag[1..-2]}`" : ""
          begin
            redacted = RailsAiContext::Redaction.redact_log_lines(entry)
          rescue StandardError => e
            # Never shown unredacted: the entry is named, not printed.
            return [ "## Recent Error Logs", "_An entry for it#{request} is in #{where}, not shown: redacting it failed (#{e.class})._", "" ]
          end
          [ "## Recent Error Logs", "_The latest entry for it in #{where}#{request}:_", "```", *redacted, "```", "" ]
        rescue => e
          RailsAiContext.debug_fail(e, [], label: "gather_log_context")
        end

        def log_tail(path)
          File.open(path, "rb") do |file|
            cut = file.size > LOG_WINDOW
            file.seek(-LOG_WINDOW, IO::SEEK_END) if cut
            lines = file.read.force_encoding("UTF-8").scrub("?").split("\n")
            # The window's first line starts mid-line.
            cut ? lines.drop(1) : lines
          end
        end

        # A line naming the class, and the method or the message too when the
        # error gives one, whichever quotes the Ruby that wrote it used.
        def log_match?(line, parsed)
          return false unless line.include?(parsed[:exception_class])
          return line.match?(/[`']#{Regexp.escape(parsed[:method_name])}'/) if parsed[:method_name]

          key = loose(parsed[:message])[0, 60]
          key == parsed[:exception_class] || loose(line).include?(key)
        end

        def loose(text)
          text.to_s.tr("`", "'").gsub(/\s+/, " ").strip
        end

        # The error line's request: its request-id tag when the log writes one,
        # else the nearest "Started" line above it.
        def log_entry(lines, index)
          tag = lines[index][LOG_TAG, 1]
          own = ->(line) { tag.nil? || line.start_with?(tag) }
          text = ->(line) { (tag && line.start_with?(tag) ? line.delete_prefix(tag).delete_prefix(" ") : line).gsub(ANSI, "") }

          from = [ index - ENTRY_SPAN, 0 ].max
          started = (from...index).reverse_each.find { |i| own.call(lines[i]) && text.call(lines[i]).match?(/\AStarted [A-Z]+ "/) }
          request = started ? (started...index).select { |i| own.call(lines[i]) && text.call(lines[i]).match?(REQUEST_LINE) } : []

          frames = []
          ((index + 1)...[ index + ENTRY_SPAN, lines.size ].min).each do |i|
            # A logger tags a message's first line only, so an untagged line
            # continues the one above it.
            next unless own.call(lines[i]) || !lines[i].match?(LOG_TAG)

            line = text.call(lines[i])
            next if line.strip.empty?
            break unless line.match?(BACKTRACE_FRAME) && frames.size < FRAMES_SHOWN

            frames << i
          end

          [ tag, (request + [ index ] + frames).map { |i| text.call(lines[i]).rstrip } ]
        end

        # Truncate the content of a named section (identified by "## heading") within a lines array.
        # Returns a new array with the section's content lines truncated if they exceed max_chars.
        def truncate_section(lines, heading, max_chars)
          return lines if lines.empty? || max_chars.nil?

          header_marker = "## #{heading}"
          header_idx = lines.index(header_marker)
          return lines unless header_idx

          # Find the end of this section: next "## " header or end of array
          section_end = nil
          (header_idx + 1...lines.length).each do |i|
            if lines[i].is_a?(String) && lines[i].start_with?("## ")
              section_end = i
              break
            end
          end
          section_end ||= lines.length

          # Measure content between header and section_end
          content_lines = lines[(header_idx + 1)...section_end]
          content = content_lines.join("\n")

          return lines if content.length <= max_chars

          # Truncate and rebuild
          truncated_content = content[0, max_chars]
          truncated_content += "\n\n_... section truncated (#{content.length} chars → #{max_chars} max)._"

          result = lines[0...header_idx + 1]
          result << truncated_content
          result << ""
          result.concat(lines[section_end..])
          result
        end
      end
    end
  end
end
