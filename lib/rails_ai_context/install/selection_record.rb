# frozen_string_literal: true

require "yaml"
require "date"
require "fileutils"
require_relative "../configuration"
require_relative "../safe_file"
require_relative "../unbooted_settings"
require_relative "initializer_file"

module RailsAiContext
  module Install
    # Which AI tools the user picked, written and read the same way whichever
    # entry point ran. Two records exist because they answer to two owners:
    # the YAML file is the installer's own, and the initializer line is Rails
    # config a user hand-edits. Reading is UnbootedSettings', which takes them
    # in the boot's order, so the initializer wins.
    #
    # Writing is textual, because both files are ones a user annotates: a
    # write changes the value that moved and nothing around it, and a write
    # that moves no value leaves the file alone.
    module SelectionRecord
      YAML_FILE = ".rails-ai-context.yml"
      INITIALIZER = "config/initializers/rails_ai_context.rb"
      YAML_KEY = "ai_tools"

      # The two readers of .rails-ai-context.yml must permit the same classes,
      # or a file one of them accepts voids every key for the other.
      PERMITTED_YAML = Configuration::PERMITTED_YAML_CLASSES

      # The three keys the record writes into the initializer, each as the
      # assignment it rewrites, from the key's name on. The value is captured
      # apart from what stands before and after it, so a rewrite keeps the
      # line's indentation and whatever follows the value. The line ends short
      # of a CRLF's CR, which stays with the line ending.
      ASSIGNMENT = {
        ai_tools: /\A(?<lead>ai_tools[ \t]*=[ \t]*)(?<value>%i\[[^\]\r\n]*\])(?<rest>[^\r\n]*)/,
        tool_mode: /\A(?<lead>tool_mode[ \t]*=[ \t]*)(?<value>:\w+)(?<rest>[^\r\n]*)/,
        context_files: /\A(?<lead>context_files[ \t]*=[ \t]*)(?<value>true|false)\b(?<rest>[^\r\n]*)/
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

      # @return [Array<Symbol>, nil] the recorded tools this gem knows, or nil if none.
      def read(root:)
        tools = UnbootedSettings.read(root).ai_tools
        tools && normalize(tools)
      end

      # Why the YAML record will not read, e.g. "cannot be read (invalid YAML
      # at line 3)", the case in which a write leaves it as it is.
      #
      # @return [String, nil] nil when it reads or is not there
      def unreadable(root:)
        path = File.join(root.to_s, YAML_FILE)
        return nil unless File.exist?(path) || File.symlink?(path)
        # A link to nothing, or to itself, is said by the link rule writes use.
        return "cannot be read (#{SafeFile.write_refusal(path, root: root.to_s)})" unless File.exist?(path)

        data, error = Configuration.read_yaml(path)
        return nil if data.is_a?(Hash)

        reason = case error
        when nil then "it holds no `key: value` settings"
        when Psych::SyntaxError then "invalid YAML at line #{error.line}"
        # Ruby's own text repeats the absolute path.
        when SystemCallError then SystemCallError.new(nil, error.errno).message.downcase
        else error.message
        end
        "cannot be read (#{reason})"
      end

      # Why the YAML record cannot take the write this selection makes, nil
      # when it can or the selection leaves it as it is.
      #
      # @return [String, nil] e.g. "cannot be written (its permissions do not allow it)"
      def unwritable(tools, root:, extra_yaml: {})
        changes = yaml_changes(tools, root: root, extra_yaml: extra_yaml)
        return nil if changes.nil? || changes.empty?

        refusal = SafeFile.write_refusal(File.join(root.to_s, YAML_FILE), root: root.to_s)
        "cannot be written (#{refusal})" if refusal
      end

      # Why the initializer cannot take the write this selection makes to a
      # line it holds, nil when it can or holds none that moves: its line wins
      # over the YAML, so the selection would not be the one in force.
      #
      # @return [String, nil]
      def initializer_unwritable(tools, root:, extra_yaml: {})
        path = File.join(root.to_s, INITIALIZER)
        return nil unless File.file?(path)

        content = SafeFile.read_text(path)
        values = { ai_tools: tools, tool_mode: extra_yaml["tool_mode"]&.to_sym, context_files: extra_yaml["context_files"] }
        moved = values.any? { |key, value| !value.nil? && edit_config_line(content, key, value, insert: false).last == :updated }
        refusal = moved && SafeFile.write_refusal(path, root: root.to_s)
        "cannot be written (#{refusal}), and the selection it holds takes precedence" if refusal
      rescue SystemCallError
        nil
      end

      # The keys a write of this selection changes in the YAML record, every
      # key when there is no record.
      #
      # @return [Hash, nil] nil when the record will not read
      def yaml_changes(tools, root:, extra_yaml: {})
        yaml_state(normalize(tools), root, extra_yaml).last
      end

      # @return [Symbol, nil]
      def tool_mode(root:)
        UnbootedSettings.read(root).tool_mode
      end

      # Whether this install writes context files.
      #
      # @return [Boolean, nil] nil when nothing recorded it
      def context_files(root:)
        UnbootedSettings.read(root).context_files
      end

      # @return [Symbol] :updated, :inserted, :unchanged, :conflict, :absent or :unparsed
      def write_context_files(value, root:)
        write_config_line(root, :context_files, value ? true : false)
      end

      # Only an uncommented line is rewritten - the generated initializer ships
      # a commented-out default that must stay a comment.
      #
      # @return [Symbol] :updated, :inserted, :unchanged, :conflict, :absent or :unparsed
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
      # A record that will not read is the user's whole config, so nothing is
      # written over it, and the initializer is left too: a selection read
      # through the broken file would otherwise be written there as all five.
      #
      # @return [Hash] { tools:, yaml: :created|:updated|:unchanged|:failed,
      #   initializer: :updated|:inserted|:unchanged|:conflict|:absent|:unparsed|:skipped }
      def write(tools, root:, extra_yaml: {}, initializer: true)
        tools = normalize(tools)
        yaml = write_yaml(tools, root, extra_yaml)

        {
          tools: tools,
          yaml: yaml,
          initializer: initializer && yaml != :failed ? write_config_line(root, :ai_tools, tools) : :skipped
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
        UnbootedSettings.read(root).assigned?(:tool_mode)
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
      # A text that does not parse is left as it is, :unparsed.
      #
      # @param insert [Boolean] false rewrites only; the generator adds a
      #   missing key with the section it belongs to
      # @return [Array(String, Symbol)] the text, and :updated, :inserted,
      #   :unchanged, :conflict, :absent or :unparsed
      def edit_config_line(content, key, value, insert: true)
        # Ripper's columns and a `^` both start past a BOM, so the edit works on the text after it.
        bom, rest = SafeFile.split_bom(content)
        return edit_text(content, key, value, insert) if bom.empty?

        text, status = edit_text(rest, key, value, insert)
        [ %i[updated inserted].include?(status) ? bom + text : content, status ]
      end

      private_class_method def self.edit_text(content, key, value, insert)
        lines = content.lines
        writes = UnbootedSettings.writes(content) or return [ content, :unparsed ]
        # A line that reaches the configuration as a whole may write this key too.
        return [ content, :conflict ] if writes.any? { |_, written, _| written.nil? }

        if (write = last_write(writes, key))
          head, assignment = assignment_at(lines, write)
          # A value computed at boot, or a write under a condition, is the user's to edit.
          return [ content, :conflict ] if assignment.nil? || UnbootedSettings.unread?(write.last)
          return [ content, :unchanged ] if same_value?(key, assignment[:value], value)

          lines[write.first.first - 1] = "#{head}#{assignment[:lead]}#{value_source(key, value)}" \
                                         "#{note_after(key, value, assignment[:rest])}#{assignment.post_match}"
          return [ lines.join, :updated ]
        end
        return [ content, :absent ] unless insert

        # An inserted line ends the way the file's lines do.
        newline = content.include?("\r\n") ? "\r\n" : "\n"
        line = "#{config_line(key, value).delete_prefix('config.')}#{newline}"
        head, beside = assignment_at(lines, last_write(writes, :ai_tools)) unless key == :ai_tools
        if beside && head.match?(/\A[ \t]*\w+\.\z/) && beside[:rest].match?(/\A[ \t]*(?:#.*)?\z/)
          lines.insert(last_write(writes, :ai_tools).first.first, "#{head}#{line}")
          [ lines.join, :inserted ]
        elsif (block = InitializerFile.configure_block(content)) && block.param && block.head_line < block.close_line
          # The head of the configure block, one step in from the call, in the block's own param.
          lines.insert(block.head_line, "#{lines[block.call_line - 1][/\A[ \t]*/]}  #{block.param}.#{line}")
          [ lines.join, :inserted ]
        else
          [ content, :absent ]
        end
      end

      # The write of a key the boot keeps: the last one.
      private_class_method def self.last_write(writes, key)
        writes.select { |_, written, _| written == key }.max_by(&:first)
      end

      # The line up to a write's key, and its assignment from the key on (nil in a shape this does not rewrite).
      private_class_method def self.assignment_at(lines, write)
        return nil unless write

        (number, column), key, = write
        line = lines[number - 1]
        [ line.byteslice(0, column), line.byteslice(column..).match(ASSIGNMENT.fetch(key)) ]
      end

      private_class_method def self.yaml_message(status, place = nil)
        file = named(YAML_FILE, place)
        case status
        when :unchanged then [ :muted, "#{file} (unchanged)" ]
        when :created   then [ :ok, "Created #{file}" ]
        when :updated   then [ :ok, "Updated #{file}" ]
        when :failed    then [ :warn, "Could not read or write #{file}, so it was left as it is - your selection was not saved" ]
        end
      end

      private_class_method def self.initializer_message(status, place = nil)
        file = named(INITIALIZER, place)
        case status
        when :updated, :inserted then [ :ok, "Updated #{file}" ]
        when :conflict
          [ :warn, "#{file} sets config.ai_tools in a form this installer does not " \
                   "rewrite, and it takes precedence - edit it by hand to change your selection" ]
        when :unparsed
          [ :warn, "#{file} does not parse as Ruby, so it was left as it is - fix it and run this again to record your selection there" ]
        end
      end

      private_class_method def self.named(file, place)
        place ? File.join(place, file) : file
      end

      # Everything below is how the record is stored, not what callers ask of
      # it. The seam is read / write / add / messages / config_line /
      # edit_config_line.
      # One key's line written into the initializer file, through the same
      # edit the generator makes in memory.
      private_class_method def self.write_config_line(root, key, value)
        path = File.join(root.to_s, INITIALIZER)
        return :absent unless File.exist?(path)

        content, status = edit_config_line(SafeFile.read_text(path), key, value)
        SafeFile.atomic_write(path, content, root: root) if %i[updated inserted].include?(status)
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

      # @return [Symbol] :created, :updated, :unchanged or :failed
      private_class_method def self.write_yaml(tools, root, extra = {})
        path = File.join(root.to_s, YAML_FILE)
        data, changed = yaml_state(tools, root, extra)
        return :failed if changed.nil?
        return :unchanged if changed.empty?

        unless data
          SafeFile.atomic_write(path, changed.to_yaml, root: root)
          return :created
        end

        SafeFile.atomic_write(path, yaml_edited(SafeFile.read_text(path), data, changed), root: root)
        :updated
      rescue StandardError => e
        RailsAiContext.log_warn "[rails-ai-context] could not write #{YAML_FILE}: #{e.message}"
        :failed
      end

      # The record as it reads (nil when there is none) and the keys the
      # selection changes in it (nil when it will not read).
      private_class_method def self.yaml_state(tools, root, extra)
        path = File.join(root.to_s, YAML_FILE)
        wanted = { YAML_KEY => tools.map(&:to_s) }
        extra.each { |key, value| wanted[key.to_s] = value }
        return [ nil, wanted ] unless File.exist?(path)

        data = Configuration.read_yaml(path).first
        return [ nil, nil ] unless data.is_a?(Hash)

        changed = wanted.filter_map do |key, value|
          next if data.key?(key) && same_yaml_value?(data[key], value)

          # The tools already listed keep their places; new ones go after them.
          if value.is_a?(Array) && data[key].is_a?(Array)
            listed = data[key].map(&:to_s)
            value = (listed & value) + (value - listed)
          end
          [ key, value ]
        end.to_h
        [ data, changed ]
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
        YAML.safe_load(text, permitted_classes: PERMITTED_YAML, aliases: true) == expected
      rescue StandardError
        false
      end
    end
  end
end
