# frozen_string_literal: true

module RailsAiContext
  module Introspectors
    # Scans Stimulus controllers and extracts targets, values, and actions.
    class StimulusIntrospector < Base
      extend StaticTier
      static_tier :files_only

      # The frontend homes a package.json can live in, plus the two that hold
      # controller source without a manifest: Webpacker and ViewComponent sidecars.
      JS_ROOTS = (PackageJson::FRONTEND_DIRS + %w[app/webpacker app/components]).freeze
      CONTROLLER_FILE = /(?:_controller|\.controller)\.(?:js|ts|jsx|tsx)\z/
      SKIP_DIRS = %w[node_modules dist build coverage __tests__].freeze

      # Outside the rails-new home the filename proves nothing; the file must import Stimulus.
      STIMULUS_IMPORT = %r{\bfrom\s+["'](?:@hotwired/stimulus|stimulus)["']}
      EXTENDS = /\bextends\s+([A-Za-z_$][\w$]*)/

      class << self
        # Each controller file with its JS root: the one discovery the introspector,
        # the fingerprint and the conventions all share.
        def controller_paths(root)
          JS_ROOTS.flat_map { |dir| PathResolver.dirs_for(root, dir) }
                  .flat_map { |js_root| controller_files(js_root).map { |path| [ path, js_root ] } }
                  .uniq(&:first).sort_by(&:first)
        end

        # Walked rather than globbed so node_modules is pruned instead of
        # entered: globbing one real frontend/node_modules costs seconds.
        def controller_files(js_root)
          FileWalk.each_file(js_root, skip: SKIP_DIRS).select { |path| File.basename(path).match?(CONTROLLER_FILE) }
        end

        JS_FILE = /\.(?:js|ts|jsx|tsx)\z/

        # The class must be the whole argument: `register("x", Foo.bar)` is a stream action.
        REGISTRATION = /\b(?:pre)?register\w*\s*\(\s*["']([\w-]+)["']\s*,\s*([A-Za-z_$][\w$]*)\s*[,)]/

        # Which module a class came from: a default import, or the
        # destructured default of a dynamic import.
        IMPORT_BINDINGS = [
          /import\s+(?:type\s+)?([A-Za-z_$][\w$]*)\s+from\s+["']([^"']+)["']/,
          /\{\s*default\s*:\s*([A-Za-z_$][\w$]*)\s*\}\s*(?:from|=\s*await\s+import\()\s*["']([^"']+)["']/
        ].freeze

        # The names the app registers for its own files, and the controllers it takes
        # from an installed package; an uninstalled bare specifier is an alias, not one.
        def registrations(root)
          files = {}
          packages = []
          aliases = module_aliases(root)
          js_files(root).each do |path|
            content = RailsAiContext::SafeFile.read(path) or next
            next unless content.include?("register")

            found = content.scan(REGISTRATION)
            next if found.empty?

            bindings = import_bindings(content)
            found.each do |name, klass|
              spec = bindings[klass] or next

              if (target = resolve_module(spec, path, aliases))
                (files[target] ||= []) << name
              elsif (package = installed_package(spec, root))
                packages << { name: name, package: package }
              end
            end
          end
          { files: files, packages: packages.uniq { |entry| entry[:name] } }
        end

        # The package a bare specifier names, when the app installed it
        # through package.json or pinned it in its importmap.
        def installed_package(spec, root)
          return nil if spec.start_with?(".", "/")

          package = spec.start_with?("@") ? spec.split("/").first(2).join("/") : spec.split("/").first
          pins = AssetPipelineIntrospector.importmap_pins(root)
          installed = pins.include?(spec) || pins.include?(package) ||
                      PackageJson.deps(root.to_s).key?(package)
          installed ? package : nil
        end

        NAMED_IMPORT = /import\s+(?:type\s+)?\{([^}]*)\}\s*from\s+["']([^"']+)["']/

        def import_bindings(content)
          bindings = IMPORT_BINDINGS.each_with_object({}) do |pattern, found|
            content.scan(pattern) { |klass, spec| found[klass] ||= spec }
          end
          # `import { Autocomplete as Complete } from "x"` binds Complete.
          content.scan(NAMED_IMPORT) do |names, spec|
            names.split(",").each do |entry|
              local = entry.split(/\s+as\s+/).last.to_s.strip
              bindings[local] ||= spec if local.match?(/\A[A-Za-z_$][\w$]*\z/)
            end
          end
          bindings
        end

        # The app file an import names: a relative specifier, or a bare one
        # the app's own alias table maps onto its source.
        def resolve_module(spec, from, aliases)
          return nil unless spec
          return ModuleAliases.file_for(File.expand_path(spec, File.dirname(from))) if spec.start_with?(".")

          ModuleAliases.resolve(spec, aliases)
        end

        def module_aliases(root)
          ModuleAliases.table(root, JS_ROOTS.flat_map { |dir| PathResolver.dirs_for(root, dir) })
        end

        # stimulus-loading registers the rails-new home itself; elsewhere an app registers by hand.
        AUTO_LOADING = /(?:eager|lazy)LoadControllersFrom|stimulus-loading/

        def auto_registers?(root)
          homes = PathResolver.dirs_for(root, "app/javascript").select { |js_root| Dir.exist?(File.join(js_root, "controllers")) }
          return false if homes.empty?

          homes.any? { |js_root|
            %w[index.js index.ts].any? { |name|
              RailsAiContext::SafeFile.read(File.join(js_root, "controllers", name))&.match?(AUTO_LOADING)
            }
          } || AssetPipelineIntrospector.importmap_pins(root).include?("@hotwired/stimulus-loading")
        end

        # A test registers whatever name it likes for its fixture DOM, so
        # only application code is evidence of what the app calls a controller.
        TEST_DIRS = %w[spec test tests].freeze
        TEST_FILE = /\.(?:spec|test)\.\w+\z/

        def js_files(root)
          JS_ROOTS.flat_map { |dir| PathResolver.dirs_for(root, dir) }
                  .flat_map { |js_root|
                    FileWalk.each_file(js_root, skip: SKIP_DIRS + TEST_DIRS)
                            .select { |path| path.match?(JS_FILE) && !File.basename(path).match?(TEST_FILE) }
                  }
                  .uniq
        end

        # The name the path under `controllers` gives, and whether it is a guess: outside
        # the rails-new home an app's own loader can strip a segment the path keeps.
        def identifier_for(path, js_root)
          parts = path.sub("#{js_root}/", "").split("/")
          index = parts.index("controllers")
          stem = (index ? parts[(index + 1)..] : parts).join("/")
                   .sub(/(?:_controller|\.controller)\.\w+\z/, "")
          [ stem.gsub("/", "--").tr("_", "-"), !default_home?(path, js_root) ]
        end

        # Directly under a JS root's `controllers` directory, the tree stimulus-loading reads.
        def default_home?(path, js_root)
          path.start_with?("#{js_root}/controllers/") && js_root.end_with?("app/javascript")
        end

        # One identifier per controller across every code root, the app's own tree first; a
        # controller left without a free name is qualified by its code root and marked a guess.
        def resolve_names(paths, referenced, registered = {}, root: nil, loader_dirs: [])
          derived = paths.map { |path, js_root| [ path, js_root, identifier_for(path, js_root) ] }
                         .sort_by { |path, js_root, (_name, guess)| [ code_root_of(js_root).count("/"), guess ? 1 : 0, path ] }
          claimed = derived.map { |_path, _js_root, (name, _guess)| name }.to_set
          taken = Set.new
          resolved = {}
          assign = lambda { |path, name, guess|
            resolved[path] = [ name, guess ]
            taken << name
          }

          derived.each do |path, _js_root, (name, guess)|
            next if taken.include?(name)
            next if guess && !referenced.include?(name) && !Array(registered[path]).include?(name)

            assign.call(path, name, false)
          end

          derived.each do |path, _js_root, _derived|
            next if resolved.key?(path)

            given = Array(registered[path]).find { |n| !taken.include?(n) && !claimed.include?(n) }
            assign.call(path, given, false) if given
          end

          derived.each do |path, _js_root, (name, _guess)|
            next if resolved.key?(path)

            repair = referenced_identifier(name, referenced, taken + claimed)
            assign.call(path, repair, false) if repair
          end

          rules = naming_rules(derived, resolved, loader_dirs)
          derived.each do |path, js_root, (name, _guess)|
            next if resolved.key?(path)

            ruled = ruled_name(path, js_root, name, rules)
            next assign.call(path, ruled, true) if ruled && !taken.include?(ruled) && !claimed.include?(ruled)
            next assign.call(path, name, true) unless taken.include?(name)

            qualified = qualified_names(name, js_root, root).find { |q| !taken.include?(q) }
            assign.call(path, qualified, !referenced.include?(qualified))
          end

          resolved
        end

        # Directories whose controllers the app names without the directory's own
        # segments: read from a loader's `import(`./dir/${path}...`)`, or learned
        # where two or more confirmed controllers drop them and none keeps them.
        def naming_rules(derived, resolved, loader_dirs)
          votes = Hash.new { |h, k| h[k] = { drop: 0, keep: 0 } }
          derived.each do |path, js_root, (name, guess)|
            confirmed, = resolved[path]
            next unless guess && confirmed && resolved[path][1] == false

            home = controllers_home(path, js_root) or next
            dropped = name.delete_suffix("--#{confirmed}")
            segments = dropped == name ? 0 : dropped.split("--").size
            relative = path.delete_prefix("#{home}/").split("/")
            if segments.positive? && segments < relative.size
              votes[File.join(home, *relative.first(segments))][:drop] += 1
            elsif confirmed == name
              relative[0...-1].each_index { |i| votes[File.join(home, *relative.first(i + 1))][:keep] += 1 }
            end
          end
          learned = votes.select { |_, v| v[:drop] >= 2 && v[:keep].zero? }.keys
          (learned + loader_dirs).uniq
        end

        # A guessed name with a rule's directory segments dropped, or nil.
        def ruled_name(path, js_root, name, rules)
          home = controllers_home(path, js_root) or return nil
          dir = rules.select { |r| path.start_with?("#{r}/") }.max_by(&:length) or return nil

          dropped = dir.delete_prefix(home).split("/").reject(&:empty?).size
          name.split("--").drop(dropped).join("--").then { |n| n.empty? ? nil : n }
        end

        def controllers_home(path, js_root)
          parts = path.delete_prefix("#{js_root}/").split("/")
          index = parts.index("controllers") or return nil
          File.join(js_root, *parts.first(index + 1))
        end

        # `import(`./dynamic/${path}.controller.ts`)`: a loader naming each file
        # under that directory by its path below it.
        DYNAMIC_IMPORT = /\bimport\(\s*`(\.{1,2}\/[\w\/.-]+)\/\$\{[^}]+\}[^`]*`\s*\)/

        def loader_dirs_in(root)
          js_files(root).flat_map do |path|
            content = RailsAiContext::SafeFile.read(path) or next []
            next [] unless content.include?("import(`")

            content.scan(DYNAMIC_IMPORT).flatten.map { |dir| File.expand_path(dir, File.dirname(path)) }
          end
        end

        def js_dir_of(js_root)
          JS_ROOTS.find { |dir| js_root == dir || js_root.end_with?("/#{dir}") }
        end

        # The code root a JS root belongs to: `frontend` and `app/javascript` share one.
        def code_root_of(js_root)
          js_root.delete_suffix(js_dir_of(js_root).to_s).chomp("/")
        end

        # Names for a controller whose derived one is taken: prefixed by more and more
        # of its code root (`chat--foo`, `plugins--chat--foo`), then the whole path.
        def qualified_names(name, js_root, root)
          relative = root ? js_root.delete_prefix("#{root}/") : js_root
          js_dir = js_dir_of(relative)
          segments = (js_dir ? relative.delete_suffix(js_dir).chomp("/") : relative).split("/").reject(&:empty?)
          segments = [ js_dir.tr("/", "-") ] if segments.empty? && js_dir
          (1..segments.size).map { |n| "#{segments.last(n).join('--')}--#{name}" } +
            [ "#{relative.tr('/', '-')}--#{name}" ]
        end

        # A derived name no template mentions takes the trailing run of its segments
        # a template does name: that is the name the app registers it under.
        def referenced_identifier(name, referenced, blocked)
          parts = name.split("--")
          (1...parts.size).each do |drop|
            candidate = parts[drop..].join("--")
            return candidate if referenced.include?(candidate) && !blocked.include?(candidate)
          end
          nil
        end

        # Only a file outside a `controllers` directory has to be read.
        def used?(root)
          aliases = module_aliases(root)
          controller_paths(root).any? { |path, js_root| stimulus?(path, js_root, root, aliases) } ||
            package_controllers(root, controller_paths(root)).any?
        end

        def controller_count(root)
          paths = controller_paths(root)
          aliases = module_aliases(root)
          paths.count { |path, js_root| stimulus?(path, js_root, root, aliases) } + package_controllers(root, paths).size
        end

        # Package registrations whose name no controller file of the app's
        # own derives: the app's file is the controller by that name.
        def package_controllers(root, paths, registered = registrations(root))
          own = paths.map { |path, js_root| identifier_for(path, js_root).first }.to_set
          registered[:packages].reject { |entry| own.include?(entry[:name]) }
        end

        # Every template or Ruby file an identifier can be written in: the one
        # file set that naming and the "used in" lookup both read.
        def template_files(root)
          TEMPLATE_KINDS.flat_map { |kind| PathResolver.dirs_for(root, kind) }.uniq.flat_map { |dir|
            FileWalk.each_file(dir, skip: SKIP_DIRS).select { |path| path.match?(TEMPLATE_FILE) }.sort
          }.uniq
        end

        def identifiers_in(path, raw)
          return [] unless IDENTIFIER_HINTS.any? { |hint| raw.include?(hint) }

          content = ViewTemplateIntrospector.strip_markup_comments(raw)
          ViewTemplateIntrospector.stimulus_identifiers(content, ruby: path.end_with?(".rb"))
        end

        # The rails-new home needs no proof; elsewhere a file imports from Stimulus or
        # extends an app file that is Stimulus in turn, or an installed Stimulus package.
        def stimulus?(path, js_root, root, aliases, content = nil)
          return true if default_home?(path, js_root)

          stimulus_source?(path, root, aliases, content, Set.new)
        end

        def stimulus_source?(path, root, aliases, content, seen)
          return false if seen.include?(path) || seen.size > MAX_BASE_DEPTH

          seen << path
          content ||= RailsAiContext::SafeFile.read(path) or return false
          return true if content.match?(STIMULUS_IMPORT)

          bindings = import_bindings(content)
          content.scan(EXTENDS).flatten.any? do |klass|
            spec = bindings[klass] or next false

            if (target = resolve_module(spec, path, aliases))
              stimulus_source?(target, root, aliases, nil, seen)
            else
              installed_package(spec, root).to_s.include?("stimulus")
            end
          end
        end

        MAX_BASE_DEPTH = 20
      end

      # Where an identifier can be written: any template or Ruby file under `app`
      # and `lib` of every code root (views, components, forms, Primer templates).
      TEMPLATE_KINDS = %w[app lib].freeze
      TEMPLATE_FILE = /\.(?:erb|haml|slim|rb)\z/
      # Words every identifier shape contains, so a Ruby file mentioning none
      # of them is skipped before any pattern or parse runs over it.
      IDENTIFIER_HINTS = %w[controller target action ->].freeze

      def call
        paths = self.class.controller_paths(root)
        registered = self.class.registrations(root)
        packages = self.class.package_controllers(root, paths, registered)
        return { controllers: [], cross_controller_composition: [] } if paths.empty? && packages.empty?

        scan = scan_templates
        names = self.class.resolve_names(paths, scan[:identifiers], registered[:files], root: root.to_s,
                                                                                         loader_dirs: self.class.loader_dirs_in(root))
        controllers = paths.filter_map { |path, js_root| parse_controller(path, js_root, names[path]) }
        taken = controllers.map { |c| c[:name] }.to_set

        {
          controllers: controllers + packages.reject { |entry| taken.include?(entry[:name]) },
          auto_registers: self.class.auto_registers?(root),
          cross_controller_composition: scan[:compositions]
        }
      end

      private

      def aliases
        @aliases ||= self.class.module_aliases(root.to_s)
      end

      def parse_controller(path, js_root, resolved)
        relative = path.sub("#{root}/", "")
        name, inferred = resolved
        content = RailsAiContext::SafeFile.read(path)
        return { name: File.basename(path), error: "unreadable" } unless content
        return nil unless self.class.stimulus?(path, js_root, root.to_s, aliases, content)

        path_name = self.class.identifier_for(path, js_root).first

        {
          name: name,
          # The spelling the path gives, when the app calls it something else:
          # a reader who found the file can still look it up by that.
          path_name: (path_name unless path_name == name),
          identifier_inferred: inferred || nil,
          file: relative,
          targets: static_array(content, "targets", /["'](\w+)["']/),
          values: extract_values(content),
          actions: extract_actions(content),
          outlets: static_array(content, "outlets", /["']([^"']+)["']/),
          classes: static_array(content, "classes", /["']([^"']+)["']/),
          lifecycle: extract_lifecycle(content),
          import_graph: extract_import_graph(content),
          complexity: extract_complexity(content),
          turbo_event_listeners: extract_turbo_event_listeners(content)
        }.compact
      rescue => e
        { name: File.basename(path), error: e.message }
      end

      def static_array(content, name, pattern)
        match = content.match(/static\s+#{name}\s*=\s*\[([^\]]*)\]/)
        return [] unless match

        match[1].scan(pattern).flatten
      end

      def extract_values(content)
        start_match = content.match(/static\s+values\s*=\s*\{/) or return {}
        span = RailsAiContext::Brackets.span(content, start_match.end(0) - 1, comments: :js) or return {}

        object_entries(span[1...-1]).each_with_object({}) do |(name, value), values|
          if value.start_with?("{")
            inner = object_entries(value[1...-1]).to_h
            type = inner["type"].to_s[/\A\w+/] || "Object"
            values[name] = inner["default"] ? "#{type} (default: #{inner['default']})" : type
          elsif (type = value[/\A[A-Z]\w*/])
            values[name] = type
          end
        end
      end

      # The `key: value` pairs of a JS object body, split at its own commas.
      def object_entries(body)
        entries = [ +"" ]
        RailsAiContext::Brackets.each_top_level(body, comments: :js) do |piece, kind|
          next if kind == :comment

          kind == :char && piece == "," ? entries << +"" : entries.last << piece
        end
        entries.filter_map do |entry|
          match = entry.strip.match(/\A["']?(\w+)["']?\s*:\s*(.+)\z/m) or next
          [ match[1], match[2].strip ]
        end
      end

      def extract_actions(content)
        content.scan(/^\s+(?:async\s+)?(\w+)\s*\([^)]*\)\s*\{/).flatten
               .reject { |m| %w[constructor connect disconnect initialize if else for while switch catch function].include?(m) }
      end

      def extract_import_graph(content)
        imports = []
        content.each_line do |line|
          if (match = line.match(/import\s+.*?from\s+["']([^"']+)["']/))
            imports << match[1]
          elsif (match = line.match(/import\s+["']([^"']+)["']/))
            imports << match[1]
          end
        end
        imports
      rescue => e
        RailsAiContext.debug_fail(e, [], label: "extract_import_graph")
      end

      JS_KEYWORDS = %w[if else for while switch catch function].freeze

      def extract_complexity(content)
        loc = content.lines.count { |line| line.strip.length > 0 }
        methods = content.scan(/^\s+(?:async\s+)?(\w+)\s*\([^)]*\)\s*\{/).flatten
        method_count = methods.count { |m| !JS_KEYWORDS.include?(m) }
        { loc: loc, method_count: method_count }
      rescue => e
        RailsAiContext.debug_fail(e, { loc: 0, method_count: 0 }, label: "extract_complexity")
      end

      def extract_turbo_event_listeners(content)
        events = content.scan(/["']turbo:([\w:-]+)["']/).flatten.uniq
        events.map { |e| "turbo:#{e}" }
      rescue => e
        RailsAiContext.debug_fail(e, [], label: "extract_turbo_event_listeners")
      end

      def extract_lifecycle(content)
        hooks = content.scan(/\b(connect|disconnect|initialize)\s*\(\s*\)/).flatten.uniq
        hooks.any? ? hooks : nil
      rescue => e
        RailsAiContext.debug_fail(e, nil, label: "extract_lifecycle")
      end

      # One pass: the elements that combine controllers, and every identifier
      # the app's own markup names.
      def scan_templates
        views_dir = File.join(root, "app/views")
        compositions = []
        identifiers = Set.new

        self.class.template_files(root).each do |path|
          raw = RailsAiContext::SafeFile.read(path) or next
          identifiers.merge(self.class.identifiers_in(path, raw))
          next unless path.start_with?("#{views_dir}/")

          content = ViewTemplateIntrospector.strip_markup_comments(raw)

          content.scan(ViewTemplateIntrospector::DATA_CONTROLLER_ATTR).each do |match|
            controllers = match[0].split
            next unless controllers.size > 1
            compositions << { file: path.sub("#{views_dir}/", ""), controllers: controllers }
          end
        end

        { compositions: compositions.uniq, identifiers: identifiers }
      rescue => e
        RailsAiContext.debug_fail(e, { compositions: [], identifiers: Set.new }, label: "scan_templates")
      end
    end
  end
end
