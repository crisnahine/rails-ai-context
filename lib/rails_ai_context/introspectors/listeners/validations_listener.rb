# frozen_string_literal: true

module RailsAiContext
  module Introspectors
    module Listeners
      # Detects validation macro calls via Prism AST:
      # validates, validates_presence_of, validates_uniqueness_of, etc.
      # Also detects custom `validate :method_name` calls.
      class ValidationsListener < BaseListener
        include WithOptionsScope

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
          return unless in_scope?(node)

          if VALIDATES_METHODS.include?(node.name)
            extract_validation(node)
          elsif node.name == :validates_with
            extract_validates_with(node)
          elsif node.name == :validate
            extract_custom_validate(node)
          elsif node.name == :has_secure_password
            extract_secure_password(node)
          elsif node.name == :devise
            extract_devise(node)
          elsif node.name.start_with?("validates_")
            # A gem's macro (`validates_date`) is still a validation the model
            # declares, listed under its own name since its kind is the gem's.
            record(node, node.name, extract_symbol_args(node), declared_options(node))
          end
        end

        private

        def extract_validation(node)
          attributes = extract_symbol_args(node)
          options    = declared_options(node)
          arguments = node.arguments&.arguments || []
          # `validates field, length: ...` in a loop names its attribute at run time.
          computed = arguments.reject { |a| a.is_a?(Prism::KeywordHashNode) || literal_string(a) }
          # Rails takes a trailing hash expression after the attributes as the
          # options (`extract_options!`): computed options, not an attribute.
          options_source = computed.pop.slice if attributes.any? && computed.any? && computed.last.equal?(arguments.last) &&
                                                 !arguments.any?(Prism::KeywordHashNode) && !computed.last.is_a?(Prism::SplatNode)
          computed = computed.map(&:slice)
          # `validates :x` with no rule at all declares nothing (Rails raises).
          return if node.name == :validates && options.empty? && computed.empty? && options_source.nil? && attributes.any?

          # For `validates :email, presence: true, uniqueness: true`
          # split into per-validator-kind entries
          kinds  = node.name == :validates ? options.reject { |k, _| SHARED_OPTIONS.include?(k) } : {}
          # Rails skips a validator whose option is false: `presence: false` requires nothing.
          if kinds.any?
            kinds = kinds.reject { |_, value| value == false }
            return if kinds.empty?
          end
          shared = options.select { |k, _| SHARED_OPTIONS.include?(k) }

          if kinds.any?
            kinds.each do |kind, kind_opts|
              opts = kind_opts.is_a?(Hash) ? shared.merge(kind_opts) : shared
              record(node, kind, attributes, opts, computed: computed)
            end
          else
            # Legacy-style: validates_presence_of :email
            record(node, node.name.to_s.sub(/\Avalidates_/, "").sub(/_of\z/, ""), attributes, options, computed: computed,
                                                                                                   options_source: options_source)
          end
        end

        # `validates_with RecordValidator` names a validator class, not an
        # attribute; the attributes, when there are any, come as an option.
        def extract_validates_with(node)
          validator = extract_arg_values(node).first
          options = declared_options(node)
          attributes = Array(options.delete(:attributes)).map(&:to_s)
          record(node, "validates_with", attributes, options, validator: validator.to_s)
        end

        def extract_custom_validate(node)
          methods = extract_symbol_args(node)
          options = declared_options(node)

          methods.each { |method_name| record(node, "custom", [ method_name ], options) }
          record(node, "custom", [], options, block: block_text(node.block)) if methods.empty? && node.block.is_a?(Prism::BlockNode)
        end

        # The block's first statement, which is usually the rule itself.
        def block_text(block)
          first = block.body.is_a?(Prism::StatementsNode) ? block.body.body.first : block.body
          first ? one_line_source(first).truncate(120) : ""
        end

        # The validators `has_secure_password` registers. Rails 7.1 turned the
        # length one into a `validate` block, so it carries the version it
        # stops at and the model tier keeps it by the app's Rails version.
        def extract_secure_password(node)
          return if node.receiver || extract_keyword_options(node)[:validations] == false

          attribute = extract_symbol_args(node).first || :password
          added(node, "has_secure_password", [ [ :length, attribute, { maximum: 72 }, "7.1" ], [ :confirmation, attribute, {} ] ])
        end

        # Devise's :validatable module; its options come from the Devise
        # config, which only the booted tier reads.
        def extract_devise(node)
          return if node.receiver || !extract_symbol_args(node).include?(:validatable)

          added(node, "devise :validatable", [
                  [ :presence, :email, {} ], [ :uniqueness, :email, {} ], [ :format, :email, {} ],
                  [ :presence, :password, {} ], [ :confirmation, :password, {} ], [ :length, :password, {} ]
                ])
        end

        def added(node, macro, validators)
          validators.each do |kind, attribute, options, before_rails|
            @results << { kind: kind.to_s, attributes: [ attribute.to_s ], options: options, added_by: macro,
                          before_rails: before_rails, location: node.location.start_line,
                          confidence: confidence_for(node) }.compact
          end
        end

        # What the macro's line says, under the options any enclosing
        # `with_options` block merges in.
        def declared_options(node)
          scope_options(receiver_name(node)).merge(extract_keyword_sources(node))
        end

        # The booted tier reads the kind off `validator.kind.to_s`, so a
        # static record spells it the same way or no consumer can compare the
        # two.
        def record(node, kind, attributes, options, validator: nil, computed: nil, options_source: nil, block: nil)
          @results << {
            kind:       kind.to_s,
            attributes: attributes.map(&:to_s),
            block:      block,
            computed_attributes: computed.presence,
            options_source: options_source,
            validator:  validator,
            options:    options,
            location:   node.location.start_line,
            confidence: confidence_for(node)
          }.compact
        end
      end
    end
  end
end
