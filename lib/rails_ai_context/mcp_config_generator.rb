# frozen_string_literal: true

require "json"
require "fileutils"
require "securerandom"

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
    TOOL_CONFIGS = {
      claude:   { path: ".mcp.json",          root_key: "mcpServers", format: :mcp_json },
      cursor:   { path: ".cursor/mcp.json",   root_key: "mcpServers", format: :mcp_json },
      copilot:  { path: ".vscode/mcp.json",   root_key: "servers",    format: :vscode_json },
      opencode: { path: "opencode.json",      root_key: "mcp",        format: :opencode_json },
      codex:    { path: ".codex/config.toml",  root_key: nil,          format: :codex_toml }
    }.freeze

    SERVER_NAME = "rails-ai-context"

    # @param tools [Array<Symbol>] selected AI tool keys (e.g. [:claude, :cursor])
    # @param output_dir [String] project root path
    # @param standalone [Boolean] true for standalone CLI mode
    # @param tool_mode [Symbol] :mcp or :cli
    def initialize(tools:, output_dir:, standalone: false, tool_mode: :mcp)
      @tools = Array(tools).map(&:to_sym)
      @output_dir = output_dir
      @standalone = standalone
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

    def generate_for(tool, path, config)
      case config[:format]
      when :mcp_json     then write_mcp_json(path, config[:root_key])
      when :vscode_json  then write_vscode_json(path)
      when :opencode_json then write_opencode_json(path)
      when :codex_toml   then write_codex_toml(path)
      end
    end

    # Claude Code (.mcp.json) and Cursor (.cursor/mcp.json)
    # Format: { "mcpServers": { "rails-ai-context": { "command": "...", "args": [...] } } }
    def write_mcp_json(path, root_key)
      entry = mcp_json_entry
      merge_json(path, root_key, entry)
    end

    # VS Code / Copilot (.vscode/mcp.json)
    # Format: { "servers": { "rails-ai-context": { "command": "...", "args": [...] } } }
    # Type is optional for stdio - VS Code infers from presence of command.
    def write_vscode_json(path)
      entry = mcp_json_entry
      merge_json(path, "servers", entry)
    end

    # OpenCode (opencode.json)
    # Format: { "mcp": { "rails-ai-context": { "type": "local", "command": [...] } } }
    # Note: command is an ARRAY (not separate command/args)
    def write_opencode_json(path)
      cmd = server_command
      entry = { "type" => "local", "command" => cmd }
      merge_json(path, "mcp", entry)
    end

    # Codex CLI (.codex/config.toml)
    # Format: [mcp_servers.rails-ai-context] section with command (string) and args (string array)
    def write_codex_toml(path)
      section = build_codex_section
      merge_toml(path, section)
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
        atomic_write(path, JSON.pretty_generate(existing) + "\n")
      else
        content = JSON.pretty_generate({ root_key => { SERVER_NAME => entry } }) + "\n"
        atomic_write(path, content)
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
          atomic_write(path, new_content)
        else
          # Append our section
          separator = content.end_with?("\n") ? "\n" : "\n\n"
          atomic_write(path, content + separator + section)
        end
      else
        atomic_write(path, section)
      end

      :written
    end

    def build_codex_section
      lines = []
      lines << "[mcp_servers.#{SERVER_NAME}]"

      if @standalone
        lines << 'command = "rails-ai-context"'
        lines << 'args = ["serve"]'
      else
        lines << 'command = "bundle"'
        lines << 'args = ["exec", "rails", "ai:serve"]'
      end

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

    def mcp_json_entry
      if @standalone
        { "command" => "rails-ai-context", "args" => [ "serve" ] }
      else
        { "command" => "bundle", "args" => [ "exec", "rails", "ai:serve" ] }
      end
    end

    def server_command
      if @standalone
        [ "rails-ai-context", "serve" ]
      else
        [ "bundle", "exec", "rails", "ai:serve" ]
      end
    end

    def atomic_write(path, content)
      dir = File.dirname(path)
      tmp = File.join(dir, ".#{File.basename(path)}.#{SecureRandom.hex(4)}.tmp")
      File.write(tmp, content)
      File.rename(tmp, path)
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
        File.write(path, JSON.pretty_generate(data) + "\n")
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
        File.write(path, new_content + "\n")
      end
      true
    end

    private_class_method :remove_json_entry, :remove_toml_entry
  end
end
