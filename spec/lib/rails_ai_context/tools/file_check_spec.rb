# frozen_string_literal: true

require "spec_helper"

# A server answered from its caches until something dropped them. Without
# live reload nothing did; with it, `listen` delivered an edit a second and
# a half later, so an agent that edited a model and asked about it at once
# was answered from before the edit - and two calls close together shared
# one check, so the second missed an edit made between them.
RSpec.describe "a server's check of the app's files at each call" do
  let(:base) { RailsAiContext::Tools::BaseTool }
  let(:root) { Dir.mktmpdir }
  let(:model) { File.join(root, "app", "models", "post.rb") }

  # An app that reloads, as in development; this suite's own does not.
  before do
    FileUtils.mkdir_p(File.dirname(model))
    File.write(model, "class Post\nend\n")
    allow(RailsAiContext::CodeReloader).to receive(:reloadable?).and_return(true)
    allow(RailsAiContext::CodeReloader).to receive(:reload!).and_return(true)
    allow(base).to receive(:reset_all_caches!).and_call_original
  end

  after { FileUtils.remove_entry(root) }

  it "walks nothing in a process that started no server" do
    expect(RailsAiContext::Fingerprinter).not_to receive(:watched_dirs)

    base.refresh_if_files_changed!
  end

  it "leaves a server whose files cannot be read to serve without the check" do
    expect { base.check_files_per_call!(Object.new) }.not_to raise_error
    expect(base::FILE_CHECK[:snapshot]).to be_nil
  end

  context "once a server has asked for it" do
    before { base.check_files_per_call!(RailsAiContext::StaticApp.new(root)) }

    it "keeps the caches while the files are as they were" do
      base.refresh_if_files_changed!

      expect(base).not_to have_received(:reset_all_caches!)
      expect(RailsAiContext::CodeReloader).not_to have_received(:reload!)
    end

    it "reloads the app's code, then drops the caches, at the first call after an edit" do
      File.write(model, "class Post\n  has_many :comments\nend\n")

      base.refresh_if_files_changed!
      base.refresh_if_files_changed!

      expect(RailsAiContext::CodeReloader).to have_received(:reload!).once.ordered
      expect(base).to have_received(:reset_all_caches!).once.ordered
    end

    it "sees an edit made between two calls with no time between them" do
      base.refresh_if_files_changed!
      File.write(model, "class Post\n  has_many :tags\nend\n")
      base.refresh_if_files_changed!

      expect(RailsAiContext::CodeReloader).to have_received(:reload!).once
    end

    # Two writes in one clock tick leave the same mtime, and a same-length
    # edit the same size.
    it "sees an edit that leaves the file's stat as it was" do
      File.write(model, "class Post\n  has_many :aaaa\nend\n")
      base.refresh_if_files_changed!
      stamp = File.mtime(model)
      File.write(model, "class Post\n  has_many :bbbb\nend\n")
      File.utime(stamp, stamp, model)

      base.refresh_if_files_changed!

      expect(RailsAiContext::CodeReloader).to have_received(:reload!).twice
    end

    it "leaves the code to Rails inside a request the app serves" do
      allow(RailsAiContext::CodeReloader).to receive(:inside_app_executor?).and_return(true)
      File.write(model, "class Post\n  has_many :comments\nend\n")

      base.refresh_if_files_changed!

      expect(RailsAiContext::CodeReloader).not_to have_received(:reload!)
      expect(base).to have_received(:reset_all_caches!).once
    end

    it "checks once for a call that answers by calling other tools" do
      snapshot = base::FILE_CHECK[:snapshot]
      allow(snapshot).to receive(:changed?).and_call_original

      RailsAiContext::Tools::GetContext.call(model: "Post")

      expect(snapshot).to have_received(:changed?).once
    end

    it "checks for a call made inside a run, and drops what the run read before the edit" do
      allow(RailsAiContext).to receive(:introspect).and_return({ app_name: "Before" }, { app_name: "After" })

      RailsAiContext::RunCache.around do
        first = RailsAiContext::Tools::GetConventions.send(:cached_context)[:app_name]
        File.write(model, "class Post\n  has_many :comments\nend\n")
        RailsAiContext::Tools::GetConventions.call

        expect([ first, RailsAiContext::Tools::GetConventions.send(:cached_context)[:app_name] ]).to eq(%w[Before After])
      end
    end

    context "through the built server's tools/call" do
      let(:server) { RailsAiContext::Server.new(Rails.application, transport: :stdio).build }
      let(:snapshot) { base::FILE_CHECK[:snapshot] }

      def answer(name = "rails_get_conventions", arguments = {})
        call = { jsonrpc: "2.0", id: 1, method: "tools/call", params: { name: name, arguments: arguments } }
        server.handle(call).dig(:result, :content, 0, :text)
      end

      def introspect_as(*patterns)
        contexts = patterns.map { |pattern| { conventions: { patterns: [ pattern ] } } }
        allow(RailsAiContext).to receive(:introspect).and_return(*contexts)
      end

      it "answers the second of two calls from the files as edited between them" do
        introspect_as("before_edit", "after_edit")

        first = answer
        File.write(model, "class Post\n  has_many :comments\nend\n")
        second = answer

        expect(first).to include("Before edit")
        expect(second).to include("After edit")
        expect(second).not_to include("Before edit")
        expect(RailsAiContext::CodeReloader).to have_received(:reload!).once
      end

      it "ends the answer after an edit with the stale code note when the app cannot reload" do
        introspect_as("before_edit", "after_edit")
        allow(RailsAiContext::CodeReloader).to receive(:reloadable?).and_return(false)
        allow(RailsAiContext::CodeReloader).to receive(:changed_code).and_return([ "app/models/post.rb" ])

        first = answer
        File.write(model, "class Post\n  has_many :comments\nend\n")

        expect(first).not_to include("App code changed")
        expect(answer).to include("After edit", "App code changed since this server booted (app/models/post.rb)")
      end

      it "checks once for a tool that calls other tools, and for a retired tool name" do
        allow(snapshot).to receive(:changed?).and_call_original

        answer("rails_get_context", { model: "Post" })
        answer("rails_get_gems")

        expect(snapshot).to have_received(:changed?).twice
      end

      it "keeps the custom tools the server resolved, warning of none again" do
        saved = RailsAiContext.configuration.custom_tools
        RailsAiContext.configuration.custom_tools = [ "NoSuchApp::Tool" ]
        expect { server }.to output(/Skipping custom_tool/).to_stderr
        File.write(model, "class Post\n  has_many :comments\nend\n")

        expect { answer("rails_get_context", { model: "Post" }) }.not_to output(/Skipping custom_tool/).to_stderr
      ensure
        RailsAiContext.configuration.custom_tools = saved
      end
    end

    context "with calls running at once, as over HTTP" do
      let(:snapshot) { base::FILE_CHECK[:snapshot] }
      let(:checks) { [] }
      let(:release) { Queue.new }

      # The first check holds until released, so later calls arrive during it.
      before do
        entered = Queue.new
        allow(snapshot).to receive(:changed?) do
          checks << Thread.current
          if checks.size == 1
            entered << true
            release.pop
          end
          false
        end
        @first = Thread.new { base.refresh_if_files_changed! }
        entered.pop
      end

      after { release << true if @first.alive? }

      it "has a call that arrives during a check wait for one that began after it" do
        second = Thread.new { base.refresh_if_files_changed! }
        sleep 0.05
        expect(second).to be_alive

        release << true
        [ @first, second ].each(&:join)

        expect(checks.size).to eq(2)
        expect(checks.last).to eq(second)
      end

      it "has calls that arrive during the same check share the next one" do
        waiting = Array.new(3) { Thread.new { base.refresh_if_files_changed! } }
        # Each has arrived once it blocks, on the mutex or on the check.
        Timeout.timeout(5) { sleep 0.01 until waiting.all? { |thread| thread.status == "sleep" } }

        release << true
        [ @first, *waiting ].each(&:join)

        expect(checks.size).to eq(2)
      end
    end

    # Bootsnap's compile cache knows a file by its size and the second of its
    # mtime: a model saved twice in one second at the same size was reloaded
    # as the first save, and the answer said nothing of it.
    context "with Bootsnap's compile cache loading the app's code" do
      let(:note) do
        "App code was saved twice within one second at the same size (app/models/post.rb); Bootsnap's compile cache " \
          "knows a file by its size and the second it was saved, so what reflection reads, such as associations and " \
          "enums, may be from the earlier save. Save the file again a second later, or start the server with " \
          "DISABLE_BOOTSNAP_COMPILE_CACHE=1."
      end
      let(:second) { Time.now.to_i }

      def save(content, millisecond, second: self.second)
        File.write(model, content)
        time = Time.at(second, millisecond, :millisecond)
        File.utime(time, time, model)
      end

      def answer
        RailsAiContext::Tools::GetConventions.call.content.first[:text]
      end

      before do
        allow(RailsAiContext::CodeReloader).to receive(:compile_cached) { |files| files.map { |file| file.delete_prefix("#{File.realpath(root)}/").delete_prefix("#{root}/") } }
        save("class Post\n  has_many :aaaa\nend\n", 100)
        base.check_files_per_call!(RailsAiContext::StaticApp.new(root))
      end

      it "names a file saved again in that second at that size in every answer, until it is saved in another" do
        save("class Post\n  has_many :bbbb\nend\n", 600)
        expect(answer).to end_with("\n\n---\n_#{note}_")
        expect(answer).to end_with("\n\n---\n_#{note}_")

        save("class Post\n  has_many :cccc\nend\n", 0, second: second + 1)
        expect(answer).not_to include("Bootsnap")
      end

      it "says nothing of a save that changed the size" do
        save("class Post\n  has_many :bbbbbb\nend\n", 600)

        expect(answer).not_to include("Bootsnap")
      end
    end

    it "checks again at the call after a check that failed" do
      snapshot = base::FILE_CHECK[:snapshot]
      outcomes = [ -> { raise Errno::EACCES, "app/models" }, -> { true } ]
      allow(snapshot).to receive(:changed?) { outcomes.shift.call }

      base.refresh_if_files_changed!
      base.refresh_if_files_changed!

      expect(snapshot).to have_received(:changed?).twice
      expect(RailsAiContext::CodeReloader).to have_received(:reload!).once
    end
  end

  # The path a client's call takes: an answer read before an edit is not
  # served after it.
  it "gives a tool call the context as the files are now" do
    base.check_files_per_call!(RailsAiContext::StaticApp.new(root))
    allow(RailsAiContext).to receive(:introspect).and_return({ app_name: "Before" }, { app_name: "After" })

    first = RailsAiContext::Tools::GetConventions.send(:cached_context)[:app_name]
    File.write(model, "class Post\n  has_many :comments\nend\n")
    RailsAiContext::Tools::GetConventions.call

    expect([ first, RailsAiContext::Tools::GetConventions.send(:cached_context)[:app_name] ]).to eq(%w[Before After])
  end

  # RAILS_ENV=test, or production with eager loading: Rails keeps the code it
  # booted with, so an edited model was answered from boot-time reflection,
  # labelled verified, with no word that the file had changed.
  context "when the app cannot reload its code" do
    let(:note) do
      "App code changed since this server booted (app/models/post.rb); RAILS_ENV=test does not reload code, " \
        "so what reflection reads, such as associations and enums, is as of boot. Restart the server to see the edit."
    end

    before do
      allow(RailsAiContext::CodeReloader).to receive(:reloadable?).and_return(false)
      allow(RailsAiContext::CodeReloader).to receive(:changed_code).and_return([ "app/models/post.rb" ])
      base.check_files_per_call!(RailsAiContext::StaticApp.new(root))
      File.write(model, "class Post\n  has_many :comments\nend\n")
    end

    it "ends every answer with the files changed since they loaded" do
      text = RailsAiContext::Tools::GetConventions.call.content.first[:text]

      expect(text).to end_with("\n\n---\n_#{note}_")
      expect(RailsAiContext::CodeReloader).not_to have_received(:reload!)
    end

    it "ends an error with it too, and carries it under a key in a JSON answer" do
      base.refresh_if_files_changed!

      expect(base.error_response("No such model.").content.first[:text]).to end_with("_#{note}_")
      expect(JSON.parse(base.json_response({ "rows" => [] }).content.first[:text])).to include("_stale_code" => note)
    end

    # A resource read answered from the same boot-time reflection with
    # nothing said: a model's body read `"dependent": "destroy"` while the
    # file said `:nullify`.
    it "carries it under the same key in a resource's JSON body" do
      allow(RailsAiContext).to receive(:introspect).and_return(
        models: { "Post" => { table_name: "posts", associations: [ { type: "has_many", name: "comments", dependent: "destroy" } ] } },
        conventions: { patterns: [] }
      )
      server = RailsAiContext::Server.new(Rails.application, transport: :stdio).build
      read = ->(uri) { server.handle({ jsonrpc: "2.0", id: 1, method: "resources/read", params: { uri: uri } }).dig(:result, :contents, 0, :text) }

      expect(JSON.parse(read.call("rails-ai-context://models/Post"))).to include("_stale_code" => note)
      expect(JSON.parse(read.call("rails://conventions"))).to include("_stale_code" => note)
    end

    it "leaves it out of a sub-tool's text that a composing tool quotes" do
      base.refresh_if_files_changed!

      expect(base.response_text(base.text_response("inner answer"))).to eq("inner answer")
    end

    it "says nothing while no app code changed" do
      allow(RailsAiContext::CodeReloader).to receive(:changed_code).and_return([])

      expect(RailsAiContext::Tools::GetConventions.call.content.first[:text]).not_to include("App code changed")
      expect(RailsAiContext::VFS.json_content("rails://schema", { "tables" => [] })[:text]).not_to include("_stale_code")
    end
  end
end
