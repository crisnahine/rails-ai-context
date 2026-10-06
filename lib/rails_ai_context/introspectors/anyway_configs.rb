# frozen_string_literal: true

module RailsAiContext
  module Introspectors
    # Each Anyway::Config class under config/configs and app/configs, with its
    # attributes and the env names anyway_config reads them from.
    module AnywayConfigs
      DIRS = %w[config/configs app/configs].freeze
      BASES = %w[Anyway::Config ApplicationConfig].freeze
      MACROS = %i[attr_config required config_name env_prefix].freeze

      module_function

      # @return [Array<Hash>] { name:, file:, attributes: [{ name:, env:, required: }] }
      def scan(root)
        root = root.to_s
        DIRS.flat_map { |dir| Dir.glob(File.join(root, dir, "**", "*.rb")).sort }.flat_map do |path|
          file = path.delete_prefix("#{root}/")
          source = SafePath.read(file, under: root).first
          source ? classes(source, file) : []
        end
      end

      def classes(source, file)
        all = DeclaredConstant.declarations(source)
        declared = all.select { |d| BASES.include?(d.superclass.to_s.delete_prefix("::")) }
        return [] if declared.empty?

        parsed = AstCache.parse_string(source)
        calls = SourceIntrospector.walk_dispatch(parsed, { calls: -> { Listeners::GenericMacroListener.new(*MACROS) } })[:calls]
        bodies = all.flat_map do |d|
          DeclaredConstant.class_bodies(parsed.value, d.name).map { |body| [ d.name, body.location.start_offset...body.location.end_offset ] }
        end
        owned = calls.group_by { |call| innermost(bodies, call[:offset]) }

        declared.filter_map { |d| config(d.name, file, Array(owned[d.name])) }
      end

      # A call belongs to the innermost class body around it, so a nested class keeps its own macros.
      def innermost(bodies, offset)
        bodies.select { |_, range| range.cover?(offset) }.min_by { |_, range| range.size }&.first
      end

      def config(name, file, calls)
        by_macro = calls.group_by { |c| c[:macro] }
        names = Array(by_macro[:attr_config]).flat_map { |c| c[:args].map(&:to_s) + c[:options].keys.map(&:to_s) }.uniq
        return nil if names.empty?

        required = Array(by_macro[:required]).flat_map { |c| c[:args].map(&:to_s) }
        prefix = env_prefix(name, by_macro)
        { name: name, file: file, attributes: names.map { |n| { name: n, env: ("#{prefix}_#{n.upcase}" if prefix), required: required.include?(n) } } }
      end

      # anyway_config reads "#{env_prefix}_#{ATTR}"; the prefix defaults to the class name before `Config` (PAYMENT_*).
      def env_prefix(class_name, by_macro)
        explicit = Array(by_macro[:env_prefix]).last&.dig(:args, 0) || Array(by_macro[:config_name]).last&.dig(:args, 0)
        return explicit.to_s.upcase if explicit

        class_name[/\A(\w+)(?:::)?Config\z/, 1]&.upcase
      end
      private_class_method :classes, :innermost, :config, :env_prefix
    end
  end
end
