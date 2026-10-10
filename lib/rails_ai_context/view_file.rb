# frozen_string_literal: true

module RailsAiContext
  # The view tool and the view resource each decided which template an
  # extension-less name meant, and disagreed; this is the one answer.
  module ViewFile
    LOGICAL_PATH = %r{\A[\w\-]+(?:/[\w\-]+)*\z}

    # What Rails registers when nothing else is bundled, for the static tier
    # and for a booted app whose handlers cannot be read. A file under
    # app/views whose last extension is none of these is not a template the
    # tools can read: an image counted as a template, and the ivar regex ran
    # over its bytes.
    # Rails registers only erb/html/builder/ruby/raw itself; every other
    # handler here comes from a gem. Booted, the registry answers and this
    # list is a floor. Unbooted there is no registry, so a template a gem
    # renders has to be on it or the app reads as having fewer views than it
    # has. `rb` is Phlex, a Ruby class under app/views rather than a
    # template.
    DEFAULT_HANDLER_EXTENSIONS = %w[
      raw erb html builder ruby rb jbuilder haml slim
      rabl liquid arb md markdown prawn csv atom rss
    ].freeze

    # A name with no handler extension still renders, through the raw
    # handler, when its last extension is a format. Only the text formats
    # Rails registers count: an image or font under app/views is an asset.
    RAW_FORMAT_EXTENSIONS = %w[
      html text js css xml json ics csv vcf vtt md svg rss atom yaml
    ].freeze

    RUBY_HANDLER_EXTENSIONS = %w[rb ruby builder jbuilder rabl prawn arb].freeze

    # The language a template's source is written in, by its handler.
    TEMPLATE_MIME_TYPES = {
      "erb" => "text/x-erb", "haml" => "text/x-haml", "slim" => "text/x-slim",
      "liquid" => "text/x-liquid", "md" => "text/markdown", "markdown" => "text/markdown"
    }.freeze

    # What a file with no handler of its own is: the raw handler serves it as written.
    FORMAT_MIME_TYPES = {
      "html" => "text/html", "text" => "text/plain", "js" => "text/javascript", "css" => "text/css",
      "xml" => "application/xml", "json" => "application/json", "ics" => "text/calendar", "csv" => "text/csv",
      "vcf" => "text/vcard", "vtt" => "text/vtt", "md" => "text/markdown", "svg" => "image/svg+xml",
      "rss" => "application/rss+xml", "atom" => "application/atom+xml", "yaml" => "application/yaml"
    }.freeze

    MARKUP_GLOB = "**/*.{erb,haml,slim}"

    module_function

    # Every view file across every views root (the app's first, then packs, engines,
    # plugins) with the name it renders by; a name a later root repeats is the first's.
    def each(root, glob = "**/*")
      seen = {}
      PathResolver.view_dirs(root).each do |dir|
        glob(root, dir, glob).each do |path|
          next if File.directory?(path)

          seen[path.sub("#{dir}/", "")] ||= path
        end
      end
      seen.map { |relative, path| [ path, relative ] }
    end

    # The paths under one views root, less those of a root declared inside it
    # (app/views/custom/posts/show is posts/show when app/views/custom is a
    # root) and those a symlink carries out of the app.
    def glob(root, dir, pattern)
      nested = PathResolver.view_dirs(root).select { |other| other.start_with?("#{dir}/") }
      Dir.glob(File.join(dir, pattern)).sort.reject do |path|
        nested.any? { |other| path.start_with?("#{other}/") } || PathResolver.linked_out?(path, root)
      end
    end

    # The innermost views root holding path: app/views/themes/posts/x renders as
    # posts/x when app/views/themes is a root of its own.
    def root_for(path, dirs)
      dirs.select { |dir| path.start_with?("#{dir}/") }.max_by(&:length)
    end

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

    # @param path [String] any path under app/views
    # @return [Boolean] whether Rails renders it: a handler extension, or a text format the raw handler takes
    def template?(path)
      ext = File.extname(path.to_s).delete_prefix(".").downcase
      return false if ext.empty?

      handler_extensions.include?(ext) || RAW_FORMAT_EXTENSIONS.include?(ext)
    end

    # Mime types Rails registers itself; a segment named one is a format before it is a locale.
    FORMAT_EXTENSIONS = (RAW_FORMAT_EXTENSIONS + %w[turbo_stream pdf zip]).freeze
    LOCALE = /\A[a-z]{2}(?:[-_][A-Z]{2})?\z/

    # @param path [String] a view path such as "posts/show.fr.html+mobile.erb"
    # @param locales [Array<String>] the app's available locales, which Rails reads in any spelling (`zh-Hant`)
    # @return [String, nil] the locale and variant the file renders for, and the template name it shares
    def alternate_of(path, locales = nil)
      base = File.basename(path.to_s)
      return nil if base.empty?

      rest = base.sub(/\.[^.+]+\z/, "")
      variant = rest[/\+([^.]*)\z/, 1]
      segments = rest.sub(/\+[^.]*\z/, "").split(".")
      segments.pop if segments.size > 1 && FORMAT_EXTENSIONS.include?(segments.last)
      locale = segments.pop if segments.size > 1 && (segments.last.match?(LOCALE) || Array(locales).include?(segments.last))
      parts = [ ("`#{locale}` locale" if locale), ("`#{variant}` variant" if variant.present?) ].compact
      return nil if parts.empty? || segments.empty?

      "#{parts.join(', ')} of `#{segments.join('.').delete_prefix('_')}`"
    end

    # @param path [String] a view path such as "posts/_post.json.jbuilder"
    # @return [String, nil] the format its name renders for ("json"), or nil
    #   for a name that gives none, which Rails serves in any format
    def format_of(path)
      segments = File.basename(path.to_s).sub(/\.[^.+]+\z/, "").sub(/\+[^.]*\z/, "").split(".")
      segments.last if segments.size > 1 && FORMAT_EXTENSIONS.include?(segments.last)
    end

    # Labelled by the handler: html, csv and the like render raw, so their tags print as written.
    def fence(path)
      ext = File.extname(path.to_s).delete_prefix(".").downcase
      RUBY_HANDLER_EXTENSIONS.include?(ext) ? "ruby" : ext
    end

    # The type of a template's source, not of what it renders: the view
    # resource hands back the file as written, so `show.json.jbuilder` is
    # Ruby and `index.html.erb` is ERB. A file the raw handler serves is what
    # its format says, and anything else is plain text.
    def mime_type(path)
      extensions = File.basename(path.to_s).split(".").drop(1).map(&:downcase)
      handler = extensions.last.to_s
      handler = extensions[-2].to_s if handler == "raw"
      return "text/x-ruby" if RUBY_HANDLER_EXTENSIONS.include?(handler)

      TEMPLATE_MIME_TYPES[handler] || FORMAT_MIME_TYPES.fetch(handler, "text/plain")
    end

    # app/views/layouts also holds the partials those layouts render, and the
    # partial listing counts those; a layout is a non-partial template there.
    def layout?(path)
      template?(path) && !File.basename(path.to_s).start_with?("_")
    end

    # path: relative to app/views, or spelled from the app root.
    # Tried under every views root, so an engine's or plugin's view resolves too. A
    # refusal other than "not here" is the answer wherever it comes from.
    def locate(root, path)
      path = path.to_s.delete_prefix("app/views/")
      refusal = nil

      PathResolver.view_dirs(root).each do |views|
        result = locate_under(views, root, path)
        return result if result.ok?

        refusal ||= result.refusal unless result.refusal == :missing
      end

      SafePath::Resolution.new(realpath: nil, relative: nil, refusal: refusal || :missing)
    end

    def locate_under(views, root, path)
      guard = SafePath.locate(path, under: views, root: root)
      return SafePath::Resolution.new(realpath: nil, relative: nil, refusal: guard.refusal) if guard.refusal && guard.refusal != :missing

      resolved = guard.ok? && File.file?(guard.realpath) ? path : logical_template(views, path)
      return SafePath::Resolution.new(realpath: nil, relative: nil, refusal: :missing) unless resolved

      located = SafePath.locate(resolved, under: views, root: root)
      return SafePath::Resolution.new(realpath: nil, relative: nil, refusal: located.refusal) unless located.ok?

      SafePath::Resolution.new(realpath: located.realpath, relative: resolved, refusal: nil)
    end
    private_class_method :locate_under

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
