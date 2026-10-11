# frozen_string_literal: true

require "spec_helper"
require "tmpdir"
require "open3"

RSpec.describe RailsAiContext::Install::ValidationHook do
  describe ".script" do
    it "names its apps on a line a shell reads, and loops over them" do
      script = described_class.script([ "apps/web", "my app" ], standalone: false)

      expect(script).to include("# rails-ai-context apps: apps/web my\\ app\n")
      expect(script).to include("for app in apps/web my\\ app; do\n")
      expect(script).to include(%((cd "./$app" && bundle exec rails-ai-context tool validate --files "$files")\n))
      expect(script).to include("--diff-filter=d")
    end

    # The rake task has to boot the app, and its errors went to /dev/null:
    # an app whose initializer needs a variable the shell lacks failed every
    # commit, and the hook said only that validation found issues. The CLI
    # checks the files from source when the app cannot boot, and says why.
    it "validates through the app's bundle's CLI in an in-Gemfile install, and lets its errors through" do
      script = described_class.script([ "." ], standalone: false)

      expect(script).to include("if command -v bundle &> /dev/null")
      expect(script).to include(%(bundle exec rails-ai-context tool validate --files "$files"))
      expect(script).not_to include("ai:tool")
      expect(script).not_to include("2>/dev/null")
    end

    it "validates with the binary in a standalone install, which has no rake tasks" do
      script = described_class.script([ "." ], standalone: true)

      expect(script).to include("if command -v rails-ai-context &> /dev/null")
      expect(script).to include(%(rails-ai-context tool validate --files "$files"))
      expect(script).not_to include("ai:tool")
      expect(script).not_to include("2>/dev/null")
    end

    it "is a script bash reads, whatever the app paths hold" do
      Dir.mktmpdir do |dir|
        path = File.join(dir, "pre-commit")
        File.write(path, described_class.script([ ".", "a b", "x$y", %(q"r), "it's" ], standalone: false))

        _out, status = Open3.capture2e("bash", "-n", path)

        expect(status.success?).to be(true)
      end
    end
  end

  describe ".coverage" do
    it "reads the apps and the install form of a hook nobody changed" do
      [ true, false ].each do |standalone|
        coverage = described_class.coverage(described_class.script(%w[apps/web apps/admin], standalone: standalone))

        expect(coverage.to_h).to eq(apps: %w[apps/web apps/admin], standalone: standalone, legacy: false)
      end
    end

    # Each was installed only for the app at the top of its repository.
    it "knows each earlier version's hook as the root app's" do
      expect(described_class::LEGACY.size).to eq(3)
      described_class::LEGACY.each do |legacy, standalone|
        expect(described_class.coverage(legacy).to_h).to eq(apps: [ "." ], standalone: standalone, legacy: true)
        expect(described_class.coverage(legacy.b).to_h).to eq(apps: [ "." ], standalone: standalone, legacy: true)
      end
    end

    # The form for several apps that ran the rake task with its errors thrown
    # away, written for any apps, in either install form.
    it "knows the earlier form for several apps as an earlier version's, with its apps and form" do
      expect(described_class.earlier_script([ "." ], standalone: false))
        .to include(%((cd "./$app" && rails 'ai:tool[validate]' files="$files" 2>/dev/null)))
      [ true, false ].each do |standalone|
        [ [ "." ], %w[apps/web apps/admin] ].each do |apps|
          coverage = described_class.coverage(described_class.earlier_script(apps, standalone: standalone))

          expect(coverage.to_h).to eq(apps: apps, standalone: standalone, legacy: true)
        end
      end
    end

    it "claims no hook changed by hand since" do
      expect(described_class.coverage(described_class.script([ "." ], standalone: false) + "echo mine\n")).to be_nil
      expect(described_class.coverage("#{described_class::LEGACY.keys.first}echo mine\n")).to be_nil
      expect(described_class.coverage("#!/bin/bash\nrails-ai-context tool validate\n")).to be_nil
    end
  end

  describe ".listed" do
    it "reads the apps line the way a shell does" do
      expect(described_class.listed("# rails-ai-context apps: . apps/web my\\ app\n")).to eq([ ".", "apps/web", "my app" ])
      expect(described_class.listed("#!/bin/bash\n")).to be_nil
    end

    it "answers nil for a line a shell would not read, or bytes that are no text" do
      expect(described_class.listed(%(# rails-ai-context apps: apps/web "apps/x\n))).to be_nil
      expect(described_class.listed("# rails-ai-context apps: caf\xC3(\xFF\n".b)).to be_nil
    end
  end
end
