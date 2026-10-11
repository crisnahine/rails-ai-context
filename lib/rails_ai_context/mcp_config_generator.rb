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

    # The byte order mark some editors put at the head of a JSON file.
    BOM = "\uFEFF"

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
      def argv(folder = nil)
        argv = standalone ? %w[rails-ai-context serve] : %w[bundle exec rails-ai-context serve]
        app_path ? [ *argv, "--app-path", anchored(app_path, folder) ] : argv
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
      @tools = Array(tools).map(&:to_sym)
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
          generate_for(path, config)
        rescue SystemCallError, IOError, JSON::JSONError, ShapeError => e
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

    # A config that parses but holds no object to merge into, at the top or
    # under its servers key: replacing it would drop what it holds.
    class ShapeError < StandardError; end

    # A JSON config its client cannot read: one that reads JSON refuses the
    # comments and trailing commas a JSONC reader passes over.
    class UnreadableError < StandardError; end

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

      # One sub-table of a section, `[mcp_servers.<name>.<key>]` or the
      # section's own `<key>.<item> = ...`, as each item's string value.
      def sub_table(lines, range, _name, key, found = statements(lines))
        table = section_data(lines, range, found)[key]
        return {} unless table.is_a?(Hash)

        table.filter_map { |item, values| [ item, Array(values).grep(String).first ] if Array(values).grep(String).any? }.to_h
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

      # TOML's basic-string escapes are JSON's, but for \U and \e.
      def unescape(basic)
        JSON.parse(basic)
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

    # A config's text past an editor's byte order mark, and the mark, which
    # is the file's and goes back at its head when it is written.
    def self.split_bom(text)
      return [ text, "".dup.force_encoding(text.encoding) ] unless text.b.start_with?(BOM.b)

      [ text.byteslice(BOM.bytesize..).force_encoding(text.encoding), BOM.dup.force_encoding(text.encoding) ]
    end

    # A JSON config's text and byte order mark, and why it cannot be read
    # as JSON at all: JSON is UTF-8.
    #
    # @return [Array(String, String, String)] text, mark, problem (nil when none)
    def self.json_text(path)
      text, bom = split_bom(RailsAiContext::SafeFile.read_text(path))
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
      lines = split_bom(RailsAiContext::SafeFile.read_text(path)).first.lines
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
    def generate_for(path, config)
      return merge_toml(path) if config[:format] == :codex_toml

      entries = @servers.to_h { |server| [ server.name, json_entry(server, config) ] }
      merge_json(path, config, entries)
    end

    def json_entry(server, config)
      argv = server.argv(config[:folder_variable])
      env = server.env(config[:folder_variable])
      opencode = config[:format] == :opencode_json
      entry = opencode ? { "type" => "local", "command" => argv } : { "command" => argv.first, "args" => argv[1..] }
      entry[opencode ? "environment" : "env"] = env unless env.empty?
      entry
    end

    # --- JSON merge logic ---

    def merge_json(path, config, entries)
      FileUtils.mkdir_p(File.dirname(path))

      text, bom, problem = File.exist?(path) ? self.class.json_text(path) : [ nil, "", nil ]
      raise ShapeError, problem if problem

      # An empty file holds nothing to lose.
      data = text.nil? || text.strip.empty? ? {} : parse_json(text, config)
      raise ShapeError, "it is JSON but not an object" unless data.is_a?(Hash)

      root_key = config[:root_key]
      data[root_key] ||= {}
      servers = data[root_key]
      raise ShapeError, %("#{root_key}" is not an object) unless servers.is_a?(Hash)

      ours = servers.filter_map do |name, entry|
        argv = self.class.json_argv(entry)
        [ name, self.class.entry_app_root(argv, config[:folder_variable], @output_dir) ] if self.class.own_entry?(name, argv)
      end
      # An entry under one of this write's names that is not the gem's - the
      # HTTP one SETUP.md describes - is kept in place of the gem's.
      kept = entries.keys.select { |name| servers.key?(name) && !self.class.own_entry?(name, self.class.json_argv(servers[name])) }
      note_kept(path, kept)
      entries = entries.except(*kept)
      stale = stale_names(ours.to_h)
      return :skipped if text && stale.empty? && entries.all? { |name, entry| servers[name] == entry }
      # JSON.parse passes over comments, and the file written back would
      # have none.
      raise ShapeError, COMMENTS_PROBLEM if text && self.class.json_comments?(text)

      stale.each { |name| servers.delete(name) }
      servers.merge!(entries)
      RailsAiContext::SafeFile.atomic_write(path, bom + JSON.pretty_generate(data) + "\n")
      :written
    rescue UnreadableError => e
      # Adding the entry by hand would leave a file its client still cannot read.
      raise ShapeError, "#{e.message}, so it is left as it is. Make it plain JSON by hand, and the next run merges into it"
    rescue ShapeError => e
      raise ShapeError, "#{e.message}, so it is left as it is. Add #{JSON.generate(config[:root_key] => entries)} to it by hand"
    end

    # A file JSON cannot parse is never replaced: a fresh file would drop
    # everything somebody wrote there.
    def parse_json(text, config)
      self.class.parse_json_text(text, config)
    rescue JSON::ParserError => e
      raise ShapeError, self.class.parse_problem(e, text)
    end

    def note_kept(path, kept)
      return if kept.empty?

      @notes[path] = "kept #{kept.join(', ')}, which #{kept.one? ? 'runs' : 'run'} something other than the gem's " \
                     "server (an HTTP entry?), in place of the gem's"
    end

    # --- TOML merge logic ---

    # Each server's section is replaced where it stands, a stale one is
    # dropped, and a new one goes at the end after a blank line.
    def merge_toml(path)
      FileUtils.mkdir_p(File.dirname(path))
      content, bom = self.class.split_bom(File.exist?(path) ? RailsAiContext::SafeFile.read_text(path) : +"")
      lines = content.lines
      # A file kept with Windows line endings keeps them, and one that is not
      # UTF-8 gets the new sections as bytes beside its own.
      newline = content.include?("\r\n") ? "\r\n" : "\n"
      by_name = @servers.to_h do |server|
        section = toml_section(server).gsub("\n", newline)
        [ server.name, content.encoding == Encoding::BINARY ? section.b : section ]
      end

      found = Toml.statements(lines)
      own_name = ->(name) { name.match?(OWN_SERVER_NAME) }
      named = Toml.sections(lines, found, &own_name)
      ours = Toml.own_sections(lines, found).map do |range, name|
        [ name, self.class.entry_app_root(Toml.argv(lines, range, found), nil, @output_dir) ]
      end
      # A server of this write's spelled any way but one table - an inline
      # table, dotted keys - is never written beside: a table next to it
      # declares the server twice, which Codex refuses to read.
      unwritable = Toml.servers(lines, found, &own_name).select { |server| by_name.key?(server.name) && !server.rewritable? }
      check_toml_shape(found, unwritable)
      # A section or entry under one of this write's names that is not the
      # gem's is kept in place of the gem's, which would be a second table of
      # one name, and that does not parse.
      kept = named.map(&:last).select { |name| by_name.key?(name) } - ours.map(&:first) + unwritable.map(&:name)
      note_kept(path, kept.uniq)
      by_name = by_name.except(*kept)
      drop = stale_names(ours.to_h)
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
          out << by_name.fetch(name)
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
      by_name.each do |name, section|
        next if written.key?(name)

        separator = if new_content.empty? then ""
        elsif new_content.end_with?(newline * 2) then ""
        elsif new_content.end_with?(newline) then newline
        else newline * 2
        end
        new_content = new_content + separator + section
      end

      return :skipped if File.exist?(path) && new_content == content

      RailsAiContext::SafeFile.atomic_write(path, bom + new_content)
      :written
    end

    # A Codex config the merge would leave unreadable, or could not keep
    # current, is left as it is: one where mcp_servers is a single inline
    # table, one that already declares a server of this write twice, and one
    # that sets the gem's entry in a form the merge does not rewrite. What
    # is left after that - someone else's entry under the gem's name - is
    # kept in its place.
    def check_toml_shape(found, unwritable)
      if (closed = Toml.closed(found))
        raise ShapeError, "#{closed}, so it is left as it is. Write it as [mcp_servers.<name>] tables by hand"
      end

      twice = unwritable.select(&:twice?)
      if twice.any?
        raise ShapeError, "it declares #{twice.map(&:name).join(', ')} twice, which Codex refuses to read, " \
                          "so it is left as it is. Delete all but one by hand"
      end

      own = unwritable.select { |server| self.class.own_entry?(server.name, server.argv) }
      return if own.empty?

      it = own.one? ? "it" : "them"
      tables = own.one? ? "a [mcp_servers.#{own.first.name}] table" : "[mcp_servers.<name>] tables"
      raise ShapeError, "#{self.class.unwritable_toml(own.map(&:name))}, so it is left as it is. Write #{it} as " \
                        "#{tables} by hand, or delete #{it}, and the next run keeps #{it} current"
    end

    def toml_section(server)
      argv = server.argv
      lines = [ "[mcp_servers.#{server.name}]" ]
      lines << "command = #{toml_string(argv.first)}"
      lines << "args = [#{argv[1..].map { |arg| toml_string(arg) }.join(', ')}]"

      # Codex CLI env_clear()s the process environment. Capture the current
      # Ruby environment so the MCP server can find gems regardless of version
      # manager (rbenv, rvm, asdf, mise, or system Ruby).
      env = ruby_env_snapshot.merge(server.env)
      unless env.empty?
        lines << ""
        lines << "[mcp_servers.#{server.name}.env]"
        env.each { |key, value| lines << "#{key} = #{toml_string(value)}" }
      end

      lines.join("\n") + "\n"
    end

    # A TOML basic string. JSON's string escapes are a subset of TOML's, where
    # Ruby's #inspect writes `\#{` and `\e`, which TOML rejects. ENV hands
    # back bytes tagged BINARY where the locale names no encoding, so they are
    # read as the UTF-8 they almost always are.
    def toml_string(value)
      JSON.generate(value.to_s.dup.force_encoding(Encoding::UTF_8).scrub)
    end

    # Snapshot environment variables needed for Ruby/Bundler to work.
    # Only captures vars that are actually set - works with any version manager.
    RUBY_ENV_KEYS = %w[PATH GEM_HOME GEM_PATH GEM_ROOT RUBY_VERSION BUNDLE_PATH].freeze

    def ruby_env_snapshot
      ENV.slice(*RUBY_ENV_KEYS).reject { |_, value| value.empty? }
    end

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
      if config[:format] == :codex_toml
        return toml_servers(path).first.map do |server|
          { name: server.name, argv: server.argv, env: server.env, own: own_entry?(server.name, server.argv) }
        end
      end

      data = read_json(path, config)
      servers = data.is_a?(Hash) ? data[config[:root_key]] : nil
      return [] unless servers.is_a?(Hash)

      # OpenCode calls its environment `environment`, as json_entry writes it.
      env_key = config[:format] == :opencode_json ? "environment" : "env"
      servers.filter_map do |name, entry|
        next unless name.match?(OWN_SERVER_NAME)

        argv = json_argv(entry).map(&:to_s)
        env = entry[env_key] if entry.is_a?(Hash)
        { name: name, argv: argv, env: env.is_a?(Hash) ? env.transform_values(&:to_s) : {}, own: own_entry?(name, argv) }
      end
    end

    # The app every server of ours in one config file names.
    def self.app_roots_in(path, tool, dir)
      folder = TOOL_CONFIGS.fetch(tool.to_sym)[:folder_variable]
      named_entries(path, tool).filter_map { |entry| entry_app_root(entry[:argv], folder, dir) if entry[:own] }
    rescue SystemCallError, IOError, JSON::ParserError, UnreadableError
      []
    end
    private_class_method :app_roots_in

    # --- Merge-safe removal ---

    # Removes every rails-ai-context entry - the app's own and each workspace
    # one - from each tool's MCP config file, preserving other servers.
    # Deletes the file only if no other entries remain.
    #
    # @param tools [Array<Symbol>] tool keys to remove MCP entries from
    # @param output_dir [String] project root path
    # @param warn [#call, nil] called with a config's path and why it was left
    #   as it is, for the caller to say in its own voice; nil logs it
    # @return [Array<String>] paths that were modified or deleted
    def self.remove(tools:, output_dir:, warn: nil)
      warn ||= ->(path, reason) { RailsAiContext.log_warn("[rails-ai-context] could not update #{path}: #{reason}") }
      cleaned = []
      Array(tools).map(&:to_sym).each do |tool|
        config = TOOL_CONFIGS[tool]
        next unless config

        path = File.join(output_dir, config[:path])
        next unless File.exist?(path)

        begin
          left = config[:format] == :codex_toml ? remove_toml_entry(path) : remove_json_entry(path, config)
          if left == true then cleaned << path
          elsif left then warn.call(path, left)
          end
        rescue SystemCallError, IOError => e
          warn.call(path, e.message)
        end
      end
      cleaned
    end

    # @return [true, String, nil] true when the entries went, the reason they
    #   stay when the file cannot be written back faithfully, nil when it
    #   holds none of the gem's
    def self.remove_json_entry(path, config)
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

      own = servers.select { |name, entry| own_entry?(name, json_argv(entry)) }.keys
      return nil if own.empty?
      if json_comments?(text)
        return "#{COMMENTS_PROBLEM}, so it is left as it is. " \
               "Remove #{own.join(', ')} from it by hand"
      end

      own.each { |name| servers.delete(name) }
      data.delete(root_key) if servers.empty?

      if data.empty?
        File.delete(path)
      else
        RailsAiContext::SafeFile.atomic_write(path, bom + JSON.pretty_generate(data) + "\n")
      end
      true
    end

    # @return [true, String, nil] as remove_json_entry
    def self.remove_toml_entry(path)
      content, bom = split_bom(RailsAiContext::SafeFile.read_text(path))
      lines = content.lines
      found = Toml.statements(lines)
      # Taking its table out would leave the rest of an entry spelled
      # another way, which is no entry Codex can start.
      held = Toml.servers(lines, found) { |name| name.match?(OWN_SERVER_NAME) }
        .select { |server| !server.rewritable? && own_entry?(server.name, server.argv) }
      return "#{unwritable_toml(held.map(&:name))}, so it is left as it is. Remove #{held.one? ? 'it' : 'them'} by hand" if held.any?

      sections = Toml.own_sections(lines, found)
      return nil if sections.empty?

      # A comment above a section stays: it may be a key of the table before,
      # set aside by hand.
      sections.reverse_each { |range, _| lines.slice!(range) }
      # Clean up extra blank lines left behind, in the file's own line ending
      newline = content.include?("\r\n") ? "\r\n" : "\n"
      new_content = lines.join.force_encoding(content.encoding).gsub(/(?:\r?\n){3,}/, newline * 2).strip

      if new_content.empty?
        File.delete(path)
      else
        RailsAiContext::SafeFile.atomic_write(path, bom + new_content + newline)
      end
      true
    end

    private_class_method :remove_json_entry, :remove_toml_entry
  end
end
