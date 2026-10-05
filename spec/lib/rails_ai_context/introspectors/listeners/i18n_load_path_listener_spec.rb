# frozen_string_literal: true

require "spec_helper"

RSpec.describe RailsAiContext::Introspectors::Listeners::I18nLoadPathListener do
  def paths(source)
    RailsAiContext::Introspectors::SourceIntrospector.walk_source(source, { i18n: described_class })[:i18n]
  end

  it "reads every literal form a locale file is added to the load path in" do
    expect(paths(<<~RUBY)).to eq(%w[my/locales/*.{rb,yml} lib/locales/*.yml extra/de.yml vendor/x/*.yml])
      config.i18n.load_path += Dir[Rails.root.join("my/locales/*.{rb,yml}")]
      config.i18n.load_path << "\#{Rails.root}/lib/locales/*.yml"
      I18n.load_path += [Rails.root.join("extra", "de.yml").to_s]
      Rails.application.config.i18n.load_path.concat(Dir.glob(Rails.root.join("vendor/x/*.yml")))
    RUBY
  end

  it "reads a load path replaced with =" do
    expect(paths(<<~RUBY)).to eq(%w[config/locales/**/*.yml lib/locales/de.yml])
      config.i18n.load_path = Dir[Rails.root.join("config/locales/**/*.yml")]
      I18n.load_path = ["\#{Rails.root}/lib/locales/de.yml"]
    RUBY
  end

  it "leaves out other load paths and removals" do
    expect(paths(<<~RUBY)).to eq([])
      $LOAD_PATH << Rails.root.join("lib").to_s
      config.autoload_paths += %W[\#{config.root}/lib]
      config.i18n.load_path -= Dir[Rails.root.join("old/*.yml")]
      config.i18n.load_path += Dir[Gem.root.join("x/*.yml")]
    RUBY
  end
end
