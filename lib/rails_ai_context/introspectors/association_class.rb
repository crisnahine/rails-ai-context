# frozen_string_literal: true

module RailsAiContext
  module Introspectors
    # The class an association points at, from an association record either
    # tier wrote, as the app spells it. `models` is the payload's models
    # section; `by_name` is the owner's associations keyed by name.
    module AssociationClass
      module_function

      COLLECTION_MACROS = %w[has_many has_and_belongs_to_many embeds_many].freeze

      # A class name a node can be drawn from, rather than the expression a
      # file wrote in place of one.
      CLASS_SHAPED = /\A(::)?[A-Z][A-Za-z0-9_]*(::[A-Z][A-Za-z0-9_]*)*\z/

      def readable_class?(value)
        value.to_s.match?(CLASS_SHAPED)
      end

      # Why no class can be named: :unreadable when the class_name is an
      # expression or the name is computed, :through when `through:` names no
      # association of the owner (Rails raises on it); nil when one can be.
      def unresolved(assoc, by_name)
        return :unreadable if (assoc[:class_name] && !readable_class?(assoc[:class_name])) ||
                              (assoc[:class_name].nil? && assoc[:computed_name])
        :through if assoc[:through] && !by_name.key?(assoc[:through].to_s)
      end

      # An owner's associations keyed by name, the `by_name` the functions here take.
      def by_name(associations)
        Array(associations).grep(Hash).to_h { |assoc| [ assoc[:name].to_s, assoc ] }
      end

      # The model the payload holds for the association's class, nil when it holds none.
      def model(assoc, models, owner:, by_name: by_name(models.dig(owner, :associations)))
        found = resolve(assoc, models, by_name: by_name, owner: owner)
        found if models.key?(found)
      end

      # The class, or nil when `unresolved` gives a reason, the record is unavailable, or the
      # association is polymorphic: Rails reads that class from each row's _type column.
      def resolve(assoc, models, by_name:, owner:)
        return nil if assoc[:unavailable] || assoc[:polymorphic] || unresolved(assoc, by_name)

        target(assoc, models, by_name: by_name, owner: owner)
      end

      # Booted, a through reflection's `class_name` already follows
      # `source:`. Static records none, so the far side is read off the
      # source association on the class the through hop lands on.
      def target(assoc, models, by_name: {}, owner: nil)
        # Rails reads class_name first; a polymorphic source names no class, so then source_type does.
        return declared_spelling(assoc[:class_name], models, owner: owner) if assoc[:class_name]

        source_type = assoc.dig(:options, :source_type) || assoc[:source_type]
        return declared_spelling(source_type, models, owner: owner) if assoc[:through] && readable_class?(source_type)
        return derive(assoc, models, owner: owner) unless assoc[:through]

        middle = through_class(assoc, by_name, models, owner: owner)
        source_name = (assoc.dig(:options, :source) || assoc[:source] || assoc[:name]).to_s
        middle_data = models[middle.to_s]
        source_assoc = Array(middle_data.is_a?(Hash) ? middle_data[:associations] : nil)
                         .find { |a| a[:name].to_s == source_name }

        # The far side belongs to the middle class, and resolves from there.
        if source_assoc
          named = source_assoc[:class_name] if readable_class?(source_assoc[:class_name])
          named ? declared_spelling(named, models, owner: middle) : derive(source_assoc, models, owner: middle)
        else
          derive(assoc, models, owner: owner)
        end
      end

      # The class the `through:` association points at: its own `class_name`
      # when one is declared, so `through: :author` with `class_name: "User"`
      # is User and never Author.
      def through_class(assoc, by_name, models, owner: nil)
        hop = by_name[assoc[:through].to_s]
        return declared_spelling(assoc[:through].to_s.singularize.camelize, models, owner: owner) unless hop

        named = hop[:class_name] if readable_class?(hop[:class_name])
        named ? declared_spelling(named, models, owner: owner) : derive(hop, models, owner: owner)
      end

      # Rails singularizes an association name only for a collection
      # (`derive_class_name`), so `belongs_to :preferences` is `Preferences`
      # and never `Preference`. A computed name (`belongs_to owner_name`)
      # names no class.
      def derive(assoc, models, owner: nil)
        return nil if assoc[:name].to_s.empty? || assoc[:computed_name]

        declared_spelling(derived_name(assoc), models, owner: owner)
      end

      def derived_name(assoc)
        name = assoc[:name].to_s
        (COLLECTION_MACROS.include?((assoc[:macro] || assoc[:type]).to_s) ? name.singularize : name).camelize
      end

      # Camelizing knows none of the app's acronyms, so `ApiClient` is
      # spelled as the app declares it, `APIClient`.
      def declared_spelling(candidate, models, owner: nil)
        TableName.model_for(candidate, owner, models) || candidate.to_s.delete_prefix("::")
      end
    end
  end
end
