# frozen_string_literal: true

require "json"

module RailsAiContext
  # Fits a data structure into a character budget and serializes it as JSON
  # that always parses.
  #
  # A tool response is markdown and can be cut anywhere, so BaseTool#text_response
  # slices the string. Resource payloads are served under an application/json
  # mime type, so the same trick ends the body mid-object and JSON.parse raises.
  # The budget is applied to the DATA instead: whole elements are dropped until
  # what remains fits, and what went missing is reported under a reserved
  # "_truncated" key. Values are otherwise served exact, except an over-long
  # string, which is cut at a marker and counted in the report.
  module JsonBudget
    # Reserved key carrying the reduction report on an oversized payload, and
    # the marker left inside a string value that had to be cut.
    TRUNCATION_KEY = "_truncated"
    TRUNCATION_REASON = "response_size_cap"
    STRING_CLIP_MARKER = "... (truncated)"

    TRUNCATION_HINT = "Whole elements were dropped and an over-long string value may be cut at a " \
                      "\"#{STRING_CLIP_MARKER}\" marker; nothing else was altered. " \
                      "Use the rails_get_* tools to page through what is missing."

    # How deep the reducer descends before it empties a container instead of
    # recursing. Introspection payloads bottom out far above this; the cap is
    # here so a pathological structure cannot drive unbounded recursion.
    MAX_REDUCE_DEPTH = 16

    # Chars held back from the data budget for the report, how many clipped
    # paths it names, and how many refits are allowed when a report outgrows
    # the reserve. The reserve is capped at a quarter of the budget so a small
    # budget still leaves room for data.
    NOTE_RESERVE = 2_048
    MAX_CLIP_RECORDS = 12
    MAX_FIT_ATTEMPTS = 3

    # Chars it costs to attach the report to a fitted payload, whichever shape
    # with_note ends up using. Slack, not a tight bound.
    NOTE_ATTACH_OVERHEAD = 24

    # Smallest valid JSON that still says the payload was cut. Emitted only
    # when the budget is below the size of a usable report.
    MINIMUM_TRUNCATION_JSON = %({"#{TRUNCATION_KEY}":true})

    class << self
      # Pretty JSON when the payload fits, a reduced compact document when it
      # does not. Never returns a string that fails to parse.
      def generate(data, max)
        content = JSON.pretty_generate(data)
        return content unless max && content.length > max

        # Indentation alone can be the whole overage. Dropping it loses no
        # data, so try that before reducing: the reducer works against a
        # budget held back for its report and would otherwise clip a payload
        # that fits, and report a loss that did not happen.
        compact = JSON.generate(data)
        return compact if compact.length <= max

        reduce_to_budget(data, content.length, max)
      end

      private

      # Reduced payloads are emitted compact. Indentation is content we cannot
      # afford at the cap, and compact JSON is also what makes the accounting
      # below exact: pretty-printing indents a value by where it sits in the
      # tree, so a subtree could not be measured once and reused.
      #
      # The report is built after the data is fitted, so its cost is only an
      # estimate up front (NOTE_RESERVE). A report that outgrows the reserve is
      # not allowed to push the response over the budget - the assembled string
      # is measured, and an overshoot refits against the measured report size.
      # The loop is bounded; the floor below it is not a guess.
      def reduce_to_budget(data, original_chars, max)
        budget = max - [ NOTE_RESERVE, max / 4 ].min
        attempts = 0

        while budget.positive? && attempts < MAX_FIT_ATTEMPTS
          attempts += 1
          clips = []
          taken = take_child(data, budget, budget, 0, "", clips)
          break if taken.nil?
          # Dropping the indentation was enough on its own: nothing was lost,
          # so nothing is reported.
          return JSON.generate(taken[0]) if clips.empty?

          note = truncation_note(original_chars, max, clips)
          candidate = JSON.generate(with_note(taken[0], note))
          return candidate if candidate.length <= max

          # Aim straight at the measured report size, but never above what the
          # overshoot already proved is too much: the first term lands close,
          # the second guarantees the loop makes progress.
          budget = [ max - measure(note) - NOTE_ATTACH_OVERHEAD, budget - (candidate.length - max) ].min
        end

        minimum_json(original_chars, max)
      end

      # Reached when the budget is smaller than a payload plus a usable report.
      # A parseable body outranks the budget here: the cap is a safety net
      # against unbounded frames, and no client is harmed by a response a few
      # dozen chars over a limit set that low.
      def minimum_json(original_chars, max)
        short = JSON.generate({ TRUNCATION_KEY => {
          "reason" => TRUNCATION_REASON, "original_chars" => original_chars, "max_chars" => max
        } })
        short.length <= max ? short : MINIMUM_TRUNCATION_JSON
      end

      # The report rides inside the caller's own top-level object so existing
      # key paths still resolve - data["routes"] keeps working. A payload that
      # is not an object has nowhere to hang it, so it moves under "data".
      # Key order also changes on a reduced hash, since ordered_pairs spends
      # the budget on scalars first.
      def with_note(kept, note)
        return { TRUNCATION_KEY => note, "data" => kept } unless kept.is_a?(Hash)

        kept.reject { |k, _| k.to_s == TRUNCATION_KEY }.merge(TRUNCATION_KEY => note)
      end

      def truncation_note(original_chars, max, clips)
        {
          "reason" => TRUNCATION_REASON,
          "original_chars" => original_chars,
          "max_chars" => max,
          "clipped" => clips.first(MAX_CLIP_RECORDS),
          "hint" => TRUNCATION_HINT
        }
      end

      # Decides what one child contributes to its container. Returns
      # [ value, exact compact JSON chars, whole? ] or nil when the child has
      # to be dropped. The chars are always the truth about the value being
      # returned, so a container can trust them for its own accounting.
      def take_child(value, room, budget, depth, path, clips)
        size = measure(value)
        return [ value, size, true ] if size <= room
        # A child that would have fit in an emptier container is dropped whole
        # rather than cut open: its siblings already spent the room, and a
        # clean drop the report can name beats a half-written value. That only
        # holds once the siblings really did take most of the budget - the
        # `room * 2` test. At the top of a container, where the only thing
        # spent is the braces and this child's own key, dropping it would
        # throw the entire payload away to keep its metadata, so it is opened
        # up and reduced instead.
        return nil if size <= budget && room * 2 <= budget

        reduced, chars = reduce(value, room, depth, path, clips)
        return nil if reduced.nil?

        [ reduced, chars, false ]
      end

      def reduce(value, budget, depth, path, clips)
        case value
        when Hash   then reduce_hash(value, budget, depth, path, clips)
        when Array  then reduce_array(value, budget, depth, path, clips)
        when String then reduce_string(value, budget, path, clips)
        end
      end

      # Keeps a leading run of whole pairs. `used` tracks the exact compact
      # length of what is kept: {} plus, per pair, the quoted key, its colon,
      # the value, and the separating comma.
      def reduce_hash(hash, budget, depth, path, clips)
        return [ {}, 2 ] if bottom_out?(hash.size, depth, path, clips)

        kept = {}
        used = 2

        ordered_pairs(hash).each do |key, value|
          overhead = measure(key.to_s) + 1 + (kept.empty? ? 0 : 1)
          room = budget - used - overhead
          break if room <= 0

          taken = take_child(value, room, budget, depth + 1, child_path(path, key), clips)
          break if taken.nil?

          kept[key] = taken[0]
          used += overhead + taken[1]
          # At most one child per container is opened up, which keeps the
          # reduction to a single path down the tree - and with it the report
          # short and the work bounded.
          break unless taken[2]
        end

        record_clip(clips, path, kept.size, hash.size)
        [ kept, used ]
      end

      # Scalar pairs are the cheap self-describing ones - counts, names, flags
      # - and a single dominant collection must not crowd them out. A schema
      # payload is `adapter`, `tables`, `total_tables`, `schema_version`, ...
      # in that order, so without this the two counts that tell an agent how
      # much it is missing get dropped to fit two more tables. JSON objects are
      # unordered, so hoisting them costs nothing.
      def ordered_pairs(hash)
        scalars, containers = hash.each_pair.partition { |_, v| !v.is_a?(Hash) && !v.is_a?(Array) }
        scalars + containers
      end

      def reduce_array(array, budget, depth, path, clips)
        return [ [], 2 ] if bottom_out?(array.size, depth, path, clips)

        kept = []
        used = 2

        array.each do |element|
          separator = kept.empty? ? 0 : 1
          room = budget - used - separator
          break if room <= 0

          taken = take_child(element, room, budget, depth + 1, "#{path}[]", clips)
          break if taken.nil?

          kept << taken[0]
          used += separator + taken[1]
          break unless taken[2]
        end

        record_clip(clips, path, kept.size, array.size)
        [ kept, used ]
      end

      # A long string is cut with a visible marker rather than dropped: a
      # marked prefix of a description still answers most questions. Escaping
      # makes the encoded length unpredictable, so halve until the measurement
      # agrees instead of trusting the character count.
      def reduce_string(string, budget, path, clips)
        clipped = string[0, [ budget - STRING_CLIP_MARKER.length - 2, 0 ].max].to_s
        value = clipped + STRING_CLIP_MARKER
        size = measure(value)

        until size <= budget || clipped.empty?
          clipped = clipped[0, clipped.length / 2]
          value = clipped + STRING_CLIP_MARKER
          size = measure(value)
        end

        record_clip(clips, path, clipped.length, string.length, "chars")
        [ value, size ]
      end

      # An emptied container keeps its type honest; the clip record is what
      # says the contents are missing.
      def bottom_out?(total, depth, path, clips)
        return false if depth < MAX_REDUCE_DEPTH

        record_clip(clips, path, 0, total)
        true
      end

      # Records unwind deepest-first, so push to the front: the shallowest
      # counts are the ones a reader needs and the ones that must survive
      # MAX_CLIP_RECORDS. `unit` disambiguates the counts, which mean elements
      # for a container and characters for a cut string.
      def record_clip(clips, path, kept, total, unit = "elements")
        return if kept == total

        clips.unshift({ "path" => path.empty? ? "(root)" : path.truncate(100),
                        "kept" => kept, "total" => total, "unit" => unit })
      end

      def child_path(path, key)
        path.empty? ? key.to_s : "#{path}.#{key}"
      end

      # Exact compact length of one value's own encoding. Measured inside a
      # one-element array so the call is always a container generate: JSON
      # versions differ on whether a bare scalar may be generated on its own,
      # and the brackets cost a known 2 chars. JSON.generate rather than
      # to_json because ActiveSupport overrides to_json with as_json semantics
      # once a host app boots, which would measure something the emit path
      # never produces.
      #
      # The wrapper costs a nesting level, which would fail a payload sitting
      # exactly at JSON's default limit. Serializing the whole payload is the
      # first thing generate does, so anything measured here is already known
      # to encode - including that it is not circular, the case the nesting
      # limit exists to catch.
      def measure(value)
        JSON.generate([ value ], max_nesting: false).length - 2
      end
    end
  end
end
