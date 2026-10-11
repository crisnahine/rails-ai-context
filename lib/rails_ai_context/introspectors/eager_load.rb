# frozen_string_literal: true

module RailsAiContext
  module Introspectors
    # Loads a kind of app code before reflection reads it, when the app
    # did not eager load. eager_load_dir stops at the first unloadable file
    # and raises for a directory another loader owns, so both fall back to
    # loading one constant at a time; a file that cannot load costs itself.
    #
    # A file Ruby cannot compile is never required, and neither is one whose
    # class body names its constant, since loading that one autoloads it:
    # Prism reads each file the loader has not loaded yet first, about a
    # tenth of a millisecond a file, and a file is read again only once its
    # stat changes. Requiring one raised a SyntaxError out of Ruby's
    # compiler, and with web-console in the bundle (bindex's raise hook)
    # that crashed Ruby in about half the runs.
    module EagerLoad
      # File => [stat, answer]: whether it compiles, and the constants its
      # class body names. After a reload only the files edited since are
      # read again.
      SYNTAX = Concurrent::Map.new
      CONSTANTS = Concurrent::Map.new

      # File => [mtime, reason] for each file a note was written for, so a
      # file left broken is noted once, not at every rebuild of the caches.
      NOTED = Concurrent::Map.new

      module_function

      # Returns the files left out, by real path, each with why.
      def dir(root, kind:)
        return {} if Rails.application.config.eager_load

        dirs = PathResolver.dirs_for(root, kind) + PathResolver.enclosing_engine_roots(root).map { |engine| File.join(engine, kind) }
        left_out = dirs.select { |path| Dir.exist?(path) }.uniq.each_with_object({}) { |path, found| found.merge!(load_dir(path)) }
        RunCache.fetch([ :eager_load_skipped ]) { {} }.merge!(left_out)
        left_out
      rescue StandardError, ScriptError => e
        RailsAiContext.debug_fail(e, {}, label: "eager load of #{kind}")
      end

      # Why this run left a file unloaded, by its real path, or nil: it does
      # not compile, or its class body names a constant from one that does
      # not. Outside a run, or for a file no walk here reached, only the
      # file's own syntax is asked, and only if it is not loaded already.
      def skipped(file)
        RunCache.fetch([ :eager_load_skipped ]) { {} }[file] ||
          (syntax_error(file) unless $LOADED_FEATURES.include?(file))
      end

      # Prism's first error in a file, worded as Ruby words a SyntaxError
      # ("app/models/post.rb:4: syntax error, unexpected 'end'; ..."), or nil
      # when the running Ruby's grammar takes it - or when Prism cannot read
      # it, and the require decides as it always did.
      def syntax_error(file)
        per_file(SYNTAX, file) do
          next nil if AstCache.parse_success?(file, ruby: RUBY_VERSION)

          error = AstCache.parse(file, ruby: RUBY_VERSION).errors.first
          error && "#{relative(file)}:#{error.location.start_line}: syntax error, #{error.message}"
        end
      rescue StandardError
        nil
      end

      # eager_load_dir returns silently for a directory the loader manages
      # but does not eager load, so the per-constant walk always follows: a
      # constant already loaded is a hash lookup, and one that is not gets
      # loaded here. eager_load_dir would require the files left out, so it
      # runs only when there are none.
      def load_dir(path)
        files = Dir.glob(File.join(path, "**/*.rb")).sort
        left_out = unloadable(path, files)
        load_whole(path) if left_out.empty?
        load_individually(path, files - left_out.keys)
        left_out.transform_keys { |file| real(file) }
      end

      def load_whole(path)
        loader = Rails.autoloaders.main
        loader.eager_load_dir(path) if loader.respond_to?(:eager_load_dir)
      rescue StandardError, ScriptError => e
        RailsAiContext.debug_fail(e, label: "eager_load_dir #{path}")
      end

      # The loader names the constant, not `camelize`: an app inflection
      # makes the two disagree, and a wrong name silently loads nothing.
      def load_individually(path, files)
        loader = Rails.autoloaders.main
        files.each do |file|
          cpath_for(loader, path, file).constantize
        rescue StandardError, ScriptError
          next
        end
      end

      # SourceScan records, each loaded by the constant its file holds. Without
      # the loader's answer (Zeitwerk < 2.6.9) the source's own declaration names
      # it: path_name reads app/services/x.rb as Services::X.
      def files(records)
        loader = Rails.autoloaders.main
        records.each do |record|
          next if skipped(record.path)

          names = [ expected_cpath(loader, record.path) ].compact
          names = DeclaredConstant.declarations(record.source).map(&:name) if names.empty?
          names = [ record.path_name ] if names.empty?
          names.each(&:constantize)
        rescue StandardError, ScriptError => e
          RailsAiContext.debug_fail(e, label: "load #{record.file}")
        end
      end

      # The files under `path` the loader has not loaded and must not load
      # now, each with why: one Prism finds an error in, then each whose
      # class body names a constant from one of those - an included concern,
      # a superclass - and so on down. A file already loaded is a constant
      # lookup, which compiles nothing, and is not read.
      def unloadable(path, files)
        loaded = $LOADED_FEATURES.to_set
        pending = files.reject { |file| loaded.include?(file) }
        found = pending.each_with_object({}) do |file, broken|
          error = syntax_error(file)
          broken[file] = error if error
        end
        return found if found.empty?

        add_dependents(path, pending, found)
        found.each { |file, reason| note(file, reason) }
        found
      end

      # Each reason names the file that does not compile, however far down.
      def add_dependents(path, pending, found)
        loader = Rails.autoloaders.main
        blocked = found.keys.to_h { |file| [ cpath_for(loader, path, file), file ] }
        cause = found.keys.to_h { |file| [ file, file ] }
        names = (pending - found.keys).to_h { |file| [ file, load_time_constants(file) ] }
        loop do
          added = names.filter_map do |file, refs|
            next if found.key?(file)

            cpath = refs.lazy.filter_map { |ref| blocker(blocked, ref) }.first
            next unless cpath

            by = blocked[cpath]
            cause[file] = cause[by]
            how = by == cause[by] ? "which does not compile" : "which needs a file that does not compile"
            found[file] = "#{relative(file)} needs #{cpath}, #{how}: #{found[cause[by]]}"
            blocked[cpath_for(loader, path, file)] = file
          end
          break if added.empty?
        end
      end

      # The constants loading a file evaluates: what its code names outside
      # method bodies and lambdas - a superclass, an included concern, the
      # namespace it opens - each with the namespaces it is written under.
      # Read once per file while one is broken, so the parse is not cached.
      def load_time_constants(file)
        per_file(CONSTANTS, file) do
          names = []
          visit = lambda do |node|
            case node
            when Prism::DefNode, Prism::LambdaNode then nil
            when Prism::ConstantReadNode then names << node.name.to_s
            when Prism::ConstantPathNode
              parts = (node.full_name rescue node.slice).delete_prefix("::").split("::")
              parts.each_index { |i| names << parts[0..i].join("::") }
            else node.compact_child_nodes.each(&visit)
            end
          end
          visit.call(AstCache.parse_uncached(File.read(file)).value)
          names.uniq
        end
      rescue StandardError
        []
      end

      # The block's answer for a file, kept while the file's stat holds. A
      # file younger than AstCache::RACY_WINDOW is read every time: its stat
      # may not show a rewrite yet.
      def per_file(store, file)
        stat = File.stat(file)
        stamp = [ stat.mtime.to_i, stat.mtime.nsec, stat.size, stat.ino ] if stat.mtime < Time.now - AstCache::RACY_WINDOW
        kept = stamp && store[file]
        return kept[1] if kept && kept[0] == stamp

        answer = yield
        store[file] = [ stamp, answer ] if stamp
        answer
      end

      # A name written inside a namespace can mean that namespace's constant,
      # so a broken Admin::BaseController blocks a `< BaseController`.
      def blocker(blocked, ref)
        blocked.keys.find { |cpath| cpath == ref || cpath.end_with?("::#{ref}") }
      end

      def note(file, reason)
        stamp = [ (File.mtime(file) rescue nil), reason ]
        return if NOTED[file] == stamp

        NOTED[file] = stamp
        RailsAiContext.log_warn("[rails-ai-context] Left unloaded: #{reason}")
      end

      def relative(file)
        PortablePath.relativize_text(file, Rails.root)
      end

      def real(file)
        File.realpath(file)
      rescue SystemCallError
        file
      end

      # The loader declines a file it does not manage (a pack or an in-repo
      # engine runs its own), by nil or by raising, and Zeitwerk before 2.6.9
      # cannot answer; its inflector, segment by segment as Zeitwerk itself
      # names a file, still names it well enough for an autoload to answer.
      def cpath_for(loader, path, file)
        expected_cpath(loader, file) ||
          file.delete_prefix(path + File::SEPARATOR).delete_suffix(".rb").split(File::SEPARATOR).map { |segment| inflect(loader, segment, file) }.join("::")
      end

      def inflect(loader, segment, file)
        loader.respond_to?(:inflector) ? loader.inflector.camelize(segment, file) : segment.camelize
      end

      def expected_cpath(loader, file)
        loader.cpath_expected_at(file) if loader.respond_to?(:cpath_expected_at)
      rescue Zeitwerk::Error
        nil
      end
      private_class_method :load_dir, :load_whole, :load_individually, :unloadable, :add_dependents,
                           :load_time_constants, :per_file, :blocker, :note, :relative, :real,
                           :cpath_for, :inflect, :expected_cpath
    end
  end
end
