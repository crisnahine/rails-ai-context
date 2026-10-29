# frozen_string_literal: true

module RailsAiContext
  module Serializers
    # Which root files a set of AI tools gets and what each holds, so the root
    # content is written once into a file every chosen tool reads. Cursor reads
    # CLAUDE.md and AGENTS.md as it reads its own rules, so a copy for each
    # tool loaded the same content two or three times there.
    #
    # #root answers :content (the whole root file), :import (a line pointing a
    # tool that expands imports at the file with the content) or nil: not
    # written, and a gem block left there from an earlier run is removed.
    class LoadPlan
      def initialize(tools, root_files: RailsAiContext.configuration.generate_root_files)
        keys = Array(tools).map(&:to_sym)
        @tools = Install::AiTool.all.select { |tool| keys.include?(tool.key) }
        @root_files = root_files
        @kinds = root_files ? plan : {}
      end

      def root(path)
        @kinds[path]
      end

      # The file an :import points at.
      def content_home
        @kinds.key(:content)
      end

      # Whether a root file this tool reads carries the root content, so its
      # rules leave out what that file states.
      def root_carries?(key)
        @root_files && @tools.any? { |tool| tool.key == key }
      end

      private

      # The files read by the most AI tools first, so a file shared by several
      # is where the content goes, and a later one is written only for the
      # tools nothing chosen so far reaches.
      def plan
        reach = Install::AiTool.all.flat_map(&:reads).map(&:path).tally
        candidates = @tools.map(&:root).uniq.sort_by.with_index { |path, i| [ -reach.fetch(path, 0), i ] }
        covered = []
        candidates.each_with_object({}) do |path, kinds|
          readers = @tools.select { |tool| reading(tool, path) }
          uncovered = readers - covered
          next if uncovered.empty?

          importing = kinds.value?(:content) && uncovered.all? { |tool| reading(tool, path).imports }
          kinds[path] = importing ? :import : :content
          covered |= readers
        end
      end

      def reading(tool, path)
        tool.reads.find { |read| read.path == path }
      end
    end
  end
end
