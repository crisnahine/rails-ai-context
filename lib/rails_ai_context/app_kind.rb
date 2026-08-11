# frozen_string_literal: true

module RailsAiContext
  # Detects app-level facts that change which introspection applies, from
  # artifacts that exist without booting (config files, Gemfile.lock).
  module AppKind
    module_function

    # The four-space indent plus "(" matches Bundler's resolved-spec line
    # exactly, so gems that merely contain the name do not false-positive.
    def mongoid?(root)
      root = root.to_s
      return true if File.exist?(File.join(root, "config", "mongoid.yml"))

      lock = File.join(root, "Gemfile.lock")
      if File.exist?(lock)
        content = RailsAiContext::SafeFile.read(lock)
        return !!content&.include?("    mongoid (")
      end

      # No lockfile yet (fresh checkout, bare directory): fall back to the
      # Gemfile's own declaration so the app still gets Mongoid treatment
      # instead of misleading ActiveRecord answers.
      gemfile = File.join(root, "Gemfile")
      return false unless File.exist?(gemfile)

      content = RailsAiContext::SafeFile.read(gemfile)
      !!content&.match?(/^\s*gem\s+["']mongoid["']/)
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
