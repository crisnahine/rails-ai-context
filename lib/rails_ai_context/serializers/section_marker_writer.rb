# frozen_string_literal: true

require "fileutils"
require "securerandom"

module RailsAiContext
  module Serializers
    # Shared writer that wraps content in `<!-- BEGIN/END rails-ai-context -->`
    # markers so user-added content OUTSIDE the markers survives regeneration.
    #
    # Used by ContextFileSerializer (for CLAUDE.md, AGENTS.md, .github/copilot-
    # instructions.md) and CursorRulesSerializer (for .cursorrules). Same
    # marker contract everywhere — a user can hand-write content above or below
    # the gem-managed block and it'll persist across `rails ai:context` runs.
    module SectionMarkerWriter
      BEGIN_MARKER = "<!-- BEGIN rails-ai-context -->"
      END_MARKER   = "<!-- END rails-ai-context -->"

      module_function

      # Write `content` to `filepath` wrapped in markers. If the file already
      # exists with markers, replace only the marker block (preserving user
      # content outside). If the file exists WITHOUT markers, prepend the
      # marker block so AI tools read our context first while keeping the
      # user's prior content intact below.
      #
      # Returns :written if the file changed (created or block updated),
      # :skipped if the file already had the exact same marker block.
      def write_with_markers(filepath, content)
        marked_content = "#{BEGIN_MARKER}\n#{content}\n#{END_MARKER}\n"

        if File.exist?(filepath)
          existing = File.read(filepath)

          new_content = if existing.include?(BEGIN_MARKER) && existing.include?(END_MARKER)
            existing.sub(
              /#{Regexp.escape(BEGIN_MARKER)}.*?#{Regexp.escape(END_MARKER)}\n?/m,
              marked_content
            )
          else
            "#{marked_content}\n#{existing}"
          end

          return :skipped if new_content == existing
          atomic_write(filepath, new_content)
          :written
        else
          atomic_write(filepath, marked_content)
          :written
        end
      end

      # Write via temp file + rename so concurrent readers never see a partial.
      def atomic_write(filepath, content)
        dir = File.dirname(filepath)
        FileUtils.mkdir_p(dir)
        tmp = File.join(dir, ".#{File.basename(filepath)}.#{SecureRandom.hex(4)}.tmp")
        File.write(tmp, content)
        File.rename(tmp, filepath)
      end
    end
  end
end
