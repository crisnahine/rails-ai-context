# frozen_string_literal: true

module RailsAiContext
  # The three buckets a generate_context run answers with, walked in one
  # order for every entry point that reports a run. Each surface keeps its
  # own wording and its own stream; only the walk is shared, so a new bucket
  # is one edit here rather than one edit per surface.
  module ContextFileReport
    # The wording the surfaces share: plain for the streams a machine reads
    # back (the CLI), emoji for the two install-time surfaces. A surface with
    # wording of its own passes its own table to each_line instead.
    STYLES = {
      plain: {
        written: "Written: %s",
        skipped: "Skipped: %s (unchanged)",
        not_applicable: "Not applicable: %s (%s)"
      }.freeze,
      emoji: {
        written: "✅ %s",
        skipped: "⏭️  %s (unchanged)",
        not_applicable: "➖  %s (%s)"
      }.freeze
    }.freeze

    # What each bucket means to a surface that paints its output. A fact
    # about the bucket, so it lives beside the wording rather than in a
    # second table the next bucket would have to be added to as well.
    COLORS = { written: :green, skipped: :yellow, not_applicable: :yellow }.freeze

    module_function

    # @param name [Symbol] :plain or :emoji
    def style(name)
      STYLES.fetch(name)
    end

    # @param bucket [Symbol]
    # @return [Symbol] the colour for this bucket. Fetched, so a new bucket
    #   raises here instead of printing uncoloured.
    def color(bucket)
      COLORS.fetch(bucket)
    end

    # @param result [Hash] { written:, skipped:, not_applicable: }
    # @return [Array<Array(Symbol, String, String|nil)>] bucket, path, reason
    def entries(result)
      Array(result[:written]).map { |path| [ :written, path, nil ] } +
        Array(result[:skipped]).map { |path| [ :skipped, path, nil ] } +
        (result[:not_applicable] || {}).map { |path, reason| [ :not_applicable, path, reason ] }
    end

    # @param style [Hash] bucket => a format string taking the path and, for
    #   :not_applicable, the reason. Fetched, so a surface with no wording
    #   for a bucket raises instead of printing nothing.
    # @yieldparam bucket [Symbol]
    # @yieldparam text [String]
    def each_line(result, style)
      entries(result).each do |bucket, path, reason|
        yield bucket, format(style.fetch(bucket), *[ path, reason ].compact)
      end
    end
  end
end
