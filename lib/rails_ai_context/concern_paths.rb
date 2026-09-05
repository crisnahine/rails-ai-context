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
          # A path that is already absolute is taken as given; `File.join`
          # would graft it onto the root and point at nothing.
          Array(configured).map { |rel| File.absolute_path?(rel) ? rel : File.join(root, rel) }
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
    # @param prefer [String, nil] owner kind ("model", "controller") whose
    #   concerns directory is searched first. `resolve` sorts, so without it
    #   app/controllers/concerns wins a basename two owners share.
    # @param within [String, nil] the enclosing constant of the reference. A
    #   bare `include DebugConcern` inside Fasp::Provider resolves at runtime
    #   to Fasp::Provider::DebugConcern, which the literal spelling misses.
    # @param dirs [Array<String>, nil] pre-resolved concern directories
    def find_file(root, concern_name, prefer: nil, within: nil, dirs: nil)
      dirs = ordered_dirs(root, prefer, dirs)

      candidate_names(concern_name, within).each do |name|
        underscore = name.underscore
        next if underscore.empty? || underscore.include?("..")

        path = dirs.map { |dir| File.join(dir, "#{underscore}.rb") }.find { |p| File.exist?(p) }
        return path if path
      end

      nil
    end

    def ordered_dirs(root, prefer, dirs = nil)
      dirs ||= resolve(root)
      return dirs unless prefer

      dirs.partition { |dir| type_for(dir) == prefer }.flatten
    end

    # The reference itself first, then the enclosing namespaces from the
    # innermost outward - Ruby's own constant lookup order.
    def candidate_names(concern_name, within)
      name = concern_name.to_s
      return [ name ] if within.nil? || name.include?("::")

      scopes = within.to_s.split("::")
      [ name ] + scopes.size.downto(1).map { |n| "#{scopes.first(n).join('::')}::#{name}" }
    end
  end
end
