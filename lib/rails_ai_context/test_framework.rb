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

    # One match proves little (a bare stem also names a serializer spec or a
    # namespaced file), so the answer is the dir and suffix most subjects share.
    #
    # @return [Array(String, String), nil] [dir, suffix] relative to the root,
    #   or nil for an app with no such tests
    def layout(root, base, kind, stems)
      suffixes = SUFFIXES.dig(kind, base) or return nil
      dir = File.join(root.to_s, base)
      return nil if stems.empty? || !Dir.exist?(dir)

      by_name = Dir.glob(File.join(dir, "**", "*.rb")).map { |path| path.delete_prefix("#{root}/") }
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
      stems = [ stem, stem.singularize ].uniq
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
      files = Dir.glob(File.join(root.to_s, dir, "**", "*_test.rb")).sort.first(MAX_LAYOUT_PROBES)
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
          source && Introspectors::SuperclassChain.to(source, bases: bases, lookup: lookup).presence
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
          paths = BASES.flat_map { |base| Dir.glob(File.join(root.to_s, base, "**", rel)) }.sort
          sources[name] = paths.lazy.filter_map { |path| SafeFile.read(path) }
                               .find { |source| Introspectors::DeclaredConstant.declarations(source).any? { |d| d.name == name } }
        end
      end
    end
    private_class_method :test_class_lookup

    # A model's path under app/models, a controller's route key.
    def subject_stems(context, kind)
      case kind
      when :model
        Array(context[:models]&.keys).first(MAX_LAYOUT_PROBES).map do |name|
          Payload.model_file(context, name).sub(%r{\A.*app/models/}, "").sub(/\.rb\z/, "")
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

      Dir.glob(File.join(dir, "**", glob)) { |_match| return true }
      false
    end
    private_class_method :any_file?
  end
end
