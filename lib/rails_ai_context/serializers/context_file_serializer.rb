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
      # @return [Hash] { written:, skipped:, removed:, trimmed: [paths], not_applicable: { path => reason } }
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
        # The files a tool reads depend on what else the app has, so the plan
        # covers the recorded selection too; an unset one means every tool.
        recorded = RailsAiContext.configuration.ai_tools
        selected = recorded.nil? ? Install::AiTool.keys : Array(recorded).map(&:to_sym) & Install::AiTool.keys
        plan = LoadPlan.new(tools | selected | holding_block(output_dir), root_files: generate_root)

        write_plain(File.join(output_dir, JSON_PATH), JsonSerializer.new(context).call, result, output_dir) if formats.include?(:json)
        plan = write_roots(tools, plan, output_dir, result, generate_root)

        generate_split_rules(tools, plan, output_dir, result)

        result
      end

      private

      # The content files first: one that refuses its block (unpaired markers,
      # a link out, no permission) leaves the plan, so an import never names it
      # and a tool that read it gets the content elsewhere.
      # @return [LoadPlan] the plan the rules are written by
      def write_roots(tools, plan, output_dir, result, generate_root)
        root_paths(tools, plan).sort_by { |path| plan.root(path) == :content ? 0 : 1 }.each do |relative|
          filepath = File.join(output_dir, relative)
          # generate_root_files = false is a deliberate omission, so it is
          # reported rather than dropped.
          next result[:not_applicable][filepath] = "root files disabled" unless generate_root

          # A name linked to the content home is that file: an import written through it would import itself.
          content = plan.root(relative) == :content || same_file?(filepath, File.join(output_dir, plan.content_home)) ? root_content : "@#{plan.content_home}"
          plan = plan.without(relative) unless write_root(filepath, content, output_dir, result)
        end
        plan
      end

      # These tools' root files, and the file an import among them points at:
      # CLAUDE.md is empty without its AGENTS.md.
      # Every planned root file these tools read, a Cursor-only run's CLAUDE.md
      # among them, so no file they read keeps a second copy from an earlier run.
      def root_paths(tools, plan)
        chosen = Install::AiTool.all.select { |tool| tools.include?(tool.key) }
        paths = chosen.map(&:root) + chosen.flat_map(&:reads).map(&:path).select { |path| plan.root(path) }
        paths << plan.content_home if paths.any? { |path| plan.root(path) == :import }
        paths.uniq
      end

      # The AI tools whose root file still holds the root content an earlier run
      # wrote, for a tool the record does not name: planned for, so that copy
      # stays current and no tool reads it beside a second one. A pair of markers
      # pasted by hand carries no version stamp, so it does not count.
      STAMP = /generated by rails-ai-context v\d/i

      def holding_block(output_dir)
        Install::AiTool.all.select do |tool|
          text = RailsAiContext::SafeFile.read_text(File.join(output_dir, tool.root))
          text && ManagedBlock.state(text) == :pair && text.match?(STAMP)
        rescue SystemCallError
          false
        end.map(&:key)
      end

      def same_file?(one, other)
        File.exist?(one) && File.exist?(other) && File.realpath(one) == File.realpath(other)
      end

      def root_content
        @root_content ||= RootFile.new(context).call
      end

      # @return [Boolean] whether the file holds the content now
      def write_root(filepath, content, root, result)
        outcome = SectionMarkerWriter.write_with_markers(filepath, content, root: root)
        SectionMarkerWriter.report(outcome, filepath, result)
        %i[written skipped].include?(outcome)
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
