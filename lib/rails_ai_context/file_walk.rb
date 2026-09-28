# frozen_string_literal: true

module RailsAiContext
  # Prunes skipped directories rather than filtering after: globbing `**/*` walks one
  # real node_modules for seconds before the caller can drop its paths.
  module FileWalk
    module_function

    # @param dir [String] directory to walk
    # @param skip [Array<String>] directory names never entered
    # @yield [String] each file path
    def each_file(dir, skip: [])
      return enum_for(:each_file, dir, skip: skip) unless block_given?

      stack = [ dir.to_s ]
      until stack.empty?
        current = stack.pop
        children(current).each do |name|
          next if name.start_with?(".") || skip.include?(name)

          path = File.join(current, name)
          if File.directory?(path)
            stack << path unless File.symlink?(path)
          else
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
