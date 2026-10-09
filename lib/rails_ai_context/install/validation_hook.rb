# frozen_string_literal: true

require "shellwords"

module RailsAiContext
  module Install
    # The pre-commit hook the install generator offers: one script for every
    # app of a repository that took it. The scripts earlier versions wrote
    # are kept byte for byte, so that one nobody changed since is recognised
    # and brought up to date rather than left validating the way it did.
    module ValidationHook
      # The line a hook names the apps it covers on, relative to the top of
      # the work tree, the way a shell reads them.
      APPS_LINE = /^# rails-ai-context apps: (.*)$/

      # Earlier versions' hooks, each written for the app at the top of its
      # repository - the only place they were installed - and each handing
      # validate the deleted files too, which it then fails on. The value is
      # the install form the hook validates with.
      LEGACY = {
        # v5.9.0 to v5.10.x
        <<~'HOOK' => false,
          #!/bin/bash
          # rails-ai-context: validate Rails references before commit
          # Catches hallucinated columns, missing models, and schema drift.
          # Remove this file or the rails-ai-context section to disable.

          changed_files=$(git diff --cached --name-only | grep -E '\.(rb|erb)$' || true)

          if [ -z "$changed_files" ]; then
            exit 0
          fi

          if command -v rails &> /dev/null; then
            rails 'ai:tool[validate]' files="$(echo $changed_files | tr '\n' ',')" 2>/dev/null
            exit_code=$?
            if [ $exit_code -ne 0 ]; then
              echo ""
              echo "rails-ai-context validation found issues."
              echo "Fix them or skip with: git commit --no-verify"
              exit $exit_code
            fi
          fi
        HOOK
        # v5.11.0 on, and from v5.14.0 an in-Gemfile install's
        <<~'HOOK' => false,
          #!/bin/bash
          # rails-ai-context: validate Rails references before commit
          # Catches hallucinated columns, missing models, and schema drift.
          # Remove this file or the rails-ai-context section to disable.

          changed_files=$(git diff --cached --name-only | grep -E '\.(rb|erb)$' || true)

          if [ -z "$changed_files" ]; then
            exit 0
          fi

          if command -v rails &> /dev/null; then
            files=$(printf '%s\n' "$changed_files" | tr '\n' ',')
            rails 'ai:tool[validate]' files="$files" 2>/dev/null
            exit_code=$?
            if [ $exit_code -ne 0 ]; then
              echo ""
              echo "rails-ai-context validation found issues."
              echo "Fix them or skip with: git commit --no-verify"
              exit $exit_code
            fi
          fi
        HOOK
        # v5.14.0 on, a standalone install's
        <<~'HOOK' => true
          #!/bin/bash
          # rails-ai-context: validate Rails references before commit
          # Catches hallucinated columns, missing models, and schema drift.
          # Remove this file or the rails-ai-context section to disable.

          changed_files=$(git diff --cached --name-only | grep -E '\.(rb|erb)$' || true)

          if [ -z "$changed_files" ]; then
            exit 0
          fi

          if command -v rails-ai-context &> /dev/null; then
            files=$(printf '%s\n' "$changed_files" | tr '\n' ',')
            rails-ai-context tool validate --files "$files" 2>/dev/null
            exit_code=$?
            if [ $exit_code -ne 0 ]; then
              echo ""
              echo "rails-ai-context validation found issues."
              echo "Fix them or skip with: git commit --no-verify"
              exit $exit_code
            fi
          fi
        HOOK
      }.freeze

      # What a hook this gem wrote, and nobody changed since, covers: its
      # apps, the install form it validates with, and whether an earlier
      # version wrote it.
      Coverage = Struct.new(:apps, :standalone, :legacy, keyword_init: true)

      module_function

      # One hook for every app it names. Each app's staged files are listed
      # from the top of the work tree by paths relative to the app - never
      # from inside it, where a linked worktree's exported GIT_DIR would make
      # git list them from the top instead - deleted files left out, and
      # validated from inside the app, entered as ./app so that a CDPATH
      # the committer exported cannot send it elsewhere. An app that is gone
      # is passed over.
      #
      # @param apps [Array<String>] app paths from the top of the work tree,
      #   "." for the top itself
      # @param standalone [Boolean] validate with the gem's binary rather
      #   than the rake task, which a standalone install does not have
      def script(apps, standalone:)
        if standalone
          hook_binary = "rails-ai-context"
          validate_command = %(rails-ai-context tool validate --files "$files")
        else
          hook_binary = "rails"
          validate_command = %(rails 'ai:tool[validate]' files="$files")
        end
        listed = apps.shelljoin

        <<~HOOK
          #!/bin/bash
          # rails-ai-context: validate Rails references before commit
          # Catches hallucinated columns, missing models, and schema drift.
          # Remove this file or the rails-ai-context section to disable.
          # rails-ai-context apps: #{listed}

          status=0
          for app in #{listed}; do
            [ -d "$app" ] || continue
            if [ "$app" = "." ]; then
              changed_files=$(git diff --cached --name-only --diff-filter=d | grep -E '\\.(rb|erb)$' || true)
            else
              changed_files=$(git diff --cached --name-only --diff-filter=d --relative="$app/" | grep -E '\\.(rb|erb)$' || true)
            fi
            if [ -z "$changed_files" ]; then
              continue
            fi

            if command -v #{hook_binary} &> /dev/null; then
              files=$(printf '%s\\n' "$changed_files" | tr '\\n' ',')
              (cd "./$app" && #{validate_command} 2>/dev/null)
              exit_code=$?
              if [ $exit_code -ne 0 ]; then
                status=$exit_code
              fi
            fi
          done

          if [ $status -ne 0 ]; then
            echo ""
            echo "rails-ai-context validation found issues."
            echo "Fix them or skip with: git commit --no-verify"
            exit $status
          fi
        HOOK
      end

      # The apps a hook's apps line names, nil when it has none or names them
      # in a form a shell would not read (an unmatched quote) or in bytes that
      # are no text.
      def listed(content)
        line = text(content)[APPS_LINE, 1] or return nil
        line.shellsplit
      rescue ArgumentError
        nil
      end

      # @return [Coverage, nil] nil for a hook changed by hand since it was
      #   written, or one this gem never wrote
      def coverage(content)
        content = text(content)
        LEGACY.each do |legacy, standalone|
          return Coverage.new(apps: [ "." ], standalone: standalone, legacy: true) if content == legacy
        end

        apps = listed(content) or return nil
        standalone = [ false, true ].find { |mode| content == script(apps, standalone: mode) }
        standalone.nil? ? nil : Coverage.new(apps: apps, standalone: standalone, legacy: false)
      end

      # The hook as UTF-8 whatever the locale: it names app paths, which may
      # hold any character.
      def text(content)
        content.dup.force_encoding(Encoding::UTF_8)
      end
    end
  end
end
