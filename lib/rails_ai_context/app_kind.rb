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
      return false unless File.exist?(lock)

      content = RailsAiContext::SafeFile.read(lock)
      !!content&.include?("    mongoid (")
    end
  end
end
