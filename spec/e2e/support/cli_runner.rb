# frozen_string_literal: true

module E2E
  # Runs CLI commands against a TestAppBuilder-produced app and returns
  # a structured result (stdout, stderr, exit status). Never raises on
  # non-zero exit — callers assert what they care about.
  class CliRunner
    Result = Struct.new(:command, :stdout, :stderr, :status, keyword_init: true) do
      def success? = status.success?
      def exit_status = status.exitstatus
      def output = "#{stdout}\n#{stderr}"
      def to_s
        "[#{command.inspect}] exit=#{exit_status}\nstdout:\n#{stdout}\nstderr:\n#{stderr}"
      end
    end

    def initialize(app_builder)
      @app = app_builder
    end

    # Run `rails ai:tool[name]` via bin/rails (in-Gemfile path).
    def rake_tool(tool_name, params = {})
      param_str = params.map { |k, v| "#{k}=#{v}" }.join(" ")
      cmd = [ "bin/rails", "ai:tool[#{tool_name}]" ]
      cmd << param_str unless param_str.empty?
      run(cmd)
    end

    # Run `rails-ai-context tool <name>` via the CLI binary.
    # Honors the isolated GEM_HOME in standalone/zero_config paths.
    # For in-Gemfile path, uses `bundle exec` because Bundler does not
    # auto-generate `bin/rails-ai-context` binstubs.
    def cli_tool(tool_name, args = [], timeout: 60)
      run(cli_prefix + [ "tool", tool_name, *args ], timeout: timeout)
    end

    # Run `rails-ai-context <subcommand>` (init, doctor, context, version, ...)
    def cli(*args)
      run(cli_prefix + args)
    end

    private

    def cli_prefix
      if @app.isolated_gem_home?
        [ File.join(@app.gem_home, "bin", "rails-ai-context") ]
      else
        [ "bundle", "exec", "rails-ai-context" ]
      end
    end

    public

    # Run a raw command inside the app with the merged env.
    # Pass `stdin_input:` to feed data to the subprocess's stdin.
    def run(cmd, extra_env: {}, timeout: 60, stdin_input: nil)
      env = @app.env.merge(extra_env.compact)
      stdout = ""
      stderr = ""
      status = nil
      Open3.popen3(env, *cmd, chdir: @app.app_path) do |stdin_io, stdout_io, stderr_io, wait_thr|
        begin
          if stdin_input
            stdin_io.write(stdin_input)
            stdin_io.close
          else
            stdin_io.close
          end
          Timeout.timeout(timeout) do
            t_out = Thread.new { stdout = stdout_io.read }
            t_err = Thread.new { stderr = stderr_io.read }
            t_out.join
            t_err.join
            status = wait_thr.value
          end
        rescue Timeout::Error
          Process.kill("KILL", wait_thr.pid) rescue nil
          status = wait_thr.value
          stderr += "\n[E2E: process killed after #{timeout}s timeout]"
        end
      end
      Result.new(command: cmd, stdout: stdout, stderr: stderr, status: status)
    end
  end
end
