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
  class McpConfigGenerator
    TOOL_CONFIGS = Install::AiTool.mcp_configs_by_key.freeze

    SERVER_NAME = "rails-ai-context"

    # @param tools [Array<Symbol>] selected AI tool keys (e.g. [:claude, :cursor])
    # @param output_dir [String] project root path
    # @param standalone [Boolean, nil] true writes bare `rails-ai-context`
    #   commands, false writes `bundle exec` commands. nil (the default)
    #   detects the install mode from the app's Gemfile.lock so every entry
    #   point that writes MCP configs (standalone CLI init, rake task, Rails
    #   generator) converges on identical config content for the same app
    #   instead of rewriting each other's command form on alternate runs.
    # @param tool_mode [Symbol] :mcp or :cli
    def initialize(tools:, output_dir:, standalone: nil, tool_mode: :mcp)
      @tools = Array(tools).map(&:to_sym)
      @output_dir = output_dir
      @standalone = standalone.nil? ? InstallMode.standalone? : standalone
      @tool_mode = tool_mode
    end

    # @return [Hash] { written: [paths], skipped: [paths] }
    def call
      return { written: [], skipped: [] } if @tool_mode == :cli

      written = []
      skipped = []

      @tools.each do |tool|
        config = TOOL_CONFIGS[tool]
        next unless config

        path = File.join(@output_dir, config[:path])
        result = generate_for(tool, path, config)
        case result
        when :written then written << path
        when :skipped then skipped << path
        end
      end

      { written: written, skipped: skipped }
    end

    private

    # The root key comes from the AiTool table, the same table self.remove
    # reads. OpenCode takes the whole command as one array; the other JSON
    # tools take command plus args, with type left off - stdio is inferred
    # from command being present.
    def generate_for(_tool, path, config)
      return merge_toml(path, build_codex_section) if config[:format] == :codex_toml

      entry = if config[:format] == :opencode_json
        { "type" => "local", "command" => server_command }
      else
        { "command" => server_command.first, "args" => server_command[1..] }
      end
      merge_json(path, config[:root_key], entry)
    end

    # --- JSON merge logic ---

    def merge_json(path, root_key, entry)
      FileUtils.mkdir_p(File.dirname(path))

      if File.exist?(path)
        existing = begin
          JSON.parse(File.read(path))
        rescue JSON::ParserError
          {}
        end
        existing[root_key] ||= {}

        if existing[root_key][SERVER_NAME] == entry
          return :skipped
        end

        existing[root_key][SERVER_NAME] = entry
        RailsAiContext::SafeFile.atomic_write(path, JSON.pretty_generate(existing) + "\n")
      else
        content = JSON.pretty_generate({ root_key => { SERVER_NAME => entry } }) + "\n"
        RailsAiContext::SafeFile.atomic_write(path, content)
      end

      :written
    end

    # --- TOML merge logic ---

    TOML_SECTION_HEADER = "[mcp_servers.#{SERVER_NAME}]"
    # Matches the [mcp_servers.rails-ai-context] section and any sub-sections
    # like [mcp_servers.rails-ai-context.env], stopping at a non-sub-section header.
    TOML_SECTION_REGEX = /
      ^\[mcp_servers\.rails-ai-context\]\s*\n           # main section header
      (?:(?!\n\[(?!mcp_servers\.rails-ai-context\.))[^\n]*\n)*  # lines until non-sub-section
      (?:(?!\n?\[(?!mcp_servers\.rails-ai-context\.))[^\n]+)?   # optional last line without \n
    /mx

    def merge_toml(path, section)
      FileUtils.mkdir_p(File.dirname(path))

      if File.exist?(path)
        content = File.read(path)

        if content.include?(TOML_SECTION_HEADER)
          new_content = content.sub(TOML_SECTION_REGEX, section)
          if new_content == content
            return :skipped
          end
          RailsAiContext::SafeFile.atomic_write(path, new_content)
        else
          # Append our section
          separator = content.end_with?("\n") ? "\n" : "\n\n"
          RailsAiContext::SafeFile.atomic_write(path, content + separator + section)
        end
      else
        RailsAiContext::SafeFile.atomic_write(path, section)
      end

      :written
    end

    def build_codex_section
      lines = []
      lines << "[mcp_servers.#{SERVER_NAME}]"

      cmd = server_command
      lines << "command = #{cmd.first.inspect}"
      lines << "args = #{cmd[1..].inspect}"

      # Codex CLI env_clear()s the process environment. Capture the current Ruby
      # environment so the MCP server can find gems regardless of version manager
      # (rbenv, rvm, asdf, mise, or system Ruby).
      env_vars = ruby_env_snapshot
      unless env_vars.empty?
        lines << ""
        lines << "[mcp_servers.#{SERVER_NAME}.env]"
        env_vars.each { |k, v| lines << "#{k} = #{v.inspect}" }
      end

      lines.join("\n") + "\n"
    end

    # Snapshot environment variables needed for Ruby/Bundler to work.
    # Only captures vars that are actually set - works with any version manager.
    RUBY_ENV_KEYS = %w[PATH GEM_HOME GEM_PATH GEM_ROOT RUBY_VERSION BUNDLE_PATH].freeze

    def ruby_env_snapshot
      snapshot = {}
      RUBY_ENV_KEYS.each do |key|
        val = ENV[key]
        snapshot[key] = val if val && !val.empty?
      end
      snapshot
    end

    # --- Shared helpers ---

    # How the server is invoked, for every config format. In-Gemfile installs
    # go through the CLI binary because it quarantines app boot output away
    # from stdout starting before Bundler.require; the rake task can only
    # quarantine from the environment task onward.
    def server_command
      if @standalone
        [ "rails-ai-context", "serve" ]
      else
        [ "bundle", "exec", "rails-ai-context", "serve" ]
      end
    end

    # --- Merge-safe removal ---

    # Removes only the rails-ai-context entry from each tool's MCP config file,
    # preserving other servers. Deletes the file only if no other entries remain.
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

        if config[:format] == :codex_toml
          cleaned << path if remove_toml_entry(path)
        else
          root_key = config[:root_key]
          cleaned << path if remove_json_entry(path, root_key)
        end
      end
      cleaned
    end

    def self.remove_json_entry(path, root_key)
      data = JSON.parse(File.read(path))
      return false unless data.dig(root_key, SERVER_NAME)

      data[root_key].delete(SERVER_NAME)

      if data[root_key].empty?
        data.delete(root_key)
      end

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
      content = File.read(path)
      return false unless content.include?(TOML_SECTION_HEADER)

      new_content = content.sub(TOML_SECTION_REGEX, "")
      # Clean up extra blank lines left behind
      new_content.gsub!(/\n{3,}/, "\n\n")
      new_content.strip!

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
