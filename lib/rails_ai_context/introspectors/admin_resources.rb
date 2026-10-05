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
          FileWalk.each_file(File.join(root, dir)).select { |path| path.end_with?(".rb") }.sort.flat_map do |path|
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
                        .flat_map { |c| c[:arguments] }.select { |arg| arg.is_a?(Symbol) }.map(&:to_s)
          [ "ActiveAdmin", register[:arguments].first, params ]
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

      # `self.model_class = ::Account` names the model; otherwise the resource's own name.
      def avo(classes, calls)
        resource = classes.first or return []
        override = calls.find { |c| c[:name] == "model_class=" }&.dig(:arguments)&.first
        model = override.is_a?(String) ? override.delete_prefix("::") : resource[:name].delete_prefix("Avo::Resources::")
        [ [ "Avo", model, [] ] ]
      end
      private_class_method :resources, :registered, :trestle, :named, :avo
    end
  end
end
