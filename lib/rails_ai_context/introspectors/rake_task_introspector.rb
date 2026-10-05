# frozen_string_literal: true

module RailsAiContext
  module Introspectors
    # Discovers custom rake tasks from the Rakefile, lib/tasks/ and rakelib/.
    class RakeTaskIntrospector < Base
      extend StaticTier
      static_tier :files_only

      # The names Rake looks for, Rakefile first so a case-insensitive disk prints it as written.
      RAKEFILES = %w[Rakefile rakefile Rakefile.rb rakefile.rb].freeze

      # lib/tasks paths stay relative to lib/tasks; the Rakefile and rakelib are named from the root.
      def call
        tasks_dir = File.join(root, "lib/tasks")
        rakefile = RAKEFILES.map { |name| File.join(root, name) }.find { |path| File.file?(path) }
        sources = [ ([ rakefile, root ] if rakefile) ]
        sources += Dir.glob(File.join(tasks_dir, "**/*.rake")).sort.map { |path| [ path, tasks_dir ] }
        # Rake imports rakelib/*.rake, one level only.
        sources += Dir.glob(File.join(root, "rakelib", "*.rake")).sort.map { |path| [ path, root ] }

        { tasks: sources.compact.flat_map { |path, base| parse_rake_file(path, base) } }
      end

      private

      def parse_rake_file(path, base_dir)
        relative = path.sub("#{base_dir}/", "")
        content, located = RailsAiContext::SafePath.read(path.delete_prefix("#{root}/"), under: root)
        return [] if %i[outside sensitive traversal].include?(located.refusal)
        return [ { file: relative, error: "unreadable" } ] unless content

        ast_data = SourceIntrospector.walk_source(content, { rake: -> { Listeners::RakeTaskDslListener.new } })
        results = ast_data[:rake]

        # Rake's desc applies to the next task defined, whatever namespace it is in.
        last_desc = nil
        scopes = []
        tasks = []
        results.each do |entry|
          scopes.pop while scopes.any? && entry[:offset] >= scopes.last[:end_offset]

          case entry[:type]
          when :namespace
            scopes.push(entry)
          when :desc
            last_desc = entry[:description]
          when :task
            task = { name: (scopes.map { |ns| ns[:name] } + [ entry[:name] ]).join(":"), description: last_desc, file: relative }
            task[:dependencies] = entry[:deps] if entry[:deps]&.any?
            task[:args] = entry[:args] if entry[:args]&.any?
            tasks << task.compact
            last_desc = nil
          end
        end

        tasks
      rescue => e
        [ { file: path.sub("#{base_dir}/", ""), error: e.message } ]
      end
    end
  end
end
