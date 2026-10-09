# frozen_string_literal: true

require "json"
require "fileutils"
require "securerandom"
require_relative "install_mode"

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
    # workspace form. Removal matches all of them, so dropping an AI tool
    # leaves no workspace entry behind.
    OWN_NAME = /#{Regexp.escape(SERVER_NAME)}(?:-[A-Za-z0-9_-]+)?/
    OWN_SERVER_NAME = /\A#{OWN_NAME}\z/

    # One server entry. app_path and gemfile are relative to the folder the
    # config sits in, because the file may be committed and an absolute path
    # holds only on the machine that wrote it. `folder` is how a tool's config
    # names that folder (AiTool's folder_variable), for the tools that do not
    # promise to start the server in it; elsewhere the path stays relative.
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
        argv += [ "--app-path", anchored(app_path, folder) ] if app_path
        argv += [ "--server-name", announce ] if announce
        argv
      end

      # bundle exec looks for a Gemfile from where it starts, upward, and a
      # workspace entry starts in the folder above its app.
      def env(folder = nil)
        !standalone && gemfile ? { "BUNDLE_GEMFILE" => anchored(gemfile, folder) } : {}
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
      @output_dir = output_dir
      @tool_mode = tool_mode
      @servers = servers || [
        Server.new(name: SERVER_NAME, standalone: standalone.nil? ? InstallMode.standalone? : standalone)
      ]
    end

    # @return [Hash] { written: [paths], skipped: [paths], failed: [paths] }
    def call
      return { written: [], skipped: [], failed: [] } if @tool_mode == :cli

      written = []
      skipped = []
      failed = []

      @tools.each do |tool|
        config = TOOL_CONFIGS[tool]
        next unless config

        path = File.join(@output_dir, config[:path])
        # One rescue for every read, write and rename the merges do: an
        # unreadable or unwritable config is one tool's auto-discovery lost,
        # not a reason to abandon the install.
        result = begin
          generate_for(path, config)
        rescue SystemCallError, IOError, ShapeError => e
          RailsAiContext.log_warn "[rails-ai-context] could not write #{config[:path]}: #{e.message}"
          :failed
        end

        case result
        when :written then written << path
        when :skipped then skipped << path
        when :failed then failed << path
        end
      end

      { written: written, skipped: skipped, failed: failed }
    end

    # A config whose servers key holds something other than an object: there
    # is no entry to merge into, and replacing it would drop what it holds.
    class ShapeError < StandardError; end

    # Codex's config read by lines rather than by a TOML parser, which the
    # gem does not depend on: only the server sections it writes are ever
    # located, and everything else in the file is copied through untouched.
    module Toml
      # A table header, and the one shape of it that names a server.
      TABLE = /\A[ \t]*\[/
      SERVER_HEADER = /\A[ \t]*\[[ \t]*mcp_servers\.([A-Za-z0-9_-]+)[ \t]*\][ \t]*(?:#.*)?\r?\n?\z/

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

      def sub_table?(line, name)
        line.sub(/\A[ \t]*\[\[?[ \t]*/, "").start_with?("mcp_servers.#{name}.")
      end

      def trivia?(line)
        stripped = line.strip
        stripped.empty? || stripped.start_with?("#")
      end
    end

    private

    # In a workspace the bare entry serves the folder itself, which is no
    # app, so it can only fail; the per-app entries replace it.
    def superseded
      @servers.any? { |server| server.name == SERVER_NAME } ? [] : [ SERVER_NAME ]
    end

    # The root key comes from the AiTool table, the same table self.remove
    # reads. OpenCode takes the whole command as one array and calls its
    # environment `environment`; the other JSON tools take command plus args
    # and `env`, with type left off - stdio is inferred from command.
    def generate_for(path, config)
      return merge_toml(path) if config[:format] == :codex_toml

      entries = @servers.to_h { |server| [ server.name, json_entry(server, config) ] }
      merge_json(path, config[:root_key], entries)
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

    def merge_json(path, root_key, entries)
      FileUtils.mkdir_p(File.dirname(path))

      existing = File.exist?(path) ? parse_json(path) : nil
      data = existing.is_a?(Hash) ? existing : {}
      data[root_key] ||= {}
      servers = data[root_key]
      raise ShapeError, %("#{root_key}" is not an object; left the file as it is) unless servers.is_a?(Hash)

      stale = superseded.select { |name| servers.key?(name) }
      return :skipped if existing && stale.empty? && entries.all? { |name, entry| servers[name] == entry }

      stale.each { |name| servers.delete(name) }
      servers.merge!(entries)
      RailsAiContext::SafeFile.atomic_write(path, JSON.pretty_generate(data) + "\n")
      :written
    end

    # A file that does not parse is replaced: it serves no tool as it stands.
    def parse_json(path)
      JSON.parse(File.read(path))
    rescue JSON::ParserError
      {}
    end

    # --- TOML merge logic ---

    # Each server's section is replaced where it stands, a superseded one is
    # dropped, and a new one goes at the end after a blank line.
    def merge_toml(path)
      FileUtils.mkdir_p(File.dirname(path))
      content = File.exist?(path) ? File.read(path) : ""
      by_name = @servers.to_h { |server| [ server.name, toml_section(server) ] }
      drop = superseded

      lines = content.lines
      sections = Toml.sections(lines) { |name| by_name.key?(name) || drop.include?(name) }
      out = []
      written = {}
      index = 0
      while index < lines.size
        range, name = sections.find { |r, _| r.begin == index }
        unless range
          out << lines[index]
          index += 1
          next
        end

        if by_name.key?(name) && !written.key?(name)
          out << by_name.fetch(name)
          written[name] = true
          index = range.end
        else
          # A dropped section takes the blank line under it when the one
          # above is blank too, so the gap it leaves does not double.
          index = range.end
          index += 1 if (out.empty? || out.last.strip.empty?) && lines[index]&.strip&.empty?
        end
      end

      new_content = out.join
      by_name.each do |name, section|
        next if written.key?(name)

        separator = if new_content.empty? then ""
        elsif new_content.end_with?("\n\n") then ""
        elsif new_content.end_with?("\n") then "\n"
        else "\n\n"
        end
        new_content = new_content + separator + section
      end

      return :skipped if File.exist?(path) && new_content == content

      RailsAiContext::SafeFile.atomic_write(path, new_content)
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
    # Ruby's #inspect writes `\#{` and `\e`, which TOML rejects.
    def toml_string(value)
      JSON.generate(value.to_s)
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

      target = real(app_root.to_s)
      dir = app_root.to_s
      2.times do
        parent = File.dirname(dir)
        break if parent == dir

        dir = parent
        path = File.join(dir, config[:path])
        next unless File.file?(path)
        return path if app_paths(path, config, dir).any? { |app_path| real(File.expand_path(app_path, dir)) == target }
      end
      nil
    end

    # The --app-path of every server this gem wrote into one config file,
    # with the tool's name for the folder (`dir`) read as that folder.
    def self.app_paths(path, config, dir)
      argvs = if config[:format] == :codex_toml
        lines = File.read(path).lines
        Toml.sections(lines) { |name| name.match?(OWN_SERVER_NAME) }.filter_map do |range, _|
          args = lines[range].find { |line| line.match?(/\A[ \t]*args[ \t]*=/) } or next
          Array(JSON.parse(args.split("=", 2).last.strip))
        rescue JSON::ParserError
          nil
        end
      else
        data = JSON.parse(File.read(path))
        servers = data.is_a?(Hash) ? data[config[:root_key]] : nil
        return [] unless servers.is_a?(Hash)

        servers.filter_map do |name, entry|
          next unless name.match?(OWN_SERVER_NAME) && entry.is_a?(Hash)

          [ *entry["command"], *entry["args"] ]
        end
      end

      folder = config[:folder_variable]
      argvs.filter_map do |argv|
        argv = argv.map(&:to_s)
        at = argv.index("--app-path")
        app_path = at ? argv[at + 1] : argv.find { |arg| arg.start_with?("--app-path=") }&.delete_prefix("--app-path=")
        folder && app_path&.start_with?(folder) ? dir + app_path.delete_prefix(folder) : app_path
      end
    rescue SystemCallError, IOError, JSON::ParserError
      []
    end
    private_class_method :app_paths

    def self.real(path)
      File.realpath(path)
    rescue SystemCallError
      File.expand_path(path)
    end
    private_class_method :real

    # --- Merge-safe removal ---

    # Removes every rails-ai-context entry - the app's own and each workspace
    # one - from each tool's MCP config file, preserving other servers.
    # Deletes the file only if no other entries remain.
    #
    # @param tools [Array<Symbol>] tool keys to remove MCP entries from
    # @param output_dir [String] project root path
    # @return [Array<String>] paths that were modified or deleted
    def self.remove(tools:, output_dir:)
      cleaned = []
      Array(tools).map(&:to_sym).each do |tool|
        config = TOOL_CONFIGS[tool]
        next unless config

        path = File.join(output_dir, config[:path])
        next unless File.exist?(path)

        begin
          if config[:format] == :codex_toml
            cleaned << path if remove_toml_entry(path)
          else
            cleaned << path if remove_json_entry(path, config[:root_key])
          end
        rescue SystemCallError, IOError => e
          RailsAiContext.log_warn "[rails-ai-context] could not update #{config[:path]}: #{e.message}"
        end
      end
      cleaned
    end

    def self.remove_json_entry(path, root_key)
      data = JSON.parse(File.read(path))
      servers = data.is_a?(Hash) ? data[root_key] : nil
      return false unless servers.is_a?(Hash)

      own = servers.keys.grep(OWN_SERVER_NAME)
      return false if own.empty?

      own.each { |name| servers.delete(name) }
      data.delete(root_key) if servers.empty?

      if data.empty?
        File.delete(path)
      else
        RailsAiContext::SafeFile.atomic_write(path, JSON.pretty_generate(data) + "\n")
      end
      true
    rescue JSON::ParserError
      false
    end

    def self.remove_toml_entry(path)
      lines = File.read(path).lines
      sections = Toml.sections(lines) { |name| name.match?(OWN_SERVER_NAME) }
      return false if sections.empty?

      sections.reverse_each { |range, _| lines.slice!(range) }
      # Clean up extra blank lines left behind
      new_content = lines.join.gsub(/\n{3,}/, "\n\n").strip

      if new_content.empty?
        File.delete(path)
      else
        RailsAiContext::SafeFile.atomic_write(path, new_content + "\n")
      end
      true
    end

    private_class_method :remove_json_entry, :remove_toml_entry
  end
end
