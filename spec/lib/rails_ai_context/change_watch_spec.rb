# frozen_string_literal: true

require "spec_helper"
require "tmpdir"
require "fileutils"

RSpec.describe RailsAiContext::ChangeWatch do
  describe "#start" do
    it "has Listen ignore only the node_modules and bundles inside a declared root, which no look reads" do
      Dir.mktmpdir do |dir|
        root = File.realpath(dir)
        {
          "config/application.rb" => "module Shop\n  class Application < Rails::Application\n    config.autoload_paths << \"\#{root}/frontend\"\n" \
                                     "    config.autoload_paths << \"\#{root}/lib_static\"\n  end\nend\n",
          "frontend/thing.rb" => "module Thing\nend\n", "frontend/node_modules/pkg/lib/k.rb" => "module K\nend\n",
          "frontend/widgets/tmp/t.rb" => "module T\nend\n", "lib_static/generated/g.rb" => "module G\nend\n", "app/models/post.rb" => "class Post\nend\n"
        }.each { |path, source| FileUtils.mkdir_p(File.dirname(File.join(root, path))) && File.write(File.join(root, path), source) }
        RailsAiContext.configuration.excluded_paths |= [ "lib_static/generated" ]
        listen = Module.new
        listen.define_singleton_method(:to) { |*_dirs, **_options, &_block| }
        listener = instance_double("Listen::Listener", start: nil)
        stub_const("Listen", listen)
        allow(listen).to receive(:to).and_return(listener)
        watch = described_class.new(Struct.new(:root).new(Pathname.new(root)))
        allow(watch).to receive(:require).with("listen").and_return(true)

        watch.start { }

        expect(listen).to have_received(:to) do |*dirs, **options|
          ignored = ->(relative) { Array(options[:ignore]).any? { |pattern| pattern.match?(relative) } }
          expect(dirs).to include(File.join(root, "frontend"), File.join(root, "lib_static"))
          expect(%w[node_modules node_modules/pkg/lib/k.rb].map(&ignored)).to eq([ true, true ])
          expect(%w[thing.rb widgets widgets/tmp generated/g.rb node_modules_x models/post.rb].map(&ignored)).to eq([ false, false, false, false, false, false ])
        end
      ensure
        RailsAiContext.configuration.excluded_paths = RailsAiContext::Configuration.new.excluded_paths
      end
    end

    it "watches, and goes stale on, a log folder in app/models when the app also declares app/models, and ignores an app/* node_modules" do
      Dir.mktmpdir do |dir|
        root = File.realpath(dir)
        {
          "config/application.rb" => "module Shop\n  class Application < Rails::Application\n    config.autoload_paths << \"\#{config.root}/app/models\"\n  end\nend\n",
          "app/models/post.rb" => "class Post\nend\n", "app/models/log/entry.rb" => "module Log\n  class Entry\n  end\nend\n",
          "app/services/node_modules/pkg/k.rb" => "module K\nend\n"
        }.each { |path, source| FileUtils.mkdir_p(File.dirname(File.join(root, path))) && File.write(File.join(root, path), source) }
        app = Struct.new(:root).new(Pathname.new(root))
        mark = RailsAiContext::RunCache.around { RailsAiContext::Fingerprinter.mark(app) }
        listen = Module.new
        listen.define_singleton_method(:to) { |*_dirs, **_options, &_block| }
        stub_const("Listen", listen)
        allow(listen).to receive(:to).and_return(instance_double("Listen::Listener", start: nil))
        watch = described_class.new(app)
        allow(watch).to receive(:require).with("listen").and_return(true)

        watch.start { }
        File.write(File.join(root, "app/models/log/entry.rb"), "module Log\n  class Entry\n    def x; end\n  end\nend\n")

        expect(listen).to have_received(:to) do |*_dirs, **options|
          ignored = %w[models/log models/log/entry.rb models/log/line.rb services/node_modules/pkg/k.rb].select { |relative| Array(options[:ignore]).any? { |pattern| pattern.match?(relative) } }
          expect(ignored).to eq(%w[services/node_modules/pkg/k.rb])
        end
        RailsAiContext::Tools::BaseTool.reset_all_caches!
        expect(RailsAiContext::RunCache.around { RailsAiContext::Fingerprinter.stale?(app, mark) }).to be(true)
      end
    end
  end
end
