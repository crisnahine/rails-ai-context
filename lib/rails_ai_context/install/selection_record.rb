# frozen_string_literal: true

require "yaml"
require "date"
require "fileutils"
require_relative "../configuration"
require_relative "../safe_file"

module RailsAiContext
  module Install
    # Which AI tools the user picked, written and read the same way whichever
    # entry point ran. Two records exist because they answer to two owners:
    # the YAML file is the installer's own, and the initializer line is Rails
    # config a user hand-edits. The initializer therefore wins on read.
    #
    # Reading is a textual parse, never an eval or a boot, so the standalone
    # CLI can answer the question with no Rails in the process. Writing is
    # textual too, because both files are ones a user annotates: a write
    # changes the value that moved and nothing around it, and a write that
    # moves no value leaves the file alone.
    module SelectionRecord
      YAML_FILE = ".rails-ai-context.yml"
      INITIALIZER = "config/initializers/rails_ai_context.rb"
      YAML_KEY = "ai_tools"

      # The two readers of .rails-ai-context.yml must permit the same classes,
      # or a file one of them accepts voids every key for the other.
      PERMITTED_YAML = Configuration::PERMITTED_YAML_CLASSES

      # Matches the line the installer writes, and nothing else. Anchored past
      # any leading whitespace but not past a `#`, so the commented-out
      # default in the generated initializer is not mistaken for a selection.
      SELECTION_LINE = /^[ \t]*config\.ai_tools\s*=\s*%i\[([^\]]*)\]/

      MODE_LINE = /^[ \t]*config\.tool_mode\s*=\s*:(\w+)/

      # Only an uncommented assignment: the generated initializer ships the
      # key commented out, and a comment is not a choice.
      CONTEXT_FILES_LINE = /^[ \t]*config\.context_files\s*=\s*(true|false)\b/

      # Where a line goes when the initializer has none for its key yet: the
      # head of the configure block, one step in from it.
      CONFIGURE_BLOCK = /^([ \t]*)RailsAiContext\.configure do \|config\|\n/

      # The three keys the record writes into the initializer, each as the
      # assignment it rewrites. The value is captured apart from what stands
      # before and after it, so a rewrite keeps the line's indentation and
      # whatever follows the value.
      ASSIGNMENT = {
        ai_tools: /^(?<lead>[ \t]*config\.ai_tools[ \t]*=[ \t]*)(?<value>%i\[[^\]\n]*\])(?<rest>[^\n]*)$/,
        tool_mode: /^(?<lead>[ \t]*config\.tool_mode[ \t]*=[ \t]*)(?<value>:\w+)(?<rest>[^\n]*)$/,
        context_files: /^(?<lead>[ \t]*config\.context_files[ \t]*=[ \t]*)(?<value>true|false)\b(?<rest>[^\n]*)$/
      }.freeze

      # The note the generator writes after a value. It describes the value,
      # so a rewrite swaps it for the new value's; a note of the user's own is
      # kept as it is.
      NOTE = {
        tool_mode: { mcp: "   # MCP primary + CLI fallback", cli: "    # CLI only (no MCP server needed)" },
        context_files: { true => "   # write CLAUDE.md, AGENTS.md and rules files",
                         false => "  # MCP only: no context files are written" }
      }.freeze

      module_function

      # @return [Array<Symbol>, nil] the recorded tools, or nil if none.
      def read(root:)
        match = initializer_content(root)&.match(SELECTION_LINE)
        (match && presence(normalize(match[1].split))) ||
          presence(normalize(yaml_record(root)[YAML_KEY]))
      end

      # The recorded tool mode, initializer first, same precedence as the
      # tools. The record writes the mode into its YAML (`extra_yaml`), so
      # this is the reader that stopped `rails-ai-context init`'s recorded
      # mode from being inert on in-app surfaces.
      #
      # @return [Symbol, nil]
      def tool_mode(root:)
        initializer_content(root)&.slice(MODE_LINE, 1)&.to_sym || yaml_record(root)["tool_mode"]&.to_sym
      end

      # Whether this install writes context files, initializer first, the
      # same precedence the tools and the mode keep.
      #
      # @return [Boolean, nil] nil when nothing recorded it
      def context_files(root:)
        declared = initializer_content(root)&.slice(CONTEXT_FILES_LINE, 1)
        return declared == "true" unless declared.nil?

        recorded = yaml_record(root)["context_files"]
        recorded.nil? ? nil : !!recorded
      end

      # @return [Symbol] :updated, :inserted, :unchanged, :conflict or :absent
      def write_context_files(value, root:)
        write_config_line(root, :context_files, value ? true : false)
      end

      # Only an uncommented line is rewritten - the generated initializer ships
      # a commented-out default that must stay a comment.
      #
      # @return [Symbol] :updated, :inserted, :unchanged, :conflict or :absent
      def write_tool_mode(mode, root:)
        write_config_line(root, :tool_mode, mode.to_sym)
      end

      # Records the selection in both places and says what it did, because
      # every entry prints its own "Created / Updated / unchanged" line and
      # would otherwise keep its own copy of the writing just to know which.
      #
      # @param initializer [Boolean] false leaves the user's Rails config
      #   untouched, for callers refreshing this gem's own YAML on a run the
      #   user did not ask to change their selection in.
      # @return [Hash] { tools:, yaml: :created|:updated|:unchanged|:replaced|:failed,
      #   initializer: :updated|:inserted|:unchanged|:conflict|:absent|:skipped }
      def write(tools, root:, extra_yaml: {}, initializer: true)
        tools = normalize(tools)

        {
          tools: tools,
          yaml: write_yaml(tools, root, extra_yaml),
          initializer: initializer ? write_config_line(root, :ai_tools, tools) : :skipped
        }
      end

      # What a caller should tell the user about a write, as [level, text]
      # pairs. The entries differ in voice - Thor `say` with a colour, `puts`
      # with an emoji, `$stderr.puts` - not in what there is to say, and
      # keeping that judgement here means a new outcome lands in one place
      # rather than three.
      #
      # @param place [String, nil] the app root as the person running the
      #   entry names it from where they stand, when that is outside the app
      #   (Install::Surface#place); the files are named from there
      # @return [Array<Array(Symbol, String)>] level is :ok, :muted or :warn
      def messages(result, place: nil)
        [ yaml_message(result[:yaml], place), initializer_message(result[:initializer], place) ].compact
      end

      # Adds one tool to whatever is already recorded, for the per-tool
      # context tasks. Reads first so the addition lands in both files
      # together rather than only in whichever one the caller happened to
      # know about.
      def add(tool, root:)
        addition = normalize([ tool ])
        # `json` is a real context format and a real rake task but not an AI
        # tool. Recording the empty union would put `config.ai_tools = %i[]`
        # into the user's initializer and, worse, make the record look set,
        # so the first-run prompt never fires again.
        return { tools: [], yaml: :skipped, initializer: :skipped } if addition.empty?

        write((read(root: root) || []) | addition, root: root)
      end

      # What to say when a single-value key came back :conflict, nil otherwise.
      def conflict_message(key, status, place: nil)
        return unless status == :conflict

        [ :warn, "#{named(INITIALIZER, place)} sets config.#{key} in a form this installer does not " \
                 "rewrite, and it takes precedence - edit it by hand to change it" ]
      end

      # Whether the app has settled its tool mode, in the record or in an
      # initializer line of any shape, so no entry asks again.
      def tool_mode_set?(root:)
        !tool_mode(root: root).nil? || initializer_content(root).to_s.match?(/^[ \t]*config\.tool_mode\s*=/)
      end

      # The line the generator writes for a key, without its indentation.
      def config_line(key, value)
        "config.#{key} = #{value_source(key, value)}#{NOTE.dig(key, value)}"
      end

      # One key's line in an initializer's text. A line in the shape this
      # record writes gets its value replaced where it stands, and a value it
      # already holds leaves the text as it was. A key with no line gets one,
      # beside the selection line or at the head of the configure block, at
      # the indentation of what it sits beside.
      #
      # @param insert [Boolean] false rewrites only; the generator adds a
      #   missing key with the section it belongs to
      # @return [Array(String, Symbol)] the text, and :updated, :inserted,
      #   :unchanged, :conflict or :absent
      def edit_config_line(content, key, value, insert: true)
        if (line = content.match(ASSIGNMENT.fetch(key)))
          return [ content, :unchanged ] if same_value?(key, line[:value], value)

          rewritten = "#{line[:lead]}#{value_source(key, value)}#{note_after(key, value, line[:rest])}"
          return [ "#{line.pre_match}#{rewritten}#{line.post_match}", :updated ]
        end

        # Assigned in a shape this record does not rewrite. A second line
        # beside it would lose at boot and win on read.
        return [ content, :conflict ] if content.match?(/^[ \t]*config\.#{key}\s*=/)
        return [ content, :absent ] unless insert

        if key != :ai_tools && (beside = content.match(ASSIGNMENT[:ai_tools]))
          indent = beside[:lead][/\A[ \t]*/]
          [ "#{beside.pre_match}#{beside[0]}\n#{indent}#{config_line(key, value)}#{beside.post_match}", :inserted ]
        elsif (block = content.match(CONFIGURE_BLOCK))
          [ "#{block.pre_match}#{block[0]}#{block[1]}  #{config_line(key, value)}\n#{block.post_match}", :inserted ]
        else
          [ content, :absent ]
        end
      end

      private_class_method def self.yaml_message(status, place = nil)
        file = named(YAML_FILE, place)
        case status
        when :unchanged then [ :muted, "#{file} (unchanged)" ]
        when :created   then [ :ok, "Created #{file}" ]
        when :updated   then [ :ok, "Updated #{file}" ]
        when :replaced  then [ :warn, "#{file} could not be read, so it was replaced" ]
        when :failed    then [ :warn, "Could not write #{file} - your selection was not saved" ]
        end
      end

      private_class_method def self.initializer_message(status, place = nil)
        file = named(INITIALIZER, place)
        case status
        when :updated, :inserted then [ :ok, "Updated #{file}" ]
        when :conflict
          [ :warn, "#{file} sets config.ai_tools in a form this installer does not " \
                   "rewrite, and it takes precedence - edit it by hand to change your selection" ]
        end
      end

      private_class_method def self.named(file, place)
        place ? File.join(place, file) : file
      end

      # Everything below is how the record is stored, not what callers ask of
      # it. The seam is read / write / add / messages / config_line /
      # edit_config_line.
      # @return [String, nil] the initializer's source, nil when it is missing
      #   or unreadable.
      private_class_method def self.initializer_content(root)
        path = File.join(root.to_s, INITIALIZER)
        return nil unless File.exist?(path)

        File.read(path)
      rescue StandardError => e
        RailsAiContext.log_warn "[rails-ai-context] could not read #{INITIALIZER}: #{e.message}" if ENV["DEBUG"]
        nil
      end

      # @return [Hash] the parsed record, empty when it is missing or unreadable.
      private_class_method def self.yaml_record(root)
        path = File.join(root.to_s, YAML_FILE)
        return {} unless File.exist?(path)

        YAML.safe_load_file(path, permitted_classes: PERMITTED_YAML) || {}
      rescue StandardError => e
        RailsAiContext.log_warn "[rails-ai-context] could not read #{YAML_FILE}: #{e.message}" if ENV["DEBUG"]
        {}
      end

      # One key's line written into the initializer file, through the same
      # edit the generator makes in memory.
      private_class_method def self.write_config_line(root, key, value)
        path = File.join(root.to_s, INITIALIZER)
        return :absent unless File.exist?(path)

        content, status = edit_config_line(SafeFile.read_text(path), key, value)
        replace_file(path, content) if %i[updated inserted].include?(status)
        status
      rescue StandardError => e
        RailsAiContext.log_warn "[rails-ai-context] could not write #{INITIALIZER}: #{e.message}"
        :unchanged
      end

      private_class_method def self.value_source(key, value)
        case key
        when :ai_tools then "%i[#{normalize(value).join(' ')}]"
        when :tool_mode then ":#{value}"
        else value ? "true" : "false"
        end
      end

      # The tools are a set: their order on the line is not part of the
      # selection.
      private_class_method def self.same_value?(key, source, value)
        return source == value_source(key, value) unless key == :ai_tools

        normalize(source[/\[(.*)\]/, 1].to_s.split).sort == normalize(value).sort
      end

      # What follows a new value: the rest of the line as it was when the
      # user wrote it, and otherwise the generator's note on the new value -
      # its note on the old one would now describe the wrong value.
      private_class_method def self.note_after(key, value, rest)
        notes = NOTE[key]
        return rest unless notes && (rest.strip.empty? || notes.values.any? { |note| note.strip == rest.strip })

        notes.fetch(value, "")
      end

      # A name that is not a tool this gem knows would be written back out as
      # a selection nothing can act on.
      private_class_method def self.normalize(tools)
        Array(tools).filter_map { |name| AiTool.find(name)&.key }
      end

      private_class_method def self.presence(tools)
        tools.empty? ? nil : tools
      end

      # @return [Hash, nil] the parsed record, or nil when it will not parse
      private_class_method def self.readable_yaml(path)
        YAML.safe_load_file(path, permitted_classes: PERMITTED_YAML) || {}
      rescue StandardError
        nil
      end

      # @return [Symbol] :created, :updated, :unchanged, :replaced or :failed
      private_class_method def self.write_yaml(tools, root, extra = {})
        path = File.join(root.to_s, YAML_FILE)
        wanted = { YAML_KEY => tools.map(&:to_s) }
        extra.each { |key, value| wanted[key.to_s] = value }

        unless File.exist?(path)
          replace_file(path, wanted.to_yaml)
          return :created
        end

        # An unreadable record is replaced, not treated as a reason to give
        # up: this gem owns the file, and refusing would leave the selection
        # unrecordable for good after a single typo. Reported separately so
        # the caller can say the old contents went.
        data = readable_yaml(path)
        unless data.is_a?(Hash)
          replace_file(path, wanted.to_yaml)
          return :replaced
        end

        changed = wanted.filter_map do |key, value|
          next if data.key?(key) && same_yaml_value?(data[key], value)

          # The tools already listed keep their places; new ones go after them.
          if value.is_a?(Array) && data[key].is_a?(Array)
            listed = data[key].map(&:to_s)
            value = (listed & value) + (value - listed)
          end
          [ key, value ]
        end.to_h
        return :unchanged if changed.empty?

        replace_file(path, yaml_edited(SafeFile.read_text(path), data, changed))
        :updated
      rescue StandardError => e
        RailsAiContext.log_warn "[rails-ai-context] could not write #{YAML_FILE}: #{e.message}"
        :failed
      end

      # A value as the config reads it: a symbol is its name, and the order of
      # the tools is not part of the selection.
      private_class_method def self.same_yaml_value?(recorded, wanted)
        case wanted
        when Array then recorded.is_a?(Array) && recorded.map(&:to_s).sort == wanted.sort
        when String then (recorded.is_a?(String) || recorded.is_a?(Symbol)) && recorded.to_s == wanted
        else recorded == wanted
        end
      end

      # The record's text with each changed key rewritten where it stands and
      # a new key added at the end, so comments, blank lines and the keys
      # this gem does not write come through as they were. A text this cannot
      # edit in place faithfully (a quoted key, an alias, a second document)
      # is caught by reading the result back, and is written whole instead.
      private_class_method def self.yaml_edited(text, data, changed)
        lines = text.lines
        changed.each do |key, value|
          if (start = lines.index { |line| line.match?(yaml_key(key)) })
            finish = yaml_entry_end(lines, start)
            lines[start...finish] = yaml_rewritten(lines[start...finish], key, value)
          else
            lines[-1] = "#{lines[-1]}\n" unless lines.empty? || lines[-1].end_with?("\n")
            lines.concat(yaml_lines(key, value))
          end
        end

        edited = lines.join
        expected = data.merge(changed)
        yaml_reads_as?(edited, expected) ? edited : expected.to_yaml
      end

      private_class_method def self.yaml_key(key)
        /\A#{Regexp.escape(key)}[ \t]*:(?=[ \t]|\r?\n|\z)/
      end

      # Where a top-level key's entry ends: past the lines of its value
      # (indented lines, list items, and the comments and blank lines between
      # them), short of the comments and blank lines just above the next key,
      # which belong to that key.
      private_class_method def self.yaml_entry_end(lines, start)
        finish = start + 1
        finish += 1 while finish < lines.size && lines[finish].match?(/\A(?:[ \t]|-(?:[ \t]|\r?\n|\z)|#|\r?\n|\z)/)
        finish -= 1 while finish > start + 1 && (lines[finish - 1].strip.empty? || lines[finish - 1].lstrip.start_with?("#"))
        finish
      end

      # One entry, rewritten. A list keeps the lines of the tools it still
      # holds and the comments between them; a flow list and a scalar change
      # on the key's line and keep what follows the value. An entry in any
      # other shape is written the way YAML writes it.
      private_class_method def self.yaml_rewritten(entry, key, value)
        head = entry.first.match(/\A(?<lead>#{Regexp.escape(key)}[ \t]*:[ \t]*)(?<value>[^#\r\n]*?)(?<rest>[ \t]*(?:#[^\r\n]*)?(?:\r?\n)?)\z/)
        return yaml_lines(key, value) unless head

        if value.is_a?(Array) && head[:value].empty? && value.any?
          yaml_list_rewritten(entry, value)
        elsif entry.size == 1 && !head[:value].empty? && (!value.is_a?(Array) || head[:value].match?(/\A\[[^\[\]]*\]\z/))
          shown = value.is_a?(Array) ? "[#{value.join(', ')}]" : yaml_scalar(value)
          [ "#{head[:lead]}#{shown}#{head[:rest]}" ]
        else
          yaml_lines(key, value)
        end
      end

      # A block list edited item by item: an item whose tool is still picked
      # keeps its line, a dropped tool's line goes, a new tool goes after the
      # last item at its indentation, and a comment between items stays put.
      private_class_method def self.yaml_list_rewritten(entry, value)
        item = /\A(?<indent>[ \t]*)-(?:[ \t]+(?<name>[^#\r\n]*?))?[ \t]*(?:#[^\r\n]*)?\r?\n?\z/
        held = entry.each_with_index.drop(1).filter_map do |line, index|
          match = line.match(item) or next
          [ index, match[:name].to_s.delete("'\""), match[:indent] ]
        end
        indent = held.first ? held.first.last : ""
        newline = entry.first.end_with?("\r\n") ? "\r\n" : "\n"

        lines = entry.dup
        added = value - held.map { |_, name, _| name }
        lines.insert((held.last&.first || 0) + 1, *added.map { |name| "#{indent}- #{name}#{newline}" })
        held.reverse_each { |index, name, _| lines.delete_at(index) unless value.include?(name) }
        lines
      end

      # A key and its value the way YAML writes them, without the document
      # marker.
      private_class_method def self.yaml_lines(key, value)
        { key => value }.to_yaml.lines.drop(1)
      end

      private_class_method def self.yaml_scalar(value)
        value.to_yaml.delete_prefix("--- ").sub(/\n(?:\.\.\.\n)?\z/, "")
      end

      private_class_method def self.yaml_reads_as?(text, expected)
        YAML.safe_load(text, permitted_classes: PERMITTED_YAML) == expected
      rescue StandardError
        false
      end

      # Through a temp file and a rename, so a reader racing the write sees
      # the old file or the new one; through a link to the file it names, and
      # keeping that file's mode, so the file stays what it was apart from its
      # text.
      private_class_method def self.replace_file(path, content)
        path = File.realpath(path) if File.symlink?(path)
        mode = File.stat(path).mode & 0o7777 if File.exist?(path)
        SafeFile.atomic_write(path, content)
        File.chmod(mode, path) if mode
      end
    end
  end
end
