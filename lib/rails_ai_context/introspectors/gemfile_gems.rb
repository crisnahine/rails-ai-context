# frozen_string_literal: true

module RailsAiContext
  module Introspectors
    # The gems a Gemfile declares, read through the AST: a commented-out
    # `# gem "stripe"` line is not a gem the app uses.
    module GemfileGems
      MUTEX = Mutex.new
      CACHE = {}
      private_constant :MUTEX, :CACHE

      module_function

      # @return [Array<String>] gem names, in declaration order
      def names(root)
        entries(root).filter_map { |entry| entry[:name] if entry[:type] == :gem }.uniq
      end

      # Every `gem` and `group` entry, with its options and groups.
      # @return [Array<Hash>] empty when there is no Gemfile or it cannot be read
      def entries(root)
        read_bundle(GemLock.bundle(root)) || []
      end

      # The bundle's Gemfile with the files it evaluates, walked once until any
      # of them changes or appears; nil when there is no Gemfile.
      def read_bundle(bundle)
        gemfile = bundle.gemfile
        return nil unless gemfile && File.file?(gemfile)

        key = [ bundle.dir, gemfile ]
        cached = MUTEX.synchronize { CACHE[key] }
        return cached[:entries] if cached && cached[:stamps].all? { |path, stamp| GemLock.mtime(path) == stamp }

        stamps = {}
        # A failed walk is kept too: the same files fail the same way until they change.
        entries = begin
          read(bundle.dir, File.basename(gemfile), [], [], stamps)
        rescue StandardError => e
          RailsAiContext.debug_fail(e, nil, label: "GemfileGems.read_bundle")
        end
        MUTEX.synchronize { CACHE[key] = { entries: entries, stamps: stamps } }
        entries
      end

      # The mtimes of the Gemfile and every file it evaluates, as read_bundle last read them.
      def stamps(bundle)
        read_bundle(bundle)
        MUTEX.synchronize { CACHE[[ bundle.dir, bundle.gemfile ]]&.fetch(:stamps) }
      end

      # Bundler evaluates an eval_gemfile file into the same Gemfile, inside
      # the groups around the call. Never read outside the bundle's directory,
      # and a file left unread adds gems no one can name.
      def read(root, relative, groups, seen, stamps)
        stamps[File.join(root, relative)] = GemLock.mtime(File.join(root, relative))
        resolution = SafePath.locate(relative, under: root)
        return [ { type: :unknown_gems, call: :eval_gemfile } ] unless resolution.ok?
        return [] if seen.include?(resolution.realpath)

        seen << resolution.realpath
        found = Array(SourceIntrospector.walk(resolution.realpath, { gems: -> { Listeners::GemfileDslListener.new } })[:gems])
        base = File.expand_path(root)
        found.flat_map do |entry|
          entry = entry.merge(groups: (groups + entry[:groups]).uniq) if groups.any? && %i[gem eval_gemfile].include?(entry[:type])
          next [ entry ] unless entry[:type] == :eval_gemfile

          nested = File.expand_path(entry[:path], File.dirname(File.join(root, relative)))
          next [ { type: :unknown_gems, call: :eval_gemfile } ] unless SafePath.contained?(nested, base)

          read(root, nested.delete_prefix(SafePath.dir_prefix(base)), entry[:groups], seen, stamps)
        end
      end
      private_class_method :read
    end
  end
end
