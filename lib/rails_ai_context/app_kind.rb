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
  end
end
