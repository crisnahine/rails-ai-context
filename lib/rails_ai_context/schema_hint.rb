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
    :confidence     # "[VERIFIED]" or "[INFERRED]"
  ) do
    def verified?
      confidence == "[VERIFIED]"
    end

    def column_names
      columns.map { |c| c[:name] }
    end

    def association_names
      associations.map { |a| a[:name] }
    end
  end
end
