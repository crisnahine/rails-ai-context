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

    it "detects a script or template the conventions count reads, past .js and .erb" do
      root = app.root.to_s
      files = %w[app/javascript/main.tsx app/javascript/old.jsx app/javascript/App.vue app/views/posts/feed.rss.ruby app/views/posts/show.json.jbuilder]
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

    it "detects changes to .js stimulus controllers" do
      before = described_class.compute(app)
      File.utime(Time.now + 5, Time.now + 5, File.join(app.root, "app/javascript/controllers/hello_controller.js"))
      after = described_class.compute(app)

      expect(before).not_to eq(after)
    end

    # The readers walk a directory linked in from the app's repository, so an
    # edit there is one the cache must see; the glob listed the link and stopped.
    it "detects a change inside a directory linked in from the app's repository" do
      Dir.mktmpdir do |repo|
        root = File.join(repo, "apps/web")
        FileUtils.mkdir_p([ File.join(repo, ".git"), File.join(repo, "shared/billing"), File.join(root, "app/models") ])
        File.write(File.join(repo, "shared/billing/invoice.rb"), "class Billing::Invoice; end\n")
        File.symlink("../../../../shared/billing", File.join(root, "app/models/billing"))
        linked_app = RailsAiContext::StaticApp.new(root)

        before = described_class.compute(linked_app)
        File.utime(Time.now + 5, Time.now + 5, File.join(repo, "shared/billing/invoice.rb"))

        expect(described_class.compute(linked_app)).not_to eq(before)
        expect(described_class.changed_since(root, Time.now + 1)).to eq([ "app/models" ])
      end
    end

    # Only a link with no extension in its name was asked whether it leads to
    # a directory, where the readers enter any.
    it "detects a change inside a linked directory whose name has an extension" do
      Dir.mktmpdir do |repo|
        root = File.join(repo, "apps/web")
        FileUtils.mkdir_p([ File.join(repo, ".git"), File.join(repo, "shared/billing"), File.join(root, "app/models") ])
        File.write(File.join(repo, "shared/billing/invoice.rb"), "class Billing::Invoice; end\n")
        File.symlink("../../../../shared/billing", File.join(root, "app/models/billing.v2"))
        linked_app = RailsAiContext::StaticApp.new(root)

        before = described_class.compute(linked_app)
        File.utime(Time.now + 5, Time.now + 5, File.join(repo, "shared/billing/invoice.rb"))

        expect(described_class.compute(linked_app)).not_to eq(before)
      end
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

    # Each one outside the watched dirs that an introspector or the env scan reads or checks for.
    ROOT_READS = %w[Dockerfile Dockerfile.dev docker-compose.yml docker-compose.yaml Procfile Procfile.dev Capfile app.json
                    fly.toml render.yaml render.yml railway.toml railway.json Jenkinsfile .gitlab-ci.yml .travis.yml
                    bitbucket-pipelines.yml buildkite.yml .buildkite/pipeline.yml .circleci/config.yml .github/workflows/ci.yml
                    .rubocop.yml .standard.yml .erb_lint.yml .erb-lint.yml .rspec Steepfile sorbet/config
                    vite.config.ts webpack.config.js rollup.config.js bun.config.js pnpm-workspace.yaml turbo.json nx.json
                    lerna.json yarn.lock package-lock.json pnpm-lock.yaml bun.lock bun.lockb frontend/package.json
                    client/yarn.lock app/javascript/package.json .ruby-version .tool-versions mise.toml .mise.toml
                    .config/mise.toml widget.gemspec bin/setup config/sidekiq.yaml angular.json next.config.js
                    rspack.config.js jsconfig.json frontend/angular.json frontend/jsconfig.json Dockerfile.production
                    .env.example .env.sample .env.template config/credentials.yml.example config.ru].freeze

    it "detects every root file, bin script and config YAML a reader reads being added, edited and removed" do
      root = app.root.to_s
      ROOT_READS.each do |file|
        path = File.join(root, file)
        FileUtils.mkdir_p(File.dirname(path))
        before = described_class.compute(app)
        File.write(path, "\n")
        added = described_class.compute(app)
        expect(added).not_to eq(before), "#{file} added"
        File.utime(Time.now + 5, Time.now + 5, path)
        expect(described_class.compute(app)).not_to eq(added), "#{file} edited"
        File.delete(path)
        expect(described_class.compute(app)).to eq(before), "#{file} removed"
      end
    end

    it "reads bin's files only, and enters a folder only where an entry names one, never through a link" do
      Dir.mktmpdir do |tmp|
        root = File.join(tmp, "app")
        outside = File.join(tmp, "system-lib")
        FileUtils.mkdir_p([ File.join(root, "bin/helpers"), File.join(root, ".github/workflows/reusable"), outside ])
        50.times { |n| File.write(File.join(outside, "lib#{n}.so"), "") }
        File.symlink(outside, File.join(root, "bin/linked"))
        File.symlink(outside, File.join(root, ".github/workflows/linked"))
        %w[bin/setup bin/helpers/x.sh .github/workflows/reusable/build.yml].each { |file| File.write(File.join(root, file), "") }

        expect(described_class.watched(root).sort).to eq(%w[.github/workflows/reusable/build.yml bin/setup])
      end
    end

    it "never enters a workflows folder that is itself a link, nor hands it to the watcher" do
      Dir.mktmpdir do |tmp|
        root = File.join(tmp, "app")
        outside = File.join(tmp, "shared-workflows")
        FileUtils.mkdir_p([ File.join(root, ".github"), outside ])
        File.write(File.join(outside, "build.yml"), "")
        File.symlink(outside, File.join(root, ".github/workflows"))

        expect(described_class.watched(root)).not_to include(a_string_starting_with(".github/workflows"))
        expect(described_class.manifest_dirs(root)).to be_empty
      end
    end

    it "detects the manifests in a frontend_paths directory the app declared" do
      allow(RailsAiContext.configuration).to receive(:frontend_paths).and_return([ "ui" ])
      path = File.join(app.root.to_s, "ui/package.json")
      FileUtils.mkdir_p(File.dirname(path))
      before = described_class.compute(app)
      File.write(path, "{}\n")

      expect(described_class.compute(app)).not_to eq(before)
    end

    it "detects the manifests in a declared frontend_paths folder whose name has brackets" do
      allow(RailsAiContext.configuration).to receive(:frontend_paths).and_return([ "ui[v2]" ])
      Dir.mktmpdir do |root|
        FileUtils.mkdir_p(File.join(root, "ui[v2]"))
        File.write(File.join(root, "ui[v2]/package.json"), "{}\n")
        File.write(File.join(root, "config.ru"), "\n")

        expect(described_class.watched(root)).to include("ui[v2]/package.json", "config.ru")
        expect(described_class.watched(root)).not_to include("./config.ru")
      end
    end

    it "detects an edit to the files PackageJson reads outside the app root" do
      Dir.mktmpdir do |tmp|
        repo = File.join(tmp, "repo")
        root = File.join(repo, "apps/shop")
        web = File.join(repo, "web")
        FileUtils.mkdir_p([ root, web ])
        system("git", "init", "-q", repo, exception: true)
        allow(RailsAiContext.configuration).to receive(:frontend_paths).and_return([ "../../web" ])
        app = Struct.new(:root).new(Pathname.new(root))
        { File.join(web, "package.json") => "{}\n", File.join(repo, "yarn.lock") => "\n" }.each do |path, body|
          File.write(path, body)
          before = described_class.compute(app)
          File.utime(Time.now + 5, Time.now + 5, path)

          expect(described_class.compute(app)).not_to eq(before), path
        end
      end
    end

    it "leaves out what a reader's tree skips, and hands only source folders to the watcher" do
      root = app.root.to_s
      %w[public/packs/manifest.json public/system/users/000/001/meta.json docs/node_modules/x/package.json].each do |file|
        FileUtils.mkdir_p(File.dirname(File.join(root, file)))
      end
      before = described_class.compute(app)
      %w[public/packs/manifest.json public/system/users/000/001/meta.json docs/node_modules/x/package.json].each do |file|
        File.write(File.join(root, file), "{}\n")
      end

      expect(described_class.compute(app)).to eq(before)
      expect(described_class.watched_dirs(root)).not_to include(File.join(root, "public"), File.join(root, "docs"))
      expect(described_class::WATCHED_FILES).not_to include("config/vite.json")
    end

    it "detects a rename that keeps the mtime and the sort position" do
      root = app.root.to_s
      before = described_class.compute(app)
      File.rename(File.join(root, "app/models/post.rb"), File.join(root, "app/models/posts.rb"))

      expect(described_class.compute(app)).not_to eq(before)
    end

    it "skips dependency and build folders beside the files it reads" do
      root = app.root.to_s
      before = described_class.compute(app)
      %w[node_modules/left-pad/package.json frontend/node_modules/x/package.json tmp/cache/x.rb log/x.yml
         app/assets/builds/application.js].each do |file|
        FileUtils.mkdir_p(File.dirname(File.join(root, file)))
        File.write(File.join(root, file), "\n")
      end

      expect(described_class.compute(app)).to eq(before)
    end
  end

  describe "a bundler's build output" do
    def write_all(root, files)
      files.each do |file, body|
        FileUtils.mkdir_p(File.dirname(File.join(root, file)))
        File.write(File.join(root, file), body)
      end
    end

    let(:spec_body) { %({"openapi": "3.0.0"}\n) }

    it "moves neither the fingerprint nor the per-call look, nor reads as an API spec, in the default or a configured folder" do
      root = app.root.to_s
      write_all(root, "config/shakapacker.yml" => "default: &default\n  public_output_path: webpack_out\ntest:\n  <<: *default\n  public_output_path: webpack_out_test\n" \
                                                "production:\n  public_root_path: app/static\n  public_output_path: out\n",
                      "config/vite.json" => %({"all": {"publicOutputDir": "built_vite"}, "test": {"publicDir": "public", "publicOutputDir": "built_vite_test"}}\n))
      before = described_class.compute(app)
      snapshot = described_class::Snapshot.new(root)
      snapshot.changed?

      outputs = %w[public/packs-test public/vite-dev public/vite-test app/assets/builds public/webpack_out public/webpack_out_test public/built_vite public/built_vite_test]
      write_all(root, outputs.to_h { |dir| [ File.join(dir, "openapi.json"), spec_body ] }.merge("app/static/out/application.js" => "x\n"))

      expect(described_class.compute(app)).to eq(before)
      expect(snapshot.changed?).to be(false)
      openapi = RailsAiContext::Introspectors::ApiIntrospector.new(app).send(:detect_openapi_specs)
      expect(openapi).to eq([])
    end

    it "keeps a configured folder outside the app or at the public root in the look" do
      root = app.root.to_s
      write_all(root, "config/shakapacker.yml" => "default:\n  public_output_path: \"\"\n", "config/vite.json" => %({"all": {"publicOutputDir": "../../elsewhere"}}\n))

      expect(described_class.build_dirs(root)).to eq([])
    end
  end

  describe "the files the readers open" do
    let(:planted) do
      {
        "openapi.json" => %({"openapi": "3.0.0"}\n),
        "swagger/v1/swagger.yaml" => "openapi: 3.0.1\n",
        "swagger/v2/swagger.json" => %({"swagger": "2.0"}\n),
        "public/api/openapi.yml" => "openapi: 3.0.1\n",
        "docs/api.yml" => "swagger: \"2.0\"\n",
        "config/vite.json" => %({"all": {"sourceCodeDir": "app/frontend"}}\n),
        "app/views/posts/show.json.rabl" => "object @post\n",
        "Dockerfile" => "FROM ruby\n",
        "package.json" => %({"dependencies": {"react": "18.2.0"}}\n),
        ".github/workflows/ci.yml" => "on: push\n",
        "Jenkinsfile" => "pipeline {}\n",
        "Procfile.dev" => "web: bin/rails server\n",
        "docker-compose.yml" => "services: {}\n"
      }.merge(RailsAiContext::Introspectors::DevOpsIntrospector::DEPLOY_MARKERS.keys.to_h { |file| [ file, "\n" ] })
    end

    # Root-relative, every file under the root a reader opened, checked for or globbed while the block ran.
    def read_while(root)
      seen = Set.new
      %i[read binread open foreach readlines exist? file? size?].each do |name|
        allow(File).to receive(name).and_wrap_original do |original, *args, **options, &block|
          seen << File.expand_path(args.first.to_s) if args.first.is_a?(String) || args.first.is_a?(Pathname)
          original.call(*args, **options, &block)
        end
      end
      %i[glob children].each do |name|
        allow(Dir).to receive(name).and_wrap_original do |original, *args, **options, &block|
          base = name == :children ? args.first.to_s : options[:base].to_s
          record = ->(hit) { seen << File.expand_path(hit.to_s, base.empty? ? Dir.pwd : base) }
          if block
            next original.call(*args, **options) do |hit|
              record.call(hit)
              block.call(hit)
            end
          end

          original.call(*args, **options).tap { |found| Array(found).each(&record) }
        end
      end
      yield
      RSpec::Mocks.space.proxy_for(File).reset
      RSpec::Mocks.space.proxy_for(Dir).reset
      seen.select { |path| path.start_with?("#{root}/") && File.file?(path) }.map { |path| path.delete_prefix("#{root}/") }
    end

    it "sees an edit to every file a reader opens or checks for, in the snapshot and the fingerprint" do
      Dir.mktmpdir do |tmp|
        root = File.join(File.realpath(tmp), "app")
        FileUtils.cp_r(File.expand_path("../../fixtures/static_app", __dir__), root)
        planted.each do |file, body|
          FileUtils.mkdir_p(File.join(root, File.dirname(file)))
          File.write(File.join(root, file), body)
        end
        app = RailsAiContext::StaticApp.new(root)
        files = read_while(root) do
          RailsAiContext::Introspector::INTROSPECTOR_MAP.each_value do |klass|
            next unless klass.answers_statically?

            reader = klass.new(app)
            klass.static_tier == RailsAiContext::Introspectors::StaticTier::ALTERNATE_SOURCE ? reader.send(:static_call) : reader.call
          rescue StandardError
            next
          end
        end
        # The CI check globs .github/workflows/ for the folder alone, so its file is edited below without being seen here.
        expect(files).to include(*(planted.keys - [ ".github/workflows/ci.yml" ]))

        snapshot = RailsAiContext::Fingerprinter::Snapshot.new(root)
        snapshot.changed?
        unseen = (files | planted.keys).sort.reject do |file|
          mark = described_class.mark(app)
          File.write(File.join(root, file), "#{File.read(File.join(root, file))}\n")
          snapshot.changed? && described_class.stale?(app, mark)
        end

        expect(unseen).to eq([])
      end
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

  describe "an app folder whose name has glob characters" do
    %w[my[app] my{a,b}].each do |name|
      it "sees a new model in #{name}" do
        Dir.mktmpdir do |base|
          root = File.join(base, name)
          FileUtils.mkdir_p(File.join(root, "app/models"))
          File.write(File.join(root, "app/models/post.rb"), "class Post < ApplicationRecord\nend\n")
          app = RailsAiContext::StaticApp.new(root)
          mark = described_class.mark(app)
          File.write(File.join(root, "app/models/new_thing.rb"), "class NewThing; end\n")
          File.utime(Time.now + 5, Time.now + 5, File.join(root, "app/models/new_thing.rb"))

          expect(described_class.stale?(app, mark)).to be(true)
          expect(described_class.changed_since(root, Time.now + 1)).to eq([ "app/models" ])
        end
      end
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
