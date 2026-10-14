# frozen_string_literal: true

module RailsAiContext
  module Introspectors
    # The table affixes, pluralize_table_names and schema_format the app's config and initializers
    # set on Active Record. Read once per run, so a long-lived server sees the app's edits.
    module ActiveRecordSettings
      module_function

      SETTINGS = { table_name_prefix: String, table_name_suffix: String, pluralize_table_names: [ true, false ], schema_format: %i[ruby sql] }.freeze
      # Rails copies these from config.active_record onto the ActiveRecord module in an after_initialize hook, so the config wins.
      MODULE_SETTINGS = %i[schema_format].freeze
      # ActiveRecord::Base's class attributes, ActiveRecord's module ones, and self or the param in the base's load hook.
      BASE_ROOTS = %w[ActiveRecord::Base ActiveRecord on_load(:active_record)].freeze

      # {table_name_prefix: "op_", schema_format: :sql}
      def for(root)
        read_once(root).first
      end

      # The settings an assignment gives a value only the running app computes, such as `ENV.fetch`.
      def unread(root)
        read_once(root).last
      end

      def read_once(root)
        return [ {}, [] ] unless root

        root = File.expand_path(root.to_s)
        RunCache.fetch([ :active_record_settings, root ]) { read(root) }
      end

      # Files in Rails' load order, the last assignment of each kind winning. A Base
      # attribute set directly beats config, which the base's load hook copies first.
      def read(root)
        files = [ File.join(root, "config", "application.rb"), File.join(root, "config", "environments", "#{RailsAiContext.environment_name}.rb") ]
        files = files.select { |path| File.file?(path) } + PathResolver.initializer_paths(root)
        listeners = { config: -> { Listeners::ConfigAssignmentListener.new }, base: -> { Listeners::ConfigAssignmentListener.new(BASE_ROOTS) } }
        configured, configured_unread, direct, direct_unread = {}, Set.new, {}, Set.new
        files.each do |file|
          walked = SourceIntrospector.walk(file, listeners)
          collect(Array(walked[:config]).filter_map { |entry| [ entry, entry[:path].last ] if entry[:path].size == 2 && entry[:path].first == :active_record }, configured, configured_unread)
          collect(Array(walked[:base]).filter_map { |entry| [ entry, entry[:path].first ] if entry[:path].size == 1 }, direct, direct_unread)
        end
        MODULE_SETTINGS.each do |name|
          next unless configured.key?(name) || configured_unread.include?(name)

          direct.delete(name)
          direct_unread.delete(name)
        end
        [ configured.except(*direct_unread).merge(direct), (configured_unread - direct.keys | direct_unread).to_a ]
      rescue StandardError, ScriptError => e
        RailsAiContext.debug_fail(e, [ {}, [] ], label: "active_record_settings")
      end

      # A later assignment the reader cannot read hides an earlier literal one, since it runs after it.
      def collect(settings, found, unread)
        settings.sort_by.with_index { |(entry, _), i| [ entry[:location], i ] }.each do |entry, name|
          allowed = SETTINGS[name]
          next unless entry[:assignment] && allowed

          value = entry[:value]
          if allowed.is_a?(Array) ? allowed.include?(value) : value.is_a?(allowed) && entry[:literal]
            found[name] = value
            unread.delete(name)
          else
            found.delete(name)
            unread << name
          end
        end
      end

      private_class_method :read_once, :read, :collect
    end
  end
end
