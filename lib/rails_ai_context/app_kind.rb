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

    # Leading `#` excluded, so the commented example Rails ships with does not
    # read as a declaration.
    API_ONLY_ASSIGNMENT = /^\s*[^#\n]*config\.api_only\s*=\s*(true|false)/

    # An API-only app has no view layer, and saying "no Stimulus controllers
    # found" about one invites an agent to add some. The flag is written in
    # config/application.rb, so this answer needs no booted app.
    def api_only?(root)
      path = File.join(root.to_s, "config", "application.rb")
      return false unless File.exist?(path)

      content = RailsAiContext::SafeFile.read(path)
      content&.match(API_ONLY_ASSIGNMENT)&.captures&.first == "true"
    end
  end
end
