# frozen_string_literal: true

require "spec_helper"
require "tmpdir"
require "fileutils"

RSpec.describe RailsAiContext::CLI::EntryBoot do
  describe ".app_present?" do
    it "is true for a directory with config/environment.rb" do
      Dir.mktmpdir do |dir|
        FileUtils.mkdir_p(File.join(dir, "config"))
        File.write(File.join(dir, "config/environment.rb"), "")
        expect(described_class.app_present?(dir)).to be true
      end
    end

    it "is false for an empty directory" do
      Dir.mktmpdir { |dir| expect(described_class.app_present?(dir)).to be false }
    end

    # An engine keeps its dummy app under spec/dummy; its root has app/ and
    # no config/. The static tier can read it; the boot tier cannot.
    it "accepts a source-only engine repo only when asked to" do
      Dir.mktmpdir do |dir|
        FileUtils.mkdir_p(File.join(dir, "app/models"))
        File.write(File.join(dir, "app/models/widget.rb"), "class Widget; end\n")
        expect(described_class.app_present?(dir)).to be false
        expect(described_class.app_present?(dir, allow_source_only: true)).to be true
      end
    end
  end

  # Sinatra MVC trees keep config/environment.rb and app/ too.
  describe "a tree whose bundle resolved no Rails" do
    def sinatra_tree(dir, lock_gems: %w[sinatra activerecord])
      FileUtils.mkdir_p(File.join(dir, "config"))
      FileUtils.mkdir_p(File.join(dir, "app/controllers"))
      File.write(File.join(dir, "config/environment.rb"), "require 'sinatra/activerecord'\n")
      File.write(File.join(dir, "app/controllers/songs_controller.rb"), "class SongsController; end\n")
      specs = lock_gems.map { |name| "    #{name} (1.0.0)\n" }.join
      File.write(File.join(dir, "Gemfile.lock"), "GEM\n  remote: https://rubygems.org/\n  specs:\n#{specs}\n")
    end

    it "is no app in either tier" do
      Dir.mktmpdir do |dir|
        sinatra_tree(dir)
        expect(described_class.app_present?(dir)).to be false
        expect(described_class.app_present?(dir, allow_source_only: true)).to be false
      end
    end

    it "answers No Rails app found, booted and with --no-boot" do
      Dir.mktmpdir do |dir|
        sinatra_tree(dir)
        [ { no_boot: false }, { no_boot: true } ].each do |flags|
          outcome = described_class.call(root: dir, allow_static: true, **flags)
          expect([ outcome.tier, outcome.messages.first ]).to eq([ :absent, "Error: No Rails app found in #{dir}" ])
        end
      end
    end

    it "is an app when the lockfile resolves railties, as an engine's does" do
      Dir.mktmpdir do |dir|
        sinatra_tree(dir, lock_gems: %w[railties activerecord])
        expect(described_class.app_present?(dir)).to be true
      end
    end

    it "is an app when config/application.rb is there, whatever the lockfile says" do
      Dir.mktmpdir do |dir|
        sinatra_tree(dir)
        File.write(File.join(dir, "config/application.rb"), "")
        expect(described_class.app_present?(dir)).to be true
      end
    end
  end

  # With no lockfile, the Gemfile decides before anything boots: loading the tree's
  # environment.rb runs its bundler/setup, which writes a lockfile into the user's tree.
  describe "a tree with no lockfile whose Gemfile names no Rails" do
    def unlocked_tree(dir, gemfile)
      FileUtils.mkdir_p(File.join(dir, "config"))
      File.write(File.join(dir, "config/environment.rb"), "raise 'environment.rb was loaded'\n")
      File.write(File.join(dir, "Gemfile"), gemfile)
    end

    it "answers No Rails app found without loading config/environment.rb" do
      Dir.mktmpdir do |dir|
        unlocked_tree(dir, %(source "https://rubygems.org"\ngroup :test do\n  gem "rack-test"\nend\ngem "sinatra"\n))
        outcome = described_class.call(root: dir, allow_static: true)
        expect([ outcome.tier, outcome.messages.first ]).to eq([ :absent, "Error: No Rails app found in #{dir}" ])
      end
    end

    it "is an app when the Gemfile names rails, or names its gems through a gemspec" do
      Dir.mktmpdir do |dir|
        unlocked_tree(dir, %(gem "rails", "~> 8.0"\n))
        expect(described_class.app_present?(dir)).to be true
        File.write(File.join(dir, "Gemfile"), %(source "https://rubygems.org"\ngemspec\n))
        expect(described_class.app_present?(dir)).to be true
      end
    end

    it "decides before the gem is loaded, as the binary's entry does" do
      Dir.mktmpdir do |dir|
        unlocked_tree(dir, %(gem "sinatra"\n))
        lib = File.expand_path("../../../../lib", __dir__)
        script = %(require "rails_ai_context/cli/entry_boot"; p RailsAiContext::CLI::EntryBoot.app_present?(#{dir.inspect}))
        out = `ruby -I #{lib.shellescape} -e #{script.shellescape} 2>&1`
        expect(out.strip).to eq("false")
      end
    end
  end

  # The binstub activates the gem's whole dependency tree before the app's
  # Bundler.setup runs, and Bundler adds its own paths behind the ones already
  # in $LOAD_PATH. A gem left there keeps winning over the version the app
  # locks - json 3 over a lock pinning json 2, and the app stops booting at
  # the first gem that reads the removed API.
  describe "pre-boot gem activations" do
    around do |example|
      stash = described_class.preboot_gem_specs
      example.run
    ensure
      described_class.preboot_gem_specs = stash
    end

    def spec_double(name, path)
      instance_double(Gem::Specification, name: name, full_require_paths: [ path ])
    end

    def drop_with(specs, path)
      described_class.preboot_gem_specs = specs
      allow(ENV).to receive(:[]).and_call_original
      allow(ENV).to receive(:[]).with("BUNDLE_BIN_PATH").and_return(nil)
      # The registry the method clears is the running suite's own.
      allow(Gem).to receive(:loaded_specs).and_return(specs.dup)
      $LOAD_PATH << path
      described_class.send(:drop_conflicting_gem_activations!, [])
    end

    it "takes the load path of every gem the binstub activated out of $LOAD_PATH" do
      drop_with({ "json" => spec_double("json", "/fake/json-3.0.2/lib") }, "/fake/json-3.0.2/lib")

      expect($LOAD_PATH).not_to include("/fake/json-3.0.2/lib")
    ensure
      $LOAD_PATH.delete("/fake/json-3.0.2/lib")
    end

    it "leaves bundler's own load path alone" do
      drop_with({ "bundler" => spec_double("bundler", "/fake/bundler/lib") }, "/fake/bundler/lib")

      expect($LOAD_PATH).to include("/fake/bundler/lib")
    ensure
      $LOAD_PATH.delete("/fake/bundler/lib")
    end
  end

  # A restored gem path appended to the end of $LOAD_PATH sits behind Ruby's
  # own lib dirs, so a gem with a default-gem twin loads half from each: prism
  # answered `require "prism"` from Ruby 3.4's copy and `require "prism/prism"`
  # from the gem's newer C extension, and every tool died on
  # `uninitialized constant Prism::CurrentVersionError`.
  describe "the load path after the boot" do
    around do |example|
      paths = $LOAD_PATH.dup
      example.run
    ensure
      $LOAD_PATH.replace(paths)
    end

    # What decides the restore is whether the app's bundle got onto the load
    # path, not whether the boot finished. OpenProject and Canvas fail inside
    # Bundler.setup; an app whose initializer raises fails after Bundler.require
    # has already loaded half its gems, and dropping their paths then left
    # ActiveSupport unable to finish loading and mcp loaded from two versions.
    it "puts the pre-boot order back exactly when the app's bundle never got set up" do
      pre_boot = $LOAD_PATH.dup.push("/fake/prism-9.9.9/lib")

      described_class.send(:restore_standalone_environment!, pre_boot, {}, [])

      expect($LOAD_PATH).to eq(pre_boot)
    end

    it "keeps the app's bundle when it was set up, even though the boot then failed" do
      pre_boot = $LOAD_PATH.dup.push("/fake/prism-9.9.9/lib")
      $LOAD_PATH.unshift("/fake/app-bundle/lib")

      described_class.send(:restore_standalone_environment!, pre_boot, {}, [])

      expect($LOAD_PATH).to include("/fake/app-bundle/lib")
    end

    # The app's bundle still has to win for a gem both it and the binstub
    # carry, which is the pin a private API app's boot needs, and a gem with a
    # default-gem twin (prism) must not load half from Ruby's own copy.
    it "splices a restored path behind the app's bundle and ahead of Ruby's own lib dirs" do
      pre_boot = $LOAD_PATH.dup.push("/fake/prism-9.9.9/lib")
      $LOAD_PATH.unshift("/fake/app-bundle/lib")

      described_class.send(:restore_standalone_environment!, pre_boot, {}, [])

      expect($LOAD_PATH.index("/fake/app-bundle/lib"))
        .to be < $LOAD_PATH.index("/fake/prism-9.9.9/lib")
      expect($LOAD_PATH.index("/fake/prism-9.9.9/lib"))
        .to be < $LOAD_PATH.index(RbConfig::CONFIG["rubylibdir"])
    end
  end

  # The list of gems to re-register used to be hand-kept, and named json-schema,
  # which no mcp version this gem supports pulls in. Every standalone run on an
  # app that cannot boot warned about it, which is noise that hides a real one.
  describe "the gemspecs put back after the boot" do
    def spec_double(name)
      instance_double(Gem::Specification, name: name, full_require_paths: [])
    end

    def restore(stash, registry)
      messages = []
      allow(ENV).to receive(:[]).and_call_original
      allow(ENV).to receive(:[]).with("BUNDLE_BIN_PATH").and_return(nil)
      allow(Gem).to receive(:loaded_specs).and_return(registry)
      described_class.send(:restore_standalone_environment!, $LOAD_PATH.dup, stash, messages)
      messages
    end

    it "says nothing about a gem this gem does not use" do
      stash = { "mcp" => spec_double("mcp") }

      expect(restore(stash, {})).to be_empty
    end

    # An app that locks one of this gem's own dependencies has already loaded
    # it, and a second copy in the same process is the mixed load. The app's
    # copy is used when it satisfies the gemspec, and named when it does not.
    def gem_spec_with(requirement)
      instance_double(
        Gem::Specification, name: "rails-ai-context", full_require_paths: [],
        runtime_dependencies: [ Gem::Dependency.new("mcp", *requirement) ]
      )
    end

    def app_spec(name, version)
      instance_double(Gem::Specification, name: name, version: Gem::Version.new(version))
    end

    it "takes the app's copy of a dependency quietly when it fits the gemspec" do
      stash = { "rails-ai-context" => gem_spec_with([ ">= 0.13", "< 2.0" ]) }

      expect(restore(stash, { "mcp" => app_spec("mcp", "0.24.0") })).to be_empty
    end

    it "names a dependency the app locks at a version this gem does not support" do
      stash = { "rails-ai-context" => gem_spec_with([ ">= 0.13", "< 2.0" ]) }

      messages = restore(stash, { "mcp" => app_spec("mcp", "0.10.0") })

      expect(messages.join("\n")).to include("mcp 0.10.0", ">= 0.13, < 2.0")
    end

    it "still warns for a gemspec that did not make it back" do
      refusing_registry = Class.new(Hash) { def []=(_key, _value); end }.new
      stash = { "mcp" => spec_double("mcp") }

      messages = restore(stash, refusing_registry)

      expect(messages.first).to include("could not restore gemspec(s): mcp")
    end
  end

  describe ".call" do
    # Entering the static tier is real here, not stubbed.
    around do |example|
      app_root = RailsAiContext.configuration.app_root
      example.run
    ensure
      RailsAiContext.tier = :runtime
      RailsAiContext.static_reason = nil
      RailsAiContext.static_kind = nil
      RailsAiContext.configuration.app_root = app_root
    end

    it "answers :absent with the message for a directory that is not an app" do
      Dir.mktmpdir do |dir|
        outcome = described_class.call(root: dir, allow_static: true)
        expect(outcome.tier).to eq(:absent)
        expect(outcome.messages.first).to eq("Error: No Rails app found in #{dir}")
      end
    end

    # Standing in an app root and being told to go to the app root is the
    # wrong diagnosis: the tree is an app, it just cannot boot.
    it "names the missing file for a tree that has source but no environment" do
      Dir.mktmpdir do |dir|
        FileUtils.mkdir_p(File.join(dir, "config"))
        File.write(File.join(dir, "config/application.rb"), "")
        outcome = described_class.call(root: dir, allow_static: false)

        expect(outcome.tier).to eq(:absent)
        expect(outcome.messages.first).to include("config/environment.rb", dir)
        expect(outcome.messages.first).not_to include("No Rails app found")
      end
    end

    it "names the command in that message when it knows it" do
      Dir.mktmpdir do |dir|
        FileUtils.mkdir_p(File.join(dir, "config"))
        File.write(File.join(dir, "config/application.rb"), "")
        outcome = described_class.call(root: dir, allow_static: false, command: "doctor")

        expect(outcome.messages.first).to eq("Error: doctor needs a bootable app: no config/environment.rb in #{dir}")
      end
    end

    # A source-only tree is what the static tier exists for: nothing can boot
    # without config/environment.rb, so the tier takes over rather than
    # printing a boot failure the reader cannot act on.
    it "falls through to the static tier for a source-only tree, without booting" do
      allow(RailsAiContext::BootManager).to receive(:boot!).and_raise("boot attempted")

      Dir.mktmpdir do |dir|
        FileUtils.mkdir_p(File.join(dir, "config"))
        File.write(File.join(dir, "config/application.rb"), "")

        outcome = described_class.call(root: dir, allow_static: true, allow_source_only: true, command: "init")

        expect(outcome.tier).to eq(:static)
        expect(outcome.kind).to eq(:source_only)
        expect(outcome.reason).to include("config/environment.rb")
        expect(outcome.messages).not_to include(a_string_starting_with("[rails-ai-context] App boot failed:"))
        expect(RailsAiContext.static_reason).to eq("no config/environment.rb in the app root")
      end
    end

    # doctor reads a source-only tree to diagnose it, and the diagnosis is the
    # missing file itself - not a boot failure downstream of it.
    it "refuses a source-only tree without booting when static is not allowed" do
      allow(RailsAiContext::BootManager).to receive(:boot!).and_raise("boot attempted")

      Dir.mktmpdir do |dir|
        FileUtils.mkdir_p(File.join(dir, "config"))
        File.write(File.join(dir, "config/application.rb"), "")

        outcome = described_class.call(root: dir, allow_static: false, allow_source_only: true, command: "doctor")

        expect(outcome.tier).to eq(:absent)
        expect(outcome.messages.first).to eq("Error: doctor needs a bootable app: no config/environment.rb in #{dir}")
      end
    end

    it "answers :static without booting when --no-boot is passed to a readable app" do
      Dir.mktmpdir do |dir|
        FileUtils.mkdir_p(File.join(dir, "app/models"))
        File.write(File.join(dir, "app/models/widget.rb"), "class Widget; end\n")
        outcome = described_class.call(root: dir, allow_static: true, no_boot: true)
        expect(outcome.tier).to eq(:static)
        expect(outcome.kind).to eq(:requested)
        expect(outcome.reason).to eq("static mode requested with --no-boot")
      end
    end

    it "refuses --no-boot on a directory with nothing to read" do
      Dir.mktmpdir do |dir|
        outcome = described_class.call(root: dir, allow_static: true, no_boot: true)
        expect(outcome.tier).to eq(:absent)
      end
    end

    # `reason` on an :absent outcome is what tells the binary a boot failed,
    # and --no-boot never booted anything.
    it "carries no reason when --no-boot cannot load the gem" do
      allow(described_class).to receive(:require_gem_without_app!).and_raise(LoadError, "cannot load such file -- mcp")

      Dir.mktmpdir do |dir|
        FileUtils.mkdir_p(File.join(dir, "app/models"))
        File.write(File.join(dir, "app/models/widget.rb"), "class Widget; end\n")

        outcome = described_class.call(root: dir, allow_static: true, no_boot: true)
        expect(outcome.tier).to eq(:absent)
        expect(outcome.reason).to be_nil
      end
    end

    it "hands the static tier the root it was given" do
      Dir.mktmpdir do |dir|
        FileUtils.mkdir_p(File.join(dir, "app/models"))
        File.write(File.join(dir, "app/models/widget.rb"), "class Widget; end\n")
        expect(RailsAiContext::Configuration).to receive(:auto_load!).with(dir)

        described_class.call(root: dir, allow_static: true, no_boot: true)
        expect(RailsAiContext.configuration.app_root).to eq(dir)
      end
    end

    context "with a failed boot" do
      let(:failed) { RailsAiContext::BootManager::Result.new(status: :failed, error: RuntimeError.new("boom")) }

      before { allow(RailsAiContext::BootManager).to receive(:boot!).and_return(failed) }

      def failing_app
        Dir.mktmpdir do |dir|
          FileUtils.mkdir_p(File.join(dir, "config"))
          File.write(File.join(dir, "config/environment.rb"), "raise 'boom'\n")
          yield dir
        end
      end

      it "degrades to :static when static is allowed, and to :absent when it is not" do
        failing_app do |dir|
          allowed = described_class.call(root: dir, allow_static: true)
          expect(allowed.tier).to eq(:static)
          expect(allowed.kind).to eq(:boot_failed)
          expect(allowed.messages).to include(a_string_starting_with("[rails-ai-context] App boot failed:"))

          refused = described_class.call(root: dir, allow_static: false)
          expect(refused.tier).to eq(:absent)
          expect(refused.messages.first).to eq("Error: Rails app failed to boot in #{dir}")
        end
      end

      it "gives a command that needs the boot the whole missing-gem list" do
        gems = (1..10).map { |i| "gem#{i}-1.0" }
        allow(RailsAiContext::BootManager).to receive(:boot!).and_return(
          RailsAiContext::BootManager::Result.new(status: :failed,
                                                  error: RuntimeError.new("Could not find #{gems.join(', ')} in locally installed gems"))
        )
        failing_app do |dir|
          expect(described_class.call(root: dir, allow_static: false).messages.join).to include("gem10-1.0")
          expect(described_class.call(root: dir, allow_static: true).messages.join).not_to include("gem10-1.0")
        end
      end

      it "names the failure once" do
        failing_app do |dir|
          messages = described_class.call(root: dir, allow_static: true).messages

          expect(messages.count { |line| line.include?("boom") }).to eq(1)
          expect(messages).to include("[rails-ai-context] static tier active")
        end
      end

      # The app calls RailsAiContext.configure but does not bundle the gem, so
      # the constant is the bare namespace the binary opened. Both branches
      # must say so: the static banner sends the user to doctor, and doctor
      # boots with static refused.
      context "when an initializer calls configure without the gem in the Gemfile" do
        let(:failed) do
          RailsAiContext::BootManager::Result.new(
            status: :failed,
            error: NoMethodError.new("undefined method 'configure' for module RailsAiContext")
          )
        end

        it "names the cause and the two ways out in the static banner" do
          failing_app do |dir|
            messages = described_class.call(root: dir, allow_static: true).messages.join("\n")

            expect(messages).to include("does not bundle the gem")
            expect(messages).to include("bundle add rails-ai-context --group development")
            expect(messages).to include(".rails-ai-context.yml")
          end
        end

        it "names the same cause where static is refused" do
          failing_app do |dir|
            messages = described_class.call(root: dir, allow_static: false).messages.join("\n")

            expect(messages).to include("does not bundle the gem")
            expect(messages).to include("bundle add rails-ai-context --group development")
          end
        end

        it "says nothing about configure for an unrelated boot failure" do
          other = RailsAiContext::BootManager::Result.new(status: :failed, error: RuntimeError.new("boom"))
          allow(RailsAiContext::BootManager).to receive(:boot!).and_return(other)

          failing_app do |dir|
            messages = described_class.call(root: dir, allow_static: false).messages.join("\n")

            expect(messages).not_to include("does not bundle the gem")
          end
        end
      end

      # A broken install cannot load the gem either; the boot diagnosis
      # collected so far must still reach the terminal.
      # doctor refuses the static tier, so its branch returns before the old
      # restore ran and left the process with no load path for its own gem.
      it "puts the stripped load paths back even where static is refused" do
        described_class.preboot_gem_specs = {
          "json" => instance_double(Gem::Specification, name: "json",
                                    full_require_paths: [ "/fake/json-3.0.2/lib" ])
        }
        allow(ENV).to receive(:[]).and_call_original
        allow(ENV).to receive(:[]).with("BUNDLE_BIN_PATH").and_return(nil)
        allow(Gem).to receive(:loaded_specs).and_return(Gem.loaded_specs.dup)
        $LOAD_PATH << "/fake/json-3.0.2/lib"

        failing_app do |dir|
          outcome = described_class.call(root: dir, allow_static: false, command: "doctor")

          expect(outcome.tier).to eq(:absent)
          expect($LOAD_PATH).to include("/fake/json-3.0.2/lib")
        end
      ensure
        described_class.preboot_gem_specs = {}
        $LOAD_PATH.delete("/fake/json-3.0.2/lib")
      end

      it "keeps the boot-failure lines when the static tier itself cannot load" do
        allow(described_class).to receive(:require_gem_without_app!).and_raise(LoadError, "cannot load such file -- mcp")

        failing_app do |dir|
          outcome = described_class.call(root: dir, allow_static: true)
          expect(outcome.tier).to eq(:absent)
          expect(outcome.messages).to include(a_string_starting_with("[rails-ai-context] App boot failed:"))
          expect(outcome.messages.last).to eq("Error: cannot load such file -- mcp")
          expect(outcome.reason).to eq(failed.failure_summary)
        end
      end
    end
  end
end
