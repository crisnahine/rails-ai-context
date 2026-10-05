# frozen_string_literal: true

require "spec_helper"

RSpec.describe RailsAiContext::Introspectors::Listeners::ViewPathsListener do
  def paths_in(source)
    RailsAiContext::Introspectors::SourceIntrospector
      .walk_source(source, { paths: described_class })[:paths]
  end

  it "reads the roots an app puts before and after app/views" do
    source = <<~RUBY
      config.paths["app/views"].unshift(Rails.root.join("app/views/custom").to_s)
      config.paths["app/views"] << "enterprise/app/views"
      config.paths["app/views"].push("\#{config.root}/themes/dark")
      paths["app/views"].concat(["more/views"])
      config.paths["app/assets"].unshift("ignored")
      config.autoload_paths << "lib_static"
    RUBY

    expect(paths_in(source)).to eq([
      [ :prepend, "app/views/custom" ], [ :append, "enterprise/app/views" ],
      [ :append, "themes/dark" ], [ :append, "more/views" ]
    ])
  end
end
