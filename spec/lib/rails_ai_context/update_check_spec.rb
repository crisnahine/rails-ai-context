# frozen_string_literal: true

require "spec_helper"

RSpec.describe RailsAiContext::UpdateCheck do
  let(:dir) { Dir.mktmpdir }
  let(:state) { File.join(dir, "state", "rails-ai-context", "latest") }

  before do
    described_class.instance_variable_set(:@enabled, true)
    described_class.instance_variable_set(:@newest_at_start, nil)
    allow(described_class).to receive_messages(state_file: state, ci?: false, newest_installed: nil)
    stub_const("ENV", ENV.to_h.merge(described_class::OPT_OUT_ENV => nil))
    stub_const("RailsAiContext::VERSION", "5.36.3")
  end

  after do
    described_class.remove_instance_variable(:@enabled)
    described_class.remove_instance_variable(:@newest_at_start)
    described_class.remove_instance_variable(:@gem_dirs) if described_class.instance_variable_defined?(:@gem_dirs)
    FileUtils.rm_rf(dir)
  end

  def write_latest(text)
    FileUtils.mkdir_p(File.dirname(state))
    File.binwrite(state, text)
  end

  # Serves one answer per connection until the example ends.
  def serve(body, status: "200 OK")
    server = TCPServer.new("127.0.0.1", 0)
    Thread.new do
      loop do
        client = server.accept
        client.gets("\r\n\r\n")
        client.write("HTTP/1.1 #{status}\r\nContent-Type: application/json\r\nContent-Length: #{body.bytesize}\r\nConnection: close\r\n\r\n#{body}")
        client.close
      rescue IOError, SystemCallError
        break
      end
    end
    stub_const("#{described_class}::URL", "http://127.0.0.1:#{server.addr[1]}/api/v1/versions/rails-ai-context/latest.json")
    server
  end

  def wait_for(path)
    deadline = Time.now + 15
    sleep 0.05 until File.size?(path) || Time.now > deadline
    File.read(path)
  end

  describe ".notice" do
    it "names the newer release, the Ruby to update under and the opt-out" do
      write_latest("5.37.0")
      note = described_class.notice
      expect(note).to include("rails-ai-context 5.37.0 is out; this is 5.36.3 on Ruby #{RUBY_VERSION} (#{RbConfig.ruby})")
      expect(note).to include("`gem update rails-ai-context`", "`rails-ai-context init --defaults`", "RAILS_AI_CONTEXT_NO_UPDATE_CHECK=1")
    end

    it "says nothing when the running copy is the latest or newer" do
      write_latest("5.36.3")
      expect(described_class.notice).to be_nil
      write_latest("5.36.2")
      expect(described_class.notice).to be_nil
    end

    it "says nothing before a fetch wrote a version, or when it wrote something else" do
      expect(described_class.notice).to be_nil
      [ "", "unknown", "5.37.0.rc1", "<html>" ].each do |text|
        write_latest(text)
        expect(described_class.notice).to be_nil, text.inspect
      end
    end

    it "asks for a restart when the newer release was installed after this process started" do
      write_latest("5.37.0")
      described_class.instance_variable_set(:@newest_at_start, Gem::Version.new("5.36.3"))
      allow(described_class).to receive(:newest_installed).and_return(Gem::Version.new("5.37.0"))
      expect(described_class.notice).to eq(
        "rails-ai-context 5.37.0 is installed, but this process still runs 5.36.3. Restart the MCP server (or the AI client) to load it."
      )
    end

    it "asks for the update when the copy installed since is still older than the latest" do
      write_latest("5.37.0")
      described_class.instance_variable_set(:@newest_at_start, Gem::Version.new("5.36.3"))
      allow(described_class).to receive(:newest_installed).and_return(Gem::Version.new("5.36.5"))
      expect(described_class.notice).to start_with("rails-ai-context 5.37.0 is out; this is 5.36.3")
    end

    it "says nothing, and raises nothing, for a state file that is not text or no home to find it in" do
      write_latest("\xFF\xFE5.99.0".b)
      expect(described_class.notice).to be_nil
      allow(described_class).to receive(:state_file).and_raise(ArgumentError, "couldn't find login name")
      expect(described_class.notice).to be_nil
      allow(described_class).to receive(:state_file).and_return(state)
      FileUtils.rm_rf(File.dirname(state))
      FileUtils.mkdir_p(state)
      expect(described_class.notice).to be_nil
    end

    it "says nothing to an older copy run on purpose while a newer one was installed" do
      write_latest("5.37.0")
      described_class.instance_variable_set(:@newest_at_start, Gem::Version.new("5.37.0"))
      expect(described_class.notice).to be_nil
    end

    it "is off outside the standalone binary, with the opt-out, in CI and on a prerelease" do
      write_latest("5.37.0")
      described_class.instance_variable_set(:@enabled, nil)
      expect(described_class.notice).to be_nil
      described_class.instance_variable_set(:@enabled, true)

      ENV[described_class::OPT_OUT_ENV] = "1"
      expect(described_class.notice).to be_nil
      ENV[described_class::OPT_OUT_ENV] = nil

      allow(described_class).to receive(:ci?).and_return(true)
      expect(described_class.notice).to be_nil
      allow(described_class).to receive(:ci?).and_return(false)

      stub_const("RailsAiContext::VERSION", "5.37.0.beta1")
      expect(described_class.notice).to be_nil
    end
  end

  describe ".refresh" do
    it "fetches the latest version in a child and writes it for the next check" do
      server = serve(%({"version":"5.40.1"}))
      described_class.refresh(env: ENV.to_h)
      expect(wait_for(state)).to eq("5.40.1")
      expect(described_class.latest_release).to eq(Gem::Version.new("5.40.1"))
    ensure
      server&.close
    end

    it "returns at once, keeps the child off this process's stdio, and the child gives up on a silent server" do
      server = TCPServer.new("127.0.0.1", 0)
      stub_const("#{described_class}::URL", "http://127.0.0.1:#{server.addr[1]}/latest.json")
      expect(Process).to receive(:spawn).with(
        hash_including("HOME"), RbConfig.ruby, "-e", described_class::FETCH, state, described_class::URL,
        hash_including(unsetenv_others: true, in: File::NULL, out: File::NULL, err: File::NULL,
                       **(Gem.win_platform? ? { new_pgroup: true } : { pgroup: true }))
      ).and_call_original
      started = Time.now
      waiter = described_class.refresh(env: ENV.to_h)
      expect(Time.now - started).to be < 3
      expect(waiter.join(15)).to be_truthy
      expect(File.read(state)).to eq("")
      expect(Dir[File.join(File.dirname(state), "*")]).to eq([ state ])
    ensure
      server&.close
    end

    it "fetches again when the last fetch is dated in the future" do
      write_latest("5.36.3")
      File.utime(Time.now + 3600, Time.now + 3600, state)
      expect(Process).to receive(:spawn).and_return(Process.spawn(RbConfig.ruby, "-e", "0"))
      described_class.refresh(env: ENV.to_h)
      expect(File.mtime(state)).to be_within(60).of(Time.now)
    end

    it "starts no fetch within a day of the last one" do
      write_latest("5.36.3")
      expect(Process).not_to receive(:spawn)
      described_class.refresh(env: ENV.to_h)
    end

    it "fetches again after a day, and a failed fetch keeps the old answer and waits another day" do
      write_latest("5.36.3")
      File.utime(Time.now - described_class::INTERVAL - 60, Time.now - described_class::INTERVAL - 60, state)
      server = serve("oops", status: "500 Internal Server Error")
      expect(described_class.refresh(env: ENV.to_h).join(15)).to be_truthy
      expect(File.read(state)).to eq("5.36.3")
      expect(Time.now - File.mtime(state)).to be < 60
      expect(Process).not_to receive(:spawn)
      described_class.refresh(env: ENV.to_h)
    ensure
      server&.close
    end

    it "leaves no temporary file behind when the answer cannot be put in place" do
      server = serve(%({"version":"5.40.1"}))
      FileUtils.mkdir_p(File.join(state, "taken"))
      system(RbConfig.ruby, "-e", described_class::FETCH, state, described_class::URL, err: File::NULL)
      expect(Dir[File.join(File.dirname(state), "*")]).to eq([ state ])
    ensure
      server&.close
    end

    it "does nothing when the check is off" do
      ENV[described_class::OPT_OUT_ENV] = "1"
      expect(Process).not_to receive(:spawn)
      described_class.refresh(env: ENV.to_h)
      expect(File.exist?(state)).to be(false)
    end

    it "swallows a home it cannot write" do
      File.write(File.join(dir, "file"), "")
      allow(described_class).to receive(:state_file).and_return(File.join(dir, "file", "rails-ai-context", "latest"))
      expect { described_class.refresh(env: ENV.to_h) }.not_to raise_error
    end
  end

  describe ".enable!" do
    it "keeps the gem path and the newest copy it had before an app's boot replaces them" do
      allow(described_class).to receive(:newest_installed).and_call_original
      described_class.remove_instance_variable(:@newest_at_start)
      described_class.enable!
      expect(described_class.instance_variable_get(:@gem_dirs)).to eq(Gem.path)
      expect(described_class.instance_variable_defined?(:@newest_at_start)).to be(true)
    end
  end

  describe "where the notice shows" do
    before { write_latest("5.37.0") }

    after { described_class.remove_instance_variable(:@told) if described_class.instance_variable_defined?(:@told) }

    it "is in the MCP server's instructions for the agent to pass on" do
      expect(RailsAiContext::Server.instructions).to end_with("Tell the user: #{described_class.notice}")
    end

    it "ends rails_onboard, and the CLI does not print it a second time" do
      text = RailsAiContext::Tools::Onboard.call(detail: "summary").content.first[:text]
      expect(text).to end_with("Tell the user: #{described_class.notice}").or include("Tell the user: #{described_class.notice}\n")
      expect(described_class.told?).to be(true)
    end

    describe "on the command line" do
      # The child runs the real VERSION over an empty gem path: no installed copy can look newer than 999.0.0.
      before { write_latest("999.0.0") }

      let(:exe) { File.expand_path("../../../exe/rails-ai-context", __dir__) }
      let(:lib) { File.expand_path("../../../lib", __dir__) }
      # Outside bundler, whose setup sets BUNDLE_BIN_PATH, and outside any CI the runner announces.
      let(:env) do
        ci = defined?(Gem::CIDetector::ENV_INDICATORS) ? Gem::CIDetector::ENV_INDICATORS : %w[CI]
        { "XDG_STATE_HOME" => File.join(dir, "state"), "GEM_HOME" => dir, "GEM_PATH" => dir, described_class::OPT_OUT_ENV => nil }
          .merge((%w[RUBYOPT RUBYLIB BUNDLE_GEMFILE BUNDLE_LOCKFILE BUNDLE_BIN_PATH BUNDLER_SETUP BUNDLER_VERSION] + ci).to_h { |name| [ name, nil ] })
      end
      let(:thor) { Gem.loaded_specs.fetch("thor").full_require_paths.first }

      def run_on_terminal(extra = {})
        require "pty"
        reader, _writer, pid = PTY.spawn(env.merge(extra), RbConfig.ruby, "-I", lib, "-I", thor, exe, "version")
        out = +""
        begin
          loop { out << reader.readpartial(4096) }
        rescue Errno::EIO, EOFError
          nil
        end
        Process.wait(pid)
        out
      end

      it "prints one line on a terminal, from the standalone binary only" do
        skip "no PTY on Windows" if Gem.win_platform?
        expect(run_on_terminal).to include("rails-ai-context 999.0.0 is out")
        expect(run_on_terminal("BUNDLE_BIN_PATH" => "/the/bundle/exe/bundle")).not_to include("is out")
      end

      it "prints nothing when stderr is not a terminal" do
        _out, err, status = Open3.capture3(env, RbConfig.ruby, "-I", lib, "-I", thor, exe, "version")
        expect(status).to be_success
        expect(err).not_to include("is out")
      end
    end
  end

  describe ".newest_installed" do
    it "reads every directory of the gem path it started with and ignores other gems' specs" do
      allow(described_class).to receive(:newest_installed).and_call_original
      home, global = %w[home global].map { |name| File.join(dir, name, "specifications").tap { |d| FileUtils.mkdir_p(d) } }
      %w[rails-ai-context-5.36.3 rails-ai-context-extras-9.0].each { |name| File.write(File.join(home, "#{name}.gemspec"), "") }
      File.write(File.join(global, "rails-ai-context-5.37.0.gemspec"), "")

      described_class.instance_variable_set(:@gem_dirs, [ File.dirname(home), File.dirname(global) ])
      expect(described_class.newest_installed).to eq(Gem::Version.new("5.37.0"))
      described_class.instance_variable_set(:@gem_dirs, [ File.dirname(home) ])
      expect(described_class.newest_installed).to eq(Gem::Version.new("5.36.3"))
      described_class.instance_variable_set(:@gem_dirs, [ dir ])
      expect(described_class.newest_installed).to be_nil
    end
  end

  it "loads no gem, so the binary can load it before the app's bundle" do
    file = File.expand_path("../../../lib/rails_ai_context/update_check.rb", __dir__)
    out, status = Open3.capture2e(RbConfig.ruby, "-e", <<~RUBY, file)
      specs = Gem.loaded_specs.keys
      features = $LOADED_FEATURES.dup
      require ARGV[0]
      print((Gem.loaded_specs.keys - specs).join(","), "|", ($LOADED_FEATURES - features).grep(%r{/(json|net/http|fileutils)}).join(","))
    RUBY
    expect(status).to be_success, out
    expect(out).to eq("|")
  end
end
