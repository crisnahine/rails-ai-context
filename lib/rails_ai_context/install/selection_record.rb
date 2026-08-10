# frozen_string_literal: true

require "yaml"
require "fileutils"

module RailsAiContext
  module Install
    # Which AI tools the user picked, written and read the same way whichever
    # entry point ran. Two records exist because they answer to two owners:
    # the YAML file is the installer's own, and the initializer line is Rails
    # config a user hand-edits. The initializer therefore wins on read.
    #
    # Reading is a textual parse, never an eval or a boot, so the standalone
    # CLI can answer the question with no Rails in the process.
    module SelectionRecord
      YAML_FILE = ".rails-ai-context.yml"
      INITIALIZER = "config/initializers/rails_ai_context.rb"
      YAML_KEY = "ai_tools"

      # Dates and times because a hand-added `generated_at:` is ordinary in a
      # config file, and refusing to load one used to cost the user the write.
      PERMITTED_YAML = [ Symbol, Date, Time ].freeze

      # Matches the line the installer writes, and nothing else. Anchored past
      # any leading whitespace but not past a `#`, so the commented-out
      # default in the generated initializer is not mistaken for a selection.
      SELECTION_LINE = /^[ \t]*config\.ai_tools\s*=\s*%i\[([^\]]*)\]/

      # Any assignment to the key, in any shape. A hand-written
      # `config.ai_tools = [:claude]` is not one this module rewrites, but
      # inserting beside it would leave two assignments: the stale one wins at
      # boot while `read` returns the fresh one.
      ANY_ASSIGNMENT = /^[ \t]*config\.ai_tools\s*=/

      # Where a selection line goes when the initializer has none yet.
      CONFIGURE_BLOCK = /RailsAiContext\.configure do \|config\|\n/

      module_function

      # @return [Array<Symbol>, nil] the recorded tools, or nil if none.
      def read(root:)
        from_initializer(root) || from_yaml(root)
      end

      # Records the selection in both places and says what it did, because
      # every entry prints its own "Created / Updated / unchanged" line and
      # would otherwise keep its own copy of the writing just to know which.
      #
      # @param initializer [Boolean] false leaves the user's Rails config
      #   untouched, for callers refreshing this gem's own YAML on a run the
      #   user did not ask to change their selection in.
      # @return [Hash] { tools:, yaml: :created|:updated|:unchanged|:failed,
      #   initializer: :updated|:inserted|:unchanged|:conflict|:absent|:skipped }
      def write(tools, root:, extra_yaml: {}, initializer: true)
        tools = normalize(tools)

        {
          tools: tools,
          yaml: write_yaml(tools, root, extra_yaml),
          initializer: initializer ? write_initializer(tools, root) : :skipped
        }
      end

      # What a caller should tell the user about a write, as [level, text]
      # pairs. The entries differ in voice - Thor `say` with a colour, `puts`
      # with an emoji, `$stderr.puts` - not in what there is to say, and
      # keeping that judgement here means a new outcome lands in one place
      # rather than three.
      #
      # @return [Array<Array(Symbol, String)>] level is :ok, :muted or :warn
      def messages(result)
        [ yaml_message(result[:yaml]), initializer_message(result[:initializer]) ].compact
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

      def initializer_line(tools)
        "  config.ai_tools = %i[#{normalize(tools).join(' ')}]"
      end

      private_class_method def self.yaml_message(status)
        case status
        when :unchanged then [ :muted, "#{YAML_FILE} (unchanged)" ]
        when :created   then [ :ok, "Created #{YAML_FILE}" ]
        when :updated   then [ :ok, "Updated #{YAML_FILE}" ]
        when :failed    then [ :warn, "Could not write #{YAML_FILE} - your selection was not saved" ]
        end
      end

      private_class_method def self.initializer_message(status)
        case status
        when :updated, :inserted then [ :ok, "Updated #{INITIALIZER}" ]
        when :conflict
          [ :warn, "#{INITIALIZER} sets config.ai_tools in a form this installer does not " \
                   "rewrite, and it takes precedence - edit it by hand to change your selection" ]
        end
      end

      # Everything below is how the record is stored, not what callers ask of
      # it. The seam is read / write / add / messages / initializer_line.
      private_class_method def self.from_initializer(root)
        path = File.join(root.to_s, INITIALIZER)
        return nil unless File.exist?(path)

        match = File.read(path).match(SELECTION_LINE)
        return nil unless match

        presence(normalize(match[1].split))
      rescue StandardError => e
        RailsAiContext.log_warn "[rails-ai-context] could not read #{INITIALIZER}: #{e.message}" if ENV["DEBUG"]
        nil
      end

      private_class_method def self.from_yaml(root)
        path = File.join(root.to_s, YAML_FILE)
        return nil unless File.exist?(path)

        data = YAML.safe_load_file(path, permitted_classes: PERMITTED_YAML) || {}
        presence(normalize(data[YAML_KEY]))
      rescue StandardError => e
        RailsAiContext.log_warn "[rails-ai-context] could not read #{YAML_FILE}: #{e.message}" if ENV["DEBUG"]
        nil
      end

      # A name that is not a tool this gem knows would be written back out as
      # a selection nothing can act on.
      private_class_method def self.normalize(tools)
        Array(tools).filter_map { |name| AiTool.find(name)&.key }
      end

      private_class_method def self.presence(tools)
        tools.empty? ? nil : tools
      end

      # @return [Symbol] :created, :updated, :unchanged or :failed
      private_class_method def self.write_yaml(tools, root, extra = {})
        path = File.join(root.to_s, YAML_FILE)
        existed = File.exist?(path)
        data = existed ? (YAML.safe_load_file(path, permitted_classes: PERMITTED_YAML) || {}) : {}

        before = existed ? File.read(path) : nil
        data[YAML_KEY] = tools.map(&:to_s)
        extra.each { |key, value| data[key.to_s] = value }
        after = data.to_yaml

        return :unchanged if before == after

        File.write(path, after)
        existed ? :updated : :created
      rescue StandardError => e
        RailsAiContext.log_warn "[rails-ai-context] could not write #{YAML_FILE}: #{e.message}"
        :failed
      end

      # Rewrites the selection line, or adds one to a configure block that has
      # none. Creating the initializer itself is the generator's job: a
      # project without one is not a Rails app this gem installed into.
      #
      # @return [Symbol] :updated, :inserted, :unchanged, :conflict or :absent
      private_class_method def self.write_initializer(tools, root)
        path = File.join(root.to_s, INITIALIZER)
        return :absent unless File.exist?(path)

        content = File.read(path)
        line = initializer_line(tools)

        if content.match?(SELECTION_LINE)
          updated = content.sub(SELECTION_LINE, line)
          return :unchanged if updated == content

          File.write(path, updated)
          :updated
        elsif content.match?(ANY_ASSIGNMENT)
          # Assigned in a shape this module will not rewrite. It still wins on
          # read, so the caller's selection is inert until a human edits it.
          :conflict
        elsif content.match?(CONFIGURE_BLOCK)
          File.write(path, content.sub(CONFIGURE_BLOCK) { "#{Regexp.last_match(0)}#{line}\n" })
          :inserted
        else
          :absent
        end
      rescue StandardError => e
        RailsAiContext.log_warn "[rails-ai-context] could not write #{INITIALIZER}: #{e.message}"
        :unchanged
      end
    end
  end
end
