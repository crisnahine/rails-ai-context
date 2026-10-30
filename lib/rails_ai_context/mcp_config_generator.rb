# frozen_string_literal: true

require "fileutils"
require_relative "install_mode"

# json and strscan are gems an app's bundle pins, and the install loads this
# file before the app boots: required here, our copies loaded first and the
# app's then loaded over them ("already initialized constant"), leaving a
# mixed library. Each loads when first named, a rescue clause naming
# JSON::ParserError included.
autoload :JSON, "json"
autoload :StringScanner, "strscan"

module RailsAiContext
  # Generates per-tool MCP config files so each AI tool auto-discovers the MCP server.
  #
  # Each tool has its own config file format:
  #   Claude Code  → .mcp.json          (mcpServers key)
  #   Cursor       → .cursor/mcp.json   (mcpServers key)
  #   VS Code      → .vscode/mcp.json   (servers key)
  #   OpenCode     → opencode.json      (mcp key, type: "local", command as array)
  #   Codex CLI    → .codex/config.toml (TOML, [mcp_servers.NAME] section)
  #
  # An app's own configs carry one server, rails-ai-context. A workspace's
  # (a folder of apps, Install::Workspace) carry one per app, each named
  # rails-ai-context-<app> and pointed at its app with --app-path.
  class McpConfigGenerator
    # Keyed by AI tool, and by its own key for a config another client of the tool reads: each `tool` below is such a key.
    TOOL_CONFIGS = Install::AiTool.mcp_configs_by_key.freeze

    SERVER_NAME = "rails-ai-context"

    # Every name this gem writes a server under: the app's own, and the
    # workspace form. The names are the gem's: removal takes all of them, so
    # dropping an AI tool leaves no workspace entry behind.
    OWN_NAME = /#{Regexp.escape(SERVER_NAME)}(?:-[A-Za-z0-9_-]+)?/
    OWN_SERVER_NAME = /\A#{OWN_NAME}\z/

    # The name the server announces, where an entry sets one. A variable
    # rather than a flag: an app whose bundle pins an older gem ignores it
    # and starts, where an unknown flag would stop it (ADR-0005).
    SERVER_NAME_ENV = "RAILS_AI_CONTEXT_SERVER_NAME"

    # On Windows a gem's executables are .bat files (rails-ai-context.bat,
    # bundle.bat), which a client that starts its server without a shell -
    # Node's child_process.spawn in Claude Code, Codex's Rust Command - does
    # not run. cmd.exe is a program every client starts, and it runs them; /d
    # skips the registry's AutoRun commands, whose output would reach the
    # client before the server's first message.
    WINDOWS_SHELL = %w[cmd /d /c].freeze

    # Run as `ruby -e LAUNCHER <command...>` where a client passes PATH but no GEM_PATH (the Cursor CLI): rvm and chruby put
    # each gem folder's bin on PATH, the empty last entry keeps RubyGems' own, and a GEM_PATH or GEM_HOME passed stays.
    LAUNCHER = 'dirs = ENV["PATH"].to_s.split(File::PATH_SEPARATOR).map { |dir| File.dirname(dir) }' \
               '.select { |dir| File.directory?(File.join(dir, "specifications")) }.uniq; ' \
               'ENV["GEM_PATH"] = [*dirs, ""].join(File::PATH_SEPARATOR) if dirs.any? && ENV["GEM_PATH"].to_s.empty? && ' \
               'ENV["GEM_HOME"].to_s.empty?; exec(*ARGV)'

    # One server entry. app_path and gemfile are relative to the folder the
    # config sits in, because the file may be committed and an absolute path
    # holds only on the machine that wrote it. `folder` is how a tool's config
    # names that folder (AiTool's folder_variable), where the tool has a name
    # for it; elsewhere the path stays relative, read from the folder the tool
    # starts the server in.
    #
    # `announce` is the name the server gives the client, where it differs
    # from the entry's: VS Code names every tool after the announced name and
    # keeps 13 characters of it, so a workspace server puts its app first.
    Server = Struct.new(:name, :standalone, :app_path, :gemfile, :announce, keyword_init: true) do
      # In-Gemfile installs go through the CLI binary because it quarantines
      # app boot output away from stdout starting before Bundler.require; the
      # rake task can only quarantine from the environment task onward.
      def argv(folder = nil, launcher: false)
        argv = standalone ? %w[rails-ai-context serve] : %w[bundle exec rails-ai-context serve]
        argv = [ *argv, "--app-path", anchored(app_path, folder) ] if app_path
        McpConfigGenerator.platform_argv(argv, launcher: launcher)
      end

      # bundle exec looks for a Gemfile from where it starts, upward, and a
      # workspace entry starts in the folder above its app.
      def env(folder = nil)
        env = {}
        env["BUNDLE_GEMFILE"] = anchored(gemfile, folder) if !standalone && gemfile
        env[SERVER_NAME_ENV] = announce if announce
        env
      end

      private

      # A relative path that starts with a dash would be read as an option.
      def anchored(path, folder)
        return "#{folder}/#{path}" if folder

        path.start_with?("-") ? "./#{path}" : path
      end
    end

    # @param tools [Array<Symbol>] selected AI tool keys (e.g. [:claude, :cursor])
    # @param output_dir [String] project root path
    # @param standalone [Boolean, nil] true writes bare `rails-ai-context`
    #   commands, false writes `bundle exec` commands. nil (the default)
    #   detects the install mode from the app's Gemfile.lock so every entry
    #   point that writes MCP configs (standalone CLI init, rake task, Rails
    #   generator) converges on identical config content for the same app
    #   instead of rewriting each other's command form on alternate runs.
    # @param tool_mode [Symbol] :mcp or :cli
    # @param servers [Array<Server>, nil] the entries to write; nil writes the
    #   app's own single server, in the install mode `standalone` names.
    def initialize(tools:, output_dir:, standalone: nil, tool_mode: :mcp, servers: nil)
      @tools = Install::AiTool.mcp_config_keys(tools)
      @output_dir = output_dir.to_s
      @tool_mode = tool_mode
      @servers = servers || [
        Server.new(name: SERVER_NAME, standalone: standalone.nil? ? InstallMode.standalone? : standalone)
      ]
    end

    # @return [Hash] { written: [paths], skipped: [paths], failed: [paths],
    #   reasons: { path => why it failed }, notes: { path => an entry kept
    #   in place of the gem's } }, the reasons and notes for the caller to
    #   say in its own voice
    def call
      return { written: [], skipped: [], failed: [], reasons: {}, notes: {} } if @tool_mode == :cli

      written = []
      skipped = []
      failed = []
      reasons = {}
      @notes = {}

      @tools.each do |tool|
        config = TOOL_CONFIGS[tool]
        next unless config

        path = File.join(@output_dir, config[:path])
        # One rescue for every read, write and rename the merges do: an
        # unreadable or unwritable config is one tool's auto-discovery lost,
        # not a reason to abandon the install.
        result = begin
          verdict = verdict(tool, path)
          @notes[path] = verdict.note if verdict.note
          case verdict.action
          when :refuse
            reasons[path] = verdict.message
            :failed
          when :keep then :skipped
          else
            RailsAiContext::SafeFile.atomic_write(path, verdict.content, root: @output_dir)
            :written
          end
        rescue SystemCallError, IOError, JSON::JSONError => e
          reasons[path] = e.message
          :failed
        end

        case result
        when :written then written << path
        when :skipped then skipped << path
        when :failed then failed << path
        end
      end

      { written: written, skipped: skipped, failed: failed, reasons: reasons, notes: @notes }
    end

    # What the write does with one tool's config at `path`, decided without
    # writing: the write carries it out, and doctor says it. Reads the file,
    # so it raises what a read raises.
    #
    # @return [Verdict]
    def verdict(tool, path)
      config = TOOL_CONFIGS.fetch(tool.to_sym)
      verdict = config[:format] == :codex_toml ? toml_verdict(path) : json_verdict(path, config, json_entries(config))
      verdict.existing = verdict.existing&.map do |entry|
        entry.merge(app: self.class.entry_app_root(entry[:argv], self.class.folder_name(config), @output_dir) || @output_dir)
      end
      verdict
    end

    # What the write does with one config (:write, :merge, :keep, :refuse), `reason` why it refuses or its client
    # cannot read it (`readable` false), `edit` and `next_run` the fix by hand and what the install then does, `note`
    # what it kept in place of the gem's, and `existing` the gem's entries it holds, nil where it could not read them.
    Verdict = Struct.new(:action, :reason, :edit, :next_run, :readable, :note, :content, :existing, keyword_init: true) do
      # The edit by hand, naming the file `name`; nil when none is needed.
      def by_hand(name = "it", next_run: true)
        edit && "#{edit.call(name)}#{self.next_run if next_run}"
      end

      # A refused config in the install's words.
      def message
        "#{reason}, so it is left as it is. #{by_hand}"
      end
    end

    # What follows an edit by hand to a file the install could not read.
    MERGES_NEXT = ", and the next run merges into it"

    # The entries a write puts under a JSON config's servers key, by name,
    # as it writes them: what a config it leaves as it is needs by hand.
    def json_entries(config)
      @servers.to_h { |server| [ server.name, json_entry(server, config) ] }
    end

    # A JSON config its client cannot read: one that reads JSON refuses the
    # comments and trailing commas a JSONC reader passes over.
    class UnreadableError < StandardError; end

    # Codex reads its config as TOML, which is UTF-8, and refuses one that
    # is not ("stream did not contain valid UTF-8"), starting no server.
    TOML_NOT_UTF8 = "Codex CLI cannot read it: it is not UTF-8, which TOML is"

    # Codex's config read without a TOML parser, which the gem does not
    # depend on. The file is split into its statements - table headers and
    # key/value pairs, each with the full key path TOML gives it - so a
    # server is found however its name is spelled, quoted or not, whether as
    # a table, an inline table or dotted keys; everything else in the file is
    # copied through untouched.
    module Toml
      # One statement: a :table or :array_table header, or a :pair. path is
      # the full key path - a pair's is its table's and its own dotted key -
      # nil for a header this cannot read and for every pair after it. first
      # and last are the lines it spans; a pair's value is its text.
      Statement = Struct.new(:kind, :path, :first, :last, :value)

      # Everything the file says about one server: its [mcp_servers.<name>]
      # tables, as line ranges; every other statement that defines part of
      # it - an inline table, dotted keys from outside its table, a sub-table
      # away from it, mcp_servers itself as an inline table; and its command
      # line and env, read from all of them.
      Server = Struct.new(:name, :sections, :elsewhere, :argv, :env, :twice) do
        # Its one table, or none, is all there is of it: the merge can
        # replace it where it stands, or add it.
        def rewritable?
          elsewhere.empty?
        end

        # Defined twice over, which Codex refuses to read: a second table, or
        # an inline table or dotted keys beside its table.
        def twice?
          twice
        end
      end

      SERVERS = "mcp_servers"
      BARE_KEY = /[A-Za-z0-9_-]+/
      BASIC = /"(?:[^"\\\n]|\\.)*"/
      LITERAL = /'[^'\n]*'/
      MULTILINE_BASIC = /"""(?:[^"\\]|\\.|"(?!""))*"""(?:""?)?/m
      MULTILINE_LITERAL = /'''(?:[^']|'(?!''))*'''(?:''?)?/m

      module_function

      # The file's statements, in order.
      def statements(lines)
        text = lines.join
        # Where each line starts, in bytes, as StringScanner counts.
        starts = lines.each_with_object([ 0 ]) { |line, offsets| offsets << offsets.last + line.bytesize }
        line_at = ->(pos) { (starts.bsearch_index { |offset| offset > pos } || lines.size) - 1 }
        scanner = StringScanner.new(text)
        table = []
        found = []
        until scanner.eos?
          next if scanner.skip(/[ \t\r\n]+|#[^\n]*/)

          start = scanner.pos
          if scanner.skip(/\[\[/) || scanner.skip(/\[/)
            kind = text.byteslice(start, 2) == "[[" ? :array_table : :table
            path = key_path(scanner)
            path = nil unless path && scanner.skip(kind == :table ? /[ \t]*\]/ : /[ \t]*\]\]/)
            table = path
            found << Statement.new(kind, path, line_at.call(start), line_at.call(start), nil)
          elsif (key = key_path(scanner)) && scanner.skip(/[ \t]*=[ \t]*/)
            from = scanner.pos
            skip_value(scanner)
            found << Statement.new(:pair, table && table + key, line_at.call(start), line_at.call([ scanner.pos - 1, start ].max),
                                   text.byteslice(from...scanner.pos))
          end
          # The rest of the line: a comment, or what could not be read.
          scanner.skip(/[^\n]*/)
        end
        found
      end

      # A dotted key, its parts bare or quoted: nil where there is none.
      def key_path(scanner)
        path = []
        loop do
          scanner.skip(/[ \t]*/)
          part = if (bare = scanner.scan(BARE_KEY)) then bare
          elsif (basic = scanner.scan(BASIC)) then unescape(basic)
          elsif (literal = scanner.scan(LITERAL)) then literal[1..-2]
          end
          return nil unless part

          path << part
          scanner.skip(/[ \t]*/)
          return path unless scanner.skip(/\./)
        end
      end

      # Past one value, however many lines its strings, arrays and inline
      # tables span; to the end of its line, not over it.
      def skip_value(scanner)
        depth = 0
        until scanner.eos?
          if scanner.skip(MULTILINE_BASIC) || scanner.skip(MULTILINE_LITERAL) || scanner.skip(BASIC) || scanner.skip(LITERAL)
            next
          elsif scanner.skip(/[\[{]/)
            depth += 1
          elsif scanner.skip(/[\]}]/)
            depth -= 1
          elsif scanner.skip(/#[^\n]*/)
            next
          elsif scanner.check(/\r?\n/)
            break if depth <= 0

            scanner.skip(/\r?\n/)
          elsif !scanner.skip(/[^"'\[\]{}#\r\n]+/)
            scanner.getch
          end
        end
      end

      # A value as data, as far as a server's entry needs one: a string, an
      # array, an inline table; nil for any other scalar.
      def value(text)
        parse_value(StringScanner.new(text))
      end

      def parse_value(scanner)
        scanner.skip(/(?:[ \t\r\n]+|#[^\n]*)*/)
        if scanner.skip(/\{/)
          items(scanner, "}", {}) do |table|
            path = key_path(scanner) or next
            next unless scanner.skip(/[ \t]*=/)

            *outer, last = path
            holder = outer.inject(table) { |hash, key| hash[key].is_a?(Hash) ? hash[key] : (hash[key] = {}) }
            holder[last] = parse_value(scanner)
          end
        elsif scanner.skip(/\[/)
          items(scanner, "]", []) { |array| array << parse_value(scanner) }
        elsif (text = scanner.scan(MULTILINE_BASIC) || scanner.scan(MULTILINE_LITERAL))
          # Escapes and line-ending backslashes left as they are: no entry
          # the gem reads spans lines.
          text[3..-4].sub(/\A\r?\n/, "")
        elsif (text = scanner.scan(BASIC))
          unescape(text)
        elsif (text = scanner.scan(LITERAL))
          text[1..-2]
        else
          scanner.skip(/[^,\]}\s#]*/)
          nil
        end
      end

      # The items of an array or inline table, each read by the block, up to
      # its closing bracket. One that cannot be read ends it.
      def items(scanner, close, into)
        loop do
          scanner.skip(/(?:[ \t\r\n,]+|#[^\n]*)*/)
          break if scanner.eos? || scanner.skip(/#{Regexp.escape(close)}/)

          at = scanner.pos
          yield into
          break if scanner.pos == at
        end
        into
      end

      # The tables of the servers `keep` accepts, by name, as [line range,
      # name]. A table runs to the next header that is not one of its own
      # sub-tables; blank and comment lines just above that header stay out
      # of it, since a comment over a header belongs to the header.
      def sections(lines, found = statements(lines), &keep)
        headers = found.reject { |statement| statement.kind == :pair }
        headers.each_with_index.filter_map do |header, at|
          next unless header.kind == :table && server_path?(header.path) && keep.call(header.path[1])

          after = headers[(at + 1)..].find { |other| !under?(other.path, header.path) }
          finish = after ? after.first : lines.size
          finish -= 1 while finish > header.first + 1 && trivia?(lines[finish - 1])
          [ header.first...finish, header.path[1] ]
        end
      end

      # The tables of the gem's own servers, by the rule own_entry? keeps:
      # [line range, name] each.
      def own_sections(lines, found = statements(lines))
        sections(lines, found) { |name| name.match?(OWN_SERVER_NAME) }.select do |range, name|
          McpConfigGenerator.own_entry?(name, argv(lines, range, found))
        end
      end

      # Each server `keep` accepts, by name, as the whole file defines it.
      def servers(lines, found = statements(lines), &keep)
        tables = sections(lines, found, &keep)
        whole = found.find { |statement| statement.kind == :pair && statement.path == [ SERVERS ] }
        whole_value = whole && value(whole.value)
        names = found.filter_map { |statement| statement.path[1] if statement.path&.size.to_i >= 2 && statement.path[0] == SERVERS }
        names = (names + (whole_value.is_a?(Hash) ? whole_value.keys : [])).uniq

        names.select(&keep).map do |name|
          ranges = tables.filter_map { |range, table_name| range if table_name == name }
          defining = found.select { |statement| statement.path && statement.path.size >= 2 && statement.path.first(2) == [ SERVERS, name ] }
          elsewhere = defining.reject { |statement| ranges.any? { |range| range.cover?(statement.first) } }
          elsewhere << whole if whole_value.is_a?(Hash) && whole_value.key?(name)

          data = entry_data(defining)
          data = whole_value[name].merge(data) if whole_value.is_a?(Hash) && whole_value[name].is_a?(Hash)
          env = data["env"].is_a?(Hash) ? data["env"].filter_map { |key, item| [ key, item ] if item.is_a?(String) }.to_h : {}
          Server.new(name, ranges, elsewhere, [ *data["command"], *data["args"] ].grep(String), env, twice?(ranges, elsewhere))
        end
      end

      # A second table, a second inline table, or a table beside an inline
      # table or dotted keys from outside it: what no TOML reader accepts.
      def twice?(ranges, elsewhere)
        inline = elsewhere.count { |statement| statement.kind == :pair && statement.path.size <= 2 }
        dotted = elsewhere.any? { |statement| statement.kind == :pair && statement.path.size > 2 }
        detached = elsewhere.any? { |statement| statement.kind != :pair }
        ranges.size + inline + (dotted ? 1 : 0) > 1 || (inline.positive? && (dotted || detached))
      end

      # Why no [mcp_servers.<name>] table can be added to the file: when
      # mcp_servers itself is an inline table or an array of tables. nil
      # when one can.
      def closed(found)
        return unless found.any? { |statement| statement.path == [ SERVERS ] && statement.kind != :table }

        "its #{SERVERS} is an inline table or an array of tables, beside which no [#{SERVERS}.<name>] table can go"
      end

      # One server's keys as data, from the pairs that define them.
      def entry_data(defining)
        defining.select { |statement| statement.kind == :pair }.each_with_object({}) do |statement, data|
          keys = statement.path.drop(2)
          item = value(statement.value)
          next data.merge!(item) { |_, mine, theirs| mine || theirs } if keys.empty? && item.is_a?(Hash)
          next if keys.empty?

          *outer, last = keys
          holder = outer.inject(data) { |hash, key| hash[key].is_a?(Hash) ? hash[key] : (hash[key] = {}) }
          holder[last] = item unless holder.key?(last)
        end
      end

      # One section's command line, its `command` and `args`, read from the
      # table itself and not its sub-tables.
      def argv(lines, range, found = statements(lines))
        data = section_data(lines, range, found)
        [ *data["command"], *data["args"] ].grep(String)
      end

      def section_data(lines, range, found)
        header = found.find { |statement| statement.kind == :table && statement.first == range.begin && server_path?(statement.path) }
        return {} unless header

        entry_data(found.select { |statement| range.cover?(statement.first) && under?(statement.path, header.path) })
      end

      # The strings at the start of a value: a basic ("...") or literal
      # ('...') string, or an array of them however a formatter wrapped it,
      # with comments and a trailing comma.
      def strings(text)
        Array(value(text)).grep(String)
      end

      # TOML's basic-string escapes are JSON's, but for \U and \e. A file that
      # is not UTF-8 is read as bytes, and json reads a string out of those as
      # UTF-8 it is not, which the first pattern matched against it raised on:
      # such a string stays the bytes it is.
      def unescape(basic)
        text = JSON.parse(basic)
        text.is_a?(String) && text.valid_encoding? ? text : basic[1..-2]
      rescue JSON::ParserError
        basic[1..-2]
      end

      def server_path?(path)
        path&.size == 2 && path[0] == SERVERS
      end

      # Whether path is a key or table inside the table at `table`.
      def under?(path, table)
        !path.nil? && path.size > table.size && path.first(table.size) == table
      end

      def trivia?(line)
        stripped = line.strip
        stripped.empty? || stripped.start_with?("#")
      end
    end

    # How a config's entries name the folder it sits in, as the gem writes them now or an earlier release did.
    def self.folder_name(config)
      config[:folder_variable] || config[:legacy_folder_variable]
    end

    # The directory an entry's --app-path names, read the way its tool reads
    # it: the tool's name for its config's folder is that folder, and a bare
    # relative path starts there too. Any other variable (${HOME},
    # ${userHome}) is the tool's to expand, so such a path names no app this
    # can judge.
    #
    # @return [String, nil] absolute, nil when the entry names no app
    def self.entry_app_root(argv, folder, dir)
      argv = argv.map(&:to_s)
      at = argv.index("--app-path")
      path = at ? argv[at + 1] : argv.find { |arg| arg.start_with?("--app-path=") }&.delete_prefix("--app-path=")
      return nil if path.nil? || path.empty?

      entry_path(path, folder, dir)
    end

    # A path an entry holds (its --app-path, its BUNDLE_GEMFILE), read the
    # way entry_app_root reads one.
    #
    # @return [String, nil] absolute, nil when another variable is the tool's to expand
    def self.entry_path(path, folder, dir)
      path = dir + path.delete_prefix(folder) if folder && path.start_with?(folder)
      return nil if path.include?("$")

      File.expand_path(path, dir)
    end

    # Whether this platform's clients start a gem's executable only through
    # `cmd /d /c`: Windows', where it is a .bat file.
    def self.windows_shell?
      Gem.win_platform?
    end

    # The command line as the platform's clients can start it, through the launcher where a client of the config
    # can drop GEM_PATH. Windows has neither rvm nor chruby, and cmd.exe would read the launcher's code.
    def self.platform_argv(argv, launcher: false)
      return [ *WINDOWS_SHELL, *argv ] if windows_shell?

      launcher ? [ "ruby", "-e", LAUNCHER, *argv ] : argv
    end

    # The command line an entry runs, inside a `cmd /d /c` it was given on Windows (`cmd`, `cmd.exe`,
    # `C:\Windows\System32\cmd.exe`, or an earlier release's `cmd /c`) or the gem's launcher as the gem writes it.
    def self.unwrapped_argv(argv)
      argv = Array(argv).map(&:to_s)
      at = windows_command_at(argv)
      return argv[at..] if at
      return argv[3..] if argv.size > 3 && argv[0] == "ruby" && argv[1] == "-e" && argv[2] == LAUNCHER

      argv
    end

    # Whether a command line runs inside the `cmd /d /c` the gem writes on Windows, or the `cmd /c` it wrote before.
    def self.windows_wrapped?(argv)
      !windows_command_at(Array(argv).map(&:to_s)).nil?
    end

    # Where the command a Windows `cmd /c` or `cmd /d /c` runs starts in its command line; nil for any other.
    private_class_method def self.windows_command_at(argv)
      return nil unless argv.size > 2 && File.basename(argv[0].tr("\\", "/"), ".*").casecmp?("cmd")
      return 2 if argv[1].casecmp?("/c")

      3 if argv.size > 3 && argv[1].casecmp?("/d") && argv[2].casecmp?("/c")
    end

    # A JSON entry's command line: OpenCode's command array, or command plus args.
    def self.json_argv(entry)
      entry.is_a?(Hash) ? [ *entry["command"], *entry["args"] ] : []
    end

    # Whether an entry is the gem's: the app's own by its name and a command,
    # which every version has written in one form or another, and a
    # workspace one by its name and by running the gem's server. An entry
    # with no command - an HTTP one, `rails-ai-context-prod` or the bare
    # name - is whoever made it's: the gem writes none.
    def self.own_entry?(name, argv)
      argv = argv.map(&:to_s)
      return !argv.empty? if name == SERVER_NAME
      return false unless name.match?(OWN_SERVER_NAME)

      at = argv.index("rails-ai-context")
      !at.nil? && argv[at + 1] == "serve"
    end

    # The command lines the gem writes, and has written, ahead of an
    # optional --app-path. An entry of the gem's spelled any other way - its
    # server started through Docker - is the user's to keep.
    WRITTEN_ARGV = [ %w[bundle exec rails-ai-context serve], %w[rails-ai-context serve], %w[bundle exec rails ai:serve] ].freeze

    # The env vars the gem writes into an entry; any other is the user's.
    WRITTEN_ENV = [ "BUNDLE_GEMFILE", SERVER_NAME_ENV ].freeze

    # Whether a command line is one the gem writes, inside a Windows `cmd` or not.
    def self.written_argv?(argv)
      argv = unwrapped_argv(argv)
      form = WRITTEN_ARGV.find { |written| argv.first(written.size) == written } or return false

      rest = argv.drop(form.size)
      rest.empty? || (rest.size == 2 && rest[0] == "--app-path") || (rest.one? && rest[0].start_with?("--app-path="))
    end

    # Whether an entry is one the gem wrote, the only kind its removals take: a name of the gem's and a command form it writes.
    def self.written_entry?(name, argv)
      own_entry?(name, argv) && written_argv?(argv)
    end

    # Whether a command line starts the gem's server, however a user spelled it: the binary from any path, `serve`
    # after other flags, or the rake task.
    def self.runs_gem?(argv)
      argv = unwrapped_argv(argv)
      at = argv.index { |arg| File.basename(arg.tr("\\", "/"), ".*") == SERVER_NAME }
      (!at.nil? && argv.drop(at + 1).include?("serve")) || argv.include?("ai:serve")
    end

    # The keys of a JSON entry the gem never writes, an env var as `env.NAME`.
    def self.unwritten_keys(entry, config)
      env_key = config.fetch(:env_key, "env")
      env = entry[env_key]
      written = config[:format] == :opencode_json ? %w[type command] : %w[command args]
      # Whatever value a user gave them: they configure only the gem's server, which a removal takes.
      written += config.fetch(:entry_defaults, {}).keys
      written += [ env_key ] if env.is_a?(Hash)
      entry.keys - written + (env.is_a?(Hash) ? env.keys - WRITTEN_ENV : []).map { |key| "#{env_key}.#{key}" }
    end

    # Whether a removal takes a JSON entry: one the gem wrote, holding nothing the gem never writes.
    def self.removable_json?(name, entry, config)
      entry.is_a?(Hash) && written_entry?(name, json_argv(entry)) && unwritten_keys(entry, config).empty?
    end

    # Why a removal leaves an entry that runs the gem, nil when it takes it (or the entry is not the gem's at all).
    def self.kept_reason(name, argv, extra)
      return nil unless own_entry?(name, argv) || runs_gem?(argv)
      return "its name is not one rails-ai-context writes" unless name.match?(OWN_SERVER_NAME)
      return "its command is not one rails-ai-context writes" unless written_entry?(name, argv)

      "it holds #{extra}, which rails-ai-context never writes" if extra
    end

    # An HTTP entry under one of the gem's names: only the gem's mounted
    # endpoint answers it.
    def self.http_entry?(name, entry)
      name.match?(OWN_SERVER_NAME) && entry.is_a?(Hash) && entry.key?("url") && !entry.key?("command")
    end

    # A JSON config's text and byte order mark, and why it cannot be read
    # as JSON at all: JSON is UTF-8.
    #
    # @return [Array(String, String, String)] text, mark, problem (nil when none)
    def self.json_text(path)
      bom, text = RailsAiContext::SafeFile.split_bom(RailsAiContext::SafeFile.read_text(path))
      [ text, bom, text.encoding == Encoding::BINARY ? "it is not UTF-8, which JSON is" : nil ]
    end

    # A JSON config as data, read as its client reads it (config, its
    # TOOL_CONFIGS entry). One that is not UTF-8 raises as one that does not
    # parse.
    def self.read_json(path, config = nil)
      text, _, problem = json_text(path)
      raise JSON::ParserError, problem if problem

      parse_json_text(text, config)
    end

    # A config's JSON read the way its client reads it. A JSONC client - VS
    # Code, OpenCode - passes over comments and trailing commas; a JSON one -
    # Claude Code, Cursor - refuses the whole file, which raises
    # UnreadableError: such a file is no config of the client's, however this
    # parser reads it. Without a config it is read as JSONC.
    #
    # json 2 passed over comments unasked (2.10 on with a deprecation
    # warning) and json 3 refuses one unless told, so the same file read
    # differently by which json the process had: comments are allowed
    # outright, and looked for here. A json before 2.9 knows no trailing
    # commas and ignores the option, refusing them still.
    def self.parse_json_text(text, config = nil)
      if config && config[:jsonc] == false && (refused = jsonc_only(text))
        raise UnreadableError, "#{config[:client]} cannot read it: it holds #{refused}, which JSON does not allow"
      end

      JSON.parse(text, allow_comments: true, allow_trailing_comma: true)
    end

    # What a JSONC reader passes over and a JSON one refuses, as the text
    # holds it: comments, a trailing comma, or both. nil for neither.
    def self.jsonc_only(text)
      found = [ ("comments" if json_comments?(text)), ("a trailing comma" if json_trailing_comma?(text)) ].compact
      found.join(" and ") unless found.empty?
    end

    COMMENTS_PROBLEM = "it holds comments, which writing it back as JSON would drop"

    # Where a JSON parser stopped, when it says (json 2.10 on), and the
    # trailing comma a json before 2.9 stops at, when the file has one; the
    # parser's own words can run to the whole file. json 3 refuses the
    # comments json 2 passed over, so a file holding them is named for them
    # whichever parser read it.
    def self.parse_problem(error, text = nil)
      return error.message if error.is_a?(UnreadableError)
      return COMMENTS_PROBLEM if text && json_comments?(text)

      where = error.message[/line \d+,? column \d+/]
      "it does not parse as JSON#{" at #{where}" if where}#{' (a trailing comma?)' if text && json_trailing_comma?(text)}"
    end

    # Whether JSON text closes an array or object right after a comma.
    # Strings are matched whole, as for comments.
    def self.json_trailing_comma?(text)
      text.scan(/"(?:[^"\\]|\\.)*"|,\s*[\]}]/).any? { |token| !token.start_with?('"') }
    end

    # Whether JSON text holds a comment, which JSON.parse passes over and a
    # rewrite would drop. Strings are matched whole, so a URL's // is none.
    def self.json_comments?(text)
      text.scan(%r{"(?:[^"\\]|\\.)*"|//|/\*}).any? { |token| !token.start_with?('"') }
    end

    # A Codex config's servers under the gem's names, read the way the merge
    # reads them, and why no server table can be added to it (nil when one
    # can).
    #
    # @return [Array(Array<Toml::Server>, String)]
    def self.toml_servers(path)
      lines = RailsAiContext::SafeFile.split_bom(RailsAiContext::SafeFile.read_text(path)).last.lines
      found = Toml.statements(lines)
      [ Toml.servers(lines, found) { |name| name.match?(OWN_SERVER_NAME) }, Toml.closed(found) ]
    end

    # Why the gem's entries in a Codex config stay as they are.
    def self.unwritable_toml(names)
      "it sets #{names.join(', ')} as an inline table or with dotted keys, which the install does not rewrite"
    end

    private

    # What a write drops besides replacing its own entries, from the entries
    # of ours already there (name => the app root each names). An app's own
    # write drops nothing. A workspace's drops the bare entry, which would
    # serve the folder itself, and an entry under a name it gives an app in
    # this folder, when that app is gone or now goes by another name. Every
    # other entry stays as somebody's own: a second one named by hand, one
    # naming an app outside the folder, or one only another machine has.
    # The stale names split into the ones held, since the gem did not write them, and the ones dropped.
    def stale_split(ours, &handmade)
      stale_names(ours.to_h).partition(&handmade)
    end

    def stale_names(existing)
      return [] unless workspace_write?

      names = @servers.map(&:name)
      roots = @servers.map { |server| RailsAiContext::SafePath.canonical(File.expand_path(server.app_path, @output_dir)) }
      inside = "#{@output_dir.delete_suffix('/')}/"
      existing.filter_map do |name, app_root|
        next name if name == SERVER_NAME
        next if names.include?(name) || app_root.nil? || !app_root.start_with?(inside)
        next unless Install::Workspace.generated_name?(name, app_root.delete_prefix(inside))

        name if !File.directory?(app_root) || roots.include?(RailsAiContext::SafePath.canonical(app_root))
      end
    end

    # A workspace's write: per-app servers, with the app's own bare one gone.
    def workspace_write?
      @servers.none? { |server| server.name == SERVER_NAME }
    end

    # The root key comes from the AiTool table, the same table self.remove
    # reads. OpenCode takes the whole command as one array and calls its
    # environment `environment`; the other JSON tools take command plus args
    # and `env`, with type left off - stdio is inferred from command.
    def json_entry(server, config)
      argv = server.argv(config[:folder_variable], launcher: config[:launcher])
      env = server.env(config[:folder_variable])
      opencode = config[:format] == :opencode_json
      entry = opencode ? { "type" => "local", "command" => argv } : { "command" => argv.first, "args" => argv[1..] }
      entry[config.fetch(:env_key, "env")] = env unless env.empty?
      entry.merge(config.fetch(:entry_defaults, {}))
    end

    # --- JSON merge logic ---

    def json_verdict(path, config, entries)
      text, bom, problem = File.exist?(path) ? self.class.json_text(path) : [ nil, "", nil ]
      # The entry added by hand would sit in a file JSON still cannot read.
      return refused(problem) { |file| "Save #{file} as UTF-8" } if problem

      # An empty file holds nothing to lose. A new one starts with the "$schema" its client would add on first load.
      empty = text.nil? || text.strip.empty?
      data = if !empty then self.class.parse_json_text(text, config)
      elsif config[:schema] then { "$schema" => config[:schema] }
      else {}
      end
      return refused("it is JSON but not an object") { |file| "Make #{file} a JSON object" } unless data.is_a?(Hash)

      root_key = config[:root_key]
      data[root_key] ||= {}
      servers = data[root_key]
      return refused(%("#{root_key}" is not an object)) { |file| %(Make "#{root_key}" in #{file} an object) } unless servers.is_a?(Hash)

      existing = Named.json(servers, config)

      ours = servers.filter_map do |name, entry|
        argv = self.class.json_argv(entry)
        [ name, self.class.entry_app_root(argv, self.class.folder_name(config), @output_dir) ] if self.class.own_entry?(name, argv)
      end
      # An entry under one of this write's names that is not the gem's - the
      # HTTP one SETUP.md describes - or that starts the gem's server some way
      # the gem does not write is kept in place of the gem's. The gem's own
      # is merged into, so keys it never writes stay.
      handmade = ->(name) { !self.class.written_argv?(self.class.json_argv(servers[name])) }
      held, stale = stale_split(ours, &handmade)
      kept = entries.keys.select { |name| servers.key?(name) && handmade.call(name) }
      note = kept_note(kept + held, kept.select { |name| self.class.http_entry?(name, servers[name]) },
                       kept.select { |name| self.class.own_entry?(name, self.class.json_argv(servers[name])) } + held)
      entries = entries.except(*kept).to_h { |name, entry| [ name, merged_entry(servers[name], entry, config) ] }
      if text && stale.empty? && entries.all? { |name, entry| servers[name] == entry }
        return Verdict.new(action: :keep, readable: true, note: note, existing: existing)
      end
      # JSON.parse passes over comments, and the file written back would
      # have none.
      if text && self.class.json_comments?(text)
        added = JSON.generate(root_key => entries)
        return refused(COMMENTS_PROBLEM, readable: true, next_run: nil, existing: existing) { |file| "Add #{added} to #{file} by hand" }
      end

      stale.each { |name| servers.delete(name) }
      servers.merge!(entries)
      Verdict.new(action: empty ? :write : :merge, readable: true, note: note, content: bom + JSON.pretty_generate(data) + "\n",
                  existing: existing)
    rescue UnreadableError => e
      # Adding the entry by hand would leave a file its client still cannot read.
      refused(e.message) { |file| "Make #{file} plain JSON by hand" }
    rescue JSON::ParserError => e
      # A file JSON cannot parse is never replaced: a fresh file would drop
      # everything somebody wrote there.
      refused(self.class.parse_problem(e, text)) { |file| "Make #{file} valid JSON holding an object" }
    end

    # A config left as it is, and the edit that lets the next run write it.
    def refused(reason, readable: false, next_run: MERGES_NEXT, existing: nil, &edit)
      Verdict.new(action: :refuse, reason: reason, edit: edit, next_run: next_run, readable: readable, existing: existing)
    end

    # The gem's entry over the one there: the keys and env vars the gem
    # writes come from the new entry, every other stays as it was, and so do
    # the config's entry_defaults a user set.
    def merged_entry(existing, entry, config)
      return entry unless existing.is_a?(Hash)

      env_key = config.fetch(:env_key, "env")
      env = existing[env_key].is_a?(Hash) ? existing[env_key].except(*WRITTEN_ENV) : {}
      env = env.merge(entry.fetch(env_key, {}))
      merged = entry.merge(existing.slice(*config.fetch(:entry_defaults, {}).keys)).merge(existing.except(*entry.keys, env_key))
      env.empty? ? merged : merged.merge(env_key => env)
    end

    def kept_note(kept, http, own)
      return nil if kept.empty?

      own = own.uniq - http
      other = kept - http - own
      said = [ (http.any? && "#{http.join(', ')}, which #{http.one? ? 'reaches' : 'reach'} the gem's HTTP endpoint"),
               (own.any? && "#{own.join(', ')}, which #{own.one? ? 'starts' : 'start'} the gem's server with a command of its own"),
               (other.any? && "#{other.join(', ')}, which #{other.one? ? 'runs' : 'run'} something other than the gem's server") ]
      "kept #{said.select { |part| part }.join(', and ')}, in place of the gem's"
    end

    # --- TOML merge logic ---

    # Each server's section is replaced where it stands, a stale one is
    # dropped, and a new one goes at the end after a blank line.
    def toml_verdict(path)
      bom, content = RailsAiContext::SafeFile.split_bom(File.exist?(path) ? RailsAiContext::SafeFile.read_text(path) : +"")
      lines = content.lines
      # A file kept with Windows line endings keeps them, and one that is not
      # UTF-8 gets the new sections as bytes beside its own.
      newline = content.include?("\r\n") ? "\r\n" : "\n"
      in_file = ->(section) { section.gsub("\n", newline).then { |text| content.encoding == Encoding::BINARY ? text.b : text } }
      by_name = @servers.to_h { |server| [ server.name, server ] }

      found = Toml.statements(lines)
      own_name = ->(name) { name.match?(OWN_SERVER_NAME) }
      named = Toml.sections(lines, found, &own_name)
      own_sections = Toml.own_sections(lines, found)
      ours = own_sections.map do |range, name|
        [ name, self.class.entry_app_root(Toml.argv(lines, range, found), nil, @output_dir) ]
      end
      handmade = own_sections.reject { |range, _| self.class.written_argv?(Toml.argv(lines, range, found)) }.map(&:last)
      held, stale = stale_split(ours) { |name| handmade.include?(name) }
      # A server of this write's spelled any way but one table - an inline
      # table, dotted keys - is never written beside: a table next to it
      # declares the server twice, which Codex refuses to read.
      own_servers = Toml.servers(lines, found, &own_name)
      existing = Named.toml(own_servers)
      unwritable = own_servers.select { |server| by_name.key?(server.name) && !server.rewritable? }
      refusal = toml_refusal(found, own_servers, unwritable)
      return refusal.tap { refusal.existing = existing } if refusal

      # A section or entry under one of this write's names that is not the
      # gem's is kept in place of the gem's, which would be a second table of
      # one name, and that does not parse.
      # So is one of the gem's that starts its server some way the gem does
      # not write; the gem's own is merged into, so keys it never writes stay.
      own_command = named.filter_map do |range, name|
        name if by_name.key?(name) && ours.map(&:first).include?(name) && !self.class.written_argv?(Toml.argv(lines, range, found))
      end
      kept = named.map(&:last).select { |name| by_name.key?(name) } - ours.map(&:first) + unwritable.map(&:name) + own_command + held
      kept = kept.uniq
      note = kept_note(kept, kept.select { |name| self.class.toml_http?(found, name) }, own_command + held)
      binary = content.encoding == Encoding::BINARY
      # Written all the same, as it always was: the bytes are the user's.
      note = [ note, TOML_NOT_UTF8 ].compact.join("; ") if binary
      by_name = by_name.except(*kept)
      drop = stale - kept
      starts = named.select { |_, name| by_name.key?(name) || drop.include?(name) }
        .to_h { |range, name| [ range.begin, [ range, name ] ] }

      out = []
      written = {}
      dropped = false
      index = 0
      while index < lines.size
        range, name = starts[index]
        if range.nil?
          out << lines[index]
          index += 1
        elsif by_name.key?(name) && !written.key?(name)
          out << in_file.call(toml_section(by_name.fetch(name), self.class.toml_kept(lines, range, found, name)))
          written[name] = true
          index = range.end
        else
          # A dropped section takes the blank line under it when the one above
          # is blank too, so the gap it leaves does not double. A comment above
          # it stays: it may be a key of the table before, set aside by hand.
          index = range.end
          index += 1 if (out.empty? || out.last.strip.empty?) && lines[index]&.strip&.empty?
          dropped = true
        end
      end

      new_content = out.join.force_encoding(content.encoding)
      # A section dropped from the end leaves no blank line behind it.
      new_content = new_content.sub(/(?:\r?\n)+\z/, newline) if dropped && !new_content.empty?
      by_name.each do |name, server|
        next if written.key?(name)

        separator = if new_content.empty? then ""
        elsif new_content.end_with?(newline * 2) then ""
        elsif new_content.end_with?(newline) then newline
        else newline * 2
        end
        new_content = new_content + separator + in_file.call(toml_section(server))
      end

      action = if !File.exist?(path) || content.strip.empty? then :write
      elsif new_content == content then :keep
      else :merge
      end
      verdict = Verdict.new(action: action, readable: true, note: note, content: bom + new_content, existing: existing)
      # Codex reads no file of two tables under one name: the write merges
      # the ones it rewrites, and leaves the rest to an edit by hand.
      twice = own_servers.select(&:twice?)
      if binary
        verdict.reason = TOML_NOT_UTF8
        verdict.edit = ->(file) { "Save #{file} as UTF-8" }
      elsif twice.any?
        verdict.reason = "it declares #{twice.map(&:name).join(', ')} twice, which Codex refuses to read"
        verdict.edit = ->(_) { "Delete all but one by hand" } unless twice.all? { |server| by_name.key?(server.name) && server.rewritable? }
      end
      verdict.readable = verdict.reason.nil?
      verdict
    end

    # A Codex server set by a url and no command, in a table, dotted keys or an inline table.
    def self.toml_http?(found, name)
      keys = found.select { |statement| statement.kind == :pair && statement.path&.take(2) == [ Toml::SERVERS, name ] }.flat_map do |pair|
        pair.path.size > 2 ? [ pair.path[2] ] : Toml.value(pair.value).then { |value| value.is_a?(Hash) ? value.keys : [] }
      end
      keys.include?("url") && !keys.include?("command")
    end

    # A Codex config the merge would leave unreadable, or could not keep
    # current, is left as it is: one where mcp_servers is a single inline
    # table, one that already declares a server of this write twice, and one
    # that sets the gem's entry in a form the merge does not rewrite. What
    # is left after that - someone else's entry under the gem's name - is
    # kept in its place.
    def toml_refusal(found, own_servers, unwritable)
      if (closed = Toml.closed(found))
        if own_servers.any? { |server| server.sections.any? }
          return refused("#{closed}, yet it holds one, which Codex refuses to read", next_run: nil) { "Delete one of them by hand" }
        end

        return refused(closed, readable: true, next_run: nil) { |file| "Write #{file} as [#{Toml::SERVERS}.<name>] tables by hand" }
      end

      twice = unwritable.select(&:twice?)
      if twice.any?
        return refused("it declares #{twice.map(&:name).join(', ')} twice, which Codex refuses to read", next_run: nil) do
          "Delete all but one by hand"
        end
      end

      own = unwritable.select { |server| self.class.own_entry?(server.name, server.argv) }
      return nil if own.empty?

      it = own.one? ? "it" : "them"
      tables = own.one? ? "a [#{Toml::SERVERS}.#{own.first.name}] table" : "[#{Toml::SERVERS}.<name>] tables"
      refused(self.class.unwritable_toml(own.map(&:name)), readable: true, next_run: ", and the next run keeps #{it} current") do
        "Write #{it} as #{tables} by hand, or delete #{it}"
      end
    end

    # The gem's table for a server, holding what `kept` (toml_kept) carries
    # over from the table it replaces.
    def toml_section(server, kept = { pairs: [], env_lines: [], env: {}, tables: [], env_vars: [], timeout: [] })
      argv = server.argv
      lines = [ "[mcp_servers.#{server.name}]" ]
      lines << "command = #{toml_string(argv.first)}"
      lines << "args = [#{argv[1..].map { |arg| toml_string(arg) }.join(', ')}]"
      lines.concat(kept[:pairs])
      names = RUBY_ENV_NAMES.map { |name| kept[:env_vars].find { |item| item.is_a?(Hash) && item["name"] == name } || name }
      lines << "env_vars = [#{(names + (kept[:env_vars] - names)).map { |item| toml_item(item) }.join(', ')}]"
      lines << "startup_timeout_sec = #{STARTUP_TIMEOUT}" if kept[:timeout].empty?

      env_lines = server.env.map { |key, value| "#{toml_key(key)} = #{toml_string(value)}" } + kept[:env_lines] +
                  kept[:env].map { |key, value| "#{toml_key(key)} = #{toml_string(value)}" }
      unless env_lines.empty?
        lines << ""
        lines << "[mcp_servers.#{server.name}.env]"
        lines.concat(env_lines)
      end
      kept[:tables].each { |table| lines << "" << table }

      lines.join("\n") + "\n"
    end

    # What the user added to the gem's table, as written: every key and env var the gem does not write, and sub-tables.
    def self.toml_kept(lines, range, found, name)
      own = found.select { |statement| range.cover?(statement.first) }
      headers = own.reject { |statement| statement.kind == :pair }
      env_path = [ Toml::SERVERS, name, "env" ]
      text = ->(from, to) { lines[from..to].join.gsub("\r\n", "\n").chomp }
      region = lambda do |header, at|
        finish = (headers[at + 1]&.first || range.end) - 1
        finish -= 1 while finish > header.first && Toml.trivia?(lines[finish])
        [ header.first, finish ]
      end
      # Each line of a table's body but those of the keys the gem writes and
      # the blank ones between statements.
      body = lambda do |from, to, written|
        (from..to).filter_map do |index|
          statement = own.find { |pair| pair.kind == :pair && (pair.first..pair.last).cover?(index) }
          next if statement ? written.call(statement) : lines[index].strip.empty?
          next if statement && index != statement.first

          statement ? text.call(statement.first, statement.last) : text.call(index, index)
        end
      end

      main = headers.first
      main_last = headers[1] ? headers[1].first - 1 : range.end - 1
      own_key = ->(statement, key) { statement.kind == :pair && statement.path == [ Toml::SERVERS, name, key ] }
      # The timeout the gem writes is its own; one the user set is theirs, and the gem then writes none beside it.
      gem_timeout = ->(statement) { own_key.(statement, "startup_timeout_sec") && statement.value.sub(/#.*/m, "").strip == STARTUP_TIMEOUT }
      pairs = body.call(main.first + 1, main_last, lambda do |statement|
        statement.path.nil? || %w[command args env env_vars].include?(statement.path[2]) || gem_timeout.(statement)
      end)
      timeout = own.select { |statement| %w[startup_timeout_sec startup_timeout_ms].any? { |key| own_key.(statement, key) } && !gem_timeout.(statement) }
                   .map { |statement| text.call(statement.first, statement.last) }
      listed = own.find { |statement| own_key.(statement, "env_vars") }
      # The user's items but the gem's bare names; a table naming one of those says where Codex reads it, and stays.
      env_vars = Array(listed && Toml.value(listed.value)).select { |item| item.is_a?(String) || item.is_a?(Hash) }
        .reject { |item| RUBY_ENV_NAMES.include?(item) }.uniq
      gem_env = SAVED_ENV_KEYS + WRITTEN_ENV
      env_lines = []
      in_table = []
      tables = []
      headers.each_with_index do |header, at|
        next if header.equal?(main) || header.path.nil?

        from, to = region.call(header, at)
        if header.path == env_path
          env_lines.concat(body.call(from + 1, to, ->(statement) { statement.path&.size == 4 && gem_env.include?(statement.path[3]) }))
          in_table.concat(own.select { |pair| pair.kind == :pair && pair.path&.size == 4 && (from..to).cover?(pair.first) }.map { |pair| pair.path[3] })
        else
          tables << text.call(from, to)
        end
      end
      env = Toml.entry_data(own.select { |statement| statement.path&.first(2) == [ Toml::SERVERS, name ] })["env"]
      env = env.is_a?(Hash) ? env.select { |_, value| value.is_a?(String) } : {}
      env = env.except(*gem_env, *in_table)
      # own: whether it holds what the gem never writes, which keeps the table from a removal. A user's timeout
      # configures only the gem's server, as a user's tools list does in a JSON entry.
      { pairs: pairs, env_lines: env_lines, env: env, tables: tables, env_vars: env_vars, timeout: timeout,
        own: [ pairs - timeout, env_lines, env, tables, env_vars ].any? { |part| !part.empty? } }
    end

    # A TOML basic string. JSON's string escapes are a subset of TOML's, where
    # Ruby's #inspect writes `\#{` and `\e`, which TOML rejects. ENV hands
    # back bytes tagged BINARY where the locale names no encoding, so they are
    # read as the UTF-8 they almost always are.
    def toml_string(value)
      JSON.generate(value.to_s.dup.force_encoding(Encoding::UTF_8).scrub)
    end

    def toml_key(key)
      key.to_s.match?(/\A#{Toml::BARE_KEY}\z/) ? key.to_s : toml_string(key)
    end

    # An env_vars item: a name, or a table naming one with where to read it.
    def toml_item(item)
      return toml_string(item) unless item.is_a?(Hash)

      "{ #{item.map { |key, value| "#{toml_key(key)} = #{toml_string(value)}" }.join(', ')} }"
    end

    # Codex starts a server with only PATH, HOME, SHELL, USER, LANG, TMPDIR and a few more of its own environment;
    # env_vars passes these too, which rvm and chruby set beside PATH, from the shell Codex started in.
    RUBY_ENV_NAMES = %w[GEM_HOME GEM_PATH GEM_ROOT RUBY_VERSION BUNDLE_PATH].freeze

    # What releases before env_vars saved into the env table from the installing machine, which a rewrite drops.
    # `mcp-entry` still prints them, for a client the gem writes no config for.
    SAVED_ENV_KEYS = [ "PATH", *RUBY_ENV_NAMES ].freeze

    # Codex waited 10 s for a server's start before 0.120, and the server boots the app first for up to
    # BootManager::STDIO_TIMEOUT (20 s). Written as TOML's float, the type Codex reads it as.
    STARTUP_TIMEOUT = "30.0"

    # --- Which config serves an app ---

    # The config file that serves the app at app_root for one AI tool: the
    # app's own, else a workspace's one or two levels up (the depth a
    # workspace finds its apps at) whose entry names the app by --app-path.
    #
    # @return [String, nil] the path, nil when no config serves the app
    def self.serving_config(app_root, tool)
      config = TOOL_CONFIGS[tool.to_sym] or return nil
      own = File.join(app_root.to_s, config[:path])
      return own if File.exist?(own)

      target = RailsAiContext::SafePath.canonical(app_root.to_s)
      dir = app_root.to_s
      2.times do
        parent = File.dirname(dir)
        break if parent == dir

        dir = parent
        path = File.join(dir, config[:path])
        next unless File.file?(path)
        return path if app_roots_in(path, tool, dir).any? { |root| RailsAiContext::SafePath.canonical(root) == target }
      end
      nil
    end

    # A config one or two levels up that names the gem's servers but cannot
    # be read as JSON: a workspace's, which may or may not serve the app.
    #
    # @return [String, nil] the path
    def self.unreadable_config_above(app_root, tool)
      config = TOOL_CONFIGS[tool.to_sym] or return nil
      return nil if config[:format] == :codex_toml

      dir = app_root.to_s
      2.times do
        parent = File.dirname(dir)
        break if parent == dir

        dir = parent
        path = File.join(dir, config[:path])
        next unless File.file?(path) && File.binread(path).include?(SERVER_NAME)

        begin
          read_json(path, config)
        rescue JSON::ParserError, UnreadableError
          return path
        end
      end
      nil
    rescue SystemCallError, IOError
      nil
    end

    # The entries under the gem's names in one config file, read the way the
    # install reads the file: each one's name, command line and environment,
    # and whether it is the gem's own by own_entry?'s rule. An unreadable
    # file raises as the readers below do.
    #
    # @return [Array<Hash>] { name:, argv:, env:, own: } each
    def self.named_entries(path, tool)
      config = TOOL_CONFIGS.fetch(tool.to_sym)
      return Named.toml(toml_servers(path).first) if config[:format] == :codex_toml

      data = read_json(path, config)
      Named.json(data.is_a?(Hash) ? data[config[:root_key]] : nil, config)
    end

    # named_entries from servers already read, which the write's verdicts hand on.
    module Named
      module_function

      def toml(servers)
        servers.map { |server| { name: server.name, argv: server.argv, env: server.env, own: McpConfigGenerator.own_entry?(server.name, server.argv) } }
      end

      def json(servers, config)
        return [] unless servers.is_a?(Hash)

        env_key = config.fetch(:env_key, "env")
        servers.filter_map do |name, entry|
          next unless name.match?(OWN_SERVER_NAME)

          argv = McpConfigGenerator.json_argv(entry).map(&:to_s)
          env = entry[env_key] if entry.is_a?(Hash)
          { name: name, argv: argv, env: env.is_a?(Hash) ? env.transform_values(&:to_s) : {},
            own: McpConfigGenerator.own_entry?(name, argv), url: (entry["url"].to_s if McpConfigGenerator.http_entry?(name, entry)) }
        end
      end
    end
    private_constant :Named

    # The app every server of ours in one config file names.
    def self.app_roots_in(path, tool, dir)
      folder = folder_name(TOOL_CONFIGS.fetch(tool.to_sym))
      named_entries(path, tool).filter_map { |entry| entry_app_root(entry[:argv], folder, dir) if entry[:own] }
    rescue SystemCallError, IOError, JSON::ParserError, UnreadableError
      []
    end
    private_class_method :app_roots_in

    # --- Merge-safe removal ---

    # Removes every entry the gem wrote (written_entry?, holding no key the
    # gem never writes) - the app's own and each workspace one - from each
    # tool's MCP config file, preserving other servers. Deletes the file only
    # if no other entries remain.
    #
    # @param tools [Array<Symbol>] tool keys to remove MCP entries from
    # @param output_dir [String] project root path
    # @param warn [#call, nil] called with a config's path and why it was left
    #   as it is, for the caller to say in its own voice; nil logs it
    # @param http_entries [Boolean] also take an HTTP entry under one of the
    #   gem's names (http_entry?), which only uninstall wants
    # @param report [#call, nil] called once per config with its path, the
    #   names it took, each entry that runs the gem and stays (with why), and
    #   the ones of those that still start the gem's server
    # @return [Array<String>] paths that were modified or deleted
    def self.remove(tools:, output_dir:, warn: nil, http_entries: false, report: nil)
      warn ||= ->(path, reason) { RailsAiContext.log_warn("[rails-ai-context] could not update #{path}: #{reason}") }
      cleaned = []
      Install::AiTool.mcp_config_keys(tools).each do |tool|
        config = TOOL_CONFIGS[tool]
        next unless config

        path = File.join(output_dir, config[:path])
        next unless File.exist?(path)

        begin
          left = if config[:format] == :codex_toml
            remove_toml_entry(path, output_dir, http_entries: http_entries, report: report)
          else
            remove_json_entry(path, config, output_dir, http_entries: http_entries, report: report)
          end
          if left == true then cleaned << path
          elsif left then warn.call(path, left)
          end
        rescue SystemCallError, IOError => e
          warn.call(path, e.message)
        end
      end
      cleaned
    end

    # `http_entries: true` takes an HTTP entry under one of the gem's names too.
    #
    # @return [true, String, nil] true when the entries went, the reason they
    #   stay when the file cannot be written back faithfully, nil when it
    #   holds none of the gem's
    def self.remove_json_entry(path, config, root, http_entries: false, report: nil)
      root_key = config[:root_key]
      text, bom, problem = json_text(path)
      # A file that cannot be read says so only when it names the gem.
      unreadable = ->(why) { "#{why}, so it is left as it is. Remove its rails-ai-context entries by hand" if text.include?(SERVER_NAME) }
      return unreadable.call(problem) if problem

      data = begin
        parse_json_text(text, config)
      rescue JSON::ParserError, UnreadableError => e
        return unreadable.call(parse_problem(e, text))
      end
      servers = data.is_a?(Hash) ? data[root_key] : nil
      return nil unless servers.is_a?(Hash)

      kept = servers.to_h do |name, entry|
        extra = entry.is_a?(Hash) ? unwritten_keys(entry, config) : []
        [ name, kept_reason(name, json_argv(entry), (extra.join(", ") if extra.any?)) ]
      end.compact
      own = servers.select { |name, entry| removable_json?(name, entry, config) || (http_entries && http_entry?(name, entry)) }.keys
      gone = []
      begin
        return nil if own.empty?
        if json_comments?(text)
          return "#{COMMENTS_PROBLEM}, so it is left as it is. " \
                 "Remove #{own.join(', ')} from it by hand"
        end

        own.each { |name| servers.delete(name) }
        data.delete(root_key) if servers.empty?

        # A link stays, and the file it names is what loses the entries. The "$schema" its client writes into it is no config.
        if (data.empty? || data == { "$schema" => config[:schema] }) && !File.symlink?(path)
          RailsAiContext::SafeFile.delete(path, root: root)
        else
          RailsAiContext::SafeFile.atomic_write(path, bom + JSON.pretty_generate(data) + "\n", root: root)
        end
        gone = own
        true
      ensure
        # Once, whether the file was written or not: the entries that stay are named either way.
        report&.call(path, gone, kept, kept.keys.select { |name| runs_gem?(json_argv(servers[name])) }) if gone.any? || kept.any?
      end
    end

    # @return [true, String, nil] as remove_json_entry
    def self.remove_toml_entry(path, root, http_entries: false, report: nil)
      bom, content = RailsAiContext::SafeFile.split_bom(RailsAiContext::SafeFile.read_text(path))
      lines = content.lines
      found = Toml.statements(lines)
      # Taking its table out would leave the rest of an entry spelled
      # another way, which is no entry Codex can start.
      servers = Toml.servers(lines, found) { true }
      added = Toml.own_sections(lines, found).to_h do |range, name|
        [ name, toml_kept(lines, range, found, name)[:own] ]
      end
      kept = servers.to_h { |server| [ server.name, kept_reason(server.name, server.argv, added[server.name] ? "keys of its own" : nil) ] }.compact
      gone = []
      held = servers.select { |server| !server.rewritable? && written_entry?(server.name, server.argv) }
      return "#{unwritable_toml(held.map(&:name))}, so it is left as it is. Remove #{held.one? ? 'it' : 'them'} by hand" if held.any?

      sections = Toml.own_sections(lines, found).reject { |_, name| kept.key?(name) }
      if http_entries
        sections += Toml.sections(lines, found) { |name| name.match?(OWN_SERVER_NAME) }.select { |_, name| toml_http?(found, name) }
      end
      return nil if sections.empty?

      # Dropped as toml_verdict drops a section, so the user's spacing and a comment above stay.
      newline = content.include?("\r\n") ? "\r\n" : "\n"
      sections.reverse_each do |range, _|
        last = range.end
        last += 1 if (range.begin.zero? || lines[range.begin - 1].strip.empty?) && lines[last]&.strip&.empty?
        lines[range.begin...last] = []
      end
      new_content = lines.join.force_encoding(content.encoding).sub(/(?:\r?\n)+\z/, "")

      if new_content.empty? && !File.symlink?(path)
        RailsAiContext::SafeFile.delete(path, root: root)
      else
        RailsAiContext::SafeFile.atomic_write(path, bom + new_content + newline, root: root)
      end
      gone = sections.map(&:last)
      true
    ensure
      starting = servers.select { |server| kept&.key?(server.name) && runs_gem?(server.argv) }.map(&:name) if servers
      report&.call(path, gone, kept, starting) if report && (gone&.any? || kept&.any?)
    end

    private_class_method :remove_json_entry, :remove_toml_entry, :kept_reason
  end
end
