# frozen_string_literal: true

require "spec_helper"

RSpec.describe RailsAiContext::Introspectors::Listeners::AutoloadPathsListener do
  def paths_in(source)
    RailsAiContext::Introspectors::SourceIntrospector
      .walk_source(source, { paths: described_class })[:paths].map(&:first)
  end

  it "names the list railties keeps each root in, which orders it among the app's roots" do
    source = <<~RUBY
      config.autoload_paths << "lib_static"
      config.eager_load_paths += %W(\#{config.root}/extras)
      config.autoload_once_paths << "once_here"
      config.autoload_lib(ignore: %w[assets tasks])
      config.paths.add "lib/base", eager_load: true, autoload: true
      config.paths.add "app/middleware", eager_load: true
    RUBY

    expect(RailsAiContext::Introspectors::SourceIntrospector.walk_source(source, { paths: described_class })[:paths]).to eq(
      [ [ "lib_static", :autoload ], [ "extras", :eager ], [ "once_here", :once ], [ "lib", :autoload ],
        [ "lib/base", :paths_autoload ], [ "app/middleware", :paths_eager ] ]
    )
  end

  it "marks an assignment as replacing its list, and names the autoload_once root paths.add makes" do
    source = "config.autoload_paths = %W(\#{config.root}/lib_static)\nconfig.paths.add \"once\", autoload_once: true\n"

    expect(RailsAiContext::Introspectors::SourceIntrospector.walk_source(source, { paths: described_class })[:paths])
      .to eq([ [ :reset, :autoload ], [ "lib_static", :autoload ], [ "once", :paths_once ] ])
  end

  it "resets a list only for a literal list, and reads a self-referencing sum as an append" do
    walk = lambda do |source|
      RailsAiContext::Introspectors::SourceIntrospector.walk_source(source, { paths: described_class })[:paths]
    end

    expect(walk.call("config.autoload_paths = config.autoload_paths + %w[b]")).to eq([ [ "b", :autoload ] ])
    expect(walk.call("config.autoload_paths = [*config.autoload_paths, 'b']")).to eq([ [ "b", :autoload ] ])
    expect(walk.call("config.autoload_paths = (config.autoload_paths | %w[b]).uniq")).to eq([ [ "b", :autoload ] ])
    expect(walk.call("config.autoload_paths = %w[b] + config.autoload_paths")).to eq([ [ "b", :autoload ] ])
    expect(walk.call("config.autoload_paths = %w[a] + %w[b]")).to eq([ [ :reset, :autoload ], [ "a", :autoload ], [ "b", :autoload ] ])
    expect(walk.call("config.autoload_paths = Dir['x/*']")).to eq([ [ :reset, :autoload ], [ "x/*", :autoload, :glob ] ])
    expect(walk.call("config.autoload_paths = [*other, 'b']")).to eq([])
    expect(walk.call("x = %w[b]\nconfig.autoload_paths = x")).to eq([])
    expect(walk.call("config.autoload_paths = %w[b]")).to eq([ [ :reset, :autoload ], [ "b", :autoload ] ])
  end

  it "reads every literal form an app adds a root with" do
    source = <<~RUBY
      module Tracker
        class Application < Rails::Application
          config.autoload_paths << "lib_static"
          config.eager_load_paths += %W(\#{config.root}/modules/shared \#{config.root}/app/extra)
          config.autoload_paths.push(Rails.root.join("gems", "plugins").to_s)
          config.autoload_once_paths << "\#{config.root}/once_here"
          config.autoload_lib(ignore: %w[assets tasks])
        end
      end
    RUBY

    expect(paths_in(source)).to contain_exactly(
      "lib_static", "modules/shared", "app/extra", "gems/plugins", "once_here", "lib"
    )
  end

  it "reads a root railties' own paths.add declares, and only when it loads code" do
    source = <<~RUBY
      config.paths.add("lib/base", eager_load: true, autoload_once: true)
      config.paths.add("app/middleware", eager_load: true)
      config.paths.add("config/database", with: "config/db.yml")
    RUBY

    expect(paths_in(source)).to contain_exactly("lib/base", "app/middleware")
  end

  it "does not read a path rooted in a gem" do
    source = <<~RUBY
      config.paths.add Primer::ViewComponents::Engine.root.join("app/components").to_s, eager_load: true
      config.autoload_paths << "\#{Primer::ViewComponents::Engine.root}/previews"
    RUBY

    expect(paths_in(source)).to eq([])
  end

  it "does not read a root the file removes" do
    source = <<~RUBY
      config.eager_load_paths -= [Rails.root.join("app/coffeescripts")]
    RUBY

    expect(paths_in(source)).to eq([])
  end

  it "reads a literal Dir glob as a pattern to expand, and no other Dir call" do
    walk = lambda do |line|
      RailsAiContext::Introspectors::SourceIntrospector.walk_source(line, { paths: described_class })[:paths]
    end

    expect(walk.call('config.autoload_paths += Dir["#{config.root}/app/models/**/"]')).to eq([ [ "app/models/**/", :autoload, :glob ] ])
    expect(walk.call("config.autoload_paths += Dir.glob(Rails.root.join('app', 'models', '{**}'))")).to eq([ [ "app/models/{**}", :autoload, :glob ] ])
    expect(walk.call("config.eager_load_paths += Dir['lib/*/']")).to eq([ [ "lib/*/", :eager, :glob ] ])
    expect(walk.call("config.autoload_paths += Dir['/etc/*']")).to eq([])
    expect(walk.call("config.autoload_paths += Dir.glob('x/*', base: dir)")).to eq([])
    expect(walk.call("config.autoload_paths += Dir['x/*'].reject { |p| p.end_with?('y') }")).to eq([])
  end

  it "leaves a computed root unread rather than guessing at it" do
    source = <<~RUBY
      config.autoload_paths << Dir["plugins/*/lib"].max
      config.autoload_paths += discovered_roots
      config.autoload_paths << Rails.root.join("lib", ENV["EXTRA"])
      config.autoload_paths << Rails.root(true).join("lib")
      config.autoload_paths << "\#{config.root}/lib/\#{name}"
      config.eager_load_paths << "\#{config.root}/editions/\#{EDITION}/models"
    RUBY

    expect(paths_in(source)).to eq([])
  end

  it "reads lib as a root for autoload_lib_once, as railties adds it to eager_load_paths" do
    expect(paths_in("config.autoload_lib_once(ignore: %w[tasks])\n")).to eq(%w[lib])
  end

  it "reads the app root at the node, however it is spelled" do
    source = <<~RUBY
      config.autoload_paths << ::Rails.root.join("lib", "rooted")
      config.autoload_paths << Rails  .root.join("spaced")
      config.autoload_paths << config.root.join("from_config")
      config.autoload_paths << app.config.root.join("other_config")
    RUBY

    expect(paths_in(source)).to eq(%w[lib/rooted spaced from_config])
  end
end
