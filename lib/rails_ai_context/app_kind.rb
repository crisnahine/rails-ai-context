# frozen_string_literal: true

module RailsAiContext
  # Detects app-level facts that change which introspection applies, from
  # artifacts that exist without booting (config files, Gemfile.lock).
  module AppKind
    module_function

    def mongoid?(root)
      File.exist?(File.join(root.to_s, "config", "mongoid.yml")) || uses_gem?(root, "mongoid")
    end

    def sequel?(root)
      uses_gem?(root, "sequel-rails", "sequel")
    end

    def uses_gem?(root, *names)
      lock = RailsAiContext::GemLock.for(root.to_s)
      return names.any? { |name| lock.present?(name) } unless lock.missing?

      # No lockfile yet (fresh checkout, bare directory): the Gemfile's own declaration.
      RailsAiContext::Introspectors::GemfileGems.names(root.to_s).intersect?(names)
    end

    ACTIVE_RECORD_REQUIRES = %w[rails/all active_record/railtie active_record].freeze

    # False only when config/application.rb picks its frameworks railtie by
    # railtie and leaves Active Record's out (a require, or a list it requires
    # in a loop) and never configures it; a file it cannot read is taken to load it.
    def active_record?(root)
      source = RailsAiContext::SafeFile.read(File.join(root.to_s, "config", "application.rb"))
      tree = source && RailsAiContext::AstCache.parse_string(source)
      return true unless tree && tree.errors.empty?

      nodes = Introspectors::AstWalk.each(tree.value).to_a
      strings = nodes.grep(Prism::StringNode).map(&:unescaped)
      return true if strings.intersect?(ACTIVE_RECORD_REQUIRES) || nodes.grep(Prism::CallNode).any? { |n| n.name == :active_record }

      strings.none? { |s| s.end_with?("/railtie", "/engine") }
    rescue StandardError, ScriptError
      true
    end

    # Why Active Record introspection does not apply here, or nil when it does.
    def without_active_record(root)
      return nil if active_record?(root)

      return "this app uses Mongoid" if mongoid?(root)
      return "this app uses Sequel" if sequel?(root)

      "this app does not load Active Record"
    end

    # Why the schema files Active Record would read are not its own: sequel-rails keeps its
    # schema.rb and migrations in the same places, written in Sequel's DSL. Nil when they are.
    def sequel_schema(root)
      return nil unless sequel?(root)

      format, dump = Introspectors::SchemaDumpPath.present(root)
      return nil if format == :sql

      file = dump || Introspectors::MigrationReplay.migration_files(Introspectors::MigrationReplay.migration_dirs(root), root: root).first
      return nil unless file && sequel_migration?(RailsAiContext::SafeFile.read(file))

      "#{file.delete_prefix("#{root.to_s.chomp('/')}/")} is a Sequel migration"
    end

    def sequel_migration?(source)
      tree = source && RailsAiContext::AstCache.parse_string(source)
      return false unless tree&.value

      tree.value.statements.body.any? do |node|
        node.is_a?(Prism::CallNode) && node.name == :migration &&
          (node.receiver.is_a?(Prism::ConstantReadNode) || node.receiver.is_a?(Prism::ConstantPathNode)) &&
          node.receiver.slice.delete_prefix("::") == "Sequel"
      end
    end

    # The development database config/mongoid.yml names, by `database:` or the
    # path of its `uri:`; nil when the file is absent or computes it (ERB).
    def mongoid_database(root)
      source = RailsAiContext::SafeFile.read(File.join(root.to_s, "config", "mongoid.yml"))
      return nil unless source

      client = YAML.safe_load(source, aliases: true).dig("development", "clients", "default") || {}
      name = client["database"] || client["uri"].to_s[%r{\Amongodb(?:\+srv)?://[^/]+/([^/?]+)}, 1]
      name if name.is_a?(String) && !name.include?("<%")
    rescue StandardError, Psych::Exception
      nil
    end

    # The class config/application.rb declares under Rails::Application,
    # e.g. "MyApp::Application": the constant `Rails.application` is.
    def application_class(root)
      source = RailsAiContext::SafeFile.read(File.join(root.to_s, "config", "application.rb"))
      return nil unless source

      Introspectors::DeclaredConstant.declarations(source)
        .find { |entry| entry.superclass == "Rails::Application" }&.name
    rescue StandardError, ScriptError
      nil
    end

    # An API-only app has no view layer, and saying "no Stimulus controllers
    # found" about one invites an agent to add some. The flag is written in
    # config/application.rb, so this answer needs no booted app.
    #
    # Read from the AST, not a regex: `config.api_only = true` is an
    # assignment, which docs/INTROSPECTORS.md puts squarely in AST territory,
    # and ConfigAssignmentListener already reports exactly this shape. A regex
    # also has to hand-roll what the parser knows for free - comments, strings
    # and heredocs that merely contain the text.
    def api_only?(root)
      path = File.join(root.to_s, "config", "application.rb")
      return false unless File.exist?(path)
      return false unless RailsAiContext::SafeFile.read(path)

      walked = Introspectors::SourceIntrospector.walk(
        path, { config: Introspectors::Listeners::ConfigAssignmentListener }
      )
      hit = Array(walked[:config]).find { |entry| entry[:path] == [ :api_only ] }
      !hit.nil? && hit[:value] == true
    rescue StandardError, ScriptError
      false
    end
  end
end
