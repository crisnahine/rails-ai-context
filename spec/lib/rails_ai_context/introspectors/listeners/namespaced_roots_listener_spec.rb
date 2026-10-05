# frozen_string_literal: true

require "spec_helper"

RSpec.describe RailsAiContext::Introspectors::Listeners::NamespacedRootsListener do
  def roots_in(source)
    RailsAiContext::Introspectors::SourceIntrospector
      .walk_source(source, { roots: described_class })[:roots]
  end

  it "reads both roots the phlex:install initializer pushes, and skips a push_dir with no namespace" do
    source = <<~RUBY
      module Views
      end

      module Components
        extend Phlex::Kit
      end

      Rails.autoloaders.main.push_dir(
        Rails.root.join("app/views"), namespace: Views
      )

      Rails.autoloaders.main.push_dir(
        Rails.root.join("app/components"), namespace: Components
      )

      Rails.autoloaders.main.push_dir("app/widgets", namespace: ::Admin::Widgets)
      Rails.autoloaders.main.push_dir("app/x")
      Rails.autoloaders.main.push_dir(Rails.root.join("app/y"), namespace: namespace_for(:y))
    RUBY

    expect(roots_in(source)).to eq([
      [ "app/views", "Views" ], [ "app/components", "Components" ], [ "app/widgets", "Admin::Widgets" ]
    ])
  end
end
