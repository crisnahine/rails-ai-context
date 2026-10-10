# frozen_string_literal: true

module RailsAiContext
  module Introspectors
    # The models an admin gem exposes, read from the folder each gem's
    # generator writes to: ActiveAdmin and Trestle in app/admin, Administrate
    # in app/dashboards, Avo in app/avo/resources, Madmin in
    # app/madmin/resources. Read from source, so both tiers answer the same.
    module AdminResources
      DIRS = %w[app/admin app/dashboards app/avo/resources app/madmin/resources].freeze
      CALLS = %i[register resource permit_params model_class=].freeze

      module_function

      # @return [Array<Hash>] framework, model, file (app-relative) and, for ActiveAdmin, params
      def call(root)
        root = root.to_s
        DIRS.flat_map do |dir|
          FileWalk.each_file(File.join(root, dir), root: root).select { |path| path.end_with?(".rb") }.sort.flat_map do |path|
            relative = path.delete_prefix("#{root}/")
            source, = SafePath.read(relative, under: root)
            source ? resources(dir, relative, source) : []
          end
        end
      end

      def line(resource)
        permits = " - permits #{resource[:params].join(', ')}" if resource[:params].any?
        "#{resource[:framework]} `#{resource[:model]}` (`#{resource[:file]}`)#{permits}"
      end

      def resources(dir, file, source)
        walked = SourceIntrospector.walk_source(
          source, { calls: -> { Listeners::MethodCallListener.new(names: CALLS) },
                    classes: Listeners::ClassDefinitionListener }
        )
        calls = Array(walked[:calls])
        classes = Array(walked[:classes])

        found = case dir
        when "app/admin" then registered(calls) + trestle(calls)
        when "app/dashboards" then named(classes, "Dashboard").map { |model| [ "Administrate", model, [] ] }
        when "app/madmin/resources" then named(classes, "Resource").map { |model| [ "Madmin", model, [] ] }
        else avo(classes, calls)
        end
        found.map { |framework, model, params| { framework: framework, model: model, file: file, params: params } }
      end

      # `ActiveAdmin.register User do`, each with the permit_params that
      # follow it before the next register.
      def registered(calls)
        registers = calls.select { |c| c[:name] == "register" && c[:receiver] == "ActiveAdmin" && c[:arguments].first.is_a?(String) }
        registers.each_with_index.map do |register, index|
          stop = registers[index + 1]&.dig(:offset) || Float::INFINITY
          params = calls.select { |c| c[:name] == "permit_params" && c[:offset] > register[:offset] && c[:offset] < stop }
                        .flat_map { |c| c[:arguments].select { |arg| arg.is_a?(Symbol) }.map(&:to_s) + permitted_keywords(c[:options]) }
          [ "ActiveAdmin", register[:arguments].first, params ]
        end
      end

      # permit_params forwards to params.permit: `tags: []` is an array, `meta: [:a, :b]` nested keys.
      def permitted_keywords(options)
        Array(options).filter_map do |key, value|
          next unless key.is_a?(Symbol)

          inner = case value
          when Array then value.empty? ? "array" : value.map { |v| v.is_a?(Hash) ? v.keys.join(", ") : v.to_s }.join(", ")
          when Hash then value.empty? ? "hash" : value.keys.join(", ")
          end
          inner ? "#{key} (#{inner})" : key.to_s
        end
      end

      # `Trestle.resource(:people, model: Person)`; without model:, the name.
      def trestle(calls)
        calls.select { |c| c[:name] == "resource" && c[:receiver] == "Trestle" && c[:arguments].first.is_a?(Symbol) }.map do |call|
          model = call[:options][:model]
          [ "Trestle", model.is_a?(String) ? model.delete_prefix("::") : call[:arguments].first.to_s.classify, [] ]
        end
      end

      def named(classes, suffix)
        classes.map { |c| c[:name] }.select { |name| name.end_with?(suffix) && name != suffix }.map { |name| name.delete_suffix(suffix) }
      end

      # `self.model_class = ::Account` names the model; otherwise the resource's
      # own name, less the Resource suffix Avo 2 (top-level UserResource) drops.
      def avo(classes, calls)
        resource = classes.first or return []
        override = calls.find { |c| c[:name] == "model_class=" }&.dig(:arguments)&.first
        name = resource[:name]
        model = if override.is_a?(String) then override.delete_prefix("::")
        elsif name.start_with?("Avo::Resources::") then name.demodulize
        else name.demodulize.delete_suffix("Resource")
        end
        model.empty? ? [] : [ [ "Avo", model, [] ] ]
      end
      private_class_method :resources, :registered, :permitted_keywords, :trestle, :named, :avo
    end
  end
end
