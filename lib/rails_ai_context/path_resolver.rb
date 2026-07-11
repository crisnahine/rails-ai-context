# frozen_string_literal: true

module RailsAiContext
  # Resolves where a kind of Rails app code can live for a given app root.
  # Conventional layout first, then packwerk packs (packs/*/app/<kind>),
  # then in-repo engines (engines/*/app/<kind>), then any configured
  # extra_app_paths. Only existing directories are returned so callers can
  # glob the list without their own existence guards.
  module PathResolver
    module_function

    def model_dirs(root) = dirs_for(root, "app/models")

    def controller_dirs(root) = dirs_for(root, "app/controllers")

    def view_dirs(root) = dirs_for(root, "app/views")

    def dirs_for(root, kind)
      root = root.to_s
      candidates = [ File.join(root, kind) ]
      candidates += Dir.glob(File.join(root, "packs", "*", kind)).sort
      candidates += Dir.glob(File.join(root, "engines", "*", kind)).sort
      Array(RailsAiContext.configuration.extra_app_paths).each do |extra|
        candidates << File.join(root, extra, kind)
      end
      candidates.uniq.select { |dir| Dir.exist?(dir) }
    end
  end
end
