# frozen_string_literal: true

module RailsAiContext
  module Introspectors
    # Discovers the app's own commands: rake tasks from the Rakefile, lib/tasks/
    # and rakelib/, and the generators, generator template overrides and
    # Railties it keeps under lib/.
    class RakeTaskIntrospector < Base
      extend StaticTier
      static_tier :files_only

      # The names Rake looks for, Rakefile first so a case-insensitive disk prints it as written.
      RAKEFILES = %w[Rakefile rakefile Rakefile.rb rakefile.rb].freeze

      def call
        rakefile = RAKEFILES.map { |name| File.join(root, name) }.find { |path| File.file?(path) }
        sources = [ rakefile ].compact
        sources += Dir.glob(File.join(root, "lib/tasks", "**/*.rake")).sort
        # Rake imports rakelib/*.rake, one level only.
        sources += Dir.glob(File.join(root, "rakelib", "*.rake")).sort

        {
          tasks: merge_by_name(sources.flat_map { |path| parse_rake_file(path) }),
          generators: lib_classes[:generators].sort_by { |g| g[:command] }.presence,
          generator_templates: generator_templates.presence,
          railties: lib_classes[:railties].presence
        }.compact
      end

      private

      RAILTIE_BASES = %w[Rails::Railtie].freeze

      # One pass over lib/ (the cached SourceScan list) for both kinds of class.
      def lib_classes
        @lib_classes ||= { generators: [], railties: [] }.tap do |found|
          SourceScan.each(root, kind: "lib") do |record|
            if record.file.start_with?("lib/generators/") && record.file.end_with?("_generator.rb")
              generator = generator_entry(record)
              found[:generators] << generator if generator
            elsif record.source.include?("Railtie")
              found[:railties].concat(railties_in(record))
            end
          end
        end
      end

      # The command Rails::Generators::Base.namespace gives the class:
      # Admin::PageGenerator answers to `admin:page`.
      def generator_entry(record)
        declared = DeclaredConstant.declarations(record.source, assignments: true).map(&:name).find { |name| name.end_with?("Generator") } or return nil
        entry = { command: "bin/rails generate #{declared.delete_suffix('Generator').underscore.tr('/', ':')}", file: record.file }
        usage = SafeFile.read(File.join(File.dirname(record.path), "USAGE"))
        line = usage&.lines&.map(&:strip)&.find { |text| !text.empty? && text != "Description:" }
        line ? entry.merge(usage: line) : entry
      end

      def railties_in(record)
        railties = DeclaredConstant.declarations(record.source, assignments: true).select { |d| RAILTIE_BASES.include?(d.superclass.to_s.delete_prefix("::")) }
        return [] if railties.empty?

        calls = SourceIntrospector.walk_source(record.source, { calls: -> { Listeners::GenericMacroListener.new(:initializer, :rake_tasks) } })[:calls]
        initializers = calls.select { |c| c[:macro] == :initializer }.filter_map { |c| c[:values].first if c[:values].first.is_a?(String) }
        railties.map do |railtie|
          { name: railtie.name, file: record.file, initializers: initializers, rake_tasks: calls.any? { |c| c[:macro] == :rake_tasks } }
        end
      end

      # Rails adds lib/templates to every generator's source paths ahead of its
      # own, so a file at lib/templates/<namespace>/ replaces that generator's template.
      def generator_templates
        dir = File.join(root, "lib", "templates")
        return [] unless File.directory?(dir) && SafePath.contained?(File.realpath(dir), File.realpath(root))

        Dir.glob(File.join(dir, "**", "*")).sort.filter_map do |path|
          next unless File.file?(path) && SafePath.contained?(File.realpath(path), File.realpath(root))

          relative = path.delete_prefix("#{dir}/")
          namespace = File.dirname(relative)
          next if namespace == "."

          { file: "lib/templates/#{relative}", generator: namespace.tr("/", ":") }
        end
      end

      # Rake keeps one task per name: a later definition adds its prerequisites and
      # description, and replaces the arguments only when it names some.
      def merge_by_name(entries)
        merged = {}
        entries.each do |entry|
          next merged[entry.object_id] = entry if entry[:error]

          task = merged[entry[:name]] ||= { name: entry[:name], comments: [], file: entry[:file] }
          comment = entry[:description]&.strip
          task[:comments] << comment if comment.present? && !task[:comments].include?(comment)
          task[:dependencies] = Array(task[:dependencies]) | entry[:dependencies] if entry[:dependencies]
          task[:args] = entry[:args] if entry[:args]
        end
        merged.values.map do |task|
          next task if task[:error]

          comments = task.delete(:comments)
          task.merge(description: comments.filter_map { |c| first_sentence(c) }.join(" / ").presence).compact
        end
      end

      # Rake::Task#first_sentence, which rake -T prints.
      def first_sentence(text)
        text.split(/(?<=\w)(\.|!)[ \t]|(\.$|!)|\n/).first
      end

      def parse_rake_file(path)
        relative = path.delete_prefix("#{root}/")
        content, located = RailsAiContext::SafePath.read(relative, under: root)
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
        [ { file: relative, error: e.message } ]
      end
    end
  end
end
