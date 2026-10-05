# frozen_string_literal: true

require "spec_helper"
require "tmpdir"
require "fileutils"

RSpec.describe RailsAiContext::PathResolver do
  around do |example|
    Dir.mktmpdir do |dir|
      @root = dir
      example.run
    end
  ensure
    RailsAiContext.configuration.extra_app_paths = []
  end

  def mkdirs(*paths)
    paths.each { |p| FileUtils.mkdir_p(File.join(@root, p)) }
  end

  # Two callers each wrapped initializer_files with the same
  # sub("#{root}/", ""), and both wanted the app-relative path.
  describe ".app_initializer_files" do
    it "answers the initializers app-relative, however the app spells them" do
      mkdirs("config/initializers")
      %w[009-omniauth.rb rack-attack.rb custom_devise.rb].each do |name|
        File.write(File.join(@root, "config", "initializers", name), "# x\n")
      end

      expect(described_class.app_initializer_files(@root, "rack_attack"))
        .to eq([ "config/initializers/rack-attack.rb" ])
      expect(described_class.app_initializer_files(@root, "omniauth"))
        .to eq([ "config/initializers/009-omniauth.rb" ])
      expect(described_class.app_initializer_files(@root, "devise"))
        .to eq([ "config/initializers/custom_devise.rb" ])
    end

    it "finds an initializer in a subdirectory" do
      mkdirs("config/initializers/security")
      File.write(File.join(@root, "config/initializers/security/cors.rb"), "# x\n")

      expect(described_class.app_initializer_files(@root, "cors")).to eq([ "config/initializers/security/cors.rb" ])
    end

    it "answers nothing when the app has none" do
      expect(described_class.app_initializer_files(@root, "rack_attack")).to eq([])
    end
  end

  describe ".initializer_paths" do
    it "lists initializers at any depth, in path order, without following a symlink loop" do
      mkdirs("config/initializers/i18n")
      File.write(File.join(@root, "config/initializers/z.rb"), "# x\n")
      File.write(File.join(@root, "config/initializers/i18n/locale.rb"), "# x\n")
      File.symlink(File.join(@root, "config/initializers"), File.join(@root, "config/initializers/i18n/loop"))

      expect(described_class.initializer_paths(@root).map { |path| path.delete_prefix("#{@root}/") })
        .to eq(%w[config/initializers/i18n/locale.rb config/initializers/z.rb])
    end

    it "leaves out an initializer that links outside the app root or to nothing" do
      mkdirs("config/initializers")
      Dir.mktmpdir do |outside|
        File.write(File.join(outside, "secret.rb"), "# x\n")
        File.symlink(File.join(outside, "secret.rb"), File.join(@root, "config/initializers/secret.rb"))
        File.symlink(File.join(@root, "missing.rb"), File.join(@root, "config/initializers/dangling.rb"))

        expect(described_class.initializer_paths(@root)).to eq([])
      end
    end

    it "answers nothing when the app has no initializers directory" do
      expect(described_class.initializer_paths(@root)).to eq([])
    end
  end

  describe ".file_for_constant" do
    it "finds a constant in a concerns directory and one in an in-repo engine's lib" do
      mkdirs("app/models/concerns", "engines/store/lib/store")
      File.write(File.join(@root, "app/models/concerns/archivable.rb"), "module Archivable; end\n")
      File.write(File.join(@root, "engines/store/lib/store/checkout.rb"), "module Store; class Checkout; end; end\n")

      expect(described_class.file_for_constant(@root, "Archivable"))
        .to eq(File.join(@root, "app/models/concerns/archivable.rb"))
      expect(described_class.file_for_constant(@root, "Store::Checkout"))
        .to eq(File.join(@root, "engines/store/lib/store/checkout.rb"))
    end

    it "finds a constant under a root config/application.rb adds" do
      mkdirs("config", "lib_static/open_project/authentication")
      File.write(File.join(@root, "config/application.rb"), <<~RUBY)
        module OpenProject
          class Application < Rails::Application
            config.autoload_paths << "lib_static"
          end
        end
      RUBY
      File.write(File.join(@root, "lib_static/open_project/authentication/manager.rb"),
                 "module OpenProject; module Authentication; class Manager; end; end; end\n")

      expect(described_class.file_for_constant(@root, "OpenProject::Authentication::Manager"))
        .to eq(File.join(@root, "lib_static/open_project/authentication/manager.rb"))
    end

    it "does not take a declared root that climbs out of the app" do
      mkdirs("config")
      outside = File.join(File.dirname(@root), "pa-f-shared-#{File.basename(@root)}")
      FileUtils.mkdir_p(File.join(outside, "shared_lib"))
      File.write(File.join(@root, "config/application.rb"), <<~RUBY)
        module Escapee
          class Application < Rails::Application
            config.autoload_paths << "\#{config.root}/../#{File.basename(outside)}"
          end
        end
      RUBY
      File.write(File.join(outside, "shared_lib/thing.rb"), "module SharedLib; class Thing; end; end\n")

      expect(described_class.declared_roots(@root)).to eq([])
      expect(described_class.file_for_constant(@root, "SharedLib::Thing")).to be_nil
    ensure
      FileUtils.rm_rf(outside)
    end

    it "answers nil for a constant no autoload root spells" do
      mkdirs("app/models")

      expect(described_class.file_for_constant(@root, "Rack::Cors")).to be_nil
    end
  end

  it "returns only the conventional dir for a stock app" do
    mkdirs("app/models")
    expect(described_class.model_dirs(@root)).to eq([ File.join(@root, "app/models") ])
  end

  it "includes packs and engines dirs, conventional first, packs before engines, each sorted" do
    mkdirs("app/models",
           "packs/billing/app/models", "packs/admin/app/models",
           "engines/store/app/models")
    expect(described_class.model_dirs(@root)).to eq([
      File.join(@root, "app/models"),
      File.join(@root, "packs/admin/app/models"),
      File.join(@root, "packs/billing/app/models"),
      File.join(@root, "engines/store/app/models")
    ])
  end

  it "includes configured extra_app_paths" do
    mkdirs("app/models", "src/app/models")
    RailsAiContext.configuration.extra_app_paths = [ "src" ]
    expect(described_class.model_dirs(@root)).to include(File.join(@root, "src/app/models"))
  end

  it "omits directories that do not exist" do
    mkdirs("packs/billing/app/models")
    RailsAiContext.configuration.extra_app_paths = [ "nope" ]
    expect(described_class.model_dirs(@root)).to eq([ File.join(@root, "packs/billing/app/models") ])
  end

  it "resolves controllers and views the same way" do
    mkdirs("app/controllers", "packs/billing/app/views")
    expect(described_class.controller_dirs(@root)).to eq([ File.join(@root, "app/controllers") ])
    expect(described_class.view_dirs(@root)).to eq([ File.join(@root, "packs/billing/app/views") ])
  end

  it "accepts a Pathname root" do
    mkdirs("app/models")
    expect(described_class.model_dirs(Pathname.new(@root))).to eq([ File.join(@root, "app/models") ])
  end

  describe "in-repo code roots" do
    def touch(*paths)
      paths.each do |p|
        FileUtils.mkdir_p(File.dirname(File.join(@root, p)))
        FileUtils.touch(File.join(@root, p))
      end
    end

    it "finds a Discourse-style plugin tree" do
      mkdirs("app/models", "plugins/chat/app/models")
      touch("plugins/chat/plugin.rb")
      expect(described_class.model_dirs(@root)).to include(File.join(@root, "plugins/chat/app/models"))
    end

    it "finds a gemspec-bearing module tree" do
      mkdirs("app/models", "modules/budgets/app/controllers")
      touch("modules/budgets/budgets.gemspec")
      expect(described_class.dirs_for(@root, "app/controllers"))
        .to include(File.join(@root, "modules/budgets/app/controllers"))
    end

    it "finds a nested plugin tree three levels down" do
      mkdirs("app/models", "gems/plugins/account_reports/app/models")
      touch("gems/plugins/account_reports/account_reports.gemspec")
      expect(described_class.model_dirs(@root))
        .to include(File.join(@root, "gems/plugins/account_reports/app/models"))
    end

    it "finds an engine declared only by lib/*/engine.rb" do
      mkdirs("app/models", "components/billing/app/models")
      touch("components/billing/lib/billing/engine.rb")
      expect(described_class.model_dirs(@root)).to include(File.join(@root, "components/billing/app/models"))
    end

    it "skips a JavaScript tree whose app/ only looks like Rails" do
      mkdirs("app/models", "frontend/ember/app/models", "frontend/ember/app/controllers")
      touch("frontend/ember/package.json")
      expect(described_class.model_dirs(@root)).to eq([ File.join(@root, "app/models") ])
    end

    it "skips dummy apps and vendored trees" do
      mkdirs("app/models",
             "spec/dummy/app/models", "test/dummy/app/models",
             "vendor/gems/thing/app/models", "node_modules/pkg/app/models")
      touch("spec/dummy/thing.gemspec", "test/dummy/thing.gemspec",
            "vendor/gems/thing/thing.gemspec", "node_modules/pkg/pkg.gemspec")
      expect(described_class.model_dirs(@root)).to eq([ File.join(@root, "app/models") ])
    end

    it "does not report the app root itself as a code root" do
      mkdirs("app/models")
      touch("myapp.gemspec")
      expect(described_class.code_roots(@root)).to eq([])
    end
  end

  # One in-repo-engine app asked dirs_for once per model and once per view,
  # so a 30-module tree re-globed packs/ and engines/ 12,000 times in a run.
  describe "directory resolution cost" do
    it "resolves a kind once per root within a run" do
      mkdirs("app/models", "modules/thing/app/models")
      FileUtils.touch(File.join(@root, "modules/thing/thing.gemspec"))
      described_class.clear_code_roots

      globs = 0
      allow(Dir).to receive(:glob).and_wrap_original do |original, *args, **kwargs, &block|
        globs += 1
        original.call(*args, **kwargs, &block)
      end

      RailsAiContext::RunCache.around do
        first = described_class.dirs_for(@root, "app/models")
        after_first = globs
        5.times { expect(described_class.dirs_for(@root, "app/models")).to eq(first) }
        # Another spelling of the same root is the same app.
        expect(described_class.dirs_for("#{@root}/./", "app/models").size).to eq(first.size)

        expect(globs).to eq(after_first)
      end
    end

    # The answer keeps only directories that exist, so a cached one hid a lib/,
    # pack or engine created after it from a long-running server.
    it "sees a directory created after it answered" do
      expect(described_class.dirs_for(@root, "lib")).to eq([])
      mkdirs("lib")

      expect(described_class.dirs_for(@root, "lib")).to eq([ File.join(@root, "lib") ])
      expect(RailsAiContext::ConcernPaths.resolve(@root)).to eq([])
      mkdirs("app/models/concerns")
      expect(RailsAiContext::ConcernPaths.resolve(@root)).to eq([ File.join(@root, "app/models/concerns") ])
    end
  end
  # What the answer says it searched and what dirs_for reads are written in
  # two places; every directory the scan finds has to be one the list names.
  describe ".search_patterns" do
    it "names a pattern for every directory dirs_for finds" do
      Dir.mktmpdir do |root|
        %w[app/services packs/billing/app/services engines/admin/app/services
           plugins/chat/app/services custom/app/services].each { |dir| FileUtils.mkdir_p(File.join(root, dir)) }
        File.write(File.join(root, "plugins", "chat", "plugin.rb"), "# chat\n")
        FileUtils.mkdir_p(File.join(root, "plugins", "chat", "app", "models"))
        allow(RailsAiContext.configuration).to receive(:extra_app_paths).and_return([ "custom" ])

        patterns = described_class.search_patterns(root, "app/services")
        found = described_class.dirs_for(root, "app/services").map { |dir| dir.delete_prefix("#{root}/") }

        expect(found).to all(satisfy { |dir| patterns.any? { |pattern| File.fnmatch(pattern, dir) } })
        expect(found.size).to eq(5)
      end
    end
  end

  describe ".path_gem_libs" do
    # A lockfile written on Windows ends its lines with CRLF.
    it "reads the path gems of a lockfile whatever its line endings, and only those inside the repo" do
      Dir.mktmpdir do |dir|
        FileUtils.mkdir_p(File.join(dir, "gems", "broadcast_policy", "lib"))
        File.write(File.join(dir, "gems", "broadcast_policy", "broadcast_policy.gemspec"), "")
        lock = "PATH\n  remote: gems\n  specs:\n    broadcast_policy (1.0)\n\nPATH\n  remote: ../outside\n  specs:\n"
        File.write(File.join(dir, "Gemfile.lock"), lock.gsub("\n", "\r\n"))
        described_class.clear_code_roots

        expect(described_class.path_gem_libs(dir)).to eq([ File.join(dir, "gems", "broadcast_policy", "lib") ])
      end
    end
  end

  describe "a root an initializer pushes under a namespace" do
    it "finds the namespace's constants under it, and reads nothing outside the app" do
      FileUtils.mkdir_p([ File.join(@root, "app/components"), File.join(@root, "config/initializers") ])
      File.write(File.join(@root, "app/components/base.rb"), "class Components::Base < Phlex::HTML\nend\n")
      File.write(File.join(@root, "config/initializers/phlex.rb"),
                 "Rails.autoloaders.main.push_dir(Rails.root.join(\"app/components\"), namespace: Components)\n" \
                 "Rails.autoloaders.main.push_dir(Rails.root.join(\"../outside\"), namespace: ::Outside)\n")
      outside = File.join(File.dirname(@root), "outside")
      FileUtils.mkdir_p(outside)

      expect(described_class.file_for_constant(@root, "Components::Base")).to eq(File.join(@root, "app/components/base.rb"))
      expect(described_class.namespaced_roots(@root)).to eq([ [ File.join(@root, "app/components"), "Components" ] ])
    ensure
      FileUtils.rm_rf(outside) if outside
    end

    it "skips an initializer whose bytes are not UTF-8" do
      FileUtils.mkdir_p(File.join(@root, "config/initializers"))
      File.binwrite(File.join(@root, "config/initializers/broken.rb"), "push_dir(\xFF\xFE \n".b)

      expect(described_class.file_for_constant(@root, "Components::Base")).to be_nil
    end
  end
end
