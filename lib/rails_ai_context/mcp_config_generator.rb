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

      def anchored(path, folder)
        folder ? "#{folder}/#{path}" : path
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

    # Codex's config read by lines rather than by a TOML parser, which the
    # gem does not depend on: only the server sections it writes are ever
    # located, and everything else in the file is copied through untouched.
    module Toml
      # A table header, and the one shape of it that names a server.
      TABLE = /\A[ \t]*\[/
      SERVER_HEADER = /\A[ \t]*\[[ \t]*mcp_servers\.([A-Za-z0-9_-]+)[ \t]*\][ \t]*(?:#.*)?\r?\n?\z/
      KEY_LINE = /\A[ \t]*([A-Za-z0-9_-]+)[ \t]*=[ \t]*/

      module_function

      # The sections of the servers `keep` accepts, as [line range, name]. A
      # section runs to the next table header that is not one of its own
      # sub-tables; blank and comment lines just above that header stay out
      # of it, since a comment over a header belongs to the header.
      def sections(lines, &keep)
        lines.each_with_index.filter_map do |line, start|
          name = line[SERVER_HEADER, 1]
          next unless name && keep.call(name)

          finish = start + 1
          finish += 1 while finish < lines.size && !(lines[finish].match?(TABLE) && !sub_table?(lines[finish], name))
          finish -= 1 while finish > start + 1 && trivia?(lines[finish - 1])
          [ start...finish, name ]
        end
      end

      # The sections of the gem's own servers, by the rule own_entry? keeps:
      # [line range, name] each.
      def own_sections(lines)
        sections(lines) { |name| name.match?(OWN_SERVER_NAME) }.select do |range, name|
          McpConfigGenerator.own_entry?(name, argv(lines, range))
        end
      end

      # One section's command line, its `command` and `args`, read from the
      # table itself and not its sub-tables.
      def argv(lines, range)
        values = table(lines[range].drop(1).take_while { |line| !line.match?(TABLE) })
        [ *values["command"], *values["args"] ]
      end

      # One sub-table of a section, `[mcp_servers.<name>.<key>]`, as each
      # key's string value.
      def sub_table(lines, range, name, key)
        header = /\A[ \t]*\[[ \t]*mcp_servers\.#{Regexp.escape(name)}\.#{Regexp.escape(key)}[ \t]*\][ \t]*(?:#.*)?\r?\n?\z/
        start = range.find { |index| lines[index].match?(header) } or return {}
        body = lines[(start + 1)...range.end].take_while { |line| !line.match?(TABLE) }
        table(body).filter_map { |item, values| [ item, values.first ] if values.first }.to_h
      end

      # The string values of one table's keys, from its lines: key => the
      # strings it holds, one for a string and each element's for an array.
      def table(lines)
        text = lines.join
        values = {}
        offset = 0
        lines.each do |line|
          key = line[KEY_LINE, 1]
          values[key] = strings(text[(offset + line[KEY_LINE].size)..]) if key && !values.key?(key)
          offset += line.size
        end
        values
      end

      # The strings at the start of a value: a basic ("...") or literal
      # ('...') string, or an array of them however a formatter wrapped it,
      # with comments and a trailing comma.
      def strings(text)
        scanner = StringScanner.new(text)
        found = []
        depth = 0
        until scanner.eos?
          if scanner.scan(/[ \t\r,]+|#[^\n]*/)
            next
          elsif scanner.scan(/\n/)
            break if depth.zero?
          elsif scanner.scan(/\[/)
            depth += 1
          elsif scanner.scan(/\]/)
            depth -= 1
            break if depth <= 0
          elsif (basic = scanner.scan(/"(?:[^"\\\n]|\\.)*"/))
            found << unescape(basic)
            break if depth.zero?
          elsif (literal = scanner.scan(/'[^'\n]*'/))
            found << literal[1..-2]
            break if depth.zero?
          else
            break
          end
        end
        found
      end

      # TOML's basic-string escapes are JSON's, but for \U and \e.
      def unescape(basic)
        JSON.parse(basic)
      rescue JSON::ParserError
        basic[1..-2]
      end

      def sub_table?(line, name)
        line.sub(/\A[ \t]*\[\[?[ \t]*/, "").start_with?("mcp_servers.#{name}.")
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

    # A JSON config as data. One that is not UTF-8 raises as one that does
    # not parse.
    def self.read_json(path)
      text, _, problem = json_text(path)
      raise JSON::ParserError, problem if problem

      JSON.parse(text)
    end

    # Where a JSON parser stopped, when it says (json 2.10 on), and what
    # usually stops it in a config an editor keeps; its own words can run to
    # the whole file.
    def self.parse_problem(error)
      where = error.message[/line \d+,? column \d+/]
      "it does not parse as JSON#{" at #{where}" if where} (a trailing comma?)"
    end

    # Whether JSON text holds a comment, which JSON.parse passes over and a
    # rewrite would drop. Strings are matched whole, so a URL's // is none.
    def self.json_comments?(text)
      text.scan(%r{"(?:[^"\\]|\\.)*"|//|/\*}).any? { |token| !token.start_with?('"') }
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
      data = text.nil? || text.strip.empty? ? {} : parse_json(text)
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
      raise ShapeError, "it holds comments, which writing it back as JSON would drop" if text && self.class.json_comments?(text)

      stale.each { |name| servers.delete(name) }
      servers.merge!(entries)
      RailsAiContext::SafeFile.atomic_write(path, bom + JSON.pretty_generate(data) + "\n")
      :written
    rescue ShapeError => e
      raise ShapeError, "#{e.message}, so it is left as it is. Add #{JSON.generate(config[:root_key] => entries)} to it by hand"
    end

    # A file JSON cannot parse is never replaced: VS Code's and OpenCode's
    # configs take trailing commas, and a fresh file would drop everything
    # somebody wrote there.
    def parse_json(text)
      JSON.parse(text)
    rescue JSON::ParserError => e
      raise ShapeError, self.class.parse_problem(e)
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

      named = Toml.sections(lines) { |name| name.match?(OWN_SERVER_NAME) }
      ours = Toml.own_sections(lines).map do |range, name|
        [ name, self.class.entry_app_root(Toml.argv(lines, range), nil, @output_dir) ]
      end
      # A section under one of this write's names that is not the gem's is
      # kept in place of the gem's, which would be a second table of one
      # name, and that does not parse.
      kept = named.map(&:last).select { |name| by_name.key?(name) } - ours.map(&:first)
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
        return path if app_roots_in(path, config, dir).any? { |root| RailsAiContext::SafePath.canonical(root) == target }
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
          read_json(path)
        rescue JSON::ParserError
          return path
        end
      end
      nil
    rescue SystemCallError, IOError
      nil
    end

    # The app every server of ours in one config file names.
    def self.app_roots_in(path, config, dir)
      argvs = if config[:format] == :codex_toml
        lines = split_bom(RailsAiContext::SafeFile.read_text(path)).first.lines
        Toml.own_sections(lines).map { |range, _| Toml.argv(lines, range) }
      else
        data = read_json(path)
        servers = data.is_a?(Hash) ? data[config[:root_key]] : nil
        return [] unless servers.is_a?(Hash)

        servers.filter_map { |name, entry| json_argv(entry) if own_entry?(name, json_argv(entry)) }
      end
      argvs.filter_map { |argv| entry_app_root(argv, config[:folder_variable], dir) }
    rescue SystemCallError, IOError, JSON::ParserError
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
          if config[:format] == :codex_toml
            cleaned << path if remove_toml_entry(path)
          elsif (left = remove_json_entry(path, config[:root_key]))
            left == true ? cleaned << path : warn.call(path, left)
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
    def self.remove_json_entry(path, root_key)
      text, bom, problem = json_text(path)
      # A file that cannot be read says so only when it names the gem.
      unreadable = ->(why) { "#{why}, so it is left as it is. Remove its rails-ai-context entries by hand" if text.include?(SERVER_NAME) }
      return unreadable.call(problem) if problem

      data = begin
        JSON.parse(text)
      rescue JSON::ParserError => e
        return unreadable.call(parse_problem(e))
      end
      servers = data.is_a?(Hash) ? data[root_key] : nil
      return nil unless servers.is_a?(Hash)

      own = servers.select { |name, entry| own_entry?(name, json_argv(entry)) }.keys
      return nil if own.empty?
      if json_comments?(text)
        return "it holds comments, which writing it back as JSON would drop, so it is left as it is. " \
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

    def self.remove_toml_entry(path)
      content, bom = split_bom(RailsAiContext::SafeFile.read_text(path))
      lines = content.lines
      sections = Toml.own_sections(lines)
      return false if sections.empty?

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
