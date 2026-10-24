# frozen_string_literal: true

require "rbconfig"
require_relative "version"

module RailsAiContext
  # Tells the copy `gem install` put on PATH that rubygems.org has a newer
  # release. Only the gem's own binary, run outside a bundle, turns it on
  # (enable!), so a copy an app's bundle loads never checks: its lockfile
  # decides the version.
  #
  # Core Ruby only. The binary loads this before the app boots, and requiring
  # net/http or json here would activate the newest installed versions over
  # the ones the app's lock pins. The fetch runs in a detached child instead,
  # at most once a day, and the version it writes is what the next check reads.
  module UpdateCheck
    OPT_OUT_ENV = "RAILS_AI_CONTEXT_NO_UPDATE_CHECK"
    URL = "https://rubygems.org/api/v1/versions/rails-ai-context/latest.json"
    INTERVAL = 24 * 60 * 60

    FETCH = <<~RUBY
      require "net/http"
      path, url = ARGV
      uri = URI(url)
      response = Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == "https", open_timeout: 5, read_timeout: 5) do |http|
        http.get(uri.request_uri)
      end
      version = response.body[/"version"\\s*:\\s*"([^"]+)"/, 1] if response.is_a?(Net::HTTPSuccess)
      exit unless version
      tmp = "\#{path}.\#{Process.pid}"
      begin
        File.write(tmp, version)
        File.rename(tmp, path)
      ensure
        File.delete(tmp) if File.exist?(tmp)
      end
    RUBY

    module_function

    # Called before an app's boot, which swaps Gem.path for the bundle's.
    def enable!
      @enabled = true
      @gem_dirs = Gem.path
      newest_at_start
    end

    # The notice for an agent to pass on. Giving it marks it told, so the CLI does not print it again.
    def agent_note
      note = notice or return
      @told = true
      "Tell the user: #{note}"
    end

    def told?
      @told == true
    end

    def disabled?
      !@enabled || @pinned || !ENV[OPT_OUT_ENV].to_s.empty? || ci? || Gem::Version.new(VERSION).prerelease?
    end

    # The app this run reads pins the gem in its lockfile, which decides its version.
    def pinned!
      @pinned = true
    end

    # Starts the fetch when the last one is a day old (or in the future, after a
    # clock change). The file's time is set first, so a failed fetch waits a day
    # too. Its own process group keeps a Ctrl-C at the terminal from killing it.
    # @param env [Hash] the environment the binary started in, before an app's boot changed it
    def refresh(env:)
      return if disabled?

      path = state_file
      age = Time.now - File.mtime(path) if File.exist?(path)
      return if age&.between?(0, INTERVAL)

      make_dirs(File.dirname(path))
      File.open(path, "a") { nil }
      File.utime(nil, nil, path)
      group = Gem.win_platform? ? { new_pgroup: true } : { pgroup: true }
      pid = Process.spawn(env, RbConfig.ruby, "-e", FETCH, path, URL,
                          unsetenv_others: true, in: File::NULL, out: File::NULL, err: File::NULL, **group)
      Process.detach(pid)
    rescue StandardError
      nil
    end

    # One sentence for the user, or nil when this copy is current.
    def notice
      return if disabled?

      latest = latest_release or return
      running = Gem::Version.new(VERSION)
      return unless latest > running
      # A newer copy installed when this process started means an older one was run on purpose (`_5.30.0_`).
      return if newest_at_start && newest_at_start > running

      installed = newest_installed
      plugin = plugin_server?
      if installed && installed >= latest
        restart = plugin ? "Reconnect the server in /mcp (or start a new session)" : "Restart the MCP server (or the AI client)"
        "rails-ai-context #{installed} is installed, but this process still runs #{VERSION}. #{restart} to load it."
      else
        # A plugin's server needs no init, which would add a second server beside it.
        after = plugin ? "reconnect the server in /mcp (or start a new session)" : "`rails-ai-context init --defaults` in each app"
        "rails-ai-context #{latest} is out; this is #{VERSION} on Ruby #{RUBY_VERSION} (#{RbConfig.ruby}). " \
          "Under that Ruby run `gem update rails-ai-context`, then #{after}. " \
          "#{OPT_OUT_ENV}=1 turns this check off."
      end
    end

    # Claude Code sets this for every MCP server a plugin starts.
    def plugin_server?
      !ENV["CLAUDE_PLUGIN_ROOT"].to_s.empty?
    end

    def latest_release
      text = File.read(state_file, 64).to_s.strip
      return if text.empty? || !Gem::Version.correct?(text)

      version = Gem::Version.new(text)
      version unless version.prerelease?
    rescue StandardError
      nil
    end

    def state_file
      home = Gem.respond_to?(:state_home) ? Gem.state_home : (ENV["XDG_STATE_HOME"] || File.join(Gem.user_home, ".local", "state"))
      File.join(home, "rails-ai-context", "latest")
    end

    # The newest copy installed for this Ruby, in any directory of the gem path.
    def newest_installed
      Array(@gem_dirs).flat_map { |dir| Dir.glob("specifications/rails-ai-context-*.gemspec", base: dir) }.filter_map do |spec|
        number = File.basename(spec, ".gemspec").delete_prefix("rails-ai-context-")
        Gem::Version.new(number) if Gem::Version.correct?(number)
      end.max
    end

    def newest_at_start
      return @newest_at_start if defined?(@newest_at_start)

      @newest_at_start = newest_installed
    end

    def ci?
      defined?(Gem::CIDetector) ? Gem::CIDetector.ci? : !ENV["CI"].to_s.empty?
    end

    # Dir.mkdir one level at a time: fileutils is a gem an app may pin.
    def make_dirs(dir)
      return if Dir.exist?(dir)

      make_dirs(File.dirname(dir))
      Dir.mkdir(dir)
    rescue Errno::EEXIST
      nil
    end
  end
end
