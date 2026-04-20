# frozen_string_literal: true

module RailsAiContext
  module Introspectors
    # Enumerates Rails.application.initializers — the graph Rails assembles
    # during boot. Captures each initializer's name, the file:line where its
    # block is defined, and any declared `before:` / `after:` ordering edges.
    #
    # Covers RAILS_NERVOUS_SYSTEM.md §2 (Initializer graph).
    class InitializerIntrospector
      attr_reader :app

      def initialize(app)
        @app = app
      end

      # @return [Hash] initializer catalog with name, source, and ordering edges
      def call
        return { available: false, reason: "Rails.application.initializers unavailable" } unless app.respond_to?(:initializers)

        all = app.initializers.to_a
        app_initializers = extract_application_initializers

        {
          total: all.size,
          application_initializers: app_initializers,
          by_owner: group_by_owner(all),
          initializers: summarize(all)
        }
      rescue => e
        $stderr.puts "[rails-ai-context] InitializerIntrospector#call failed: #{e.message}" if ENV["DEBUG"]
        { error: e.message }
      end

      private

      def root
        app.root.to_s
      end

      # Summarize every initializer as { name, owner, before, after, source }.
      # Keeps the list bounded by returning a flat array of primitives only.
      def summarize(initializers)
        initializers.map do |init|
          entry = {
            name: init.name.to_s,
            owner: owner_name(init)
          }
          entry[:before] = Array(init.before).map(&:to_s) if init.before
          entry[:after]  = Array(init.after).map(&:to_s)  if init.after

          loc = block_source_location(init)
          entry[:source] = loc if loc
          entry
        rescue => e
          $stderr.puts "[rails-ai-context] summarize initializer failed: #{e.message}" if ENV["DEBUG"]
          { name: init.name.to_s, error: e.message }
        end
      end

      # Initializers defined in config/application.rb or config/initializers/*.rb
      # are the ones the user wrote. Return file + count of initializer blocks
      # declared inside each file so AI can jump straight to user-owned code.
      def extract_application_initializers
        dir = File.join(root, "config/initializers")
        return [] unless Dir.exist?(dir)

        Dir.glob(File.join(dir, "*.rb")).sort.filter_map do |path|
          content = RailsAiContext::SafeFile.read(path) or next
          initializer_count = content.scan(/^\s*initializer\s+["']/).size
          entry = { file: path.sub("#{root}/", "") }
          entry[:initializers] = initializer_count if initializer_count > 0
          entry[:setup_calls]  = content.scan(/^\s*config\.(\w+)/).flatten.uniq.first(10)
          entry
        end
      end

      def group_by_owner(initializers)
        initializers.group_by { |i| owner_name(i) }.transform_values(&:size)
      end

      def owner_name(init)
        context = init.instance_variable_get(:@context)
        if context.is_a?(Class)
          context.name || "anonymous"
        elsif context.respond_to?(:class)
          context.class.name || "anonymous"
        else
          "unknown"
        end
      rescue => e
        $stderr.puts "[rails-ai-context] owner_name failed: #{e.message}" if ENV["DEBUG"]
        "unknown"
      end

      # Extract file:line for the initializer's block. `Rails::Initializer`
      # stores the block in `@block`; Proc#source_location returns [path, line].
      def block_source_location(init)
        block = init.instance_variable_get(:@block)
        return nil unless block.respond_to?(:source_location)
        loc = block.source_location
        return nil unless loc

        path, line = loc
        path = path.sub("#{root}/", "") if path.start_with?(root)
        "#{path}:#{line}"
      rescue => e
        $stderr.puts "[rails-ai-context] block_source_location failed: #{e.message}" if ENV["DEBUG"]
        nil
      end
    end
  end
end
