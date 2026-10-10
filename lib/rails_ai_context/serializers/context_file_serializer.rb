# frozen_string_literal: true

require "fileutils"
require "json"
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
    class ContextFileSerializer < Base
      attr_reader :format

      # Formats that produce only split rules (no root file).
      SPLIT_ONLY_FORMATS = %i[cursor].freeze

      # The root file each format writes: an AI tool's first context path,
      # plus the toolless JSON dump. Derived so a tool's files are declared
      # once, in Install::AiTool.
      FORMAT_MAP = Install::AiTool.all
        .reject { |tool| SPLIT_ONLY_FORMATS.include?(tool.key) }
        .to_h { |tool| [ tool.key, tool.context_paths.first ] }
        .merge(json: ".ai-context.json")
        .freeze

      ALL_FORMATS = (FORMAT_MAP.keys + SPLIT_ONLY_FORMATS).freeze

      # Which serializer writes each format's root file, and which writes its
      # rules directory. Tables rather than two case statements, so a spec
      # asking "does every generated file carry X" reads the same list the
      # generator runs. Codex reuses OpenCode's files.
      ROOT_SERIALIZERS = {
        json: JsonSerializer, claude: ClaudeSerializer, opencode: OpencodeSerializer,
        codex: OpencodeSerializer, copilot: CopilotSerializer
      }.freeze

      RULES_SERIALIZERS = {
        claude: ClaudeRulesSerializer, cursor: CursorRulesSerializer,
        opencode: OpencodeRulesSerializer, codex: OpencodeRulesSerializer,
        copilot: CopilotInstructionsSerializer
      }.freeze

      # Section markers live exclusively on SectionMarkerWriter - anyone
      # who needs them references SectionMarkerWriter::BEGIN_MARKER /
      # END_MARKER directly. (Re-exports were considered for back-compat
      # but no external code referenced ContextFileSerializer::BEGIN_MARKER.)
      def initialize(context, format: :all)
        super(context)
        @format = format
      end

      # Callers that pay for an introspection before writing check the format
      # first, so a name nothing can write is refused before the work. The
      # names come in the order the CLI's help lists them, and a single name
      # (a command's --format or argument) may also be `all`; a list, which
      # is config.ai_tools, may not.
      def self.validate_format!(format)
        return if format.nil? || format == :all

        unknown = Array(format).reject { |fmt| ALL_FORMATS.include?(fmt) }
        return if unknown.empty?

        valid = (Install::AiTool.all.map(&:key) & ALL_FORMATS) | ALL_FORMATS
        valid += [ :all ] unless format.is_a?(Array)
        raise ArgumentError, "Unknown format: #{unknown.first}. Valid formats: #{valid.join(', ')}"
      end

      # Write context files, skipping unchanged ones.
      # @return [Hash] { written: [paths], skipped: [paths], not_applicable: { path => reason } }
      def call
        # `.ai-context.json` is the machine artifact, not an AI tool, so no
        # install menu can offer it. A recorded tool selection arrives here as
        # a list and used to switch the file off for good, while the generator
        # went on gitignoring it. A single explicit format is a request for one
        # file and stays one.
        formats = case format
        when :all             then ALL_FORMATS
        when Array            then format.empty? ? [] : format | [ :json ]
        else Array(format)
        end
        self.class.validate_format!(formats)
        # `default_app` is the tier-aware handle: the booted application, or the
        # filesystem-rooted stand-in. Reaching for `Rails.application` directly
        # raises NameError under `--no-boot`, where Rails is never loaded at all
        # - a different path from a boot that started and failed.
        output_dir = RailsAiContext.configuration.output_dir_for(RailsAiContext.default_app)
        generate_root = RailsAiContext.configuration.generate_root_files
        result = { written: [], skipped: [], not_applicable: {} }

        seen_root_files = Set.new

        formats.each do |fmt|
          next if SPLIT_ONLY_FORMATS.include?(fmt)

          filename = FORMAT_MAP[fmt]

          # Deduplicate: skip if this root file was already written (e.g. AGENTS.md for both :opencode and :codex)
          next if seen_root_files.include?(filename)
          seen_root_files << filename

          filepath = File.join(output_dir, filename)

          # generate_root_files = false is a deliberate omission, so it is
          # reported rather than dropped. The JSON dump is no tool's root file.
          unless generate_root || fmt == :json
            result[:not_applicable][filepath] = "root files disabled"
            next
          end

          FileUtils.mkdir_p(File.dirname(filepath))
          content = serialize(fmt)

          if fmt == :json
            write_plain(filepath, content, result)
          else
            SectionMarkerWriter.report(SectionMarkerWriter.write_with_markers(filepath, content), filepath, result)
          end
        end

        # Split rules are always generated regardless of generate_root_files
        generate_split_rules(formats, output_dir, result)

        result
      end

      private

      def serialize(fmt)
        (ROOT_SERIALIZERS[fmt] || MarkdownSerializer).new(context).call
      end

      # JSON and other formats that don't support HTML comments
      def write_plain(filepath, content, result)
        if File.exist?(filepath) && same_payload?(File.read(filepath), content)
          result[:skipped] << filepath
        else
          RailsAiContext::SafeFile.atomic_write(filepath, content)
          result[:written] << filepath
        end
      end

      # The JSON carries the run's own timestamp, so a run that found nothing
      # new still rewrote the file and put a diff in a repo that commits it.
      def same_payload?(existing, content)
        return true if existing == content

        parsed = JSON.parse(existing)
        return false unless parsed.is_a?(Hash)

        parsed.except("generated_at") == JSON.parse(content).except("generated_at")
      rescue JSON::ParserError
        false
      end

      def generate_split_rules(formats, output_dir, result)
        serializers = formats.filter_map { |fmt| RULES_SERIALIZERS[fmt] }.uniq

        serializers.each do |serializer|
          rules = serializer.new(context).call(output_dir)
          result[:written].concat(rules[:written])
          result[:skipped].concat(rules[:skipped])
          result[:not_applicable].merge!(rules[:not_applicable] || {})
        end
      end
    end
  end
end
