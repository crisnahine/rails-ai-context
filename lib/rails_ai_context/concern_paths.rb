# frozen_string_literal: true

module RailsAiContext
  # One answer to "where does this app keep its concerns", for every surface
  # that lists or counts them.
  #
  # `GetConcern` hardcoded two directories and `ActiveSupportIntrospector`
  # hardcoded five, so a single run answered 80 concerns and 81 concerns for
  # the same app, and the mailer concern only the second one found could not be
  # reached through the first at all. Neither list matches Rails, which
  # autoloads these paths by glob - `Rails::Engine::Configuration#paths` adds
  # `app` with `glob: "{*,*/concerns}"` - so any hardcoded list is one entry
  # behind an app that keeps `app/serializers/concerns`.
  module ConcernPaths
    module_function

    # @param root [String] application root
    # @return [Array<String>] absolute concern directories that exist
    def resolve(root)
      # An app that names its concern directories means those and no others -
      # the setting has to be able to narrow, or it only ever adds noise. It is
      # unset by default, which is what asks for discovery.
      configured = RailsAiContext.configuration.concern_paths
      dirs =
        if configured.nil?
          Dir.glob(File.join(root, "app", "*", "concerns"))
        else
          Array(configured).map { |rel| File.join(root, rel) }
        end

      dirs.uniq.select { |dir| Dir.exist?(dir) }.sort
    end

    # The owner segment names the type: `app/mailers/concerns` holds mailer
    # concerns. Singular so a filter reads `type: "mailer"`.
    def type_for(dir)
      segment = dir[%r{/app/([^/]+)/concerns/?\z}, 1]
      segment ? segment.singularize : "other"
    end

    # Source file for a concern named by its constant, or nil.
    #
    # @param root [String] application root
    # @param concern_name [String] constant name, e.g. "BulkMailSettingsConcern"
    def find_file(root, concern_name)
      underscore = concern_name.to_s.underscore
      return nil if underscore.empty? || underscore.include?("..")

      resolve(root)
        .map { |dir| File.join(dir, "#{underscore}.rb") }
        .find { |path| File.exist?(path) }
    end
  end
end
