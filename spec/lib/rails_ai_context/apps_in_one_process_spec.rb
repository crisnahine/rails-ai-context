# frozen_string_literal: true

require "spec_helper"
require "tmpdir"
require "fileutils"
require "pathname"

# What a process keeps beyond one run (the declaration index kept beside the context, PathResolver's maps, PortablePath's
# enclosing gems) is keyed so that a second app, or the next release behind the same deploy link, sees nothing of the first.
RSpec.describe "apps served one after another in one process" do
  let(:shared) { RailsAiContext::Tools::BaseTool::SHARED_CACHE }

  after { RailsAiContext::Tools::BaseTool.reset_all_caches! }

  def write_app(dir, files)
    files.each do |path, source|
      FileUtils.mkdir_p(File.dirname(File.join(dir, path)))
      File.write(File.join(dir, path), source)
    end
  end

  def application(*roots)
    lines = roots.map { |dir| "    config.autoload_paths << \"\#{root}/#{dir}\"\n" }.join
    "module Shop\n  class Application < Rails::Application\n#{lines}  end\nend\n"
  end

  # One call's reads, under a context held at the app's current fingerprint.
  def serve(root)
    app = Struct.new(:root).new(Pathname.new(root))
    shared[:mutex].synchronize { shared[:fingerprint] = RailsAiContext::Fingerprinter.mark(app) }
    RailsAiContext::RunCache.around do
      archive = RailsAiContext::ConcernPaths.find_file(root, "Archive", within: "Post")
      {
        archive: archive && RailsAiContext::PortablePath.relativize(File.realpath(archive), root),
        declared: RailsAiContext::PathResolver.declared_roots(root),
        searched: RailsAiContext::ConcernPaths.searched(root),
        watched: RailsAiContext::Fingerprinter.watched_dirs(root)
      }
    end
  end

  def mentions(answers, dir) = answers.values.flatten.compact.select { |value| value.to_s.include?(dir) }

  it "answers a second app and the next release behind one deploy link from their own files alone" do
    Dir.mktmpdir do |tmp|
      tmp = File.realpath(tmp)
      first = File.join(tmp, "releases/1")
      second = File.join(tmp, "releases/2")
      other = File.join(tmp, "other")
      write_app(first, "config/application.rb" => application("lib_static"), "app/models/post.rb" => "class Post\nend\n",
                       "lib_static/archive.rb" => "module Archive\nend\n")
      write_app(second, "config/application.rb" => application("lib_more"), "app/models/post.rb" => "class Post\nend\n",
                        "lib_more/keep.rb" => "module Keep\nend\nmodule Archive\nend\n")
      write_app(other, "app/models/post.rb" => "class Post\nend\n\nmodule Archive\nend\n")
      current = File.join(tmp, "current")
      File.symlink(first, current)

      snapshot = RailsAiContext::Fingerprinter::Snapshot.new(current)
      snapshot.changed?
      expect(serve(current)[:archive]).to eq("lib_static/archive.rb")

      expect(serve(other)).to include(archive: "app/models/post.rb", declared: [])
      expect(mentions(serve(other), first)).to eq([])

      FileUtils.rm_f(current)
      File.symlink(second, current)
      expect(snapshot.changed?).to be(true)
      RailsAiContext::Tools::BaseTool.reset_all_caches!

      answers = serve(current)
      expect(answers).to include(archive: "lib_more/keep.rb", declared: [ File.join(current, "lib_more") ])
      expect(answers.values.flatten.compact.grep(/lib_static/)).to eq([])
      expect(mentions(answers, first) + mentions(answers, other)).to eq([])
    end
  end

  # An engine's test/dummy, holding an in-repo engine, a namespaced root and a path gem of its own.
  def write_dummy(engine, name)
    root = File.join(engine, "test/dummy")
    write_app(root, "config/application.rb" => application("lib_#{name}"),
                    "config/initializers/zeitwerk.rb" => "Rails.autoloaders.main.push_dir(Rails.root.join(\"app/#{name}_api\"), namespace: Api)\n",
                    "app/models/post.rb" => "class Post\nend\n", "app/#{name}_api/thing.rb" => "module Api\n  class Thing\n  end\nend\n",
                    "lib_#{name}/archive.rb" => "module Archive\nend\n",
                    "components/#{name}/#{name}.gemspec" => "Gem::Specification.new { |s| s.name = '#{name}' }\n",
                    "components/#{name}/app/models/#{name}_invoice.rb" => "class #{name.capitalize}Invoice\nend\n",
                    "gems/#{name}_kit/#{name}_kit.gemspec" => "Gem::Specification.new { |s| s.name = '#{name}_kit' }\n",
                    "gems/#{name}_kit/lib/#{name}_kit.rb" => "module #{name.capitalize}Kit\nend\n",
                    "Gemfile" => "gem \"#{name}_kit\", path: \"gems/#{name}_kit\"\n",
                    "Gemfile.lock" => "PATH\n  remote: gems/#{name}_kit\n  specs:\n    #{name}_kit (0.1)\n\nDEPENDENCIES\n  #{name}_kit!\n")
    write_app(engine, "app/models/widget.rb" => "class Widget\nend\n")
    root
  end

  def serve_dummy(root, engine)
    serve(root).merge(
      RailsAiContext::RunCache.around do
        {
          code_roots: RailsAiContext::PathResolver.code_roots(root),
          model_dirs: RailsAiContext::PathResolver.model_dirs(root),
          namespaced: RailsAiContext::PathResolver.namespaced_roots(root).map(&:first),
          api_thing: RailsAiContext::PathResolver.file_for_constant(root, "Api::Thing"),
          gem_libs: RailsAiContext::PathResolver.path_gem_libs(root),
          widget: RailsAiContext::PortablePath.relativize(File.join(engine, "app/models/widget.rb"), root)
        }
      end
    )
  end

  it "keeps no code root, namespaced root, path gem lib or enclosing gem of one app for the next" do
    Dir.mktmpdir do |tmp|
      tmp = File.realpath(tmp)
      engines = %w[alpha beta].map { |name| File.join(tmp, "#{name}_engine") }
      roots = engines.zip(%w[alpha beta]).map { |engine, name| write_dummy(engine, name) }
      specs = Gem.loaded_specs.merge(engines.to_h { |engine| [ File.basename(engine), double("Gem::Specification", full_gem_path: engine, full_name: "#{File.basename(engine)}-0.1.0", default_gem?: false) ] })
      allow(Gem).to receive(:loaded_specs).and_return(specs)

      first, second = roots.zip(engines).map { |root, engine| serve_dummy(root, engine) }

      expect(first).to include(archive: "lib_alpha/archive.rb", widget: "../../app/models/widget.rb",
                               code_roots: [ File.join(roots[0], "components/alpha") ], namespaced: [ File.join(roots[0], "app/alpha_api") ],
                               api_thing: File.join(roots[0], "app/alpha_api/thing.rb"), gem_libs: [ File.join(roots[0], "gems/alpha_kit/lib") ])
      expect(first[:model_dirs]).to include(File.join(roots[0], "components/alpha/app/models"))
      expect(second).to include(archive: "lib_beta/archive.rb", widget: "../../app/models/widget.rb",
                                code_roots: [ File.join(roots[1], "components/beta") ], namespaced: [ File.join(roots[1], "app/beta_api") ],
                                api_thing: File.join(roots[1], "app/beta_api/thing.rb"), gem_libs: [ File.join(roots[1], "gems/beta_kit/lib") ])
      expect(mentions(second, engines[0])).to eq([])
      # To the second app, the first engine is a loaded gem, named by its gem, never a path from the first app's root.
      expect(RailsAiContext::PortablePath.relativize(File.join(engines[0], "app/models/widget.rb"), roots[1])).to eq("alpha_engine-0.1.0/app/models/widget.rb")
    end
  end
end
