# frozen_string_literal: true

module RailsAiContext
  module Tools
    class GetConcern < BaseTool
      tool_name "rails_get_concern"
      description "Get ActiveSupport::Concern details: public methods, included modules, and which models/controllers include it. " \
        "Use when: understanding shared behavior, checking concern interfaces, or finding where a concern is used. " \
        "Specify name:\"Searchable\" for full detail, or omit for a list of all concerns. Filter with type:\"model\" or type:\"controller\"."

      input_schema(
        properties: {
          name: {
            type: "string",
            description: "Concern module name (e.g. 'Searchable', 'Authenticatable'). Omit to list all concerns."
          },
          type: {
            type: "string",
            description: "Filter by concern type, the name each section heading of the listing prints: model for app/models/concerns/, mailer for app/mailers/concerns/, and for a concern outside every concerns directory the root it lives in (service for app/services, lib for lib). other: app/concerns itself, or a configured directory. all: everything (default)."
          },
          detail: RailsAiContext::DetailLevel.schema("Detail level, read when `name` is given. summary and standard (default): method signatures. full: method signatures with source code.")
        }
      )

      guide_row(
        order: 12,
        mcp: "rails_get_concern(name:\"X\", detail:\"full\")",
        cli_args: "name=X detail=full",
        summary: "Concern methods with source + which models include it"
      )

      annotations(read_only_hint: true, destructive_hint: false, idempotent_hint: true, open_world_hint: false)

      # Model and controller concerns lead because that is where most apps keep
      # most of them; anything else follows in discovery order.
      SECTION_ORDER = %w[model controller mailer job channel helper].freeze

      def self.call(name: nil, type: "all", detail: "standard", server_context: nil)
        blank = blank_name_response("name", name, kind: "concern")
        return blank if blank

        root = rails_app.root.to_s
        max_size = RailsAiContext.configuration.max_file_size

        # The heading prints the type camelized, so either spelling is taken.
        type = type.to_s.underscore unless type.nil?
        concern_dirs = resolve_concern_dirs(root, type)
        outside = ConcernPaths.outside(root).select { |o| type.nil? || type == "all" || o.type == type }

        # The name is refused on its own terms. Deciding this inside the
        # directory loop meant an app with no concern directory answered
        # "not found" for a traversal.
        refused = refuse_name(name, root)
        return refused if refused

        if concern_dirs.empty? && outside.empty?
          types = ConcernPaths.types(root)
          if types.any? && !(type.nil? || type == "all")
            return text_response("No concerns of type `#{type}`. Types this app has: #{types.map { |t| "`#{t}`" }.join(', ')}.")
          end

          return text_response("No concern directories found. Searched: #{searched_dirs(type).join(', ')}")
        end

        # Specific concern - full detail
        if name
          return show_concern(name, concern_dirs, root, max_size, detail, outside)
        end

        # List all concerns
        list_concerns(concern_dirs, root, outside)
      end

      private_class_method def self.refuse_name(name, root)
        return nil if name.nil? || name.to_s.empty?

        located = RailsAiContext::SafePath.locate(concern_relative(name), under: root, root: root)
        case located.refusal
        when :traversal then error_response("Path not allowed: #{name}")
        when :sensitive then error_response("Path not allowed: #{name} (sensitive file)")
        end
      end

      private_class_method def self.concern_relative(name)
        "#{name.to_s.underscore}.rb"
      end

      private_class_method def self.resolve_concern_dirs(root, type)
        dirs = ConcernPaths.resolve(root)
        return dirs if type.nil? || type == "all"

        dirs.select { |dir| ConcernPaths.type_for(dir) == type }
      end

      private_class_method def self.searched_dirs(type)
        return [ "app/concerns/", "app/*/concerns/" ] if type.nil? || type == "all"
        return [ "app/concerns/", "any configured directory outside app/*/concerns" ] if type == "other"

        [ "app/#{type.pluralize}/concerns/" ]
      end

      private_class_method def self.show_concern(name, concern_dirs, root, max_size, detail = "standard", outside = [])
        if name.nil? || name.to_s.empty?
          return text_response("The `name` parameter is required.")
        end

        relative = concern_relative(name)

        # One name can sit in more than one concerns directory - the default
        # glob returns every app/*/concerns - so every match is kept and the
        # ones below the first are named against the file that is read.
        matches = []
        # A file the name reaches that links out of the app is refused, unless the name finds its concern elsewhere.
        refused = nil

        concern_dirs.each do |dir|
          located = RailsAiContext::SafePath.locate(relative, under: dir, root: root, max_size: max_size)
          case located.refusal
          when :too_large
            next if matches.any?
            return text_response("Concern file too large: #{located.realpath} (#{File.size(located.realpath)} bytes, max: #{max_size})")
          when :sensitive
            next if matches.any?
            return error_response("Path not allowed: #{name} (sensitive file)")
          when :outside
            refused = "Path not allowed: #{name}"
            next
          when :missing then next
          end

          matches << [ located.realpath, located.relative, ConcernPaths.type_for(dir), dir ]
        end

        real_root = File.realpath(root).to_s
        outside_files(outside, real_root).each do |real, real_dir, concern_type|
          next unless real.delete_prefix("#{real_dir}/") == relative

          matches << [ real, real.delete_prefix("#{real_root}/"), concern_type, real_dir ]
        end

        # A file whose path does not spell its constant (a plugin's concerns/group.rb declaring
        # Plugin::Group) is found by the constant.
        if matches.empty?
          concern_files(concern_dirs, outside, real_root).each do |real, real_dir, concern_type|
            next unless ConcernPaths.name_for(real, real_dir, RailsAiContext::SafeFile.read(real)).casecmp?(name.to_s)

            matches << [ real, real.delete_prefix("#{real_root}/"), concern_type, real_dir ]
          end
        end

        file_path, relative_path, concern_type, concern_dir = matches.first

        unless file_path
          return error_response(refused) if refused

          # Build available list for fuzzy match
          available = collect_concern_names(concern_dirs, real_root, outside)
          return not_found_response("Concern", name, available,
            recovery_tool: "Call rails_get_concern() to see all concerns")
        end

        source = RailsAiContext::SafeFile.read(file_path)
        return text_response("Could not read concern file: #{file_path}") unless source
        # However the caller spelled it, the answer is headed by the constant
        # the file declares, so both spellings name the one concern.
        name = ConcernPaths.name_for(file_path, File.realpath(concern_dir).to_s, source)
        lines = [ "# #{name}", "" ]
        lines << "**File:** `#{relative_path}` (#{count_phrase(source.lines.size, "line")})"
        validator = Introspectors::SuperclassChain.validator_base(source, name: name, lookup: Introspectors::SuperclassChain.lookup_for(root.to_s))
        lines << (validator ? "**Type:** validator (`#{validator}`)" : "**Type:** #{concern_type} concern")

        # A second file at the same relative path answers the same name, and
        # everything below is read from the first one only. The other files are
        # named by path, not by the module they declare - that need not match.
        if matches.size > 1
          others = matches.drop(1).map { |_real, rel, type, _dir| "`#{rel}` (#{type} concern)" }
          lines << "**Also at:** #{others.join(', ')}"
        end

        # Only the module's own mixins: a class nested in the file includes for itself.
        mixins = ConcernMembership.owned_by(
          Introspectors::SourceIntrospector.walk_source(source, { mixins: Introspectors::Listeners::MixinsListener })[:mixins], name, root: root
        )
        conditions = mixin_conditions(source)
        included_modules = mixins.select { |m| m[:macro] == :include }.map { |m| mixin_label(m, conditions, name) }.uniq
        extended_modules = mixins.select { |m| m[:macro] == :extend }.map { |m| mixin_label(m, conditions, name) }.uniq
        if included_modules.any?
          lines << "**Includes:** #{included_modules.join(', ')}"
        end
        if extended_modules.any?
          lines << "**Extends:** #{extended_modules.join(', ')}"
        end

        # Parse class-level macros inside included/class_methods blocks
        macros = parse_concern_macros(source)
        if macros.any?
          lines << "" << "## Macros & DSL"
          macros.each { |m| lines << "- #{m}" }
        end

        public_methods = unique(Introspectors::ActionResolver.public_methods_in(source, owner: name))
        class_methods = concern_class_methods(source, name)
        own_module_methods = module_methods(source, name)
        render_methods(lines, source, detail, "Public Methods", public_methods)
        render_methods(lines, source, detail, "Class Methods", class_methods)
        render_methods(lines, source, detail, "Module Methods", own_module_methods)
        # The includer gets these too, and a `helper_method` hands them to its views.
        render_methods(lines, source, detail, "Private Methods",
          unique(Introspectors::ActionResolver.private_methods_in(source, owner: name)))

        # Parse callbacks defined in the concern
        callbacks = parse_concern_callbacks(source)
        if callbacks.any?
          lines << "" << "## Callbacks"
          callbacks.each { |c| lines << "- `#{c}`" }
        end

        # A validator is wired with `validates_with` (or, for an
        # EachValidator, the option key its name gives), never with `include`,
        # so looking for an include reported every validator as dead code.
        if validator
          users = find_validator_users(name, root)
          if users.any?
            lines << "" << "## Validated By (#{users.size})"
            users.each { |u| lines << "- #{u}" }
          else
            lines << "" << "_No model or concern in app/models wires this validator._"
          end

          lines << "" << "_Next: `rails_search_code(pattern:\"#{name.demodulize.camelize}\")` for every use_"
          return text_response(lines.join("\n"))
        end

        # Find which models/controllers include this concern
        includers = find_includers(name, root)
        if includers.any?
          lines << "" << "## Included By (#{includers.size})"
          includers.each { |i| lines << "- #{i}" }
        else
          lines << "" << "_Nothing under #{includer_locations(root)} includes this concern._"
        end

        # Cross-reference hints
        lines << ""
        case concern_type
        when "model"
          lines << "_Next: `rails_get_model_details(model:\"ModelName\")` for models using this concern_"
        when "controller"
          lines << "_Next: `rails_get_controllers(controller:\"ControllerName\")` for controllers using this concern_"
        else
          lines << "_Next: `rails_search_code(pattern:\"include #{name.demodulize.camelize}\")` for everything using this concern_"
        end

        text_response(lines.join("\n"))
      end

      # The body comes from this def's own walked bounds, so a same-named private method or delegate is never shown.
      private_class_method def self.render_methods(lines, source, detail, title, methods)
        return if methods.empty?

        lines << "" << "## #{title}"
        full = RailsAiContext::DetailLevel.full?(detail)
        methods.each do |m|
          signature = Introspectors::ActionResolver.signature(m)
          # The private list holds the protected ones too.
          visibility = m[:visibility] == :protected ? " (protected)" : ""
          body = full && Introspectors::ActionResolver.body_of(source, m)
          if body
            lines << "### #{signature}#{visibility}" << "```ruby" << RailsAiContext::Redaction.redact_source(body[:code]) << "```" << ""
          else
            lines << "- `#{signature}`#{visibility}"
          end
        end
      end

      # `include Pagy::Backend if defined?(Pagy::Backend)` mixes in only when
      # its condition holds; pagy 43 has no Backend at all.
      private_class_method def self.mixin_conditions(source)
        calls = Introspectors::SourceIntrospector.walk_source(source, {
          calls: -> { Introspectors::Listeners::ConditionalMacroListener.new(:include, :extend, :prepend) }
        })[:calls]
        Array(calls).each_with_object({}) do |call, found|
          next unless call[:condition]

          Array(call[:values]).each { |value| found[[ call[:macro], value.to_s, call[:location] ]] = call[:condition] }
        end
      rescue => e
        RailsAiContext.debug_fail(e, {}, label: "mixin_conditions")
      end

      private_class_method def self.mixin_label(mixin, conditions, concern_name)
        condition = conditions[[ mixin[:macro], mixin[:name], mixin[:location] ]]
        return mixin[:name] unless condition

        "#{mixin[:name]} (only `#{condition}`#{mixin_verdict(mixin, concern_name)})"
      end

      # Booted, the loaded constants say what the condition did: a module that
      # does not exist was never mixed in, and one the concern carries was.
      # Anything else stays the condition alone - an `included do` include
      # lands on the includer, not on the concern.
      private_class_method def self.mixin_verdict(mixin, concern_name)
        return "" if RailsAiContext.static_tier?

        mod = mixin[:name].safe_constantize
        return "; not mixed in here: `#{mixin[:name]}` is not defined" unless mod.is_a?(Module)

        concern = concern_name.to_s.safe_constantize
        target = mixin[:macro] == :extend ? concern&.singleton_class : concern
        target.is_a?(Module) && target.include?(mod) ? "; mixed in here" : ""
      rescue StandardError, ScriptError => e
        RailsAiContext.debug_fail(e, "", label: "mixin_verdict")
      end

      # `module ClassMethods` defs count too: ActiveSupport::Concern extends the includer with it.
      private_class_method def self.concern_class_methods(source, name)
        gained = own_class_methods(source, name).select { |m| m[:class_methods_block] }
        unique(gained + Introspectors::ActionResolver.public_methods_in(source, owner: "#{name}::ClassMethods"))
      end

      # `def self.x` and `class << self` methods live on the module; no includer gains them, nor a mixin hook.
      private_class_method def self.module_methods(source, name)
        unique(own_class_methods(source, name).reject { |m| m[:class_methods_block] || ConcernMembership::MIXIN_HOOKS.include?(m[:name]) })
      end

      private_class_method def self.unique(methods)
        methods.uniq { |m| Introspectors::ActionResolver.signature(m) }
      end

      private_class_method def self.own_class_methods(source, name)
        Introspectors::ActionResolver.own_methods_in(source, name).select { |m| m[:scope] == :class && m[:visibility] == :public }
      end

      # The private ones are counted apart: an includer gets them too, so a
      # concern of mostly private helpers is not a one-method concern.
      private_class_method def self.methods_phrase(concern)
        return count_phrase(concern[:method_count], "method") unless concern[:private_count].positive?

        "#{count_phrase(concern[:method_count], "public method")} (#{concern[:private_count]} private)"
      end

      private_class_method def self.list_concerns(concern_dirs, root, outside = [])
        all_concerns = []
        excluded_count = 0
        real_root = File.realpath(root).to_s
        # One lookup for the whole listing: it resolves the app's autoload
        # roots once and keeps every source it reads, so a tree of validators
        # sharing one base class reads that base once.
        lookup = Introspectors::SuperclassChain.lookup_for(root.to_s)

        concern_files(concern_dirs, outside, real_root).each do |real, real_dir, concern_type|
          relative = real.sub("#{real_root}/", "")
          source = RailsAiContext::SafeFile.read(real)
          concern_name = ConcernPaths.name_for(real, real_dir, source)
          if ConcernMembership.excluded?(concern_name)
            excluded_count += 1
            next
          end

          method_count = 0
          if source
            public_methods = Introspectors::ActionResolver.public_methods_from_source(source, owner: concern_name)
            class_methods = concern_class_methods(source, concern_name)
            method_count = public_methods.size + class_methods.size + module_methods(source, concern_name).size
            private_count = Introspectors::ActionResolver.private_methods_from_source(source, owner: concern_name).size
          end

          all_concerns << {
            name: concern_name,
            type: concern_type,
            validator: source && Introspectors::SuperclassChain.validator_base(source, name: concern_name, lookup: lookup),
            path: relative,
            method_count: method_count,
            private_count: private_count.to_i
          }
        end

        if all_concerns.empty?
          dirs = concern_dirs.map { |d| d.sub("#{root}/", "") }.join(", ")
          if excluded_count > 0
            return text_response("No concerns to list in #{dirs}: " \
              "#{count_phrase(excluded_count, "concern")} hidden by `excluded_concerns`.")
          end

          return text_response("No concerns found in #{dirs}.")
        end

        validators, all_concerns = all_concerns.partition { |c| c[:validator] }

        lines = [ "# Concerns (#{all_concerns.size})", "" ]
        if excluded_count > 0
          lines << "_#{count_phrase(excluded_count, "concern")} hidden by `excluded_concerns`._"
          lines << ""
        end

        # Grouped by whatever types the app actually has. Rendering a fixed
        # pair of sections meant a concern outside them counted toward the
        # total and then appeared nowhere, which is a worse answer than the
        # undercount it replaced.
        # Name breaks the tie: `sort_by` is not stable, so two types outside
        # SECTION_ORDER would otherwise swap places between runs.
        all_concerns.group_by { |c| c[:type] }
                    .sort_by { |type, _| [ SECTION_ORDER.index(type) || SECTION_ORDER.size, type ] }
                    .each do |type, concerns|
          lines << "## #{type.camelize} Concerns (#{concerns.size})"
          concerns.each do |c|
            lines << "- **#{c[:name]}** - #{methods_phrase(c)} (`#{c[:path]}`)"
          end
          lines << ""
        end

        if validators.any?
          lines << "## Validators (#{validators.size})"
          lines << "_Not concerns: each subclasses `ActiveModel::Validator` or `ActiveModel::EachValidator`, " \
                   "and is wired with `validates_with` or a validation option rather than with `include`._"
          validators.each do |v|
            lines << "- **#{v[:name]}** - #{methods_phrase(v)} (`#{v[:path]}`)"
          end
          lines << ""
        end

        lines << "_Use `name:\"ConcernName\"` for full detail including method signatures and includers._"
        text_response(lines.join("\n"))
      end

      # The option keys ActiveModel and ActiveRecord answer with their own
      # validators, which the model's ancestry reaches before any app class of
      # the same name: `presence: true` never runs an app PresenceValidator.
      FRAMEWORK_VALIDATION_KEYS = %w[
        absence acceptance associated comparison confirmation exclusion format
        inclusion length numericality presence uniqueness
      ].freeze

      # The keys `validates` reads for itself, which never name a validator.
      VALIDATES_OWN_KEYS = %w[if unless on allow_blank allow_nil strict].freeze

      # The models that wire a validator: `validates_with TheValidator`, and
      # for an EachValidator the option key its name gives
      # (EmailValidator -> `validates :x, email: true`). Both are macro calls,
      # so both are read off the AST - a text match also finds the one in a
      # comment or a heredoc.
      private_class_method def self.find_validator_users(validator_name, root)
        simple = validator_name.to_s.demodulize.camelize
        option_key = simple.sub(/Validator\z/, "").underscore

        real_root = File.realpath(root).to_s
        PathResolver.dirs_for(root, "app/models").flat_map { |dir|
          safe_glob(dir, "**/*.rb", real_root).filter_map do |file_path|
            source = RailsAiContext::SafeFile.read(file_path) or next
            # A file naming neither the class nor the key cannot wire it, and
            # this skips the parse for nearly every model.
            next unless source.include?(simple) || (!option_key.empty? && source.include?(option_key))
            next unless wires_validator?(source, simple, option_key)

            name = Introspectors::DeclaredConstant.declared_names(source).first ||
              Introspectors::DeclaredConstant.declared_module_names(source).first ||
              File.basename(file_path, ".rb").camelize
            file_path.include?("/concerns/") ? "#{name} (concern)" : name
          end
        }.uniq.sort
      rescue => e
        RailsAiContext.debug_fail(e, [], label: "find_validator_users")
      end

      private_class_method def self.wires_validator?(source, simple, option_key)
        macros = Introspectors::SourceIntrospector.walk_source(source, {
          validations: -> { Introspectors::Listeners::GenericMacroListener.new(:validates_with, :validates) }
        })[:validations] || []

        macros.any? do |macro|
          case macro[:macro]
          when :validates_with
            Array(macro[:values]).flatten.map(&:to_s).any? { |value| value.split("::").last == simple }
          when :validates
            !option_key.empty? && !FRAMEWORK_VALIDATION_KEYS.include?(option_key) &&
              !VALIDATES_OWN_KEYS.include?(option_key) &&
              macro[:options].key?(option_key.to_sym)
          end
        end
      end

      private_class_method def self.collect_concern_names(concern_dirs, real_root, outside = [])
        concern_files(concern_dirs, outside, real_root).map do |real, real_dir, _type|
          ConcernPaths.name_for(real, real_dir, RailsAiContext::SafeFile.read(real))
        end.uniq.sort
      end

      private_class_method def self.concern_files(concern_dirs, outside, real_root)
        from_dirs = concern_dirs.flat_map do |dir|
          real_dir = File.realpath(dir).to_s
          type = ConcernPaths.type_for(dir)
          safe_glob(dir, "**/*.rb", real_root).sort.map { |real| [ real, real_dir, type ] }
        end
        from_dirs + outside_files(outside, real_root)
      end

      private_class_method def self.outside_files(outside, real_root)
        outside.filter_map do |entry|
          real = File.realpath(entry.path).to_s
          next unless RailsAiContext::SafePath.contained?(real, real_root)

          [ real, File.realpath(entry.root_dir).to_s, entry.type ]
        rescue SystemCallError
          nil
        end
      end

      private_class_method def self.parse_concern_macros(source)
        macros = []
        # Common Rails macros that might appear in included blocks
        macro_patterns = [
          /\A\s*(has_many|has_one|belongs_to|has_and_belongs_to_many)\s+(.+)/,
          /\A\s*(validates|validate)\s+(.+)/,
          /\A\s*(scope)\s+(.+)/,
          /\A\s*(enum)\s+(.+)/,
          /\A\s*(before_\w+|after_\w+|around_\w+)\s+(.+)/,
          /\A\s*(attr_accessor|attr_reader|attr_writer)\s+(.+)/,
          /\A\s*(delegate)\s+(.+)/,
          # A controller concern hands its private helpers to the views this way.
          /\A\s*(helper_method)\s+(.+)/
        ]

        # The block ends at the `end` indented as its `included do` line; past
        # it, a `class_methods` body's `skip_before_action` declares nothing.
        block_end = nil
        source.each_line do |line|
          if block_end.nil? && (opening = line.match(/\A(\s*)included\s+do\b/))
            block_end = /\A#{opening[1]}end\b/
            next
          end
          next unless block_end

          if line.match?(block_end)
            block_end = nil
            next
          end

          macro_patterns.each do |pattern|
            if (match = line.match(pattern))
              macros << "#{match[1]} #{match[2].strip}"
              break
            end
          end
        end

        macros
      rescue => e
        RailsAiContext.debug_fail(e, [], label: "parse_concern_macros")
      end

      # The listener knows every callback macro Rails has, so the section no
      # longer spells its own list and drops the ones it forgot. One
      # declaration resolves to one record per `on:` event, so the rendered
      # lines are deduped back down to the lines the file holds.
      private_class_method def self.parse_concern_callbacks(source)
        Introspectors::SourceIntrospector
          .walk_source(source, { callbacks: Introspectors::Listeners::CallbacksListener })[:callbacks]
          .map { |cb| callback_declaration(cb) }
          .uniq
      rescue => e
        RailsAiContext.debug_fail(e, [], label: "parse_concern_callbacks")
      end

      # Names the directories find_includers actually searched, so the empty
      # answer says where it looked rather than naming two it may not have.
      private_class_method def self.includer_locations(root)
        tops = includer_dirs(root).map { |dir| "#{dir.delete_prefix("#{root}/").split("/").first}/" }.uniq.sort
        tops.size > 1 ? "#{tops[0..-2].join(', ')} or #{tops.last}" : tops.first.to_s
      end

      # Every directory the app autoloads code from: an includer can be any
      # kind of class, and a concern outside app/*/concerns has no kind.
      private_class_method def self.includer_dirs(root)
        PathResolver.autoload_roots(root.to_s)
      end

      private_class_method def self.find_includers(concern_name, root)
        # Resolved as Ruby does, from the includer's namespace outward.
        real_root = File.realpath(root).to_s
        sources = includer_dirs(root).flat_map { |dir| safe_glob(dir, "**/*.rb", real_root) }.uniq
          .reject { |file_path| file_path.include?("/concerns/") }
          .filter_map { |file_path| (source = RailsAiContext::SafeFile.read(file_path)) && [ file_path, source ] }
        Introspectors::Includers.of(root, sources, [ concern_name ], macros: %i[include prepend]).values.flatten.uniq.sort
      rescue => e
        RailsAiContext.debug_fail(e, [], label: "find_includers")
      end
    end
  end
end
