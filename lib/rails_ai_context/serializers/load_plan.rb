# frozen_string_literal: true

module RailsAiContext
  module Serializers
    # Which root files a set of AI tools gets, so the root content is written
    # once into a file every chosen tool reads. #root answers :content, :import
    # (a pointer for a tool that expands imports) or nil (not written).
    class LoadPlan
      # unwritable: root files a write refused, which the plan routes around.
      def initialize(tools, root_files: RailsAiContext.configuration.generate_root_files, unwritable: [])
        keys = Array(tools).map(&:to_sym)
        @tools = Install::AiTool.all.select { |tool| keys.include?(tool.key) }
        @root_files = root_files
        @unwritable = unwritable
        @kinds = root_files ? plan : {}
      end

      # The plan once this root file is known to refuse its block.
      def without(path)
        LoadPlan.new(@tools.map(&:key), root_files: @root_files, unwritable: @unwritable + [ path ])
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
        tool = Install::AiTool.find(key)
        tool.reads.any? { |read| @kinds.key?(read.path) }
      end

      private

      # The files read by the most AI tools first, so a file shared by several
      # is where the content goes, and a later one is written only for the
      # tools nothing chosen so far reaches.
      def plan
        reach = Install::AiTool.all.flat_map(&:reads).map(&:path).tally
        candidates = (@tools.map(&:root).uniq - @unwritable).sort_by.with_index { |path, i| [ -reach.fetch(path, 0), i ] }
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
