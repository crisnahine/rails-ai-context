# frozen_string_literal: true

require "fileutils"
require "securerandom"
require "set"

module RailsAiContext
  module Serializers
    # Orchestrates writing context files to disk in various formats.
    # Supports: CLAUDE.md, AGENTS.md, .github/copilot-instructions.md, JSON
    # Also generates split rule files for AI tools that support them.
    #
    # Root files (CLAUDE.md, etc.) are wrapped in section markers so user content
    # outside the markers is preserved on re-generation. Set config.generate_root_files = false
    # to skip root files entirely and only produce split rules.
    class ContextFileSerializer
      attr_reader :context, :format

      FORMAT_MAP = {
        claude:    "CLAUDE.md",
        opencode:  "AGENTS.md",
        codex:     "AGENTS.md",
        copilot:   ".github/copilot-instructions.md",
        json:      ".ai-context.json"
      }.freeze

      # Formats that produce only split rules (no root file).
      SPLIT_ONLY_FORMATS = %i[cursor].freeze

      ALL_FORMATS = (FORMAT_MAP.keys + SPLIT_ONLY_FORMATS).freeze

      # Re-exported from SectionMarkerWriter so existing code that referenced
      # ContextFileSerializer::BEGIN_MARKER / END_MARKER keeps working.
      BEGIN_MARKER = SectionMarkerWriter::BEGIN_MARKER
      END_MARKER   = SectionMarkerWriter::END_MARKER

      def initialize(context, format: :all)
        @context = context
        @format  = format
      end

      # Write context files, skipping unchanged ones.
      # @return [Hash] { written: [paths], skipped: [paths] }
      def call
        formats = format == :all ? ALL_FORMATS : Array(format)
        output_dir = RailsAiContext.configuration.output_dir_for(Rails.application)
        generate_root = RailsAiContext.configuration.generate_root_files
        written = []
        skipped = []

        seen_root_files = Set.new

        formats.each do |fmt|
          next if SPLIT_ONLY_FORMATS.include?(fmt)

          filename = FORMAT_MAP[fmt]
          unless filename
            valid = ALL_FORMATS.map(&:to_s).join(", ")
            raise ArgumentError, "Unknown format: #{fmt}. Valid formats: #{valid}"
          end

          # Skip root files when generate_root_files is false
          next unless generate_root

          # Deduplicate: skip if this root file was already written (e.g. AGENTS.md for both :opencode and :codex)
          next if seen_root_files.include?(filename)
          seen_root_files << filename

          filepath = File.join(output_dir, filename)
          FileUtils.mkdir_p(File.dirname(filepath))
          content = serialize(fmt)

          if fmt == :json
            write_plain(filepath, content, written, skipped)
          else
            write_with_markers(filepath, content, written, skipped)
          end
        end

        # Split rules are always generated regardless of generate_root_files
        generate_split_rules(formats, output_dir, written, skipped)

        { written: written, skipped: skipped }
      end

      private

      def serialize(fmt)
        case fmt
        when :json             then JsonSerializer.new(context).call
        when :claude           then ClaudeSerializer.new(context).call
        when :opencode, :codex then OpencodeSerializer.new(context).call
        when :copilot          then CopilotSerializer.new(context).call
        else MarkdownSerializer.new(context).call
        end
      end

      # JSON and other formats that don't support HTML comments
      def write_plain(filepath, content, written, skipped)
        if File.exist?(filepath) && File.read(filepath) == content
          skipped << filepath
        else
          atomic_write(filepath, content)
          written << filepath
        end
      end

      # Wrap content in section markers so user content is preserved.
      # Delegates to SectionMarkerWriter (also used by CursorRulesSerializer
      # for .cursorrules) so the marker contract is implemented in exactly
      # one place.
      def write_with_markers(filepath, content, written, skipped)
        case SectionMarkerWriter.write_with_markers(filepath, content)
        when :written then written << filepath
        when :skipped then skipped << filepath
        end
      end

      # Atomic write — same temp-file + rename pattern as
      # SectionMarkerWriter.atomic_write. Kept here because write_plain
      # (JSON path) calls it directly without the marker layer.
      def atomic_write(filepath, content)
        SectionMarkerWriter.atomic_write(filepath, content)
      end

      def generate_split_rules(formats, output_dir, written, skipped)
        if formats.include?(:claude)
          result = ClaudeRulesSerializer.new(context).call(output_dir)
          written.concat(result[:written])
          skipped.concat(result[:skipped])
        end

        if formats.include?(:cursor)
          result = CursorRulesSerializer.new(context).call(output_dir)
          written.concat(result[:written])
          skipped.concat(result[:skipped])
        end

        if formats.include?(:opencode)
          result = OpencodeRulesSerializer.new(context).call(output_dir)
          written.concat(result[:written])
          skipped.concat(result[:skipped])
        end

        if formats.include?(:copilot)
          result = CopilotInstructionsSerializer.new(context).call(output_dir)
          written.concat(result[:written])
          skipped.concat(result[:skipped])
        end

        # Codex reuses OpenCode's directory-level AGENTS.md split rules
        if formats.include?(:codex) && !formats.include?(:opencode)
          result = OpencodeRulesSerializer.new(context).call(output_dir)
          written.concat(result[:written])
          skipped.concat(result[:skipped])
        end
      end
    end
  end
end
