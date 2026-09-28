# frozen_string_literal: true

require "spec_helper"

RSpec.describe RailsAiContext::Introspectors::Listeners::RouteFilesListener do
  it "reads a list the app assigns, in order, mapped or not" do
    results = parse_and_dispatch(<<~RUBY)
      config.paths["config/routes.rb"] = %w(
        config/routes/api.rb
        config/routes.rb
        config/routes/admin.rb
      ).map { |relative_path| Rails.root.join(relative_path) }
    RUBY

    expect(results).to eq([ { op: :set, paths: %w[config/routes/api.rb config/routes.rb config/routes/admin.rb] } ])
  end

  it "reads an addition, a literal glob and a Rails.root.join" do
    results = parse_and_dispatch(<<~RUBY)
      config.paths["config/routes.rb"] << "config/routes/extra.rb"
      config.paths["config/routes.rb"].concat(Dir[Rails.root.join("config/routes/*.rb")])
      config.paths["config/routes.rb"].unshift(Rails.root.join("config", "routes", "first.rb"))
    RUBY

    expect(results).to eq([
      { op: :append, paths: [ "config/routes/extra.rb" ] },
      { op: :append, globs: [ "config/routes/*.rb" ] },
      { op: :prepend, paths: [ "config/routes/first.rb" ] }
    ])
  end

  it "says when the list is computed rather than guessing" do
    results = parse_and_dispatch(<<~RUBY)
      config.paths["config/routes.rb"].concat(route_files_for(tenant))
    RUBY

    expect(results).to eq([ { op: :append, computed: true } ])
  end

  it "leaves every other path setting alone" do
    results = parse_and_dispatch(<<~RUBY)
      config.paths["app/views"] << "themes/views"
      config.paths.add "lib/base", eager_load: true
    RUBY

    expect(results).to be_empty
  end
end
