# frozen_string_literal: true

require "spec_helper"

RSpec.describe RailsAiContext::Introspectors::Listeners::PreviewPathsListener do
  def paths(source)
    RailsAiContext::Introspectors::SourceIntrospector.walk_source(source, { previews: described_class })[:previews]
  end

  it "reads every literal form a preview directory is set in" do
    expect(paths(<<~RUBY)).to eq(%w[lookbook/previews spec/previews test/previews])
      config.view_component.previews.paths += [Rails.root.join("lookbook/previews").to_s]
      config.view_component.preview_paths << "\#{Rails.root}/spec/previews"
      config.view_component.preview_path = "test/previews"
    RUBY
  end

  it "leaves out every other paths setting" do
    expect(paths(<<~RUBY)).to eq([])
      config.autoload_paths += %W[\#{config.root}/lib]
      config.action_mailer.preview_paths << Rails.root.join("spec/mailers/previews")
      config.paths.add "lib/base", eager_load: true
    RUBY
  end
end
