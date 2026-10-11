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

      # The form for several apps written before the hook validated through
      # the gem's CLI, kept byte for byte with its apps and install form left
      # as placeholders. An in-Gemfile install's ran the rake task, which has
      # to boot the app, and threw stderr away, so an app that could not boot
      # (an initializer needing a variable the shell lacks) failed every
      # commit with no reason given.
      EARLIER_SCRIPT = <<~'HOOK'
        #!/bin/bash
        # rails-ai-context: check the staged Ruby and ERB files before a commit.
        # A commit whose staged .rb or .erb files do not parse is stopped.
        # Remove this file or the rails-ai-context section to disable.
        # rails-ai-context apps: %<listed>s

        status=0
        for app in %<listed>s; do
          [ -d "$app" ] || continue
          relative=()
          [ "$app" = "." ] || relative=(--relative="$app/")
          files=""
          while IFS= read -r -d '' name; do
            case "$name" in
              *.rb|*.erb) ;;
              *) continue ;;
            esac
            case "$name" in
              *,*) echo "rails-ai-context: $name is not checked: validate cannot take a comma in a file name" ;;
              *) files="${files:+$files,}$name" ;;
            esac
          done < <(git diff --cached --name-only -z --diff-filter=d "${relative[@]}")
          if [ -z "$files" ]; then
            continue
          fi

          if command -v %<binary>s &> /dev/null; then%<heading>s
            (cd "./$app" && %<validate>s 2>/dev/null)
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
      # Names come NUL-separated: git quotes one holding a character outside
      # ASCII, a quote or a backslash in its line format, which no extension
      # test matched, so the file went unchecked. validate takes its list
      # comma-separated, so a name holding a comma is named and left out.
      #
      # The files go to the gem's CLI, which boots the app and, when the app
      # cannot boot, checks them from source instead and says why on stderr;
      # a syntax check needs no booted app. stderr is shown, so a check that
      # cannot run at all (a bundle that does not resolve) says so.
      #
      # @param apps [Array<String>] app paths from the top of the work tree,
      #   "." for the top itself
      # @param standalone [Boolean] validate with the gem's binary on the
      #   PATH rather than the one the app's bundle holds
      def script(apps, standalone:)
        if standalone
          hook_binary = "rails-ai-context"
          validate_command = %(rails-ai-context tool validate --files "$files")
        else
          hook_binary = "bundle"
          validate_command = %(bundle exec rails-ai-context tool validate --files "$files")
        end
        listed = apps.shelljoin
        # With several apps, each one's lines are headed by its name.
        heading = apps.size > 1 ? %(\n    echo "rails-ai-context: $app") : ""

        <<~HOOK
          #!/bin/bash
          # rails-ai-context: check the staged Ruby and ERB files before a commit.
          # A commit whose staged .rb or .erb files do not parse is stopped.
          # Remove this file or the rails-ai-context section to disable.
          # rails-ai-context apps: #{listed}

          status=0
          for app in #{listed}; do
            [ -d "$app" ] || continue
            relative=()
            [ "$app" = "." ] || relative=(--relative="$app/")
            files=""
            while IFS= read -r -d '' name; do
              case "$name" in
                *.rb|*.erb) ;;
                *) continue ;;
              esac
              case "$name" in
                *,*) echo "rails-ai-context: $name is not checked: validate cannot take a comma in a file name" ;;
                *) files="${files:+$files,}$name" ;;
              esac
            done < <(git diff --cached --name-only -z --diff-filter=d "${relative[@]}")
            if [ -z "$files" ]; then
              continue
            fi

            if command -v #{hook_binary} &> /dev/null; then#{heading}
              (cd "./$app" && #{validate_command})
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
        return Coverage.new(apps: apps, standalone: standalone, legacy: false) unless standalone.nil?

        standalone = [ false, true ].find { |mode| content == earlier_script(apps, standalone: mode) }
        standalone.nil? ? nil : Coverage.new(apps: apps, standalone: standalone, legacy: true)
      end

      # EARLIER_SCRIPT as it was written for these apps in this install form.
      def earlier_script(apps, standalone:)
        format(EARLIER_SCRIPT,
               listed: apps.shelljoin,
               binary: standalone ? "rails-ai-context" : "rails",
               validate: standalone ? %(rails-ai-context tool validate --files "$files") : %(rails 'ai:tool[validate]' files="$files"),
               heading: apps.size > 1 ? %(\n    echo "rails-ai-context: $app") : "")
      end

      # The hook as UTF-8 whatever the locale: it names app paths, which may
      # hold any character.
      def text(content)
        content.dup.force_encoding(Encoding::UTF_8)
      end
    end
  end
end
