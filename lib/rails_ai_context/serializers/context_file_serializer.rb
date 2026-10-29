# frozen_string_literal: true

require "fileutils"
require "json"
require "set"

module RailsAiContext
  module Serializers
    # Writes the context files of a set of AI tools: the root files the
    # LoadPlan picks, each tool's rules, and the JSON dump.
    #
    # Root files (CLAUDE.md, etc.) are wrapped in section markers so user content
    # outside the markers is preserved on re-generation. Set config.generate_root_files = false
    # to skip root files entirely and only produce split rules.
    class ContextFileSerializer < Base
      attr_reader :format

      JSON_PATH = ".ai-context.json"

      ALL_FORMATS = (Install::AiTool.keys + [ :json ]).freeze

      # Which serializer writes each AI tool's rules. A table rather than a case
      # statement, so a spec asking "does every generated file carry X" reads
      # the same list the generator runs. Codex reuses OpenCode's files.
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
        result = { written: [], skipped: [], not_applicable: {}, removed: [], trimmed: [] }

        tools = formats & Install::AiTool.keys
        plan = LoadPlan.new(tools | (Array(RailsAiContext.configuration.ai_tools).map(&:to_sym) & Install::AiTool.keys),
                            root_files: generate_root)

        write_plain(File.join(output_dir, JSON_PATH), JsonSerializer.new(context).call, result, output_dir) if formats.include?(:json)
        root_paths(tools, plan).each do |relative|
          filepath = File.join(output_dir, relative)
          # generate_root_files = false is a deliberate omission, so it is
          # reported rather than dropped.
          next result[:not_applicable][filepath] = "root files disabled" unless generate_root

          case plan.root(relative)
          when :content then write_root(filepath, root_content, output_dir, result)
          when :import then write_root(filepath, "@#{plan.content_home}", output_dir, result)
          else SectionMarkerWriter.drop(filepath, root: output_dir, whole: false, result: result)
          end
        end

        # Split rules are always generated regardless of generate_root_files
        generate_split_rules(tools, plan, output_dir, result)

        result
      end

      private

      # These tools' root files, and the file an import among them points at:
      # CLAUDE.md is empty without its AGENTS.md.
      def root_paths(tools, plan)
        paths = Install::AiTool.all.select { |tool| tools.include?(tool.key) }.map(&:root)
        paths << plan.content_home if paths.any? { |path| plan.root(path) == :import }
        paths.uniq
      end

      def root_content
        @root_content ||= RootFile.new(context).call
      end

      def write_root(filepath, content, root, result)
        SectionMarkerWriter.report(SectionMarkerWriter.write_with_markers(filepath, content, root: root), filepath, result)
      end

      # JSON and other formats that don't support HTML comments
      def write_plain(filepath, content, result, root)
        if File.exist?(filepath) && same_payload?(File.read(filepath), content)
          result[:skipped] << filepath
        else
          RailsAiContext::SafeFile.atomic_write(filepath, content, root: root)
          result[:written] << filepath
        end
      rescue RailsAiContext::SafeFile::LinkedOut
        result[:not_applicable][filepath] = RailsAiContext::SafeFile::LINKED
      rescue *RailsAiContext::SafeFile::DENIED
        result[:not_applicable][filepath] = RailsAiContext::SafeFile::UNWRITABLE
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

      def generate_split_rules(tools, plan, output_dir, result)
        tools.filter_map { |key| RULES_SERIALIZERS[key] }.uniq.each do |serializer|
          rules = serializer.new(context, plan).call(output_dir)
          %i[written skipped removed trimmed].each { |bucket| result[bucket].concat(rules[bucket] || []) }
          result[:not_applicable].merge!(rules[:not_applicable] || {})
        end
      end
    end
  end
end
