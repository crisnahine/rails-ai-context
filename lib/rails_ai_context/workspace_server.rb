# frozen_string_literal: true

require "json"
require "digest"
require "monitor"
require "open3"
require "pathname"
require "set"
require "rbconfig"
require_relative "child_server"
require_relative "cli/refusal"

module RailsAiContext
  # One MCP server over stdio for a folder of apps (ADR-0012): each app's own serve answers its calls, as a child
  # started at the first call that names it.
  class WorkspaceServer
    # Claude Code names a plugin's tool mcp__plugin_<plugin>_<server>__<tool> and leaves out one over 128 characters.
    TOOL_NAME_LIMIT = 128 - "mcp__plugin_rails-ai-context_rails-ai-context__".size
    # Claude Code cuts a server's instructions at 4096 characters.
    INSTRUCTIONS_LIMIT = 4000
    # A resource of one app: rails-ai-context://apps/<app>/schema, rails-ai-context://apps/<app>/models/{name}.
    APP_URI = "rails-ai-context://apps/"

    # A tool as listed: the name the client calls, the app's own name for it, its definition, the apps it answers for.
    Listed = Struct.new(:name, :own_name, :definition, :apps)

    # The binary's own serve for one app: command.call(root) gives [env, argv].
    def self.start(target, command:)
      new(target, command: command).run($stdin, $stdout)
    end

    # What a version manager reads before the folder, such as rbenv's RBENV_DIR or the version asdf's exec chose.
    VERSION_PINS = %w[RBENV_DIR RBENV_VERSION ASDF_RUBY_VERSION MISE_RUBY_VERSION ASDF_INSTALL_TYPE ASDF_INSTALL_VERSION
                      ASDF_INSTALL_PATH __MISE_TASK_TOOL_ARGS].to_h { |name| [ name, nil ] }.freeze
    # This Ruby's gems and bundle, which another Ruby must not load: its native gems are built for this one.
    OWN_GEMS = %w[GEM_HOME GEM_PATH BUNDLE_GEMFILE BUNDLE_PATH BUNDLE_BIN_PATH BUNDLE_LOCKFILE BUNDLER_SETUP BUNDLER_VERSION RUBYLIB]
               .to_h { |name| [ name, nil ] }.freeze

    # An installed gem runs as the `ruby` on PATH in the app's folder, so a shim picks the app's Ruby; a checkout or a
    # bundle stays on this Ruby, which its load path and bundle were built for.
    def self.child_command(env, argv, root, environment, rubies = {})
      env = VERSION_PINS.merge(env)
      return [ env, [ *argv, "serve", "--app-path", root ] ] unless argv.include?("-e")

      dirs = environment["PATH"].to_s.split(File::PATH_SEPARATOR)
      path = without_picked_ruby(dirs).join(File::PATH_SEPARATOR)
      env = env.merge("PATH" => path) unless path == dirs.join(File::PATH_SEPARATOR)
      ruby = ChildServer.ruby(path)
      rubyopt = environment["RUBYOPT"].to_s.split.grep_v(%r{\A-r\S*bundler/setup\z}).join(" ")
      gemless = OWN_GEMS.merge("RUBYOPT" => (rubyopt unless rubyopt.empty?)).merge(env)
      env = gemless unless same_ruby?(ruby, gemless.merge("PATH" => path), root, environment, rubies)
      [ env, [ ruby, "-e", CHILD_START, "serve", "--app-path", root ] ]
    end

    # The managers' exec put the Ruby they picked, under versions/ or installs/, ahead of their shims; other dirs stay.
    def self.without_picked_ruby(dirs)
      first = dirs.index { |dir| File.basename(dir) == "shims" } or return dirs
      tops = dirs.select { |dir| File.basename(dir) == "shims" }.map { |dir| File.dirname(dir) }
      installs = tops.flat_map { |top| [ File.join(top, "versions", ""), File.join(top, "installs", "") ] }
      dirs.take(first).reject { |dir| installs.any? { |top| dir.start_with?(top) } } + dirs.drop(first)
    end

    # The files rbenv, asdf and mise read a Ruby's version from: in the folder and each parent, then the global ones.
    def self.version_files(root, environment)
      set = ->(name) { environment[name] unless environment[name].to_s.empty? }
      home = environment["HOME"].to_s
      tool_versions = set.("ASDF_DEFAULT_TOOL_VERSIONS_FILENAME") || ".tool-versions"
      mise = set.("MISE_CONFIG_DIR") || File.join(set.("XDG_CONFIG_HOME") || File.join(home, ".config"), "mise")
      globals = [ File.join(set.("RBENV_ROOT") || File.join(home, ".rbenv"), "version"), File.join(home, tool_versions),
                  *(set.("MISE_GLOBAL_CONFIG_FILE") || %w[config.toml mise.toml config.local.toml mise.local.toml].map { |name| File.join(mise, name) }) ]
      Pathname(root).ascend.flat_map { |dir| (VERSION_FILES | [ tool_versions ]).map { |name| dir.join(name).to_s } } + globals
    end

    VERSION_FILES = %w[.ruby-version .tool-versions .mise.toml mise.toml].freeze
    PROBE_SECONDS = 5
    RUBIES_LOCK = Mutex.new

    # A shim is a script, so the Ruby it runs in the app's folder says which it is, once per folder and version files.
    def self.same_ruby?(ruby, env, root, environment, rubies)
      own = File.realpath(RbConfig.ruby)
      return true if File.realpath(ruby) == own

      pinned = version_files(root, environment).map { |file| (File.read(file) rescue nil) }
      key = [ ruby, root, pinned ]
      said = RUBIES_LOCK.synchronize { rubies[key] }
      # Not kept when it said nothing, so a shim still installing the Ruby is asked again.
      said ||= ruby_run_by(ruby, env, root)&.tap { |found| RUBIES_LOCK.synchronize { rubies[key] = found } }
      said == own
    rescue SystemCallError
      false
    end

    def self.ruby_run_by(ruby, env, root)
      group = Gem.win_platform? ? { new_pgroup: true } : { pgroup: true }
      stdin, out, wait = Open3.popen2(env, ruby, "--disable-gems", "-rrbconfig", "-e", "print RbConfig.ruby", chdir: root, err: File::NULL, **group)
      stdin.close
      unless wait.join(PROBE_SECONDS)
        # The group, so an installer a shim started goes too.
        Process.kill("KILL", Gem.win_platform? ? wait.pid : -wait.pid)
        return nil
      end

      said = out.read
      File.realpath(said) if wait.value.success? && !said.empty?
    rescue SystemCallError, IOError
      nil
    ensure
      out&.close
    end

    # Where an app's server runs this Ruby but the nearest file that names a Ruby names another version, the line that says so.
    def self.version_note(root, ruby)
      return unless File.realpath(ruby) == File.realpath(RbConfig.ruby)

      file, named = Pathname(root).ascend.lazy.filter_map { |dir| ruby_named_in(dir) }.first
      plain = named.to_s.sub(/\Aruby-/, "").split("@").first.to_s
      return if !plain.match?(/\A\d[\w.]*\z/) || RUBY_VERSION == plain || RUBY_VERSION.start_with?("#{plain}.")

      CLI::Refusal.utf8("rails-ai-context: #{file} names Ruby #{plain}, but this app's server runs Ruby #{RUBY_VERSION}, the session's Ruby.")
    rescue StandardError
      # Advisory only: a version file it cannot read never stops the app's server.
      nil
    end

    # The file in dir that names a Ruby, and what it names: mise's own files, then .tool-versions, then .ruby-version.
    # A mise file whose tools name no Ruby is passed over: mise takes each tool from the nearest file that names it.
    def self.ruby_named_in(dir)
      { ".mise.toml" => :mise, "mise.toml" => :mise, ".tool-versions" => /^\s*ruby\s+(\S+)/, ".ruby-version" => /\A\s*(\S+)/ }.each do |name, how|
        file = dir.join(name)
        next unless file.file?

        text = File.binread(file)
        named = how == :mise ? mise_ruby(text) : text[how, 1]
        return [ file, named ] if named
      end
      nil
    end

    # A mise tool that is Ruby, under its own name or a backend's (`core:ruby`).
    MISE_RUBY = /\A(?:[\w-]+:)?ruby\z/

    # The version a mise file names, "" where it names a Ruby it cannot read (which stops the walk with no note), nil
    # where it names none.
    # shortcut: a line reader for [tools], [tools.<tool>], root `tools.` keys and an inline `tools = { }` on one line;
    # parse the TOML if a reported shape spans lines.
    def self.mise_ruby(text)
      section = nil
      named = nil
      text.each_line do |line|
        line = line.sub(/\A((?:[^"'#]|"(?:[^"\\]|\\.)*"|'[^']*')*)#.*/m, '\1').strip
        next if line.empty?

        if (header = line[/\A\[\[?([^\]]+)\]/, 1])
          section = header.delete("\"' ")
          named ||= "" if section.start_with?("tools.") && section.split(".")[1].to_s.match?(MISE_RUBY)
          next
        end
        relative = if section.nil? then line[/\Atools\s*([.=].*)/m, 1]
        elsif section == "tools" || section.start_with?("tools.") then "#{section.delete_prefix("tools")}.#{line}"
        end
        found = relative && mise_tool(relative)
        return found if found && !found.empty?

        named ||= found
      end
      named
    end

    # What one `tools` key says, relative to `tools` (".ruby = ...", "= { ... }"): the Ruby, "" where it names Ruby
    # unreadably, nil where it names no Ruby version.
    def self.mise_tool(relative)
      key, value = relative.split("=", 2)
      return nil unless value

      tool, *rest = key.delete("\"' \t").split(".").drop(1)
      if tool.nil?
        keys = value.scan(/[{,]\s*["']?([^"'=\s{},]+)["']?\s*=/).flatten
        return nil unless keys.any? { |name| name.match?(MISE_RUBY) }

        inline = value[/[{,]\s*["']?ruby["']?\s*=(.*)/, 1]
        return inline ? mise_version(inline) : ""
      end
      return nil unless tool.match?(MISE_RUBY)
      return "" unless tool == "ruby"
      return mise_version(value) if rest.empty?

      value[/\A\s*["']([^"']+)/, 1] || "" if rest == [ "version" ]
    end

    # A tool's version as mise writes it: "x", ["x", ...] or { version = "x", ... }.
    def self.mise_version(value)
      return value[/\A\s*\{[^}]*\bversion\s*=\s*["']([^"']+)/, 1] || "" if value.match?(/\A\s*\{/)

      value[/\A\s*\[?\s*["']([^"']+)/, 1] || ""
    end

    CHILD_START = 'begin; bin = Gem.activate_bin_path("rails-ai-context", "rails-ai-context", ">= 0"); ' \
                  'rescue Gem::LoadError, Gem::Exception; abort "#{RbConfig.ruby} (Ruby #{RUBY_VERSION}) has no rails-ai-context: ' \
                  'run `gem install rails-ai-context` with that Ruby in #{Dir.pwd}"; end; load bin'

    def initialize(target, command:)
      @apps = target.apps.to_h { |app| [ app.name, app.root ] }
      @base = target.resolution.cwd
      @command = command
      @children = {}
      @served = {}
      @versions = {}
      @notes = {}
      @assumed = {}
      @assumed_lock = Mutex.new
      @starting = {}
      @unsent = Set.new
      @stops = []
      @lock = Mutex.new
      @out = Monitor.new
    end

    def run(io_in, io_out)
      @io_out = io_out
      calls = []
      # The settings are read while the client is still introducing itself, so the first list waits on none.
      Thread.new { @apps.each_key { |app| assumed(app) } }.tap { |warm| warm.report_on_exception = false }
      io_in.each_line do |line|
        request = CLI::Refusal.parse(line) or next
        @initialized = true if request["method"] == "notifications/initialized"
        cancel(request) if request["method"] == "notifications/cancelled"
        next unless request.key?("id") && request.key?("method")

        # A call waits on its app's server, which may be booting; the rest of the session goes on meanwhile.
        if %w[tools/call resources/read].include?(request["method"])
          @lock.synchronize { @unsent << request["id"] }
          calls << Thread.new(request) { |asked| answered(asked) }
        else
          # Under the output lock, so a tool list goes out before any change to it is announced.
          @out.synchronize { reply(request, answer(request)) }
        end
      end
    ensure
      # A call still waiting past the grace ends with its server, a booting one too.
      join_within(calls, 5)
      children, stops = @lock.synchronize do
        @closed = true
        [ @children.values, @stops ]
      end
      children.map { |child| Thread.new { child.stop } }.each(&:join)
      stops.each(&:join)
      join_within(calls, 5)
    end

    private

    def join_within(threads, seconds)
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + seconds
      threads&.each { |thread| thread.join([ deadline - Process.clock_gettime(Process::CLOCK_MONOTONIC), 0 ].max) }
    end

    def write(message)
      @out.synchronize do
        @io_out.puts JSON.generate(message)
        @io_out.flush
      end
    rescue IOError, SystemCallError
      nil
    end

    def reply(request, answer)
      write({ "jsonrpc" => "2.0", "id" => request["id"] }.merge(answer))
    end

    def as_hash(value) = value.is_a?(Hash) ? value : {}

    # A call the client cancelled before it went to its app's server is dropped: it gets no answer.
    def cancel(request)
      id = as_hash(request["params"])["requestId"]
      @lock.synchronize { @unsent.delete(id) }
    end

    def answered(request)
      answer = routed(request)
      reply(request, answer) if answer
    ensure
      @lock.synchronize { @unsent.delete(request["id"]) }
    end

    # True once, for a call still to be sent; false for one that was cancelled.
    def claim(request)
      @lock.synchronize { @unsent.delete?(request["id"]) }
    end

    def answer(request)
      case request["method"]
      when "initialize"
        CLI::Refusal.welcome(request["params"], instructions, capabilities: { "tools" => { "listChanged" => true }, "resources" => { "listChanged" => true } },
                                                              version: VERSION)
      when "tools/list"
        tools = listing.map { |listed| entry(listed) }
        @announced = tools
        { "result" => { "tools" => tools } }
      when "resources/list" then { "result" => { "resources" => resources } }
      when "resources/templates/list" then { "result" => { "resourceTemplates" => templates } }
      when "ping" then { "result" => {} }
      else { "error" => { "code" => -32_601, "message" => "Method not found: #{request["method"]}" } }
      end
    end

    # The first apps that fit, then how many more: each tool's `app` lists them all.
    def instructions
      head = "Serving #{@apps.size} Rails apps from #{@base}: "
      tail = ". Every tool takes `app`, the name of the app to answer for; file paths in its answers are relative to " \
             "that app's folder. A resource names the app in its URI: #{APP_URI}<app>/schema."
      named = []
      @apps.each do |name, root|
        item = "#{name} (#{CLI::AppRoot.display(root, @base)}/)"
        break if (head + named.join(", ") + item + tail).size + 80 > INSTRUCTIONS_LIMIT

        named << item
      end
      more = @apps.size - named.size
      CLI::Refusal.utf8(head + named.join(", ") + (more.positive? ? ", and #{more} more, which each tool's `app` lists" : "") + tail)
    end

    def defaults
      @defaults ||= Server.active_tools(RailsAiContext.configuration).to_h do |tool|
        listed = JSON.parse(JSON.generate(tool.to_h))
        [ listed["name"], listed ]
      end
    end

    # What the app's settings, read without a boot, say its server serves: its tools and the `config` they read.
    # `settled` is false where skip_tools cannot be read, so any tool may be off.
    Assumed = Struct.new(:tools, :config, :settled)

    # Under a lock: the warm thread and the first list would each read the same app's settings.
    def assumed(app)
      @assumed_lock.synchronize do
        @assumed[app] ||= begin
          read = UnbootedSettings.read(@apps[app])
          tools = defaults.slice(*read.routed_tool_names)
          Assumed.new(with_own_sections(tools, read.config), read.config, read.skip_tools_refusal.nil?)
        rescue StandardError
          Assumed.new(defaults, nil, false)
        end
      end
    end

    # rails_get_config lists the sections the app leaves on, as its own server does.
    def with_own_sections(tools, config)
      return tools unless tools.key?("rails_get_config") && Server.served_tool("rails_get_config", config).equal?(Tools::GetConfig)

      sections = Tools::GetConfig.sections_on(config)
      schema = JSON.parse(JSON.generate(MCP::Tool::InputSchema.new(Tools::GetConfig.schema_for(sections)).to_h))
      tools.merge("rails_get_config" => tools["rails_get_config"].merge("inputSchema" => schema, "description" => Tools::GetConfig.description_for(sections)))
    end

    # Apps whose tool takes the same arguments share one entry; an app whose copy takes others gets one named for it.
    def listing
      served = @apps.keys.to_h { |app| [ app, @lock.synchronize { @served[app] } || assumed(app).tools ] }
      by_name = Hash.new { |groups, name| groups[name] = {} }
      served.each do |app, tools|
        tools.each_value { |tool| (by_name[tool["name"]][tool["inputSchema"]] ||= [ tool, [] ]).last << app }
      end
      by_name.flat_map do |name, groups|
        primary = defaults.key?(name) && groups.key?(defaults[name]["inputSchema"]) ? defaults[name]["inputSchema"] : groups.max_by { |_, (_, apps)| apps.size }.first
        groups.flat_map do |schema, (tool, apps)|
          next [ Listed.new(fitted(name), name, tool, apps) ] if schema == primary

          apps.map { |app| Listed.new(fitted("#{name}_#{app}"), name, tool, [ app ]) }
        end
      end
    end

    def fitted(name)
      name.size <= TOOL_NAME_LIMIT ? name : "#{name[0, TOOL_NAME_LIMIT - 9]}_#{Digest::SHA256.hexdigest(name)[0, 8]}"
    end

    def entry(listed)
      tool = JSON.parse(JSON.generate(listed.definition))
      tool["name"] = listed.name
      tool["description"] = "For the app #{listed.apps.first}: #{tool["description"]}" if listed.name != fitted(listed.own_name)
      schema = tool["inputSchema"] = as_hash(tool["inputSchema"]).merge("type" => "object")
      schema["properties"] = { "app" => { "type" => "string", "enum" => listed.apps, "description" => "The Rails app to answer for." } }
                             .merge(as_hash(schema["properties"]))
      schema["required"] = [ "app", *schema["required"] ].uniq
      tool
    end

    # A changed list goes to a client that has read one, which then reads it again.
    def announce
      tools = listing.map { |listed| entry(listed) }
      @out.synchronize do
        return if @announced.nil? || tools == @announced

        @announced = tools
      end
      write({ "jsonrpc" => "2.0", "method" => "notifications/tools/list_changed" }) if @initialized
    end

    def routed(request)
      request["method"] == "tools/call" ? call(request) : read(request)
    rescue StandardError => e
      text = "rails-ai-context could not route this request: #{e.class}: #{CLI::Refusal.utf8(e.message)}"
      request["method"] == "tools/call" ? tool_error(text) : { "error" => { "code" => -32_603, "message" => text } }
    end

    def call(request)
      params = as_hash(request["params"])
      arguments = as_hash(params["arguments"]).dup
      app = arguments.delete("app")
      unless @apps.key?(app)
        return tool_error("`app` names the Rails app to answer for, one of: #{@apps.keys.join(", ")}. " \
                          "#{app.nil? ? "This call names none" : "#{app.to_s.inspect} is none of them"}.")
      end

      # What the app's settings already say it does not serve is answered without starting its server.
      refusal = unserved(app, params, arguments)
      return tool_error(refusal) if refusal
      return unless @lock.synchronize { @unsent.include?(request["id"]) }

      child = child_for(app)
      refusal = unserved(app, params, arguments)
      return tool_error(refusal) if refusal
      return unless claim(request)

      answer = child.request("tools/call", params.merge("name" => own_name(params), "arguments" => arguments))
      return { "error" => answer["error"] } if answer.key?("error")

      result = answer["result"]
      note = @lock.synchronize { @notes[app].tap { |said| @notes[app] = false if said } } if result.is_a?(Hash)
      result = result.merge("content" => [ { "type" => "text", "text" => note }, *Array(result["content"]) ]) if note
      { "result" => result }
    rescue ChildServer::Gone => e
      forget(app, child)
      tool_error(stopped(app, e))
    end

    def own_name(params)
      listing.find { |listed| listed.name == params["name"] }&.own_name || params["name"].to_s
    end

    # Why the app's server does not answer this call, or nil. Before its server starts, only what its settings settle.
    def unserved(app, params, arguments)
      real = own_name(params)
      started = @lock.synchronize { @served[app] }
      settled = started || (assumed(app).settled && defaults.key?(real))
      tools = listing
      if settled && tools.none? { |tool| tool.name == params["name"] && tool.apps.include?(app) }
        other = tools.find { |tool| tool.own_name == real && tool.apps.include?(app) }
        return "For the app #{app}, call `#{other.name}`, which takes that app's own arguments." if other

        return not_served(app, real)
      end
      section_refusal(app, real, arguments)
    end

    def not_served(app, real)
      version = @versions[app]
      about = "The app #{app} (#{CLI::Refusal.utf8(@apps[app])})"
      return "#{about} does not serve #{real}: its skip_tools may turn it off." unless version

      "#{about} runs rails-ai-context #{version}, whose server does not serve #{real}: the app's skip_tools may turn it off, or that release lacks it."
    end

    # A section the app's settings turn off is refused as its own server would, before that server starts.
    def section_refusal(app, real, arguments)
      config = assumed(app).config
      return unless real == "rails_get_config" && config && assumed(app).tools["rails_get_config"] && assumed(app).settled

      section = Tools::GetConfig.section_named(arguments["section"].nil? ? "app" : arguments["section"].to_s)
      return if section.nil? || section.on?(config)

      "#{section.off_message} The sections that are on: #{Tools::GetConfig.sections_on(config).map(&:name).join(", ")}."
    end

    def read(request)
      params = as_hash(request["params"])
      uri = params["uri"].to_s
      app, rest = uri.delete_prefix(APP_URI).split("/", 2) if uri.start_with?(APP_URI)
      unless @apps.key?(app) && rest
        return { "error" => { "code" => -32_602, "message" => "Resource not found: #{uri}. Each app's resources are #{APP_URI}<app>/...",
                              "data" => { "uri" => uri, "available" => @apps.keys.map { |name| "#{APP_URI}#{name}/schema" } } } }
      end

      own = Resources::STATIC_RESOURCES.key?("rails://#{rest}") ? "rails://#{rest}" : "rails-ai-context://#{rest}"
      return unless @lock.synchronize { @unsent.include?(request["id"]) }

      child = child_for(app)
      return unless claim(request)

      answer = child.request("resources/read", params.merge("uri" => own))
      return { "error" => answer["error"] } if answer.key?("error")

      result = as_hash(answer["result"])
      contents = Array(result["contents"]).map { |content| content.is_a?(Hash) && content["uri"] == own ? content.merge("uri" => uri) : content }
      { "result" => result.merge("contents" => contents) }
    rescue ChildServer::Gone => e
      forget(app, child)
      { "error" => { "code" => -32_603, "message" => stopped(app, e) } }
    end

    def resources
      @apps.keys.flat_map do |app|
        Resources::STATIC_RESOURCES.map do |uri, meta|
          { "uri" => app_uri(app, uri), "name" => "#{meta[:name]} (#{app})", "description" => meta[:description], "mimeType" => meta[:mime_type] }
        end
      end
    end

    def templates
      Resources.resource_templates.map do |template|
        listed = JSON.parse(JSON.generate(template.to_h))
        listed.merge("uriTemplate" => app_uri("{app}", listed["uriTemplate"]), "description" => "#{listed["description"]}, in the app {app} names")
      end
    end

    def app_uri(app, uri) = "#{APP_URI}#{app}/#{uri.sub(%r{\A[a-z-]+://}, "")}"

    def stopped(app, error)
      "The server for the app #{app} (#{CLI::Refusal.utf8(@apps[app])}) stopped before it answered: #{CLI::Refusal.utf8(error.message)}. " \
        "The next call for it starts it again."
    end

    def tool_error(text)
      { "result" => { "content" => [ { "type" => "text", "text" => CLI::Refusal.utf8(text) } ], "isError" => true } }
    end

    # A server that stopped answering is stopped for good, after its call is answered, and the app's next call starts another.
    def forget(app, child)
      return unless child

      queued = @lock.synchronize do
        @children.delete(app) if @children[app].equal?(child)
        next false if @closed

        @stops << Thread.new { child.stop }
        true
      end
      child.stop unless queued
    end

    # The router holds no session of its own with the client for an app's server to ask through; a ping needs none.
    def refuse_request(child, message)
      reply = if message["method"] == "ping"
        { "result" => {} }
      else
        { "error" => { "code" => -32_601, "message" => "Method not found: #{message["method"]}; the router relays no requests from an app's server to the client" } }
      end
      child.write(JSON.generate({ "jsonrpc" => "2.0", "id" => message["id"] }.merge(reply)))
    rescue ChildServer::Gone
      nil
    end

    # Finding the app's Ruby can take seconds, and the lists and other apps go on meanwhile.
    def start(app)
      Thread.current.report_on_exception = false
      env, argv = @command.call(@apps[app])
      note = self.class.version_note(@apps[app], argv.first.to_s)
      @lock.synchronize do
        raise ChildServer::Gone, "the session ended" if @closed

        @notes[app] = note if @notes[app].nil?
        # Live reload's change goes on; its log line reaches this process's log on the child's stderr.
        relay = lambda do |_line, message, child|
          if message.key?("id") && message.key?("method")
            refuse_request(child, message)
          elsif message["method"] == "notifications/resources/list_changed" && @initialized
            write(message.slice("jsonrpc", "method"))
          end
        end
        @children[app] = ChildServer.new(env.merge("RAILS_AI_CONTEXT_PLUGIN" => nil), argv, chdir: @apps[app], &relay)
      end
    ensure
      @lock.synchronize { @starting.delete(app) if @starting[app].equal?(Thread.current) }
    end

    # The app's server, started and introduced once; its own tool list replaces what was assumed for the app.
    def child_for(app)
      child, starting = @lock.synchronize do
        raise ChildServer::Gone, "the session ended" if @closed

        [ @children[app], @children[app] ? nil : (@starting[app] ||= Thread.new { start(app) }) ]
      end
      # One start per app, outside the router's lock; every call that waited on it gets its outcome.
      child ||= starting.value
      child.once do
        hello = child.request("initialize", { "protocolVersion" => "2025-06-18", "capabilities" => {},
                                              "clientInfo" => { "name" => "rails-ai-context-workspace", "version" => VERSION } })
        raise ChildServer::Gone, hello.dig("error", "message").to_s if hello.key?("error")

        child.notify("notifications/initialized")
        tools = Array(child.request("tools/list", {}).dig("result", "tools")).select { |tool| tool.is_a?(Hash) && tool["name"].is_a?(String) }
        @lock.synchronize do
          @versions[app] = hello.dig("result", "serverInfo", "version")
          @served[app] = tools.to_h { |tool| [ tool["name"], tool ] }
        end
        announce
      end
      child
    rescue ChildServer::Gone
      forget(app, child)
      raise
    end
  end
end
