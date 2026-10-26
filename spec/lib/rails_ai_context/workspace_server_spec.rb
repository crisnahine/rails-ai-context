# frozen_string_literal: true

require "spec_helper"
require "json"
require "stringio"
require "tmpdir"
require "fileutils"
require "rbconfig"
require "timeout"

RSpec.describe RailsAiContext::WorkspaceServer do
  before { skip "on Windows the plugin serves one app per session" if Gem.win_platform? }

  let(:repo) { File.expand_path("../../..", __dir__) }

  around do |example|
    # Each app's server logs to this one's stderr.
    log, $stderr = $stderr, StringIO.new
    Dir.mktmpdir do |dir|
      @dir = File.realpath(dir)
      %w[alpha svc/beta].each do |name|
        FileUtils.mkdir_p(File.dirname(File.join(@dir, name)))
        FileUtils.cp_r(File.join(repo, "spec", "fixtures", "static_app"), File.join(@dir, name))
      end
      schema = File.join(@dir, "svc", "beta", "db", "schema.rb")
      File.write(schema, File.read(schema).sub('create_table "users"', 'create_table "gadgets"'))
      example.run
    end
  ensure
    $stderr = log
  end

  let(:target) { RailsAiContext::CLI::AppRoot.target(@dir) }
  let(:started) { [] }
  # Each app's own serve, as the binary starts it, reading source only.
  let(:command) do
    lambda do |root|
      started << root
      [ {}, [ RbConfig.ruby, "-I", File.join(repo, "lib"), File.join(repo, "exe", "rails-ai-context"), "serve", "--no-boot", "--app-path", root ] ]
    end
  end
  let(:long_name) { "rails_#{"x" * 110}" }
  # An app's own copy of another release: other arguments for one tool, one built-in fewer, tools of its own.
  let(:old_copy) do
    script = File.join(@dir, "old_copy.rb")
    File.write(script, <<~RUBY)
      require "json"
      $stdout.sync = true
      tools = [ { name: "rails_get_schema", description: "Old schema", inputSchema: { type: "object", properties: { tbl: { type: "string" } } } },
                { name: "custom_widgets", description: "Widgets", inputSchema: { type: "object", properties: {} } },
                { name: #{long_name.inspect}, description: "Long", inputSchema: { type: "object", properties: {} } } ]
      $stdin.each_line do |line|
        asked = JSON.parse(line)
        next unless asked["id"]

        result = case asked["method"]
                 when "initialize" then { protocolVersion: "2025-06-18", capabilities: { tools: {} }, serverInfo: { name: "rails-ai-context", version: "5.0.0" } }
                 when "tools/list" then { tools: tools }
                 else { content: [ { type: "text", text: "called \#{asked["params"]["name"]} \#{JSON.generate(asked["params"]["arguments"])}" } ] }
                 end
        puts JSON.generate(jsonrpc: "2.0", id: asked["id"], result: result)
      end
    RUBY
    ->(root) { root.end_with?("alpha") ? [ {}, [ RbConfig.ruby, script ] ] : command.call(root) }
  end

  def requests(*list)
    StringIO.new(list.map { |request| "#{JSON.generate(request)}\n" }.join)
  end

  def call(id, arguments, name: "rails_get_schema")
    { jsonrpc: "2.0", id: id, method: "tools/call", params: { name: name, arguments: arguments } }
  end

  def serve(*list, server: described_class.new(target, command: command))
    input, feed = IO.pipe
    output, out = IO.pipe
    run = Thread.new do
      server.run(input, out)
    ensure
      out.close
    end
    text = HeldInput.exchange(feed, output, requests(*list).string.lines)
    run.join
    text.lines.map { |line| JSON.parse(line) }.to_h { |reply| [ reply["id"], reply ] }
  ensure
    [ input, output ].compact.reject(&:closed?).each(&:close)
  end

  # A session whose requests go one at a time, each answered before the next.
  class Session
    attr_reader :notes, :answered

    def initialize(server)
      @input, @feed = IO.pipe
      output, @out = IO.pipe
      @notes = []
      @answered = []
      @messages = Queue.new
      @run = Thread.new do
        server.run(@input, @out)
      ensure
        @out.close
      end
      Thread.new { output.each_line { |line| @messages << JSON.parse(line) } }
      @next = 0
    end

    def tell(message)
      @feed.puts JSON.generate(message)
      @feed.flush
    end

    def ask(method, params = {})
      id = (@next += 1)
      tell({ jsonrpc: "2.0", id: id, method: method, params: params })
      Timeout.timeout(60) do
        loop do
          message = @messages.pop
          next @notes << message["method"] unless message.key?("id")

          @answered << message["id"]
          return message if message["id"] == id
        end
      end
    end

    def close
      @feed.close
      @run.join
    end
  end

  def session(server)
    Session.new(server).tap do |opened|
      opened.ask("initialize", { protocolVersion: "2025-06-18" })
      opened.tell({ jsonrpc: "2.0", method: "notifications/initialized" })
      yield opened
    ensure
      opened.close
    end
  end

  def text(reply) = reply.dig("result", "content").map { |part| part["text"] }.join

  it "reads each app's settings once, whichever of the warm-up and the first list asks first" do
    reads = Queue.new
    allow(RailsAiContext::UnbootedSettings).to receive(:read).and_wrap_original do |original, *args|
      reads << args.first
      sleep 0.05
      original.call(*args)
    end

    serve({ jsonrpc: "2.0", id: 1, method: "initialize", params: { protocolVersion: "2025-06-18" } },
          { jsonrpc: "2.0", id: 2, method: "tools/list" })

    roots = Array.new(reads.size) { reads.pop }
    expect(roots.tally.values.uniq).to eq([ 1 ])
  end

  it "answers discover, initialize and the lists before any app's server starts" do
    replies = serve({ jsonrpc: "2.0", id: 0, method: "server/discover", params: {} },
                    { jsonrpc: "2.0", id: 1, method: "initialize", params: { protocolVersion: "2025-06-18" } },
                    { jsonrpc: "2.0", method: "notifications/initialized" },
                    { jsonrpc: "2.0", id: 2, method: "tools/list" },
                    { jsonrpc: "2.0", id: 3, method: "ping" },
                    { jsonrpc: "2.0", id: 4, method: "resources/list" },
                    { jsonrpc: "2.0", id: 5, method: "resources/templates/list" })

    expect(started).to eq([])
    expect(replies[0]["error"]).to include("code" => -32_601)
    expect(replies[1]["result"]).to include("protocolVersion" => "2025-06-18",
                                            "capabilities" => { "tools" => { "listChanged" => true }, "resources" => { "listChanged" => true } })
    expect(replies[1].dig("result", "instructions")).to include("Serving 2 Rails apps from #{@dir}: alpha (alpha/), beta (svc/beta/).")
    tools = replies[2].dig("result", "tools")
    expect(tools.map { |tool| tool["name"] }).to match_array(RailsAiContext::Server.active_tools(RailsAiContext.configuration).map(&:tool_name))
    tools.each do |tool|
      expect(tool.dig("inputSchema", "properties", "app")).to include("type" => "string", "enum" => %w[alpha beta])
      expect(tool.dig("inputSchema", "required")).to include("app")
    end
    expect(replies[3]["result"]).to eq({})
    expect(replies[4].dig("result", "resources").map { |resource| resource["uri"] })
      .to include("rails-ai-context://apps/alpha/schema", "rails-ai-context://apps/beta/routes")
    expect(replies[5].dig("result", "resourceTemplates").map { |template| template["uriTemplate"] })
      .to include("rails-ai-context://apps/{app}/models/{name}")
  end

  it "answers with the client's protocol revision where it knows it, else its newest" do
    replies = serve({ jsonrpc: "2.0", id: 1, method: "initialize", params: { protocolVersion: "2025-03-26" } },
                    { jsonrpc: "2.0", id: 2, method: "initialize", params: { protocolVersion: "2099-01-01" } })

    expect(replies.transform_values { |reply| reply.dig("result", "protocolVersion") }).to eq(1 => "2025-03-26", 2 => "2025-11-25")
  end

  # json 3 refuses a binary string outside ASCII, which is how a C locale tags each line read.
  it "reads a request line outside ASCII as UTF-8, whatever its encoding tag" do
    allow(JSON).to receive(:parse).and_wrap_original do |parse, source, *rest|
      raise JSON::ParserError, "binary source" if source.encoding == Encoding::BINARY && !source.ascii_only?

      parse.call(source, *rest)
    end
    line = JSON.generate(jsonrpc: "2.0", id: 1, method: "initialize", params: { clientInfo: { name: "caf\u00e9" } }).b
    out = StringIO.new
    described_class.new(target, command: command).run(StringIO.new("#{line}\n".b), out)

    expect(JSON.parse(out.string)).to include("id" => 1)
  end

  it "names the first apps and how many more within what Claude Code reads of its instructions" do
    apps = Array.new(60) { |i| Struct.new(:root, :name).new(File.join(@dir, "group-#{i}", "app-with-a-long-folder-name-#{i}"), "app-with-a-long-folder-name-#{i}") }
    many = Struct.new(:apps, :resolution).new(apps, Struct.new(:cwd).new(@dir))
    reply = serve({ jsonrpc: "2.0", id: 1, method: "initialize", params: {} }, server: described_class.new(many, command: command))[1]
    instructions = reply.dig("result", "instructions")

    expect(instructions.size).to be < 4096
    expect(instructions).to start_with("Serving 60 Rails apps from #{@dir}: app-with-a-long-folder-name-0 (")
    expect(instructions).to match(/, and \d+ more, which each tool's `app` lists\. Every tool takes `app`/)
  end

  it "says once, in an app's first answer, where its version file names another Ruby than the one its server runs" do
    other = RUBY_VERSION.start_with?("2.") ? "3.3.0" : "2.7.8"
    File.write(File.join(@dir, "alpha", ".ruby-version"), "ruby-#{other}\n")
    File.write(File.join(@dir, "svc", "beta", ".ruby-version"), "#{RUBY_VERSION}\n")
    replies = serve(call(1, { app: "alpha", detail: "summary" }), call(2, { app: "beta", detail: "summary" }))
    note = "#{File.join(@dir, "alpha", ".ruby-version")} names Ruby #{other}, but this app's server runs Ruby #{RUBY_VERSION}"

    expect(replies[1].dig("result", "content", 0, "text")).to include(note)
    expect(text(replies[1])).to include("users")
    expect(text(replies[2])).not_to include("names Ruby")
    expect(described_class.version_note(File.join(@dir, "svc", "beta"), RbConfig.ruby)).to be_nil
    expect(described_class.version_note(File.join(@dir, "alpha"), File.join(@dir, "not-this-ruby"))).to be_nil
  end

  it "says it only once per app" do
    File.write(File.join(@dir, "alpha", ".tool-versions"), "nodejs 20.0.0\nruby 2.6.10\n")
    replies = serve(call(1, { app: "alpha", detail: "summary" }), call(2, { app: "alpha", detail: "summary" }))
    notes = [ 1, 2 ].map { |id| text(replies[id]).include?(".tool-versions names Ruby 2.6.10") }
    expect(notes.sort_by { |noted| noted ? 0 : 1 }).to eq([ true, false ])
  end

  it "answers an app whose version file is not UTF-8, with no note from it" do
    { "\xff3.3.0\n".b => nil, "\xFF\xFE".b + "2.7.8\n".encode("UTF-16LE").b => nil,
      "# caf\xe9\nruby 2.6.10\n".b => ".tool-versions names Ruby 2.6.10" }.each_with_index do |(bytes, note), index|
      name = note ? ".tool-versions" : ".ruby-version"
      %w[.ruby-version .tool-versions].each { |file| FileUtils.rm_f(File.join(@dir, "alpha", file)) }
      File.binwrite(File.join(@dir, "alpha", name), bytes)
      reply = serve(call(index, { app: "alpha", detail: "summary" }))[index]

      expect(text(reply)).to include("users"), bytes.inspect
      expect(text(reply).include?("names Ruby")).to eq(!note.nil?), bytes.inspect
      expect(text(reply)).to include(note) if note
    end
  end

  it "takes the nearest file that names a Ruby, as the version managers do" do
    alpha = File.join(@dir, "alpha")
    File.write(File.join(@dir, ".ruby-version"), "2.7.8\n")
    expect(described_class.version_note(alpha, RbConfig.ruby)).to include("#{File.join(@dir, ".ruby-version")} names Ruby 2.7.8")

    File.write(File.join(alpha, ".tool-versions"), "nodejs 20.0.0\n")
    expect(described_class.version_note(alpha, RbConfig.ruby)).to include("#{File.join(@dir, ".ruby-version")} names Ruby 2.7.8")

    %w[system jruby-9.4.5.0 truffleruby].each do |named|
      File.write(File.join(alpha, ".ruby-version"), "#{named}\n")
      expect(described_class.version_note(alpha, RbConfig.ruby)).to be_nil, named
    end
  end

  it "reads the Ruby of mise's own files, `.mise.toml` over `mise.toml`" do
    alpha = File.join(@dir, "alpha")
    File.write(File.join(alpha, ".tool-versions"), "ruby #{RUBY_VERSION}\n")
    File.write(File.join(alpha, "mise.toml"), "[env]\nruby = \"x\"\n[tools]\nnode = \"20\"\nruby = \"2.7.8\"\n")
    expect(described_class.version_note(alpha, RbConfig.ruby)).to include("mise.toml names Ruby 2.7.8")

    File.write(File.join(alpha, ".mise.toml"), "[tools]\nruby = { version = \"2.6.10\", virtual = \"x\" }\n")
    expect(described_class.version_note(alpha, RbConfig.ruby)).to include(".mise.toml names Ruby 2.6.10")

    File.write(File.join(alpha, ".mise.toml"), "[tools.ruby]\nversion = \"#{RUBY_VERSION}\"\n")
    expect(described_class.version_note(alpha, RbConfig.ruby)).to be_nil
  end

  # mise reads these shapes as the app's Ruby, so a parent folder's file never decides.
  it "stops at a mise file whose Ruby it cannot read, with no note from a folder above" do
    alpha = File.join(@dir, "alpha")
    File.write(File.join(@dir, ".ruby-version"), "2.7.8\n")
    File.write(File.join(@dir, ".tool-versions"), "ruby 2.7.8\n")
    expect(described_class.version_note(alpha, RbConfig.ruby)).to include("names Ruby 2.7.8")

    { "tools.\"core:ruby\" = \"3.3\"\n" => "a backend-qualified root dotted key",
      "tools.ruby = [\n  \"3.3\",\n]\n" => "a multi-line array under a root dotted key",
      "[tools.ruby]\nvirtual = \"x\"\n" => "a ruby table without a version",
      "[tools]\nruby = [\n  \"3.3\",\n]\n" => "a multi-line array",
      "[tools]\n\"core:ruby\" = \"3.3\"\n" => "a backend-qualified key",
      "[tools.ruby]\nversion = [\"3.3\"]\n" => "a table whose version is a list" }.each do |content, shape|
      %w[mise.toml .mise.toml].each do |name|
        path = File.join(alpha, name)
        File.write(path, content)
        expect(described_class.version_note(alpha, RbConfig.ruby)).to be_nil, "#{name}: #{shape}"
        File.delete(path)
      end
    end

    File.write(File.join(alpha, "mise.toml"), "[env]\nRUBY_OPT = \"x\"\n")
    expect(described_class.version_note(alpha, RbConfig.ruby)).to include("names Ruby 2.7.8")
  end

  # mise merges .tool-versions and .ruby-version from the same folder under a mise file whose tools name no Ruby.
  it "reads the same folder's other version files under a mise file whose tools name no Ruby" do
    alpha = File.join(@dir, "alpha")
    File.write(File.join(@dir, ".ruby-version"), "3.0.0\n")
    File.write(File.join(alpha, "mise.toml"), "[tools]\nnode = \"20\"\n")
    File.write(File.join(alpha, ".tool-versions"), "ruby 2.7.8\n")
    expect(described_class.version_note(alpha, RbConfig.ruby)).to include("#{File.join(alpha, ".tool-versions")} names Ruby 2.7.8")

    # One that names a Ruby it cannot read wins over them, as mise.toml wins over .tool-versions.
    [ "tools = { \"core:ruby\" = \"3.3\" }\n", "[tools]\n\"core:ruby\" = \"3.3\"\n" ].each do |content|
      File.write(File.join(alpha, "mise.toml"), content)
      expect(described_class.version_note(alpha, RbConfig.ruby)).to be_nil, content
    end
    File.write(File.join(alpha, "mise.toml"), "[tools]\nnode = \"20\"\n")

    File.delete(File.join(alpha, ".tool-versions"))
    File.write(File.join(alpha, ".ruby-version"), "2.6.10\n")
    expect(described_class.version_note(alpha, RbConfig.ruby)).to include("#{File.join(alpha, ".ruby-version")} names Ruby 2.6.10")

    File.delete(File.join(alpha, ".ruby-version"))
    expect(described_class.version_note(alpha, RbConfig.ruby)).to include("#{File.join(@dir, ".ruby-version")} names Ruby 3.0.0")
  end

  # mise merges tools per tool from every folder up, so a mise file whose tools name no Ruby decides nothing about Ruby.
  it "passes over a mise file whose tools name no Ruby, to the nearest file that names one, in its folder or above" do
    alpha = File.join(@dir, "alpha")
    above = File.join(@dir, ".ruby-version")
    File.write(above, "2.7.8\n")
    [ "[tools]\nnode = \"20\"\n", "[env]\nRUBY_OPT = \"x\"\n", "[tools.node]\nruby = \"3.3\"\n", "[tools]\n\"ruby-build\" = \"x\"\n",
      "tools = { node = \"20\" } # ruby\n", "tools = { node = \"20\" } # , ruby = \"3.3\"\n", "[tools]\nnode = \"20\" # ruby = \"3.3\"\n", "[tools]\n[env]\nruby = \"3.3\"\n",
      "tools.node = { version = \"20\", note = \"ruby\" }\n", "tools = { node = { version = \"20\" } }\n" ].each do |content|
      %w[mise.toml .mise.toml].each do |name|
        File.write(File.join(alpha, name), content)
        expect(described_class.version_note(alpha, RbConfig.ruby)).to include("#{above} names Ruby 2.7.8"), "#{name}: #{content}"

        File.write(File.join(alpha, ".tool-versions"), "ruby 2.6.10\n")
        expect(described_class.version_note(alpha, RbConfig.ruby)).to include("#{File.join(alpha, ".tool-versions")} names Ruby 2.6.10"), "#{name}: #{content}"
        File.delete(File.join(alpha, ".tool-versions"))

        File.write(File.join(@dir, name), content)
        expect(described_class.version_note(alpha, RbConfig.ruby)).to include("#{above} names Ruby 2.7.8"), "above, #{name}: #{content}"
        File.delete(File.join(@dir, name))
        File.delete(File.join(alpha, name))
      end
    end
  end

  it "reads a mise file's Ruby written as root dotted keys or an inline tools table" do
    alpha = File.join(@dir, "alpha")
    File.write(File.join(@dir, ".ruby-version"), "3.0.0\n")
    { "tools.ruby = \"2.7.8\"\n" => "2.7.8",
      "tools.ruby.version = \"2.6.10\"\n" => "2.6.10",
      "tools = { ruby = \"2.5.9\", node = \"20\" }\n" => "2.5.9",
      "tools = { node = { version = \"20\" }, ruby = { version = \"2.4.10\" } }\n" => "2.4.10",
      "[tools]\nruby = { virtual = \"x\", version = \"2.3.8\" }\n" => "2.3.8" }.each do |content, version|
      File.write(File.join(alpha, "mise.toml"), content)
      expect(described_class.version_note(alpha, RbConfig.ruby)).to include("mise.toml names Ruby #{version}"), content
    end

    [ "tools = { \"core:ruby\" = \"3.3\" }\n", "tools.\"core:ruby\".version = \"3.3\"\n",
      "[tools]\nruby = { virtual = \"x\" }\n" ].each do |content|
      File.write(File.join(alpha, "mise.toml"), content)
      expect(described_class.version_note(alpha, RbConfig.ruby)).to be_nil, content
    end
  end

  it "keeps the note for an answer it can carry it in" do
    File.write(File.join(@dir, "alpha", ".ruby-version"), "2.7.8\n")
    script = File.join(@dir, "odd.rb")
    File.write(script, <<~RUBY)
      require "json"
      $stdout.sync = true
      calls = 0
      $stdin.each_line do |line|
        asked = JSON.parse(line)
        next unless asked["id"]

        result = case asked["method"]
                 when "initialize" then { protocolVersion: "2025-06-18", capabilities: {}, serverInfo: { name: "x", version: "5.0.0" } }
                 when "tools/list" then { tools: [ { name: "rails_get_schema", inputSchema: { type: "object" } } ] }
                 else (calls += 1) == 1 ? "plain" : { content: [ { type: "text", text: "second" } ] }
                 end
        puts JSON.generate(jsonrpc: "2.0", id: asked["id"], result: result)
      end
    RUBY
    session(described_class.new(target, command: ->(_root) { [ {}, [ RbConfig.ruby, script ] ] })) do |client|
      # The app's own arguments give its tool a name of its own, which the first call is told.
      expect(text(client.ask("tools/call", { name: "rails_get_schema", arguments: { app: "alpha" } }))).to include("rails_get_schema_alpha")
      expect(client.ask("tools/call", { name: "rails_get_schema_alpha", arguments: { app: "alpha" } })["result"]).to eq("plain")
      expect(text(client.ask("tools/call", { name: "rails_get_schema_alpha", arguments: { app: "alpha" } }))).to include("names Ruby 2.7.8")
    end
  end

  it "gives calls that waited on a start that failed its outcome, and starts again at a later call" do
    starts = Queue.new
    failing = lambda do |_root|
      starts << true
      sleep 1
      raise "no Ruby for this app"
    end
    replies = serve(*(1..3).map { |id| call(id, { app: "alpha" }) }, server: described_class.new(target, command: failing))
    expect((1..3).map { |id| text(replies[id]) }.uniq).to eq([ "rails-ai-context could not route this request: RuntimeError: no Ruby for this app" ])
    expect(starts.size).to eq(1)

    session(described_class.new(target, command: failing)) do |client|
      2.times { client.ask("tools/call", { name: "rails_get_schema", arguments: { app: "alpha" } }) }
    end
    expect(starts.size).to eq(3)
  end

  it "starts an app's server at its first call and answers from that app" do
    server = described_class.new(target, command: command)
    replies = serve(call(1, { app: "beta", detail: "summary" }), call(2, { app: "beta", table: "gadgets" }), server: server)

    expect(started).to eq([ File.join(@dir, "svc", "beta") ])
    expect(text(replies[1])).to include("gadgets").and(satisfy { |answer| !answer.include?("users") })
    expect(text(replies[2])).to include("gadgets")

    replies = serve(call(3, { app: "alpha", detail: "summary" }))
    expect(text(replies[3])).to include("users")
  end

  it "reads an app's resources by the app its URI names" do
    replies = serve({ jsonrpc: "2.0", id: 1, method: "resources/read", params: { uri: "rails-ai-context://apps/beta/schema" } },
                    { jsonrpc: "2.0", id: 2, method: "resources/read", params: { uri: "rails-ai-context://apps/gamma/schema" } })

    contents = replies[1].dig("result", "contents")
    expect(contents.first).to include("uri" => "rails-ai-context://apps/beta/schema")
    expect(contents.first["text"]).to include("gadgets")
    expect(replies[2]["error"]).to include("code" => -32_602)
    expect(started).to eq([ File.join(@dir, "svc", "beta") ])
  end

  it "answers a call naming no app it serves as a tool error that lists them" do
    replies = serve(call(1, { app: "gamma" }), call(2, {}))

    [ 1, 2 ].each do |id|
      expect(replies[id]["result"]).to include("isError" => true)
      expect(text(replies[id])).to include("one of: alpha, beta")
    end
    expect(started).to eq([])
  end

  it "answers a call whose routing fails as a tool error, never with silence" do
    server = described_class.new(target, command: command)
    allow(server).to receive(:child_for).and_raise(ArgumentError, "broken")
    replies = serve(call(1, { app: "alpha" }), server: server)

    expect(replies[1]["result"]).to include("isError" => true)
    expect(text(replies[1])).to include("ArgumentError: broken")
  end

  it "answers for an app whose server stops with what it said last, and starts it again at the next call" do
    dying = true
    flaky = ->(root) { dying ? [ {}, [ RbConfig.ruby, "-e", "warn 'booting'; warn 'the app cannot start'; exit 3" ] ] : command.call(root) }
    session(described_class.new(target, command: flaky)) do |client|
      reply = client.ask("tools/call", { name: "rails_get_schema", arguments: { app: "alpha" } })
      expect(reply["result"]).to include("isError" => true)
      expect(text(reply)).to include("The server for the app alpha (#{File.join(@dir, "alpha")}) stopped before it answered: booting the app cannot start")

      dying = false
      reply = client.ask("tools/call", { name: "rails_get_schema", arguments: { app: "alpha", detail: "summary" } })
      expect(text(reply)).to include("users")
    end
    expect(started).to eq([ File.join(@dir, "alpha") ])
  end

  it "waits for what a stopping server says after its output closes" do
    late = ->(_root) { [ {}, [ RbConfig.ruby, "-e", "$stdout.reopen(File::NULL); sleep 0.5; warn 'said late'; exit 3" ] ] }
    reply = serve(call(1, { app: "alpha" }), server: described_class.new(target, command: late))[1]

    expect(text(reply)).to include("stopped before it answered: said late.")
  end

  it "lists each app's own tools once its server has said them, and tells the client the list changed" do
    session(described_class.new(target, command: old_copy)) do |client|
      expect(client.ask("tools/list").dig("result", "tools").map { |tool| tool["name"] }).not_to include("custom_widgets")

      reply = client.ask("tools/call", { name: "rails_get_schema", arguments: { app: "alpha", table: "users" } })
      expect(text(reply)).to eq("For the app alpha, call `rails_get_schema_alpha`, which takes that app's own arguments.")
      expect(client.notes).to eq([ "notifications/tools/list_changed" ])

      tools = client.ask("tools/list").dig("result", "tools").to_h { |tool| [ tool["name"], tool ] }
      expect(tools["rails_get_schema"].dig("inputSchema", "properties", "app", "enum")).to eq(%w[beta])
      expect(tools["rails_get_schema_alpha"].dig("inputSchema", "properties").keys).to eq(%w[app tbl])
      expect(tools["custom_widgets"].dig("inputSchema", "properties", "app", "enum")).to eq(%w[alpha])
      expect(tools["rails_get_routes"].dig("inputSchema", "properties", "app", "enum")).to eq(%w[beta])
      long = tools.keys.find { |name| name.start_with?("rails_xxx") }
      expect(long.size).to be <= described_class::TOOL_NAME_LIMIT

      expect(text(client.ask("tools/call", { name: "rails_get_schema_alpha", arguments: { app: "alpha", tbl: "users" } })))
        .to eq('called rails_get_schema {"tbl":"users"}')
      expect(text(client.ask("tools/call", { name: long, arguments: { app: "alpha" } }))).to eq("called #{long_name} {}")
      expect(text(client.ask("tools/call", { name: "rails_get_routes", arguments: { app: "alpha" } })))
        .to eq("The app alpha (#{File.join(@dir, "alpha")}) runs rails-ai-context 5.0.0, whose server does not serve rails_get_routes: the app's skip_tools may turn it off, or that release lacks it.")
    end
  end

  it "starts an app's server as the command says, without the plugin's variable" do
    seen = File.join(@dir, "seen.json")
    recorded = ->(_root) { [ {}, [ RbConfig.ruby, "-e", "File.write(#{seen.inspect}, JSON.generate([ Dir.pwd, ENV['RAILS_AI_CONTEXT_PLUGIN'] ]))", "-rjson" ] ] }
    ENV["RAILS_AI_CONTEXT_PLUGIN"] = "1"
    begin
      serve(call(1, { app: "beta" }), server: described_class.new(target, command: recorded))
    ensure
      ENV.delete("RAILS_AI_CONTEXT_PLUGIN")
    end

    expect(JSON.parse(File.read(seen))).to eq([ File.join(@dir, "svc", "beta"), nil ])
  end

  describe "an app's own settings" do
    it "leaves a tool the app's skip_tools turns off out of the first list, and a call for it names skip_tools" do
      File.write(File.join(@dir, "alpha", ".rails-ai-context.yml"), "skip_tools:\n  - rails_get_routes\n")
      session(described_class.new(target, command: command)) do |client|
        tools = client.ask("tools/list").dig("result", "tools").to_h { |tool| [ tool["name"], tool ] }
        expect(tools["rails_get_routes"].dig("inputSchema", "properties", "app", "enum")).to eq(%w[beta])
        expect(tools["rails_get_schema"].dig("inputSchema", "properties", "app", "enum")).to eq(%w[alpha beta])

        reply = client.ask("tools/call", { name: "rails_get_routes", arguments: { app: "alpha" } })
        expect(reply["result"]).to include("isError" => true)
        expect(text(reply)).to include("does not serve rails_get_routes").and include("skip_tools")
        expect(client.notes).to eq([])
        expect(started).to eq([])
      end
    end

    {
      "an other environment's file" => [ "config/environments/production.rb", "RailsAiContext.configure { |c| c.skip_tools = %w[rails_get_routes] }\n" ],
      "a branch on the environment" => [ "config/initializers/x.rb", "RailsAiContext.configure do |c|\n  if Rails.env.production?\n    c.skip_tools = %w[rails_get_routes]\n  else\n    c.skip_tools = %w[rails_get_gems]\n  end\nend\n" ],
      "an ENV ternary" => [ "config/initializers/x.rb", "RailsAiContext.configure { |c| c.skip_tools = ENV[\"LEAN\"] ? %w[rails_get_routes] : [] }\n" ]
    }.each do |label, (file, source)|
      it "starts the app and relays a call for a tool that only #{label} skips" do
        FileUtils.mkdir_p(File.dirname(File.join(@dir, "alpha", file)))
        File.write(File.join(@dir, "alpha", file), source)
        session(described_class.new(target, command: command)) do |client|
          tools = client.ask("tools/list").dig("result", "tools").to_h { |tool| [ tool["name"], tool ] }
          expect(tools["rails_get_routes"].dig("inputSchema", "properties", "app", "enum")).to eq(%w[alpha beta])

          client.ask("tools/call", { name: "rails_get_routes", arguments: { app: "alpha" } })
          expect(started).to eq([ File.join(@dir, "alpha") ])
        end
      end
    end

    it "still refuses before any start a tool an initializer skips outright" do
      FileUtils.mkdir_p(File.join(@dir, "alpha", "config", "initializers"))
      File.write(File.join(@dir, "alpha", "config", "initializers", "x.rb"), "RailsAiContext.configure { |c| c.skip_tools = %w[rails_get_routes] }\n")
      session(described_class.new(target, command: command)) do |client|
        reply = client.ask("tools/call", { name: "rails_get_routes", arguments: { app: "alpha" } })
        expect(text(reply)).to include("does not serve rails_get_routes")
        expect(started).to eq([])
      end
    end

    it "lists rails_get_config for an app without the sections its skip_tools turns off, and refuses one before any start" do
      File.write(File.join(@dir, "alpha", ".rails-ai-context.yml"), "skip_tools:\n  - rails_get_gems\n")
      session(described_class.new(target, command: command)) do |client|
        tools = client.ask("tools/list").dig("result", "tools").to_h { |tool| [ tool["name"], tool ] }
        sections = ->(name) { tools[name].dig("inputSchema", "properties", "section", "enum") }
        expect(tools["rails_get_config"].dig("inputSchema", "properties", "app", "enum")).to eq(%w[beta])
        expect(sections.("rails_get_config")).to include("gems")
        expect(tools["rails_get_config_alpha"].dig("inputSchema", "properties", "app", "enum")).to eq(%w[alpha])
        expect(sections.("rails_get_config_alpha")).not_to include("gems")
        expect(tools["rails_get_config_alpha"]["description"]).not_to include("gems")

        reply = client.ask("tools/call", { name: "rails_get_config_alpha", arguments: { app: "alpha", section: "gems" } })
        expect(text(reply)).to include("`gems` section").and include("rails_get_gems")
        expect(started).to eq([])

        expect(text(client.ask("tools/call", { name: "rails_get_config_alpha", arguments: { app: "alpha" } }))).not_to be_empty
        expect(started).to eq([ File.join(@dir, "alpha") ])
        expect(client.notes).to eq([])
      end
    end
  end

  describe "an app's own notifications" do
    # Live reload tells the client an app's files changed, so it reads the resources again.
    it "passes on an app's resource list change, and keeps what only its log needs" do
      script = File.join(@dir, "reloading.rb")
      File.write(script, <<~RUBY)
        require "json"
        $stdout.sync = true
        $stdin.each_line do |line|
          asked = JSON.parse(line)
          next unless asked["id"]

          result = case asked["method"]
                   when "initialize" then { protocolVersion: "2025-06-18", capabilities: {}, serverInfo: { name: "x", version: "5.0.0" } }
                   when "tools/list" then { tools: [ { name: "custom_widgets", inputSchema: { type: "object", properties: {} } } ] }
                   else
                     puts JSON.generate(jsonrpc: "2.0", method: "notifications/message", params: { level: "info", data: "Files changed" })
                     puts JSON.generate(jsonrpc: "2.0", method: "notifications/resources/list_changed")
                     { content: [ { type: "text", text: "done" } ] }
                   end
          puts JSON.generate(jsonrpc: "2.0", id: asked["id"], result: result)
        end
      RUBY
      session(described_class.new(target, command: ->(_root) { [ {}, [ RbConfig.ruby, script ] ] })) do |client|
        expect(text(client.ask("tools/call", { name: "custom_widgets", arguments: { app: "alpha" } }))).to eq("done")
        client.ask("ping")

        expect(client.notes).to include("notifications/resources/list_changed")
        expect(client.notes).not_to include("notifications/message")
      end
    end

    it "says it tells the client when the resource list changes" do
      reply = serve({ jsonrpc: "2.0", id: 1, method: "initialize", params: {} })[1]

      expect(reply.dig("result", "capabilities", "resources")).to eq("listChanged" => true)
    end
  end

  describe "a request the app's server makes of the client" do
    it "is answered with an error at once, so the call it came in goes on" do
      script = File.join(@dir, "asking.rb")
      File.write(script, <<~RUBY)
        require "json"
        $stdout.sync = true
        $stdin.each_line do |line|
          asked = JSON.parse(line)
          if asked["id"] && asked["method"] == "tools/call"
            puts JSON.generate(jsonrpc: "2.0", id: 77, method: "sampling/createMessage", params: {})
            heard = JSON.parse($stdin.gets)
            puts JSON.generate(jsonrpc: "2.0", id: asked["id"], result: { content: [ { type: "text", text: "heard \#{heard["id"]} \#{heard.key?("error")}" } ] })
          elsif asked["id"]
            result = asked["method"] == "initialize" ? { protocolVersion: "2025-06-18", capabilities: {}, serverInfo: { name: "x", version: "5.0.0" } } : { tools: [ { name: "custom_widgets", inputSchema: { type: "object", properties: {} } } ] }
            puts JSON.generate(jsonrpc: "2.0", id: asked["id"], result: result)
          end
        end
      RUBY
      session(described_class.new(target, command: ->(_root) { [ {}, [ RbConfig.ruby, script ] ] })) do |client|
        expect(text(client.ask("tools/call", { name: "custom_widgets", arguments: { app: "alpha" } }))).to eq("heard 77 true")
      end
    end
  end

  describe "a ping the app's server sends" do
    it "is answered with an empty result" do
      script = File.join(@dir, "pinging.rb")
      File.write(script, <<~RUBY)
        require "json"
        $stdout.sync = true
        $stdin.each_line do |line|
          asked = JSON.parse(line)
          if asked["id"] && asked["method"] == "tools/call"
            puts JSON.generate(jsonrpc: "2.0", id: 78, method: "ping")
            heard = JSON.parse($stdin.gets)
            puts JSON.generate(jsonrpc: "2.0", id: asked["id"], result: { content: [ { type: "text", text: JSON.generate(heard) } ] })
          elsif asked["id"]
            result = asked["method"] == "initialize" ? { protocolVersion: "2025-06-18", capabilities: {}, serverInfo: { name: "x", version: "5.0.0" } } : { tools: [ { name: "custom_widgets", inputSchema: { type: "object", properties: {} } } ] }
            puts JSON.generate(jsonrpc: "2.0", id: asked["id"], result: result)
          end
        end
      RUBY
      session(described_class.new(target, command: ->(_root) { [ {}, [ RbConfig.ruby, script ] ] })) do |client|
        heard = JSON.parse(text(client.ask("tools/call", { name: "custom_widgets", arguments: { app: "alpha" } })))
        expect(heard).to eq("jsonrpc" => "2.0", "id" => 78, "result" => {})
      end
    end
  end

  describe "a call cancelled before it reaches its app's server" do
    it "is dropped, with no answer and nothing sent to the server" do
      seen = File.join(@dir, "seen.log")
      script = File.join(@dir, "logging.rb")
      File.write(script, <<~RUBY)
        require "json"
        $stdout.sync = true
        $stdin.each_line do |line|
          asked = JSON.parse(line)
          File.open(#{seen.inspect}, "a") { |file| file.puts asked["method"] }
          next unless asked["id"]

          result = asked["method"] == "initialize" ? { protocolVersion: "2025-06-18", capabilities: {}, serverInfo: { name: "x", version: "5.0.0" } } : { tools: [ { name: "custom_widgets", inputSchema: { type: "object", properties: {} } } ] }
          puts JSON.generate(jsonrpc: "2.0", id: asked["id"], result: result)
        end
      RUBY
      slow = lambda do |_root|
        sleep 0.5
        [ {}, [ RbConfig.ruby, script ] ]
      end
      replies = serve(call(5, { app: "alpha" }, name: "custom_widgets"),
                      { jsonrpc: "2.0", method: "notifications/cancelled", params: { requestId: 5 } },
                      { jsonrpc: "2.0", id: 6, method: "ping" },
                      server: described_class.new(target, command: slow))

      expect(replies.keys).to eq([ 6 ])
      expect(File.exist?(seen) ? File.read(seen) : "").not_to include("tools/call")
    end

    it "is dropped when the cancel comes while the app's server is still starting" do
      seen = File.join(@dir, "seen.log")
      script = File.join(@dir, "logging.rb")
      File.write(script, <<~RUBY)
        require "json"
        $stdout.sync = true
        $stdin.each_line do |line|
          asked = JSON.parse(line)
          File.open(#{seen.inspect}, "a") { |file| file.puts asked["method"] }
          next unless asked["id"]

          result = asked["method"] == "initialize" ? { protocolVersion: "2025-06-18", capabilities: {}, serverInfo: { name: "x", version: "5.0.0" } } : { tools: [ { name: "custom_widgets", inputSchema: { type: "object", properties: {} } } ] }
          puts JSON.generate(jsonrpc: "2.0", id: asked["id"], result: result)
        end
      RUBY
      entered = Queue.new
      gate = Queue.new
      held = lambda do |_root|
        entered << true
        gate.pop
        [ {}, [ RbConfig.ruby, script ] ]
      end
      session(described_class.new(target, command: held)) do |client|
        client.tell(call(50, { app: "alpha" }, name: "custom_widgets"))
        entered.pop
        client.tell({ jsonrpc: "2.0", method: "notifications/cancelled", params: { requestId: 50 } })
        client.ask("ping")
        gate << true
        Timeout.timeout(30) { sleep 0.05 until File.exist?(seen) && File.read(seen).include?("tools/list") }
        client.ask("ping")

        expect(client.answered).not_to include(50)
        expect(File.read(seen)).not_to include("tools/call")
      end
    end
  end

  describe "a folder named outside ASCII under a C locale" do
    # A C locale tags each path read binary, which no UTF-8 text outside ASCII joins and json 3 refuses to write.
    let(:root) { File.join(@dir, "caf\u00e9", "alpha").b }
    let(:tagged) do
      app_root = RailsAiContext::CLI::AppRoot
      app_root::Target.new(kind: :apps, apps: [ app_root::TargetApp.new(root: root, name: "alpha") ],
                           resolution: app_root::Result.new(cwd: File.dirname(root), below: [ root ]))
    end
    let(:failing) { ->(_root) { [ {}, [ RbConfig.ruby, "-e", "warn 'no app in caf\u00e9'; exit 1" ] ] } }

    it "answers a call and a read whose app's server stopped with what it said and the folder" do
      FileUtils.mkdir_p(root)
      replies = serve(call(1, { app: "alpha" }),
                      { jsonrpc: "2.0", id: 2, method: "resources/read", params: { uri: "rails-ai-context://apps/alpha/schema" } },
                      server: described_class.new(tagged, command: failing))
      said = "(#{File.join(@dir, "caf\u00e9", "alpha")}) stopped before it answered: no app in caf\u00e9"

      expect(text(replies[1])).to include(said)
      expect(replies[2].dig("error", "message")).to include(said)
    end
  end

  describe ".child_command" do
    let(:installed) { [ RbConfig.ruby, "-e", "load Gem.activate_bin_path(...)", "= 5.0.0" ] }

    let(:shims) { File.join(@dir, "shims").tap { |dir| FileUtils.mkdir_p(dir) } }
    let(:shim) do
      File.join(shims, "ruby").tap do |file|
        File.write(file, "#!/bin/sh\npwd > #{File.join(@dir, "cwd").inspect}\nenv > #{File.join(@dir, "env").inspect}\nexit 1\n")
        File.chmod(0o755, file)
      end
    end
    let(:pins) do
      { "RBENV_DIR" => nil, "RBENV_VERSION" => nil, "ASDF_RUBY_VERSION" => nil, "MISE_RUBY_VERSION" => nil, "ASDF_INSTALL_TYPE" => nil,
        "ASDF_INSTALL_VERSION" => nil, "ASDF_INSTALL_PATH" => nil, "__MISE_TASK_TOOL_ARGS" => nil }
    end
    let(:own_gems) do
      { "GEM_HOME" => nil, "GEM_PATH" => nil, "BUNDLE_GEMFILE" => nil, "BUNDLE_PATH" => nil, "BUNDLE_BIN_PATH" => nil,
        "BUNDLE_LOCKFILE" => nil, "BUNDLER_SETUP" => nil, "BUNDLER_VERSION" => nil, "RUBYLIB" => nil }
    end

    before { shim }

    it "starts the `ruby` on PATH, which the app's folder gives a version manager's shim, else this Ruby" do
      env, argv = described_class.child_command({}, installed, "/apps/a", { "PATH" => shims })
      expect(argv).to eq([ shim, "-e", described_class::CHILD_START, "serve", "--app-path", "/apps/a" ])
      expect(env).to eq(pins.merge(own_gems, "RUBYOPT" => nil))
      expect(described_class.child_command({}, installed, "/apps/a", { "PATH" => File.join(@dir, "none") }).last.first).to eq(RbConfig.ruby)

      # rbenv exec puts the Ruby it picked first on PATH, which would hide the shims.
      picked = { "PATH" => [ File.join(@dir, "versions", "3.3.0", "bin"), shims ].join(File::PATH_SEPARATOR), "RBENV_VERSION" => "3.3.0" }
      env, argv = described_class.child_command({ "X" => "1" }, installed, "/apps/a", picked)
      expect(argv.first).to eq(shim)
      expect(env).to include("X" => "1", "RBENV_VERSION" => nil, "PATH" => shims)
    end

    # A manager's layout: its shim, and the Ruby its exec puts ahead of the shims.
    def manager(name, installs)
      top = File.join(@dir, name)
      shim_dir = File.join(top, "shims")
      bin = File.join(top, installs, "3.3.0", "bin")
      [ shim_dir, bin ].each { |dir| FileUtils.mkdir_p(dir) }
      FileUtils.cp(shim, File.join(shim_dir, "ruby"))
      File.write(File.join(bin, "ruby"), "#!/bin/sh\nexit 1\n")
      File.chmod(0o755, File.join(bin, "ruby"))
      [ shim_dir, bin ]
    end

    it "starts the shim under asdf's or mise's exec, which put the session's Ruby ahead of the shims" do
      { "asdf" => [ "installs/ruby", { "ASDF_INSTALL_TYPE" => "version", "ASDF_INSTALL_VERSION" => "3.3.0", "ASDF_INSTALL_PATH" => "/x" } ],
        "mise" => [ "installs/ruby", { "__MISE_TASK_TOOL_ARGS" => "[]" } ],
        "rbenv" => [ "versions", {} ] }.each do |name, (installs, exec_vars)|
        shim_dir, bin = manager(name, installs)
        dirs = [ bin, shim_dir, "/usr/bin" ]
        env, argv = described_class.child_command({}, installed, "/apps/a", exec_vars.merge("PATH" => dirs.join(File::PATH_SEPARATOR)))

        expect(argv.first).to eq(File.join(shim_dir, "ruby")), name
        expect(env["PATH"]).to eq([ shim_dir, "/usr/bin" ].join(File::PATH_SEPARATOR)), name
        expect(env.slice(*exec_vars.keys).values.uniq).to eq(exec_vars.empty? ? [] : [ nil ]), name
        expect(env).to include("GEM_HOME" => nil), name
      end
    end

    it "keeps this Ruby's gems where the shim runs this Ruby in the app's folder, asking it once per folder" do
      app = File.join(@dir, "alpha")
      runs = File.join(@dir, "runs")
      same = File.join(@dir, "same", "ruby")
      other_ruby = File.join(@dir, "other", "bin", "ruby")
      other = File.join(@dir, "other", "shims", "ruby")
      [ same, other_ruby, other ].each { |file| FileUtils.mkdir_p(File.dirname(file)) }
      File.write(same, "#!/bin/sh\npwd >> #{runs.inspect}\necho \"${GEM_HOME:-none}\" >> #{runs.inspect}\nexec #{RbConfig.ruby.inspect} \"$@\"\n")
      File.write(other_ruby, "#!/bin/sh\nprintf '%s' \"$0\"\n")
      File.write(other, "#!/bin/sh\nexec #{other_ruby.inspect} \"$@\"\n")
      [ same, other_ruby, other ].each { |file| File.chmod(0o755, file) }

      rubies = {}
      2.times do
        env, argv = described_class.child_command({}, installed, app, { "PATH" => File.dirname(same) }, rubies)
        expect(argv.first).to eq(same)
        expect(env).to eq(pins)
      end
      expect(File.readlines(runs, chomp: true)).to eq([ app, "none" ])

      # An edited version file is read at the next start; another router asks again.
      File.write(File.join(app, ".ruby-version"), "3.3.0\n")
      described_class.child_command({}, installed, app, { "PATH" => File.dirname(same) }, rubies)
      described_class.child_command({}, installed, app, { "PATH" => File.dirname(same) }, rubies)
      described_class.child_command({}, installed, app, { "PATH" => File.dirname(same) }, {})
      expect(File.readlines(runs, chomp: true).size).to eq(6)

      env, = described_class.child_command({}, installed, app, { "PATH" => File.dirname(other) }, rubies)
      expect(env).to include("GEM_HOME" => nil, "BUNDLE_GEMFILE" => nil)
    end

    it "asks a shim that ran over its time again at the next start, and stops what it started" do
      stub_const("#{described_class}::PROBE_SECONDS", 1)
      app = File.join(@dir, "alpha")
      slow = File.join(@dir, "slow", "ruby")
      installer = File.join(@dir, "installer.pid")
      FileUtils.mkdir_p(File.dirname(slow))
      File.write(slow, <<~SH)
        #!/bin/sh
        if [ ! -f #{installer.inspect} ]; then /bin/sleep 30 & echo $! > #{installer.inspect}; wait; fi
        exec #{RbConfig.ruby.inspect} "$@"
      SH
      File.chmod(0o755, slow)
      rubies = {}

      env, = described_class.child_command({}, installed, app, { "PATH" => File.dirname(slow) }, rubies)
      expect(env).to include("GEM_HOME" => nil)
      expect(dead_within(5, [ Integer(File.read(installer)) ])).to eq([ false ])

      env, = described_class.child_command({}, installed, app, { "PATH" => File.dirname(slow) }, rubies)
      expect(env).to eq(pins)
    end

    it "drops only a manager's own Ruby dirs ahead of the first shims dir, so a manager's `system` Ruby keeps its dir" do
      shim_dir, bin = manager("rbenv", "versions")
      own = File.dirname(RbConfig.ruby)
      expect(described_class.without_picked_ruby([ own, bin, "/opt/bin", shim_dir, "/usr/bin" ])).to eq([ own, "/opt/bin", shim_dir, "/usr/bin" ])
      expect(described_class.without_picked_ruby([ shim_dir, own, bin, "/bin" ])).to eq([ shim_dir, own, bin, "/bin" ])
    end

    it "keeps a distro Ruby's /usr/bin ahead of the shims" do
      shim_dir, = manager("rbenv", "versions")
      allow(RbConfig).to receive(:ruby).and_return("/usr/bin/ruby")
      dirs = [ "/usr/local/bin", "/usr/bin", shim_dir ]
      expect(described_class.without_picked_ruby(dirs)).to eq(dirs)
    end

    it "asks the shim again after a version manager's global version file changes" do
      app = File.join(@dir, "alpha")
      home = File.join(@dir, "home")
      runs = File.join(@dir, "runs")
      same = File.join(@dir, "same", "ruby")
      FileUtils.mkdir_p(File.dirname(same))
      File.write(same, "#!/bin/sh\necho run >> #{runs.inspect}\nexec #{RbConfig.ruby.inspect} \"$@\"\n")
      File.chmod(0o755, same)
      custom = File.join(@dir, "custom")
      cases = [ [ {}, ".rbenv/version" ], [ { "RBENV_ROOT" => custom }, "../custom/version" ],
                [ {}, ".tool-versions" ], [ { "ASDF_DEFAULT_TOOL_VERSIONS_FILENAME" => ".asdf-versions" }, ".asdf-versions" ],
                [ {}, ".config/mise/config.toml" ], [ { "XDG_CONFIG_HOME" => custom }, "../custom/mise/mise.toml" ],
                [ { "MISE_CONFIG_DIR" => custom }, "../custom/config.toml" ], [ { "MISE_GLOBAL_CONFIG_FILE" => File.join(custom, "g.toml") }, "../custom/g.toml" ] ]
      expect(cases.size).to eq(8)
      cases.each do |extra, file|
        environment = extra.merge("PATH" => File.dirname(same), "HOME" => home)
        rubies = {}
        FileUtils.rm_f(runs)
        2.times { described_class.child_command({}, installed, app, environment, rubies) }
        FileUtils.mkdir_p(File.dirname(File.join(home, file)))
        File.write(File.join(home, file), "ruby 3.3.0\n")
        described_class.child_command({}, installed, app, environment, rubies)
        expect(File.readlines(runs).size).to eq(2), file
      end
    end

    it "keeps this Ruby's gems for the same Ruby, and keeps a checkout or a bundle on this Ruby" do
      same = { "PATH" => File.dirname(RbConfig.ruby), "RUBYOPT" => "-W0 -rbundler/setup" }
      env, argv = described_class.child_command({}, installed, "/apps/a", same)
      expect(argv.first).to eq(RbConfig.ruby)
      expect(env).to eq(pins)

      env, argv = described_class.child_command({}, installed, "/apps/a", { "PATH" => shims, "RUBYOPT" => "-W0 -r/x/bundler/setup" })
      expect(env).to include("GEM_HOME" => nil, "RUBYOPT" => "-W0")

      bundled = [ RbConfig.ruby, "-I", "lib", "exe" ]
      expect(described_class.child_command({ "BUNDLE_GEMFILE" => "/g" }, bundled, "/apps/a", { "PATH" => shims }))
        .to eq([ pins.merge("BUNDLE_GEMFILE" => "/g"), [ *bundled, "serve", "--app-path", "/apps/a" ] ])
    end

    it "starts the app's Ruby in the app's folder, without what pins the session's Ruby or this Ruby's gems" do
      session_pins = { "RBENV_DIR" => @dir, "RBENV_VERSION" => "3.3.0", "ASDF_RUBY_VERSION" => "3.3.0", "MISE_RUBY_VERSION" => "3.3.0",
                       "GEM_HOME" => @dir, "GEM_PATH" => @dir, "BUNDLE_GEMFILE" => File.join(@dir, "Gemfile"), "BUNDLE_PATH" => @dir,
                       "BUNDLER_SETUP" => "x", "RUBYOPT" => "-rbundler/setup", "RUBYLIB" => @dir }
      saved = session_pins.keys.to_h { |name| [ name, ENV[name] ] }
      begin
        session_pins.each { |name, value| ENV[name] = value }
        environment = ENV.to_h.merge("PATH" => [ shims, ENV["PATH"] ].join(File::PATH_SEPARATOR))
        shimmed = ->(root) { described_class.child_command({}, installed, root, environment) }
        serve(call(1, { app: "beta" }), server: described_class.new(target, command: shimmed))
      ensure
        saved.each { |name, value| ENV[name] = value }
      end

      expect(File.read(File.join(@dir, "cwd")).strip).to eq(File.join(@dir, "svc", "beta"))
      got = File.read(File.join(@dir, "env")).lines.to_h { |line| line.chomp.split("=", 2) }
      expect(got.keys & session_pins.keys).to eq([])
    end

    it "answers for an app whose Ruby has no copy of the gem with that Ruby and the command that installs one" do
      empty = File.join(@dir, "no-gems")
      gemless = ->(root) { described_class.child_command({ "GEM_HOME" => empty, "GEM_PATH" => empty, "RUBYOPT" => nil, "BUNDLE_GEMFILE" => nil,
                                                           "BUNDLE_BIN_PATH" => nil, "RUBYLIB" => nil, "BUNDLE_LOCKFILE" => nil, "BUNDLER_SETUP" => nil,
                                                           "BUNDLER_VERSION" => nil }, installed, root, ENV) }
      reply = serve(call(1, { app: "alpha" }), server: described_class.new(target, command: gemless))[1]

      expect(text(reply)).to include("The server for the app alpha (#{File.join(@dir, "alpha")}) stopped before it answered: ")
        .and include("(Ruby #{RUBY_VERSION}) has no rails-ai-context: run `gem install rails-ai-context` with that Ruby in #{File.join(@dir, "alpha")}")
    end
  end

  def alive?(pid)
    Process.kill(0, pid)
    true
  rescue Errno::ESRCH
    false
  end

  # Each start writes its pid on a line of its own, then runs the script.
  def recording(script)
    pids = File.join(@dir, "pids")
    command = ->(_root) { [ {}, [ RbConfig.ruby, "-rjson", "-e", "File.write(#{pids.inspect}, \"\#{Process.pid}\\n\", mode: 'a'); #{script}" ] ] }
    [ command, -> { File.exist?(pids) ? File.readlines(pids).map { |line| Integer(line) } : [] } ]
  end

  def dead_within(seconds, pids)
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + seconds
    sleep 0.1 while pids.any? { |pid| alive?(pid) } && Process.clock_gettime(Process::CLOCK_MONOTONIC) < deadline
    pids.map { |pid| alive?(pid) }
  end

  it "answers for an app's server that closed its output but keeps running, then stops it" do
    command, pids = recording("$stdout.reopen(File::NULL); sleep 60")
    session(described_class.new(target, command: command)) do |client|
      asked = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      reply = client.ask("tools/call", { name: "rails_get_schema", arguments: { app: "alpha" } })

      expect(text(reply)).to include("stopped before it answered: it closed its output")
      expect(Process.clock_gettime(Process::CLOCK_MONOTONIC) - asked).to be < 4
      expect(dead_within(15, pids.call)).to eq([ false ])
    end
  end

  it "stops an app's server it was still stopping when its input ends" do
    command, pids = recording("$stdout.reopen(File::NULL); sleep 60")
    client = Session.new(described_class.new(target, command: command))
    client.ask("tools/call", { name: "rails_get_schema", arguments: { app: "alpha" } })
    client.close

    expect(pids.call.map { |pid| alive?(pid) }).to eq([ false ])
  end

  it "goes on quietly where the client has gone" do
    gone = Object.new
    def gone.puts(*_lines) = raise(Errno::EPIPE)
    def gone.flush = nil
    described_class.new(target, command: command).run(requests({ jsonrpc: "2.0", id: 1, method: "ping" }, call(2, { app: "alpha" })), gone)

    expect($stderr.string).not_to include("terminated with exception")
  end

  it "stops an app's server that answered initialize with an error, and starts another at the next call" do
    command, pids = recording(<<~RUBY)
      $stdout.sync = true
      $stdin.each_line do |line|
        asked = JSON.parse(line)
        puts JSON.generate(jsonrpc: "2.0", id: asked["id"], error: { code: -32_000, message: "no database" }) if asked["id"]
      end
    RUBY
    session(described_class.new(target, command: command)) do |client|
      2.times do
        reply = client.ask("tools/call", { name: "rails_get_schema", arguments: { app: "alpha" } })
        expect(text(reply)).to include("stopped before it answered: no database")
      end

      expect(pids.call.size).to eq(2)
      expect(dead_within(15, pids.call)).to eq([ false, false ])
    end
  end

  it "tells the client the list changed where an app's server lists its tools while a list is being answered" do
    server = described_class.new(target, command: command)
    fired = false
    allow(server).to receive(:entry).and_wrap_original do |entry, listed|
      unless fired
        fired = true
        Thread.new do
          server.instance_variable_get(:@lock).synchronize do
            server.instance_variable_get(:@served)["alpha"] = { "custom_widgets" => { "name" => "custom_widgets", "inputSchema" => { "type" => "object" } } }
          end
          server.send(:announce)
        end
        sleep 0.3
      end
      entry.call(listed)
    end
    session(server) do |client|
      expect(client.ask("tools/list").dig("result", "tools").map { |tool| tool["name"] }).not_to include("custom_widgets")
      sleep 0.5
      client.ask("ping")

      expect(client.notes).to eq([ "notifications/tools/list_changed" ])
    end
  end

  it "answers other apps and the lists while one app's Ruby is still being asked for" do
    asking = Queue.new
    release = Queue.new
    slow = lambda do |root|
      if root.end_with?("alpha")
        asking << true
        release.pop
      end
      command.call(root)
    end
    session(described_class.new(target, command: slow)) do |client|
      client.tell(call(99, { app: "alpha" }))
      asking.pop
      Timeout.timeout(20) do
        expect(client.ask("tools/list").dig("result", "tools")).not_to be_empty
        expect(text(client.ask("tools/call", { name: "rails_get_schema", arguments: { app: "beta" } }))).to include("gadgets")
      end
    ensure
      release << true
    end
  end

  it "stops each app's server when its input ends, one still booting too, and returns" do
    command, pids = recording("sleep 60")
    client = Session.new(described_class.new(target, command: command))
    client.tell(call(1, { app: "alpha" }))
    Timeout.timeout(30) do
      sleep 0.1 while pids.call.empty?
      client.close
    end

    expect(pids.call.map { |pid| alive?(pid) }).to eq([ false ])
  end

  it "stops each app's server when its input ends" do
    pid_file = File.join(@dir, "child.pid")
    recorded = lambda do |root|
      env, argv = command.call(root)
      [ env, [ RbConfig.ruby, "-e", "File.write(ARGV.shift, Process.pid.to_s); exec(*ARGV)", pid_file, *argv ] ]
    end
    serve(call(1, { app: "alpha", detail: "summary" }), server: described_class.new(target, command: recorded))
    pid = Integer(File.read(pid_file))

    expect { Process.kill(0, pid) }.to raise_error(Errno::ESRCH)
  end
end
