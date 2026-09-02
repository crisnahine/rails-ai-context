# frozen_string_literal: true

module RailsAiContext
  # The view tool and the view resource each decided which template an
  # extension-less name meant, and disagreed; this is the one answer.
  module ViewFile
    Result = Data.define(:realpath, :relative, :refusal) do
      def ok?
        refusal.nil?
      end
    end

    LOGICAL_PATH = %r{\A[\w\-]+(?:/[\w\-]+)*\z}

    module_function

    # path: relative to app/views, or spelled from the app root.
    def locate(root, path)
      path = path.to_s.delete_prefix("app/views/")
      views = File.join(root.to_s, "app", "views")

      guard = SafePath.locate(path, under: views, root: root)
      return Result.new(realpath: nil, relative: nil, refusal: guard.refusal) if guard.refusal && guard.refusal != :missing

      resolved = guard.ok? && File.file?(guard.realpath) ? path : logical_template(views, path)
      return Result.new(realpath: nil, relative: nil, refusal: :missing) unless resolved

      located = SafePath.locate(resolved, under: views, root: root)
      return Result.new(realpath: nil, relative: nil, refusal: located.refusal) unless located.ok?

      Result.new(realpath: located.realpath, relative: resolved, refusal: nil)
    end

    def read(root, path)
      result = locate(root, path)
      return [ nil, result ] unless result.ok?

      [ RailsAiContext::SafeFile.read(result.realpath), result ]
    end

    # "posts/index" names posts/index.html.erb: the html format when one
    # exists, else the first format alphabetically. Only a plain segment
    # shape reaches the glob, so it stays literal, and a sensitive match is
    # dropped before it can turn a miss into a different answer.
    def logical_template(views, path)
      return nil unless path.match?(LOGICAL_PATH)

      matches = Dir.glob(File.join(views, "#{path}.*"))
        .select { |f| File.file?(f) }
        .map { |f| f.delete_prefix(views + File::SEPARATOR) }
        .reject { |f| SafePath.sensitive?(f) }
        .sort
      return nil if matches.empty?

      matches.find { |m| m.include?(".html.") || m.end_with?(".html") } || matches.first
    end
    private_class_method :logical_template
  end
end
