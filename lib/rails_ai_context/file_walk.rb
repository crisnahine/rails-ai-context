# frozen_string_literal: true

module RailsAiContext
  # Prunes skipped directories rather than filtering after: globbing `**/*` walks one
  # real node_modules for seconds before the caller can drop its paths.
  module FileWalk
    module_function

    # A linked directory is not entered, and a linked file is yielded only
    # when it stays inside the app (PathResolver.linked_out?).
    #
    # @param dir [String] directory to walk
    # @param skip [Array<String>] directory names never entered
    # @param root [String] the app root a linked file may not lead out of
    # @yield [String] each file path
    def each_file(dir, skip: [], root: dir)
      return enum_for(:each_file, dir, skip: skip, root: root) unless block_given?

      stack = [ dir.to_s ]
      until stack.empty?
        current = stack.pop
        children(current).each do |name|
          next if name.start_with?(".") || skip.include?(name)

          path = File.join(current, name)
          if File.directory?(path)
            stack << path unless File.symlink?(path)
          elsif !File.symlink?(path) || !PathResolver.linked_out?(path, root)
            yield path
          end
        end
      end
    end

    def children(dir)
      Dir.children(dir)
    rescue SystemCallError
      []
    end
  end
end
