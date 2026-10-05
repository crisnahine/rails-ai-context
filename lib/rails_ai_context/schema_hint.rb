# frozen_string_literal: true

module RailsAiContext
  # Structured hydration payload representing a model's ground truth.
  # Used by hydrators to inject cross-tool context into controller
  # and view tool responses. Immutable value object via Data.define.
  SchemaHint = Data.define(
    :model_name,    # "Post"
    :table_name,    # "posts"
    :columns,       # [{name: "title", type: "string", null: false}, ...]
    :associations,  # [{name: "comments", type: "has_many", class_name: "Comment"}, ...]
    :validations,   # [{kind: "presence", attributes: ["title"]}, ...]
    :primary_key,   # "id"
    :confidence,    # "[VERIFIED]", "[STATIC]" or "[INFERRED]"
    :collection     # true for a Mongoid document: table_name is its collection
  ) do
    def initialize(collection: false, **members)
      super
    end
  end
end
