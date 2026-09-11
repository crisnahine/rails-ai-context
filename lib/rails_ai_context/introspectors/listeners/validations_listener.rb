# frozen_string_literal: true

module RailsAiContext
  module Introspectors
    module Listeners
      # Detects validation macro calls via Prism AST:
      # validates, validates_presence_of, validates_uniqueness_of, etc.
      # Also detects custom `validate :method_name` calls.
      class ValidationsListener < BaseListener
        VALIDATES_METHODS = %i[
          validates validates_presence_of validates_uniqueness_of
          validates_format_of validates_length_of validates_numericality_of
          validates_inclusion_of validates_exclusion_of validates_confirmation_of
          validates_acceptance_of validates_associated
        ].to_set.freeze

        # Every key `validates` does not treat as a validator of its own:
        # Rails' own default keys, plus `message`, which Rails rejects at this
        # level and apps still write. What is left names a validator, which is
        # why an app's own validator can be written as an option key at all.
        SHARED_OPTIONS = %i[if unless on allow_nil allow_blank strict message].to_set.freeze

        def on_call_node_enter(node)
          return unless node.receiver.nil?

          if VALIDATES_METHODS.include?(node.name)
            extract_validation(node)
          elsif node.name == :validate
            extract_custom_validate(node)
          end
        end

        private

        def extract_validation(node)
          attributes = extract_symbol_args(node)
          options    = extract_keyword_options(node)

          # For `validates :email, presence: true, uniqueness: true`
          # split into per-validator-kind entries
          kinds  = node.name == :validates ? options.reject { |k, _| SHARED_OPTIONS.include?(k) } : {}
          shared = options.select { |k, _| SHARED_OPTIONS.include?(k) }

          if kinds.any?
            kinds.each do |kind, kind_opts|
              opts = kind_opts.is_a?(Hash) ? shared.merge(kind_opts) : shared
              record(node, kind, attributes, opts)
            end
          else
            # Legacy-style: validates_presence_of :email
            record(node, node.name.to_s.sub(/\Avalidates_/, "").sub(/_of\z/, ""), attributes, options)
          end
        end

        def extract_custom_validate(node)
          methods = extract_symbol_args(node)
          options = extract_keyword_options(node)

          methods.each { |method_name| record(node, "custom", [ method_name ], options) }
        end

        # The booted tier reads the kind off `validator.kind.to_s`, so a
        # static record spells it the same way or no consumer can compare the
        # two.
        def record(node, kind, attributes, options)
          @results << {
            kind:       kind.to_s,
            attributes: attributes.map(&:to_s),
            options:    options,
            location:   node.location.start_line,
            confidence: confidence_for(node)
          }
        end
      end
    end
  end
end
