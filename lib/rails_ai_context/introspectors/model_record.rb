# frozen_string_literal: true

module RailsAiContext
  module Introspectors
    # One model record for both tiers. The walked source (what the class declares through its bases and
    # concerns) answers every key both tiers read off the source; the tier adapter answers the keys whose
    # source differs: reflection when the app booted, the static candidates when it did not. A key added
    # here reaches both tiers, and neither carries one the other lacks.
    module ModelRecord
      module_function

      # What ModelIntrospector#class_declarations walked for one class, plus the macro keys read off it
      # (`ModelIntrospector#extract_macros_from_ast`) and the app's locked Rails version.
      Facts = Struct.new(:data, :unread, :bases_unread, :hidden, :file, :macros, :rails_version, keyword_init: true)

      # The keys a tier answers. `table` is a TableName::Answer; each method list is uncapped.
      TIER_KEYS = %i[confidence table associations validations enums concerns concern_sources class_methods instance_methods
                     source_instance_methods sti parent_model patches_unread commit_order_unread ignored_columns own_connection].freeze

      Reflection = Struct.new(*TIER_KEYS, keyword_init: true)

      StaticCandidates = Struct.new(*TIER_KEYS, keyword_init: true) do
        # Nothing in a static entry is runtime-confirmed; a record the parser could not resolve keeps its lower mark.
        def finish(record)
          record.transform_values do |value|
            next value unless value.is_a?(Array)

            value.map { |entry| entry.is_a?(Hash) && entry[:confidence] == Confidence::VERIFIED ? entry.merge(confidence: Confidence::STATIC) : entry }
          end
        end
      end

      # What the payload lists; the count beside it is the whole set.
      PAYLOAD_METHOD_CAP = 30

      CONDITION_KEYS = %i[if unless].freeze

      DECLARATION_KEYS = %i[declaration receiver condition from_concern].freeze

      ENUM_ON_BY_DEFAULT = %i[scopes instance_methods].freeze

      # @param facts [Facts]
      # @param adapter [Reflection, StaticCandidates]
      # @return [Hash] the model's record, nil keys left out
      def build(facts, adapter)
        data = facts.data
        table = adapter.table || TableName::Answer.new
        class_methods = Array(adapter.class_methods)
        instance_methods = Array(adapter.instance_methods)
        record = {
          confidence: adapter.confidence,
          table_name: table.table,
          table_set_by: table.set_by,
          primary_key: table.primary_key,
          file: facts.file,
          associations: adapter.associations,
          validations: adapter.validations,
          enums: adapter.enums,
          enum_options: enum_options(data, facts.rails_version).presence,
          # The listener's flat list, as the Hash every consumer reads: { "before_validation" => ["normalize"] }.
          callbacks: group_callbacks_by_type(data[:callbacks]),
          callback_conditions: callback_conditions(data[:callbacks]),
          callback_sources: callback_sources(data[:callbacks]),
          concerns: adapter.concerns,
          concern_sources: adapter.concern_sources,
          concerns_hidden: (facts.hidden.size if facts.hidden.any?),
          concern_callbacks: concern_callbacks(data[:callbacks]),
          concerns_unread: (facts.unread if facts.unread.any?),
          bases_unread: (facts.bases_unread if facts.bases_unread.any?),
          patches_unread: adapter.patches_unread,
          commit_order_unread: adapter.commit_order_unread,
          conditional_declarations: declarations(data[:conditional]),
          foreign_declarations: declarations(data[:foreign]),
          custom_validates: custom_validates(data),
          custom_validate_conditions: custom_validate_conditions(data),
          custom_validate_blocks: custom_validate_blocks(data),
          scopes: scopes(data),
          default_scopes: default_scopes(data),
          class_methods: class_methods.first(PAYLOAD_METHOD_CAP),
          class_method_count: class_methods.size,
          instance_methods: instance_methods.first(PAYLOAD_METHOD_CAP),
          instance_method_count: instance_methods.size,
          source_instance_methods: adapter.source_instance_methods,
          sti: adapter.sti,
          parent_model: adapter.parent_model
        }
        record.merge!(facts.macros || {})
        record[:ignored_columns] = adapter.ignored_columns
        record[:own_connection] = adapter.own_connection
        record = record.compact
        adapter.respond_to?(:finish) ? adapter.finish(record) : record
      end

      def scopes(data)
        Array(data[:scopes]).reject { |s| s[:default] }.map do |s|
          { name: s[:name], body: source_slice(s[:body]), required_params: s[:required_params] || [], confidence: s[:confidence] }.compact
        end
      end

      # Base first, as Rails stacks them; each one filters every query.
      def default_scopes(data)
        Array(data[:scopes]).select { |s| s[:default] }.map { |s| source_slices(s.slice(:body, :all_queries, :confidence)) }.presence
      end

      # `validate :method` is not a validator; both tiers report it once, here.
      def custom_validates(data)
        Array(data[:validations]).select { |v| v[:kind] == "custom" }.flat_map { |v| v[:attributes] }
      end

      # A validate block is listed by what it runs; Rails registers it next to any methods named.
      def custom_validate_blocks(data)
        found = Array(data[:validations]).select { |v| v[:kind] == "custom" && v[:block] }.map do |v|
          { body: source_slice(v[:block]), conditions: source_slices((v[:options] || {}).slice(*CONDITION_KEYS, :on)).presence }.compact
        end
        found.presence
      end

      # `validate :check, on: :create` runs only then; the method name alone
      # reads as a rule that always holds.
      def custom_validate_conditions(data)
        found = Array(data[:validations]).select { |v| v[:kind] == "custom" }.each_with_object({}) do |v, hash|
          conditions = source_slices((v[:options] || {}).slice(*CONDITION_KEYS, :on))
          v[:attributes].each { |name| hash[name.to_s] = conditions } if conditions.any?
        end
        found.presence
      end

      # The options that decide the value a new record holds and the names of
      # the methods the enum defines.
      def enum_options(data, rails_version)
        keys = Listeners::EnumsListener::OPTIONS - %i[validate]
        # Rails 7.0's enum takes no instance_methods: and lets it pass unread.
        keys.delete(:instance_methods) if rails_version && Gem::Version.new(rails_version) < Gem::Version.new("7.1")
        Array(data[:enums]).each_with_object({}) do |enum, opts|
          # Scopes and value methods are on unless an option turns them off; the rest are off unless given.
          entry = (enum[:options] || {}).slice(*keys).reject { |key, value| value.nil? || value == ENUM_ON_BY_DEFAULT.include?(key) }
          opts[enum[:name].to_s] = entry if entry.any?
        end
      end

      def group_callbacks_by_type(callbacks)
        Array(callbacks).each_with_object({}) do |cb, hash|
          next unless cb.is_a?(Hash) && cb[:type]

          (hash[cb[:type].to_s] ||= []) << cb[:method]
        end
      end

      # One conditions entry per callback, in step with the name list: one method can sit under
      # two types with different conditions.
      def callback_conditions(callbacks)
        Array(callbacks).each_with_object({}) do |cb, hash|
          next unless cb.is_a?(Hash) && cb[:type]

          options = cb[:options] || {}
          conditions = options.select { |key, _| CONDITION_KEYS.include?(key) }
          conditions = { on: options[:on] }.merge(conditions) if options.key?(:on) && !Listeners::CallbacksListener.names_event?(cb[:type])
          (hash[cb[:type].to_s] ||= []) << (conditions.empty? ? nil : source_slices(conditions))
        end.reject { |_, list| list.none? }
      end

      # The declaration of a callback no method body can show - a block, a
      # lambda, a turbo-rails broadcast macro - in step with the name list,
      # nil for a method. Its line is the declaring file's.
      def callback_sources(callbacks)
        Array(callbacks).each_with_object({}) do |cb, hash|
          next unless cb.is_a?(Hash) && cb[:type]

          source = cb[:source] && { code: source_slice(cb[:source]), start_line: cb[:location], end_line: cb[:end_location],
                                    from_concern: cb[:from_concern], runs: cb[:runs] }.compact
          (hash[cb[:type].to_s] ||= []) << source
        end.reject { |_, list| list.none? }
      end

      def concern_callbacks(callbacks)
        Array(callbacks).select { |cb| cb.is_a?(Hash) && cb[:from_concern] }.presence
      end

      # What a mixin's macro method declares only under a condition the call
      # cannot decide, or inside a block it evaluates on another receiver
      # (`translation_class.instance_eval`): named, and never counted as the model's.
      def declarations(found)
        Array(found).map { |c| c.is_a?(Hash) ? c.slice(*DECLARATION_KEYS) : c }.uniq.presence
      end

      def source_slice(text)
        Redaction.source_slice(text)
      end

      # Option values as written, at any depth: a lambda's text beside the method names.
      def source_slices(value)
        case value
        when Hash then value.transform_values { |inner| source_slices(inner) }
        when Array then value.map { |inner| source_slices(inner) }
        else source_slice(value)
        end
      end
    end
  end
end
