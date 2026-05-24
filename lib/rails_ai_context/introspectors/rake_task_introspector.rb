# frozen_string_literal: true

module RailsAiContext
  module Introspectors
    # Discovers custom rake tasks from lib/tasks/.
    class RakeTaskIntrospector
      attr_reader :app

      def initialize(app)
        @app = app
      end

      def call
        tasks_dir = File.join(app.root.to_s, "lib/tasks")
        return { tasks: [] } unless Dir.exist?(tasks_dir)

        tasks = Dir.glob(File.join(tasks_dir, "**/*.rake")).sort.flat_map do |path|
          parse_rake_file(path, tasks_dir)
        end

        { tasks: tasks }
      rescue => e
        { error: e.message }
      end

      private

      def parse_rake_file(path, base_dir)
        content = RailsAiContext::SafeFile.read(path)
        return [ { file: path.sub("#{base_dir}/", ""), error: "unreadable" } ] unless content
        relative = path.sub("#{base_dir}/", "")

        ast_data = SourceIntrospector.walk(path, { rake: -> { Listeners::RakeTaskDslListener.new } })
        results = ast_data[:rake]

        # Track namespace and desc ordering to associate descs with tasks
        last_desc = nil
        current_namespace = []
        namespace_indents = []
        tasks = []

        # RakeTaskDslListener returns results in source order.
        # Walk results: accumulate namespaces, track descs, emit tasks.
        # For namespace scope tracking, fall back to indent-based tracking
        # since the listener doesn't track block scope.
        content.each_line.with_index(1) do |line, line_no|
          indent = line.match(/^(\s*)/)[1].length

          if line.match?(/^\s*end\b/) && namespace_indents.any? && indent <= namespace_indents.last
            current_namespace.pop
            namespace_indents.pop
          end
        end

        # Re-walk with indent tracking alongside AST results
        current_namespace = []
        namespace_indents = []
        line_events = {}
        results.each { |r| (line_events[r[:location]] ||= []) << r }

        content.each_line.with_index(1) do |line, line_no|
          indent = line.match(/^(\s*)/)[1].length

          if line.match?(/^\s*end\b/) && namespace_indents.any? && indent <= namespace_indents.last
            current_namespace.pop
            namespace_indents.pop
          end

          next unless line_events[line_no]

          line_events[line_no].each do |entry|
            case entry[:type]
            when :namespace
              current_namespace.push(entry[:name])
              namespace_indents.push(indent)
            when :desc
              last_desc = entry[:description]
            when :task
              name = (current_namespace + [ entry[:name] ]).join(":")
              task = {
                name: name,
                description: last_desc,
                file: relative
              }
              task[:dependencies] = entry[:deps] if entry[:deps]&.any?
              task[:args] = entry[:args] if entry[:args]&.any?
              tasks << task.compact
              last_desc = nil
            end
          end
        end

        tasks
      rescue => e
        [ { file: path.sub("#{base_dir}/", ""), error: e.message } ]
      end
    end
  end
end
