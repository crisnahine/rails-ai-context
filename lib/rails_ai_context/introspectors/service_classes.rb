# frozen_string_literal: true

module RailsAiContext
  module Introspectors
    # Which classes under the service roots are services and which are only a base. The tool's
    # listing and the generated Services line both ask here, so they name one set.
    module ServiceClasses
      # active_interaction recommends app/interactions, and interactor-rails
      # autoloads and generates into app/interactors.
      ROOTS = %w[app/services app/interactions app/interactors].freeze

      module_function

      # The declared constant and its superclass from one parse; the path fills in a
      # namespace the source leaves out.
      #
      # @return [Array(String, String, Array<String>)] name, superclass, the nesting it is read in
      def declaration(source, path_name)
        own = DeclaredConstant.file_declaration(source, path_name)
        [ own&.name || DeclaredConstant.resolve(source, path_name), own&.superclass, own&.nesting ]
      end

      # The bases among the given [name, superclass, nesting] triples: a Base-named class
      # something else in the list inherits from, or one of Rails' own.
      def abstract_names(declared)
        named = declared.map(&:first).select { |name| SuperclassChain.abstract_base_name?(name) }
        return [] if named.empty?

        inherited = declared.filter_map do |name, superclass, nesting|
          SuperclassChain.resolve_in_scope(name, superclass, nesting: nesting) { |candidate| candidate if named.include?(candidate) }
        end
        named.select { |name| SuperclassChain.abstract_base?(name, inherited: inherited.include?(name)) }.uniq.sort
      end

      # A mixin, not a service object: it sits in any concerns directory under the root,
      # or it extends ActiveSupport::Concern wherever it sits.
      def concern?(path, source = nil)
        return true if path.to_s.split("/")[0..-2].include?("concerns")
        # The walk can only find the name the source spells, and most files
        # never spell it; skipping their walk is most of a large app's scan.
        return false if source.nil? || !source.include?("ActiveSupport::Concern")

        SourceIntrospector.walk_source(source, { mixins: Listeners::MixinsListener })[:mixins]
          .any? { |mixin| mixin[:macro] == :extend && mixin[:name] == "ActiveSupport::Concern" }
      end

      # A module with no class method, `module_function` or `extend self` is a service only
      # if nothing mixes it in (see mixed_in). A mixin hook is no entry point: Ruby calls it.
      def entryless_module?(source, name)
        return false unless DeclaredConstant.declared_module_names(source).include?(name)

        walked = SourceIntrospector.walk_source(source, {
          methods: Listeners::MethodsListener,
          macros: -> { Listeners::GenericMacroListener.new(:module_function, :extend) }
        })
        entry = ActionResolver.own_methods(walked[:methods], name).any? { |m| m[:scope] == :class && !ConcernMembership::MIXIN_HOOKS.include?(m[:name].to_s) } ||
                walked[:macros].any? { |m| m[:macro] == :module_function || (m[:macro] == :extend && m[:values].map(&:to_s) == %w[self]) }
        !entry
      end

      # Which of these module names some file under the app's trees includes,
      # extends or prepends, each include resolved as Ruby resolves it.
      def mixed_in(root, names)
        return [] if names.empty?

        sources = []
        SourceScan.each(root, kind: "app", skip_concerns: false) { |record| sources << [ record.path, record.source ] }
        Includers.of(root, sources, names).keys
      end

      # A class is one kind, and its chain decides which: OpenProject keeps
      # IncomingEmails::MailHandler, an ApplicationMailer, in app/services, and
      # the mailers listing already counts it. A parent the app does not
      # define that is named like a mailer (Devise::Mailer) counts the way the
      # mailer scan counts it.
      def mailer?(source, name, superclass, lookup)
        return false if superclass.nil?
        return true if superclass == "ActionMailer::Base" || superclass.split("::").last.end_with?("Mailer") && lookup.call(superclass).nil?

        SuperclassChain.to(source, bases: %w[ActionMailer::Base], lookup: lookup, only: name).any?
      end

      # Every service class the app has, bases and mixins left out, read the
      # way rails_get_service_pattern reads them.
      def names(root)
        pairs = []
        modules = []
        lookup = SuperclassChain.lookup_for(root)
        ROOTS.each do |kind|
          SourceScan.each(root, kind: kind) do |record|
            next if concern?(record.file, record.source)

            name, superclass, nesting = declaration(record.source, record.path_name)
            next if mailer?(record.source, name, superclass, lookup)

            pairs << [ name, superclass, nesting ]
            modules << name if entryless_module?(record.source, name)
          end
        end
        left_out = abstract_names(pairs) + mixed_in(root, modules)
        pairs.map(&:first).reject { |name| left_out.include?(name) }.uniq.sort
      rescue StandardError, ScriptError => e
        RailsAiContext.debug_fail(e, [], label: "ServiceClasses.names")
      end
    end
  end
end
