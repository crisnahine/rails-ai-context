# frozen_string_literal: true

module RailsAiContext
  module Tools
    # Asking for an introspection section and answering honestly when it is
    # unusable are one operation. A tool names the section and what to call
    # it; everything that could make the answer dishonest - the section was
    # never introspected, the introspector raised, the data source was
    # absent, the app is API-only, the tier cannot serve it - is handled
    # here, and the block only ever sees real data.
    module SectionFetch
      # Whether a section can be rendered at all: a hash carrying :error (the
      # introspector raised) or :unavailable (the data source was absent) is
      # not empty data, it is no data. The serializers ask through
      # Serializers::SectionGuard, which defers here.
      def self.usable?(data)
        data.is_a?(Hash) && !data[:error] && !data[:unavailable]
      end

      # @param unusable_message [String] one answer for both "never
      #   introspected" and "the introspector raised", for tools that do not
      #   distinguish them.
      # @return the block's value, or a text response explaining why not.
      def fetch_section(key, subject: nil, remedy: nil, api_only: nil, unusable_message: nil)
        if (refusal = static_refusal_for(key))
          return refusal
        end

        data = cached_context[key]
        unless data.is_a?(Hash) && !data[:error]
          if (note = unavailable_note(data))
            return text_response(note)
          end

          return text_response(unusable_message) if unusable_message

          # Anything that is not a hash is not a section this tool can read,
          # and asking it for `[:error]` raises - which SafeCall would then
          # report as the tool failing, the dishonest answer this seam exists
          # to prevent.
          unless data.is_a?(Hash)
            return text_response("#{subject} not available. #{remedy || "Add :#{key} to introspectors."}")
          end

          return text_response("#{subject} failed: #{data[:error]}")
        end

        if (note = unavailable_note(data))
          return text_response(note)
        end

        if api_only && (note = api_only_note(api_only))
          return text_response(note)
        end

        yield data
      end

      private

      # Driven by the introspector's own declaration rather than by whatever
      # the section hash happens to hold, so a runtime-only section refuses
      # for the reason it actually cannot answer.
      def static_refusal_for(key)
        return nil unless RailsAiContext.static_tier?

        introspector = RailsAiContext::Introspector::INTROSPECTOR_MAP[key]
        return nil unless introspector.respond_to?(:answers_statically?)
        return nil if introspector.answers_statically?

        { unavailable: unavailable_static_reason }.then { |section| text_response(unavailable_note(section)) }
      end

      def unavailable_static_reason
        Introspectors::StaticTier.unavailable_reason
      end
    end
  end
end
