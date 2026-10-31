# frozen_string_literal: true

require "prism"

module RailsAiContext
  # Ruby source as a text scan should see it: what Ruby never runs blanked to
  # spaces, so a regex cannot match a comment or a string, while every line and
  # character offset still points at the file. After boot only, as it loads Prism.
  module RubySource
    module_function

    # Comments, `=begin` blocks and the `__END__` section blanked. `cache: false`
    # for a snippet (a template's tag), so it does not push a file's tree out of AstCache.
    def without_comments(source, cache: true)
      text = source.to_s
      return text unless text.include?("#") || text.include?("=begin") || text.include?("__END__")

      once(:without_comments, text, cache) { blank_ranges(text, comment_ranges(parse(text, cache), text)) }
    end

    # Also string, heredoc, backtick and regex bodies; their delimiters, any
    # `#{}` code inside them and symbols stay.
    def code_only(source, cache: true)
      text = source.to_s
      once(:code_only, text, cache) do
        result = parse(text, cache)
        literals = Literals.new
        result.value.accept(literals)
        blank_ranges(text, comment_ranges(result, text) + literals.ranges)
      end
    end

    def parse(text, cache)
      cache ? AstCache.parse_string(text) : AstCache.parse_uncached(text)
    end
    private_class_method :parse

    # A template's readers ask for the same text several times in one run.
    def once(kind, text, cache, &blank)
      RunCache.fetch([ :ruby_source, kind, cache, text.frozen? ? text : text.dup.freeze ], &blank)
    end
    private_class_method :once

    def comment_ranges(result, text)
      ranges = result.comments.map { |comment| comment.location.start_offset...comment.location.end_offset }
      ranges << (result.data_loc.start_offset...text.bytesize) if result.data_loc
      ranges
    end
    private_class_method :comment_ranges

    # Prism's offsets count bytes; each blanked character becomes one space, so character offsets hold too.
    def blank_ranges(text, ranges)
      return text if ranges.empty?

      bytes = text.b
      out = +""
      last = 0
      ranges.sort_by(&:begin).each do |range|
        next if range.end <= last

        from = [ range.begin, last ].max
        out << bytes.byteslice(last...from)
        out << bytes.byteslice(from...range.end).force_encoding(text.encoding).scrub(" ").tr("^\n", " ").b
        last = range.end
      end
      out << bytes.byteslice(last..).to_s
      out.force_encoding(text.encoding)
    end
    private_class_method :blank_ranges

    class Literals < Prism::Visitor
      attr_reader :ranges

      def initialize
        @ranges = []
        super
      end

      def visit_string_node(node)
        ranges << range(node.content_loc)
        super
      end

      def visit_x_string_node(node)
        ranges << range(node.content_loc)
        super
      end

      def visit_regular_expression_node(node)
        ranges << range(node.content_loc)
        super
      end

      private

      def range(loc)
        loc.start_offset...loc.end_offset
      end
    end
    private_constant :Literals
  end
end
