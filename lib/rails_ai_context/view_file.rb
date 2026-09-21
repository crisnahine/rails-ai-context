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

    # What Rails registers when nothing else is bundled, for the static tier
    # and for a booted app whose handlers cannot be read. A file under
    # app/views whose last extension is none of these is not a template the
    # tools can read: an image counted as a template, and the ivar regex ran
    # over its bytes.
    # `rb` is here for Phlex views, which are Ruby classes under app/views
    # rather than ActionView templates.
    DEFAULT_HANDLER_EXTENSIONS = %w[raw erb html builder ruby rb jbuilder haml slim].freeze

    module_function

    # @return [Array<String>] the template handler extensions this app has
    def handler_extensions
      return @handler_extensions if defined?(@handler_extensions) && @handler_extensions

      registered = if defined?(ActionView::Template::Handlers) &&
                      ActionView::Template::Handlers.respond_to?(:extensions)
        ActionView::Template::Handlers.extensions.map(&:to_s)
      else
        []
      end
      @handler_extensions = registered | DEFAULT_HANDLER_EXTENSIONS
    end

    def reset_handler_extensions!
      @handler_extensions = nil
    end

    # @param path [String] any path under app/views
    # @return [Boolean] whether its last extension names a template handler
    def template?(path)
      ext = File.extname(path.to_s).delete_prefix(".").downcase
      return false if ext.empty?

      handler_extensions.include?(ext)
    end

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
