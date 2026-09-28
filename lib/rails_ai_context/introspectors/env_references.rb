# frozen_string_literal: true

module RailsAiContext
  module Introspectors
    # Every ENV name the app's source reads, file by file: the one scan behind
    # `rails_get_env` and the context file's `env` section, so the two agree.
    #
    # ENV is read from more than Ruby (database.yml ERB, rake, views). A `sensitive_patterns`
    # file is skipped, except config YAML, whose ERB gives names only, never defaults.
    module EnvReferences
      SCAN_PATTERNS = {
        "app"    => %w[**/*.rb **/*.erb],
        "config" => %w[**/*.rb **/*.yml **/*.yaml],
        "lib"    => %w[**/*.rb **/*.rake]
      }.freeze

      COMPUTED_DEFAULT = :computed

      module_function

      # @return [Hash{String => Array<Hash>}] realpath => the references in it
      def scan(root)
        real_root = File.realpath(root.to_s)
        files(root.to_s, real_root).each_with_object({}) do |(path, names_only), found|
          source = RailsAiContext::SafeFile.read(path)
          next unless source&.include?("ENV")
          # A YAML or ERB file reads ENV only inside a tag.
          next if !path.end_with?(".rb", ".rake") && !source.include?("<%")

          refs = references(ruby_source(path, source))
          refs = refs.map { |ref| ref.except(:default).merge(default_unread: true) } if names_only
          found[path] = refs if refs.any?
        end
      rescue SystemCallError => e
        RailsAiContext.debug_fail(e, {}, label: "EnvReferences.scan")
      end

      # [realpath, names_only] for every file the scan reads.
      def files(root, real_root)
        SCAN_PATTERNS.flat_map do |dir_name, patterns|
          dir = File.join(root, dir_name)
          next [] unless Dir.exist?(dir)

          real_dir = File.realpath(dir)
          patterns.flat_map { |pattern| Dir.glob(File.join(dir, pattern)) }.filter_map do |path|
            # I18n loads locale YAML without ERB, so no ENV read is there to find;
            # Canvas keeps 126MB of it.
            next if path.start_with?(File.join(root, "config", "locales", ""))

            real = File.realpath(path)
            next unless SafePath.contained?(real, real_dir)

            relative = real.delete_prefix("#{real_root}/")
            next [ real, false ] unless SafePath.sensitive?(relative)

            [ real, true ] if relative.start_with?("config/") && relative.end_with?(".yml", ".yaml")
          rescue SystemCallError
            nil
          end
        end.uniq(&:first)
      end

      # ERB tags carry the Ruby of a `.yml` or `.erb` file.
      def ruby_source(path, source)
        return source if path.end_with?(".rb", ".rake")

        RailsAiContext::ErbSource.ruby_in_place(source)
      end

      def references(source)
        walked = SourceIntrospector.walk_source(source, { env: -> { Listeners::EnvAccessListener.new } })
        Array(walked[:env]).filter_map do |entry|
          name = entry[:key]
          # Any variable name, lowercase included: `ENV["port"]` is still read.
          next unless name.match?(/\A[A-Za-z_][A-Za-z0-9_]*\z/)

          ref = { name: name, line: entry[:location] }
          # `ENV["X"]` answers nil when unset; only a fetch without a default raises.
          ref[:bracket] = true if entry[:method] == "[]"
          if entry[:default]
            ref[:default] = entry[:default] == "nil" ? "nil" : RailsAiContext::Redaction.value(name, entry[:default])
          elsif entry[:has_default]
            ref[:default] = COMPUTED_DEFAULT
          end
          ref
        end
      rescue StandardError => e
        RailsAiContext.debug_fail(e, [], label: "EnvReferences.references")
      end
    end
  end
end
