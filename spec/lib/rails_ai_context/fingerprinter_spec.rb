# frozen_string_literal: true

require "spec_helper"
require "tmpdir"

RSpec.describe RailsAiContext::Fingerprinter do
  # A throwaway copy of the fixture app for every example here. The shared
  # spec/internal is written by some twenty other specs and by any second run
  # in the same checkout, so two reads of it a moment apart can disagree; and
  # these examples touch files, which must not reach anyone else's reads.
  let(:app) do
    @tmp_app_root = Dir.mktmpdir
    FileUtils.cp_r(File.join(Rails.root.to_s, "."), @tmp_app_root)
    FileUtils.touch(File.join(@tmp_app_root, "Gemfile.lock"))
    RailsAiContext::StaticApp.new(@tmp_app_root)
  end

  after { FileUtils.remove_entry(@tmp_app_root) if @tmp_app_root && Dir.exist?(@tmp_app_root) }

  describe ".compute" do
    it "returns a hex digest string" do
      result = described_class.compute(app)
      expect(result).to match(/\A[a-f0-9]{64}\z/)
    end

    it "returns the same value on repeated calls with no changes" do
      a = described_class.compute(app)
      b = described_class.compute(app)
      expect(a).to eq(b)
    end

    it "detects changes to .rake files" do
      before = described_class.compute(app)
      File.utime(Time.now + 5, Time.now + 5, File.join(app.root, "lib/tasks/example.rake"))
      after = described_class.compute(app)

      expect(before).not_to eq(after)
    end

    it "detects a change to every source the rake task introspector reads" do
      root = app.root.to_s
      %w[rakelib lib/generators/widget lib/templates/erb/scaffold lib/acme].each { |dir| FileUtils.mkdir_p(File.join(root, dir)) }
      files = %w[Rakefile config.ru rakelib/deploy.rake lib/generators/widget/widget_generator.rb
                 lib/templates/erb/scaffold/index.html.erb.tt lib/acme/railtie.rb]
      files.each { |file| File.write(File.join(root, file), "\n") }
      files.each do |file|
        before = described_class.compute(app)
        File.utime(Time.now + 5, Time.now + 5, File.join(root, file))
        expect(described_class.compute(app)).not_to eq(before), file
      end
    end

    it "detects a change to every app, test and spec source an introspector reads into the context" do
      root = app.root.to_s
      files = %w[test/mailers/previews/user_mailer_preview.rb spec/mailers/previews/user_mailer_preview.rb
                 app/subscribers/sql_subscriber.rb app/blueprints/user_blueprint.rb app/resources/user_resource.rb
                 app/misc/rodauth_main.rb app/mailboxes/application_mailbox.rb test/fixtures/widgets.yml
                 spec/factories/widgets.rb spec/models/widget_spec.rb]
      files.each do |file|
        FileUtils.mkdir_p(File.join(root, File.dirname(file)))
        File.write(File.join(root, file), "\n")
      end
      files.each do |file|
        before = described_class.compute(app)
        File.utime(Time.now + 5, Time.now + 5, File.join(root, file))
        expect(described_class.compute(app)).not_to eq(before), file
      end
    end

    it "detects changes to .erb view files" do
      before = described_class.compute(app)
      File.utime(Time.now + 5, Time.now + 5, File.join(app.root, "app/views/posts/index.html.erb"))
      after = described_class.compute(app)

      expect(before).not_to eq(after)
    end

    it "detects changes to .js stimulus controllers" do
      before = described_class.compute(app)
      File.utime(Time.now + 5, Time.now + 5, File.join(app.root, "app/javascript/controllers/hello_controller.js"))
      after = described_class.compute(app)

      expect(before).not_to eq(after)
    end

    it "ignores a bundler's build output under app/assets/builds, which no reader reads" do
      root = app.root.to_s
      build = File.join(root, "app/assets/builds/application.js")
      FileUtils.mkdir_p(File.dirname(build))
      File.write(build, "console.log(1);\n")
      before = described_class.compute(app)
      File.utime(Time.now + 5, Time.now + 5, build)

      expect(described_class.compute(app)).to eq(before)
      expect(described_class.changed_since(root, Time.now + 1)).to eq([])
    end

    it "ignores a re-recorded VCR cassette, and counts one added or removed" do
      root = app.root.to_s
      cassette = File.join(root, "spec/fixtures/vcr_cassettes/stripe.yml")
      FileUtils.mkdir_p(File.dirname(cassette))
      File.write(cassette, "---\n")
      before = described_class.compute(app)
      File.utime(Time.now + 5, Time.now + 5, cassette)

      expect(described_class.compute(app)).to eq(before)
      expect(described_class.changed_since(root, Time.now + 1)).to eq([])

      File.write(File.join(File.dirname(cassette), "github.yml"), "---\n")
      expect(described_class.compute(app)).not_to eq(before)
    end

    it "keeps mtime staleness for a cassettes folder outside spec/ and test/, and under a root path holding one" do
      root = app.root.to_s
      view = File.join(root, "app/views/cassettes/index.html.erb")
      FileUtils.mkdir_p(File.dirname(view))
      File.write(view, "\n")
      before = described_class.compute(app)
      File.utime(Time.now + 5, Time.now + 5, view)
      expect(described_class.compute(app)).not_to eq(before)

      Dir.mktmpdir do |dir|
        nested = File.join(dir, "cassettes", "shop")
        FileUtils.mkdir_p(File.join(nested, "app/models"))
        model = File.join(nested, "app/models/post.rb")
        File.write(model, "class Post < ApplicationRecord\nend\n")
        nested_app = RailsAiContext::StaticApp.new(nested)
        before = described_class.compute(nested_app)
        File.utime(Time.now + 5, Time.now + 5, model)

        expect(described_class.compute(nested_app)).not_to eq(before)
        expect(described_class.changed_since(nested, Time.now + 1)).to eq([ "app/models" ])
      end
    end

    it "detects a change to a controller outside app/javascript" do
      Dir.mktmpdir do |root|
        FileUtils.mkdir_p(File.join(root, "app/webpacker/controllers"))
        js_file = File.join(root, "app/webpacker/controllers/bulk_form_controller.js")
        File.write(js_file, %(import { Controller } from "@hotwired/stimulus";\n))
        app = RailsAiContext::StaticApp.new(root)

        mark = described_class.mark(app)
        File.utime(Time.now + 5, Time.now + 5, js_file)

        expect(described_class).to be_stale(app, mark)
      end
    end

    it "includes app/components in WATCHED_DIRS" do
      expect(described_class::WATCHED_DIRS).to include("app/components")
    end

    # The job introspector reads three directories, so an app that keeps its
    # workers in app/sidekiq served a cached answer that had never seen the
    # edit.
    it "watches every directory the job introspector reads" do
      expect(described_class::WATCHED_DIRS)
        .to include(*RailsAiContext::Introspectors::JobIntrospector::JOB_DIRS)
      expect(described_class::RESOLVED_KINDS)
        .to include(*RailsAiContext::Introspectors::JobIntrospector::JOB_DIRS)
    end

    it "watches every directory Grape endpoints are read from" do
      expect(described_class::WATCHED_DIRS).to include(*RailsAiContext::Introspectors::GrapeEndpoints::DIRS)
    end

    it "detects a change to a worker in app/sidekiq" do
      dir = File.join(app.root, "app/sidekiq")
      FileUtils.mkdir_p(dir)

      before = described_class.compute(app)
      File.write(File.join(dir, "fingerprint_probe_job.rb"), "class FingerprintProbeJob; include Sidekiq::Job; end\n")
      after = described_class.compute(app)

      expect(before).not_to eq(after)
    end

    it "detects a change to any SQL dump in db/, a configured schema_dump included" do
      %w[primary_structure.sql structure.sql queue_structure.sql].each do |name|
        path = File.join(app.root, "db", name)
        File.write(path, "CREATE TABLE \"a\" (\"id\" integer);\n")

        before = described_class.compute(app)
        File.utime(Time.now + 5, Time.now + 5, path)
        expect(described_class.compute(app)).not_to eq(before), name
      end
    end

    it "includes package.json in WATCHED_FILES" do
      expect(described_class::WATCHED_FILES).to include("package.json")
    end

    it "includes tsconfig.json in WATCHED_FILES" do
      expect(described_class::WATCHED_FILES).to include("tsconfig.json")
    end

    it "includes the Gemfile in WATCHED_FILES" do
      expect(described_class::WATCHED_FILES).to include("Gemfile")
    end

    it "watches a packwerk pack's models, so a pack edit invalidates the cache" do
      require "tmpdir"
      Dir.mktmpdir do |root|
        FileUtils.mkdir_p(File.join(root, "packs", "billing", "app", "models"))
        dirs = described_class.send(:watched_dirs, root)
        expect(dirs).to include(File.join(root, "packs", "billing", "app", "models"))
      end
    end

    it "watches every concern home the resolver names" do
      require "tmpdir"
      Dir.mktmpdir do |root|
        FileUtils.mkdir_p(File.join(root, "app", "serializers", "concerns"))
        expect(described_class.scope_dirs(root)).to include(File.join(root, "app", "serializers", "concerns"))
      end
    end

    it "watches a dir once, through the watched dir that holds it" do
      require "tmpdir"
      Dir.mktmpdir do |root|
        FileUtils.mkdir_p(File.join(root, "lib", "api"))
        File.write(File.join(root, "lib", "api", "base.rb"), "")
        dirs = described_class.send(:watched_dirs, root)
        expect(dirs).to include(File.join(root, "lib"))
        expect(dirs).not_to include(File.join(root, "lib", "api"))
        expect(described_class.changed_since(root, Time.now - 60)).to eq([ "lib/api" ])
      end
    end

    it "detects changes to package.json" do
      package_json = File.join(app.root, "package.json")
      File.write(package_json, "{}\n") unless File.exist?(package_json)

      before = described_class.compute(app)
      File.utime(Time.now + 5, Time.now + 5, package_json)
      after = described_class.compute(app)

      expect(before).not_to eq(after)
    end
  end

  describe ".mark and .stale?" do
    it "is not stale until a watched file changes" do
      mark = described_class.mark(app)
      expect(described_class.stale?(app, mark)).to be false

      path = File.join(app.root, "app/models/post.rb")
      File.utime(Time.now + 5, Time.now + 5, path)
      expect(described_class.stale?(app, mark)).to be true
    end

    # config/routes.rb is covered by the config directory, not by a file entry.
    it "goes stale when config/routes.rb changes" do
      mark = described_class.mark(app)
      path = File.join(app.root, "config/routes.rb")
      File.utime(Time.now + 5, Time.now + 5, path)

      expect(described_class.stale?(app, mark)).to be true
    end
  end

  describe ".changed_since" do
    it "names the directories with a file newer than the time, root-relative" do
      path = File.join(app.root, "app/models/post.rb")
      File.utime(Time.now + 5, Time.now + 5, path)
      expect(described_class.changed_since(app.root, Time.now)).to include("app/models")
      expect(described_class.changed_since(app.root, Time.now + 10)).to eq([])
    end
  end
end
