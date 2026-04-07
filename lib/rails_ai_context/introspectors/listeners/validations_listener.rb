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
          validation_options = options.select { |k, _| validation_kind?(k) }
          other_options      = options.reject { |k, _| validation_kind?(k) }

          if validation_options.any?
            validation_options.each do |kind, kind_opts|
              opts = kind_opts.is_a?(Hash) ? other_options.merge(kind_opts) : other_options
              @results << {
                kind:       kind,
                attributes: attributes.map(&:to_s),
                options:    opts,
                location:   node.location.start_line,
                confidence: confidence_for(node)
              }
            end
          else
            # Legacy-style: validates_presence_of :email
            kind = node.name.to_s.sub(/\Avalidates_/, "").sub(/_of\z/, "").to_sym
            @results << {
              kind:       kind,
              attributes: attributes.map(&:to_s),
              options:    other_options,
              location:   node.location.start_line,
              confidence: confidence_for(node)
            }
          end
        end

        def extract_custom_validate(node)
          methods = extract_symbol_args(node)
          options = extract_keyword_options(node)

          methods.each do |method_name|
            @results << {
              kind:       :custom,
              attributes: [ method_name.to_s ],
              options:    options,
              location:   node.location.start_line,
              confidence: confidence_for(node)
            }
          end
        end

        def validation_kind?(key)
          %i[
            presence uniqueness format length numericality
            inclusion exclusion confirmation acceptance
            comparison associated
          ].include?(key)
        end
      end
    end
  end
end
