# frozen_string_literal: true

module RailsAiContext
  # Decided from what is in the app, not a directory name: a `spec/` holding
  # only Jasmine JavaScript is not an RSpec suite.
  module TestFramework
    BASES = %w[spec test].freeze
    NO_TESTS = "no tests yet"
    NOT_READ = "not read"
    RSPEC_MARKERS = %w[spec/spec_helper.rb spec/rails_helper.rb spec/factories].freeze
    MINITEST_MARKERS = %w[test/test_helper.rb].freeze

    module_function

    # With no test in the tree the app runs no suite, whatever the bundle
    # holds: every Rails app bundles minitest through activesupport.
    #
    # @return [String] "rspec", "minitest", "rspec, minitest", or
    #   "no tests yet", with "(rspec-rails in the bundle)" or
    #   "(minitest in the bundle)" when the bundle names one, or "not read"
    #   for a suite left unread (see `unread_gemfile`)
    def for(root)
      found = suites(root)
      return found.join(", ") if found.any?
      return NOT_READ if unread_gemfile(root)

      bundled = from_lockfile(GemLock.for(root))
      bundled ? "#{NO_TESTS} (#{bundled == "rspec" ? "rspec-rails" : bundled} in the bundle)" : NO_TESTS
    end

    # The Gemfile config/boot.rb names outside the git repository, for an app with no
    # suite of its own (an engine's test/dummy): the engine's suite there is not read.
    def unread_gemfile(root)
      return nil if BASES.any? { |dir| Dir.exist?(File.join(root.to_s, dir)) }

      GemLock.for(root).outside_gemfile
    end

    def none?(framework)
      framework.to_s.start_with?(NO_TESTS)
    end

    # Empty for an app with no test yet; `for` falls back to the bundle.
    def suites(root)
      found = []
      found << "rspec" if rspec?(root)
      found << "minitest" if minitest?(root)
      found
    end

    # What a fixtures directory holds, said the way it was counted: YAML
    # fixture sets, and any other files kept there for file_fixture.
    def fixture_phrase(fixtures)
      count = fixtures[:count].to_i
      others = fixtures[:other_files].to_i
      return CountPhrase.call(count, "file") unless others.positive?

      "#{CountPhrase.call(count, "YAML fixture set")}, #{CountPhrase.call(others, "other file")}"
    end

    # The file count of a factories entry, nil when none of its paths was read.
    def factory_files_phrase(factories)
      return nil if factories[:count].nil?

      phrase = CountPhrase.call(factories[:count], "file")
      factories[:unread] ? "#{phrase} read" : phrase
    end

    def factory_location(factories)
      files = factory_files_phrase(factories)
      files ? "#{factories[:location]} (#{files})" : factories[:location]
    end

    # RSpec wins where both are real: a new test in an app with an RSpec suite goes to RSpec.
    def command(framework)
      framework.to_s.include?("rspec") ? "bundle exec rspec" : "rails test"
    end

    # Conventional suffix first; apps also name model specs user_model_spec.rb.
    SUFFIXES = {
      model: { "spec" => %w[_spec.rb _model_spec.rb], "test" => %w[_test.rb _model_test.rb] },
      controller: { "spec" => %w[_spec.rb _controller_spec.rb], "test" => %w[_controller_test.rb] }
    }.freeze
    # These name files after a controller without testing it as one (spec/system/admin/x_spec.rb).
    # ponytail: fixed directory list; read each file's class or `type:` if controller tests live here.
    NOT_CONTROLLER_TESTS = %w[system features views routing helpers mailers models jobs components integration].freeze
    MAX_LAYOUT_PROBES = 50
    # The folders rspec-rails and minitest file tests under by kind.
    TYPE_DIRS = %w[
      channels components controllers features functional helpers integration jobs lib mailboxes
      mailers models policies requests routing serializers services system unit views workers
    ].freeze
    # The folders whose tests drive a controller through its actions and routes.
    CONTROLLER_TEST_DIRS = %w[controllers requests routing integration functional system].freeze
    # Of those, where the described class can be the controller under test: rspec-rails controller
    # specs and ActionController::TestCase, which looks its controller up from the test's name.
    DESCRIBED_CONTROLLER_DIRS = (CONTROLLER_TEST_DIRS & %w[controllers functional]).freeze

    # The suite folder a test path starts in: spec/ or test/, or an engine's or pack's own
    # (engines/billing/spec/), captured without the suite folder.
    SUITE_ROOT = %r{\A((?:[^/]+/)*?)(?:spec|test)/}

    # ["engines/billing/", "models"] for engines/billing/spec/models/x_spec.rb: "" for the app's own suite, nil for no type folder.
    def suite_folders(path)
      match = SUITE_ROOT.match(path.to_s) or return [ "", nil ]
      [ match[1], match.post_match[%r{\A([^/]+)/}, 1] ]
    end

    # The name a test is filed by, from its path under the suite root: without the suite and type
    # folders and the extension, so spec/models/account_spec.rb is "account".
    def test_name(path)
      relative = path.to_s.sub(SUITE_ROOT, "").sub(/\.rb\z/, "").sub(%r{\A(?:#{TYPE_DIRS.join("|")})/}o, "")
      without_suffix = relative.sub(/_(?:spec|test)\z/, "")
      return without_suffix unless without_suffix == relative

      # One convention or the other: a `spec_` prefix on spec_runner_spec.rb is the subject's own word.
      relative.sub(%r{(\A|/)(?:spec|test)_}, "\\1")
    end

    # Whether the test at a suite-relative path is the controller's own, by the names the generators
    # give it: key_controller in any folder, and key, key_request or key_routing in a controller test
    # folder. The key is never singularized: user_spec.rb tests UserController, not UsersController.
    def controller_test?(path, key)
      name = test_name(path)
      return true if name == "#{key}_controller"

      CONTROLLER_TEST_DIRS.include?(suite_folders(path).last) &&
        [ key, "#{key}_request", "#{key}_routing" ].include?(name)
    end

    # Whether the test at a suite-relative path is filed as a model's, job's or service's own: under
    # the subject's namespace folders, named with its words and at most a namespace or kind word
    # (_model), so never user_mailer_spec for User nor admin/badge_job_spec for BadgeJob.
    #
    # @param key [String] the subject's path under its app folder, without the extension
    def named_test?(path, kind, key)
      return controller_test?(path, key) if kind == :controller

      subject = singular_parts(key)
      *dirs, last = subject
      kind_names(test_name(path), kind).any? do |name|
        *test_dirs, test_last = singular_parts(name)
        test_dirs == dirs && (last - test_last).empty? && (test_last - subject.flatten).empty?
      end
    end

    # A path as its parts, each as its words in singular form.
    def singular_parts(path) = path.split("/").map { |part| part.split("_").map(&:singularize) }
    private_class_method :singular_parts

    # The name, and the name without a kind word the suffixes add (widget_model for widget).
    def kind_names(name, kind)
      words = Array(SUFFIXES[kind]&.values).flatten.filter_map { |suffix| suffix[/\A(_\w+?)_(?:spec|test)\.rb\z/, 1] }
      [ name ] + words.uniq.filter_map { |word| name.delete_suffix(word) if name.end_with?(word) }
    end
    private_class_method :kind_names

    # rspec-core's example group methods, and the feature aliases rspec-rails and capybara add.
    GROUP_METHODS = %i[example_group describe context xdescribe xcontext fdescribe fcontext feature xfeature ffeature].to_set.freeze

    # Per example group or test class (`described`, the outermost only in `top_level`), [the name written for the class it describes, Module.nesting there].
    Subjects = Data.define(:described, :top_level, :classes)

    def test_subjects(source)
      # Uncached: a suite's thousands of tests would crowd the source files out of the shared cache.
      parsed = AstCache.parse_uncached(source) or return Subjects.new([], [], [])
      found = Subjects.new([], [], Introspectors::SourceIntrospector.walk_dispatch(parsed, { classes: Introspectors::Listeners::ClassDefinitionListener })[:classes])
      pending = [ [ parsed.value, [], false ] ]
      declared = {}
      while (node, scope, inside = pending.pop)
        group = false
        names = nil
        full = Introspectors::DeclaredConstant.declare_node(node, scope, declared)&.delete_prefix("::")
        if node.is_a?(Prism::ModuleNode) || node.is_a?(Prism::ClassNode)
          scope = [ full ] + scope
          if node.is_a?(Prism::ClassNode)
            tested = scope.first[/\A(.*[^:])Test\z/, 1]
            group = !tested.nil?
            names = [ "::#{tested}", [] ] if group
          end
        elsif node.is_a?(Prism::CallNode) && GROUP_METHODS.include?(node.name) &&
              (node.receiver.nil? || node.receiver.slice.delete_prefix("::") == "RSpec")
          group = true
          subject = node.arguments&.arguments&.first
          names = [ subject.slice, scope ] if constant?(subject)
        end
        if names
          found.described << names
          found.top_level << names unless inside
        end
        node.compact_child_nodes.reverse_each { |child| pending << [ child, scope, inside || group ] }
      end
      found
    end

    def constant?(node) = node.is_a?(Prism::ConstantReadNode) || node.is_a?(Prism::ConstantPathNode)
    private_class_method :constant?

    # The constant a subject's file declares, which its folders need not spell: app/jobs/regular/sweep.rb
    # can declare Jobs::Sweep.
    #
    # @param path [String] the subject's file
    # @param key [String] its path under its app folder, without the extension
    def declared_constant(path, key)
      path_name = key.camelize
      declarations = Introspectors::DeclaredConstant.declarations(SafeFile.read(path), path_name: path_name)
      Introspectors::DeclaredConstant.declaration_for(declarations, path_name)&.name || path_name
    end

    # Whether a minitest file's test class reaches ActionDispatch::IntegrationTest, named outright or
    # through a base class the test tree declares.
    def integration_test?(classes, lookup)
      framework_base(classes, lookup) == INTEGRATION_BASE
    end

    # A suite's tests: a test is the subject's when it is filed as the subject's and says it tests
    # nothing else, or else when one of its example groups or test classes describes the subject.
    class Suite
      # @param root [String] the suite's root
      # @param paths [Array<String>] tests relative to it
      # @param app_root [String] the root a relative subject file is under
      def initialize(root, paths, app_root: root)
        @root = File.expand_path(root.to_s)
        @app_root = app_root.to_s
        @paths = paths
        @by_word = Hash.new { |hash, word| hash[word] = [] }
        paths.each { |path| TestFramework.test_name(path).split(%r{[/_]}).uniq.each { |word| @by_word[word] << path } }
        @source = Hash.new { |hash, path| hash[path] = SafeFile.read(File.join(@root, path)) }
        @subjects = {}
      end

      # @param kind [Symbol] :model, :controller, :job or :service
      # @param key [String] a controller's route key, else the subject's path under its app folder
      # @param constant [String, nil] the subject's declared constant
      # @param file [String, nil] the subject's file, absolute or under the app root
      # @param routes [Array<Hash>] the whole route table in draw order (`RouteCoverage.table`), for a request test filed under another name
      def tested?(kind, key, constant = nil, file: nil, routes: [])
        file &&= File.expand_path(file, @app_root)
        return true if candidates(key).any? { |path| TestFramework.named_test?(path, kind, key) && filed_for?(path, kind, constant, file) }
        return true if kind == :controller && requested?(key, routes)
        return false if constant.nil?

        # A group naming Shop::OrdersController holds the text OrdersController however it is nested.
        segment = constant.split("::").last
        sources.any? { |path, source| source.include?(segment) && subjects(path).described.any? { |names| resolves_to?(names, constant) } }
      end

      private

      # Whether a request or integration test sends a request the controller's route answers: a
      # literal path, a "POST /oauth/revoke" group name or a route helper. Rails sends a path to the
      # first route in the table that matches it, so a route a catch-all or slug route comes after
      # is the controller's, and the catch-all's own controller gets only what no route before it answers.
      # shortcut: a constraint is not evaluated, so a constrained route and the ones behind it share the credit.
      def requested?(key, table)
        return false if table.empty?

        sources.any? do |path, source|
          next false unless CONTROLLER_TEST_DIRS.include?(TestFramework.suite_folders(path).last)

          requests(path, source).any? { |request| answering_routes(request, table).any? { |route| route[:controller].to_s == key } }
        end
      end

      def requests(path, source)
        @requests ||= {}
        @requests[path] ||= begin
          parsed = AstCache.parse_uncached(source)
          parsed ? Introspectors::SourceIntrospector.walk_dispatch(parsed, { requests: Introspectors::Listeners::RequestCallListener })[:requests] : []
        end
      end

      # Every route that may answer the request: the matches in draw order up to the first one with no constraint or
      # condition, which always answers it. A constrained match might not, so the routes behind it keep their credit.
      def answering_routes(request, table)
        sent = request[:path] || helper_path(request[:helper], table)
        return [] unless sent

        @patterns ||= {}.compare_by_identity
        matches = table.select do |route|
          route[:path] && verb_answers?(route[:verb], request[:verb]) &&
            (@patterns[route] ||= route_pattern(route[:path])).match?(sent.gsub(/#\{[^}]*\}/, "1"))
        end
        firm = matches.index { |route| route[:constraints].nil? && route[:condition].nil? }
        firm ? matches.first(firm + 1) : matches
      end

      # The path a named route's helper builds, a segment standing for each argument.
      def helper_path(name, table)
        route = table.find { |entry| entry[:name].to_s == name && entry[:path] }
        route && route[:path].gsub(/\([^()]*\)/, "").gsub(/[:*]\w+/, "1")
      end

      # A HEAD request goes to the GET route, and a route with no verb or `via: :all` answers any.
      def verb_answers?(route_verb, sent)
        verbs = route_verb.to_s.split("|")
        verbs.empty? || verbs.include?("ANY") || verbs.include?(sent) || (sent == "HEAD" && verbs.include?("GET"))
      end

      # "/posts/:id(.:format)" as a pattern a sent path matches, its query and trailing slash aside.
      def route_pattern(path)
        bare = path.to_s
        bare = bare.gsub(/\([^()]*\)/, "") while bare.match?(/\([^()]*\)/)
        pieces = bare.split(%r{(/)}).map do |piece|
          case piece
          when /\A:\w+\z/ then "[^/]+"
          when /\A\*\w+\z/ then ".+"
          else Regexp.escape(piece)
          end
        end
        %r{\A#{pieces.join.chomp("/")}/?(?:[?#].*)?\z}
      end

      def sources
        @sources ||= @paths.filter_map { |path| [ path, @source[path] ] if @source[path] }
      end

      # An engine's or pack's own suite tests only what sits under that component, and a test whose
      # top-level group or test class describes another class the app declares tests that class,
      # wherever it is filed. A controller test reaches its controller through the routes, whatever
      # it describes, unless it is a controller spec or an ActionController::TestCase.
      def filed_for?(path, kind, constant, file)
        component, type_dir = TestFramework.suite_folders(path)
        return false if file && !component.empty? && !file.start_with?(File.join(@root, component))
        return true if constant.nil? || (kind == :controller && !TestFramework::DESCRIBED_CONTROLLER_DIRS.include?(type_dir))
        found = subjects(path)
        return true if found.described.any? { |list| resolves_to?(list, constant) }
        return true if kind == :controller && TestFramework.integration_test?(found.classes, lookup)

        found.top_level.none? { |written, nesting| Introspectors::DeclaredConstant.lookup(written, nesting: nesting, exists: method(:filed?)) }
      end

      def lookup
        @lookup ||= TestFramework.test_class_lookup(@root)
      end

      # A constant the app declares nearer where the subject is written shadows it.
      def resolves_to?((written, nesting), constant)
        Introspectors::DeclaredConstant.lookup(written, nesting: nesting, exists: ->(name) { name == constant || filed?(name) }) == constant
      end

      def filed?(name) = !PathResolver.file_for_constant(@root, name).nil?

      def subjects(path)
        @subjects[path] ||= TestFramework.test_subjects(@source[path].to_s)
      end

      def candidates(key)
        word = key.split("/").last.to_s.split("_").first or return []
        [ word, word.singularize, word.pluralize ].uniq.flat_map { |form| @by_word.fetch(form, []) }.uniq
      end
    end

    # One match proves little (a bare stem also names a serializer spec or a
    # namespaced file), so the answer is the dir and suffix most subjects share.
    #
    # @return [Array(String, String), nil] [dir, suffix] relative to the root,
    #   or nil for an app with no such tests
    def layout(root, base, kind, stems)
      suffixes = SUFFIXES.dig(kind, base) or return nil
      dir = File.join(root.to_s, base)
      return nil if stems.empty? || !Dir.exist?(dir)

      by_name = PathResolver.glob(dir, "**/*.rb").map { |path| path.delete_prefix("#{root}/") }
                   .group_by { |path| File.basename(path) }
      counts = Hash.new(0)
      stems.each do |stem|
        suffixes.each do |suffix|
          tail = "#{stem}#{suffix}"
          Array(by_name[File.basename(tail)]).each do |path|
            next unless path.end_with?("/#{tail}")

            found_dir = path.delete_suffix("/#{tail}")
            next if kind == :controller && NOT_CONTROLLER_TESTS.include?(found_dir.split("/")[1])

            counts[[ found_dir, suffix ]] += 1
          end
        end
      end
      return nil if counts.empty?

      counts.max_by { |(found_dir, suffix), count| [ count, -found_dir.length, -suffixes.index(suffix) ] }.first
    end

    # Every path a subject's test may live at: the Rails conventions, then the
    # app's own layout per base (test/unit/app/models, *_model_spec.rb).
    #
    # @return [Array<String>] paths relative to the root
    def candidates(root, kind, stem, context)
      # A singular controller name is another controller (UserController beside UsersController).
      stems = kind == :model ? [ stem, stem.singularize ].uniq : [ stem ]
      conventional = case kind
      when :model
        stems.flat_map do |s|
          %W[spec/models/#{s}_spec.rb test/models/#{s}_test.rb spec/models/concerns/#{s}_spec.rb test/models/concerns/#{s}_test.rb]
        end
      when :controller
        # The namespace stays: a bare name only reaches another controller's spec.
        %w[spec/controllers spec/requests test/controllers].flat_map do |dir|
          SUFFIXES[:controller][dir.split("/").first].map { |suffix| "#{dir}/#{stem}#{suffix}" }
        end
      else
        []
      end
      subjects = subject_stems(context, kind)
      learned = BASES.flat_map do |base|
        dir, suffix = layout(root, base, kind, subjects)
        next [] unless dir

        stems.product([ suffix ] + (SUFFIXES.dig(kind, base) - [ suffix ])).map { |s, sfx| "#{dir}/#{s}#{sfx}" }
      end
      (conventional + learned).uniq
    end

    FACTORY_METHODS = %i[create build build_stubbed create_list build_list].freeze
    TEST_CASE_BASE = "ActionController::TestCase"
    INTEGRATION_BASE = "ActionDispatch::IntegrationTest"

    # Whether most minitest files in `dir` reach ActionController::TestCase over
    # ActionDispatch::IntegrationTest, and whether most build records with factories.
    def test_style(root, dir)
      files = PathResolver.glob(File.join(root.to_s, dir), "**/*_test.rb").sort.first(MAX_LAYOUT_PROBES)
      return {} if files.empty?

      lookup = test_class_lookup(root)
      test_case = integration = factories = 0
      files.each do |path|
        source = SafeFile.read(path) or next
        hits = Introspectors::SourceIntrospector.walk_source(source, {
          classes: -> { Introspectors::Listeners::ClassDefinitionListener.new },
          bare: -> { Introspectors::Listeners::GenericMacroListener.new(*FACTORY_METHODS) },
          chained: -> { Introspectors::Listeners::ChainedCallListener.new(*FACTORY_METHODS, receiver: :FactoryBot) }
        })
        case framework_base(hits[:classes], lookup)
        when TEST_CASE_BASE then test_case += 1
        when INTEGRATION_BASE then integration += 1
        end
        factories += 1 if (hits[:bare] + hits[:chained]).any? { |hit| hit[:args].any? }
      end
      { test_case: test_case > integration, factories: factories * 2 > files.size }
    end

    # Named outright, or through an app base class declared in the test tree
    # (`Admin::UsersControllerTest < ApplicationControllerTestCase`).
    def framework_base(classes, lookup)
      bases = [ TEST_CASE_BASE, INTEGRATION_BASE ]
      classes.each do |klass|
        parent = klass[:superclass] or next
        return parent if bases.include?(parent)

        chain = Introspectors::SuperclassChain.resolve_in_scope(klass[:name], parent, nesting: klass[:nesting]) do |candidate|
          source = lookup.call(candidate)
          source && Introspectors::SuperclassChain.to(source, bases: bases, lookup: lookup, path_name: candidate).presence
        end
        return chain.last.superclass if chain
      end
      nil
    end
    private_class_method :framework_base

    # A test base class lives beside the tests, outside the autoload roots
    # SuperclassChain.lookup_for probes, at the path its name underscores to.
    # The glob also matches a namesake one directory down (test/admin/base_test.rb
    # for BaseTest), so the file must declare the name itself.
    def test_class_lookup(root)
      sources = {}
      lambda do |name|
        sources.fetch(name) do
          rel = "#{name.underscore}.rb"
          paths = BASES.flat_map { |base| PathResolver.glob(File.join(root.to_s, base), File.join("**", rel)) }.sort
          sources[name] = paths.lazy.filter_map { |path| SafeFile.read(path) }
                               .find { |source| Introspectors::DeclaredConstant.declarations(source, path_name: name).any? { |d| d.name == name } }
        end
      end
    end

    # A model's path under app/models, a controller's route key.
    def subject_stems(context, kind)
      case kind
      when :model
        Array(context[:models]&.keys).first(MAX_LAYOUT_PROBES).map do |name|
          Payload.model_stem(context, name)
        end
      when :controller
        Array(context.dig(:controllers, :controllers)&.keys).first(MAX_LAYOUT_PROBES)
          .map { |name| Payload.controller_route_key(context, name) }
      else
        []
      end
    end

    # A gem in the bundle is not a suite: rspec-core arrives through
    # rubocop-rspec in apps that never run RSpec.
    def rspec?(root)
      any_marker?(root, RSPEC_MARKERS) || any_file?(root, "spec", "*_spec.rb")
    end

    def minitest?(root)
      any_marker?(root, MINITEST_MARKERS) || any_file?(root, "test", "*_test.rb")
    end

    # The framework a first test would use: rspec-rails means RSpec,
    # otherwise a Rails app uses its bundled minitest default.
    def from_lockfile(lock)
      return "rspec" if lock.present?("rspec-rails")
      return "minitest" if lock.present?("minitest")

      nil
    end

    def any_marker?(root, rels)
      rels.any? { |rel| File.exist?(File.join(root.to_s, rel)) }
    end
    private_class_method :any_marker?

    # Stops at the first match rather than listing a whole spec tree.
    def any_file?(root, base, glob)
      dir = File.join(root.to_s, base)
      return false unless Dir.exist?(dir)

      Dir.glob(File.join("**", glob), base: dir) { |_match| return true }
      false
    end
    private_class_method :any_file?
  end
end
