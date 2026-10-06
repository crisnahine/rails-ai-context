# frozen_string_literal: true

require "spec_helper"

RSpec.describe RailsAiContext::Introspectors::Listeners::AutoloadPathsListener do
  def paths_in(source)
    RailsAiContext::Introspectors::SourceIntrospector
      .walk_source(source, { paths: described_class })[:paths]
  end

  it "reads every literal form an app adds a root with" do
    source = <<~RUBY
      module OpenProject
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

  it "leaves a computed root unread rather than guessing at it" do
    source = <<~RUBY
      config.autoload_paths << Dir["plugins/*/lib"].max
      config.autoload_paths += discovered_roots
      config.autoload_paths << Rails.root.join("lib", ENV["EXTRA"])
      config.autoload_paths << Rails.root(true).join("lib")
    RUBY

    expect(paths_in(source)).to eq([])
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
