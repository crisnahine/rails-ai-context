# frozen_string_literal: true

module RailsAiContext
  module Introspectors
    # The endpoints of each Grape API the routes mount, read from the API
    # classes under app/api and lib/api. A path is built the way Grape builds
    # it: mount paths, prefix, a :path version, namespaces, then the
    # endpoint's own path. Read from source, so both tiers answer the same.
    module GrapeEndpoints
      DIRS = %w[app/api lib/api].freeze
      ROOTS = %w[Grape::API Grape::API::Instance].freeze

      module_function

      # @param mounts [Array<Hash>] the routes' mounted apps, engine and path
      # @return [Hash{String => Array<Hash>}] verb, path, params and file per endpoint, by mounted API
      def call(root, mounts)
        mounts = Array(mounts).select { |m| m.is_a?(Hash) && m[:engine] }
        return {} if mounts.empty?

        classes = read(root.to_s)
        mounts.each_with_object({}) do |mount, found|
          name = resolve(classes, mount[:engine].delete_prefix("::"), nil)
          next unless name && grape?(classes, name)

          list = expand(classes, name, base: [ mount[:path] ], namespace: [], prefix: nil, version: nil, seen: [])
          found[mount[:engine]] = list if list.any?
        end
      end

      def line(endpoint)
        params = endpoint[:params].map do |param|
          details = [ param[:type], ("required" if param[:required]) ].compact
          details.any? ? "#{param[:name]} (#{details.join(', ')})" : param[:name]
        end
        "`#{endpoint[:verb]}` `#{endpoint[:path]}`#{" - params: #{params.join(', ')}" if params.any?}"
      end

      def read(root)
        classes = {}
        DIRS.each do |dir|
          FileWalk.each_file(File.join(root, dir), root: root).select { |path| path.end_with?(".rb") }.sort.each do |path|
            relative = path.delete_prefix("#{root}/")
            source, = SafePath.read(relative, under: root)
            next if source.nil? || source.empty?

            records = SourceIntrospector.walk_source(source, { grape: Listeners::GrapeApiListener })[:grape]
            Array(records).each do |record|
              entry = classes[record[:owner]] ||= { endpoints: [], mounts: [], file: relative }
              case record[:kind]
              when :class then entry[:superclass] = record[:superclass]
              when :endpoint then entry[:endpoints] << record
              when :mount then entry[:mounts] << record
              else entry[record[:kind]] ||= record
              end
            end
          end
        end
        classes
      end

      # A name written inside V1 can mean V1::Users or a top-level Users.
      def resolve(classes, name, scope)
        candidates = []
        parts = scope.to_s.split("::")
        until parts.empty?
          candidates << "#{parts.join('::')}::#{name}"
          parts.pop
        end
        candidates << name
        candidates.find { |candidate| classes.key?(candidate) } || (name if ROOTS.include?(name))
      end

      def grape?(classes, name, seen = [])
        return true if ROOTS.include?(name)
        return false if seen.include?(name) || !classes[name]

        parent = classes[name][:superclass] or return false
        grape?(classes, resolve(classes, parent, name.rpartition("::").first) || parent, seen + [ name ])
      end

      def expand(classes, name, base:, namespace:, prefix:, version:, seen:)
        return [] if seen.include?(name)

        entry = classes[name] or return []
        prefix = entry[:prefix]&.dig(:value) || prefix
        version = entry[:version] || version
        version_part = version[:value] if version && version[:using] == "path"

        own = entry[:endpoints].map do |endpoint|
          path = join(*base, prefix, version_part, *namespace, *endpoint[:namespace], endpoint[:path])
          { verb: endpoint[:verb], path: path, params: endpoint[:params], file: entry[:file] }
        end
        own + entry[:mounts].flat_map do |mount|
          target = resolve(classes, mount[:target], name)
          next [] unless target && grape?(classes, target)

          expand(classes, target, base: base + [ mount[:path] ], namespace: namespace + mount[:namespace],
                                  prefix: prefix, version: version, seen: seen + [ name ])
        end
      end

      def join(*parts)
        "/" + parts.compact.flat_map { |part| part.to_s.split("/") }.reject(&:empty?).join("/")
      end
      private_class_method :read, :resolve, :grape?, :expand, :join
    end
  end
end
