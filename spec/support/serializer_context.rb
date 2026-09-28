# frozen_string_literal: true

require "yaml"

# A payload every serializer can render; pass the keys an example asserts on.
module SerializerContext
  def serializer_context(**overrides)
    {
      app_name: "TestApp", rails_version: "8.0", ruby_version: "3.4",
      schema: { adapter: "postgresql", total_tables: 12 },
      models: {
        "User" => { associations: [ { type: :has_many, name: :posts } ], validations: [], table_name: "users", scopes: [ "active" ], constants: [] },
        "Post" => { associations: [ { type: :belongs_to, name: :user } ], validations: [], table_name: "posts", scopes: [], constants: [] }
      },
      routes: { total_routes: 45 },
      gems: {},
      conventions: {},
      controllers: {
        controllers: {
          "UsersController" => { actions: %w[index show new create edit update destroy] },
          "PostsController" => { actions: %w[index show] }
        }
      },
      view_templates: { templates: {}, partials: {} },
      stimulus: {}, turbo: {}, auth: {}, api: {}, i18n: {},
      active_storage: {}, action_text: {}, assets: {}, engines: {},
      multi_database: {}
    }.merge(overrides)
  end

  # The YAML header a Cursor .mdc or Copilot .instructions.md file carries,
  # or nil when the file has none.
  def parse_frontmatter(content)
    return nil unless content.start_with?("---")

    parts = content.split("---", 3)
    return nil if parts.size < 3

    YAML.safe_load(parts[1], permitted_classes: [ Symbol ])
  end
end

RSpec.configure { |config| config.include SerializerContext }
