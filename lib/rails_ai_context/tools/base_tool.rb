# frozen_string_literal: true

require "mcp"

module RailsAiContext
  module Tools
    # Base class for all MCP tools exposed by rails-ai-context.
    # Inherits from the official MCP::Tool to get schema validation,
    # annotations, and protocol compliance for free.
    class BaseTool < MCP::Tool
      # Default output schema for all tools. MCP::Tool.inherited resets
      # @output_schema_value to nil on each subclass, so we re-set it
      # via our own inherited hook.
      DEFAULT_OUTPUT_SCHEMA = MCP::Tool::OutputSchema.new(
        type: "object",
        properties: {
          content: {
            type: "array",
            items: {
              type: "object",
              properties: {
                type: { type: "string", enum: [ "text" ] },
                text: { type: "string", description: "Tool response as Markdown-formatted text" }
              },
              required: [ "type", "text" ]
            }
          }
        },
        required: [ "content" ]
      ).freeze

      # ── Auto-registration ────────────────────────────────────────────
      # Every subclass is tracked automatically via inherited.
      # BaseTool itself is abstract — only concrete tools are registered.
      # Thread-safe: Mutex guards @descendants and @eager_loaded.
      @descendants = []
      @abstract = true
      @registry_mutex = Mutex.new

      def self.inherited(subclass)
        super
        subclass.instance_variable_set(:@output_schema_value, DEFAULT_OUTPUT_SCHEMA)
        subclass.instance_variable_set(:@abstract, false)
        # Thread-safe append. Mutex is NOT held during eager_load!'s const_get
        # (which triggers inherited), so no recursive locking risk here.
        BaseTool.registry_mutex.synchronize { BaseTool.descendants << subclass }
      end

      class << self
        attr_reader :descendants, :registry_mutex

        # Mark a tool class as abstract (excluded from registration).
        def abstract!
          @abstract = true
          registry_mutex.synchronize { descendants.delete(self) }
        end

        def abstract?
          @abstract == true
        end

        # All non-abstract tool classes. Triggers eager loading first.
        def registered_tools
          eager_load!
          registry_mutex.synchronize { descendants.reject(&:abstract?) }
        end

        private

        def eager_load!
          # Double-checked locking: fast path avoids mutex for common case.
          return if @eager_loaded

          # Collect constants to load OUTSIDE the mutex, then load them.
          # const_get triggers Zeitwerk autoload → inherited → mutex.synchronize,
          # so we must NOT hold the mutex during const_get (avoids deadlock).
          consts_to_load = registry_mutex.synchronize do
            return if @eager_loaded # re-check inside mutex

            Dir[File.join(__dir__, "*.rb")].filter_map do |path|
              basename = File.basename(path, ".rb")
              next if basename == "base_tool"
              basename.split("_").map(&:capitalize).join.to_sym
            end
          end

          # Load outside mutex — inherited callbacks acquire the mutex individually.
          # Use inherit: false so top-level constants (Set, Hash, etc.) don't
          # shadow tool classes that Zeitwerk hasn't autoloaded yet.
          consts_to_load.each do |const|
            RailsAiContext::Tools.const_get(const, false)
          rescue NameError => e
            # Only skip if the constant itself doesn't exist (filename/constant mismatch).
            # Re-raise if the error came from inside the loaded file (a real bug).
            if e.name == const && !RailsAiContext::Tools.const_defined?(const, false)
              $stderr.puts "[rails-ai-context] eager_load! skipped #{const}: #{e.message}" if ENV["DEBUG"]
            else
              raise
            end
          end

          registry_mutex.synchronize { @eager_loaded = true }
        end
      end

      # Shared cache across all tool subclasses, protected by a Mutex
      # for thread safety in multi-threaded servers (e.g., Puma).
      SHARED_CACHE = { mutex: Mutex.new }

      # Session-level context tracking. Lets AI avoid redundant queries
      # by recording what tools have been called with what params.
      # In-memory only — resets on server restart (matches conversation lifecycle).
      SESSION_CONTEXT = { mutex: Mutex.new, queries: {} }

      class << self
        # Convenience: access the Rails app and cached introspection
        def rails_app
          Rails.application
        end

        def config
          RailsAiContext.configuration
        end

        # Cache introspection results with TTL + fingerprint invalidation.
        # Uses SHARED_CACHE so all tool subclasses share one introspection
        # result instead of each caching independently.
        def cached_context
          SHARED_CACHE[:mutex].synchronize do
            now = Process.clock_gettime(Process::CLOCK_MONOTONIC)
            ttl = RailsAiContext.configuration.cache_ttl

            if SHARED_CACHE[:context] && (now - SHARED_CACHE[:timestamp]) < ttl && !Fingerprinter.changed?(rails_app, SHARED_CACHE[:fingerprint])
              return SHARED_CACHE[:context].deep_dup
            end

            SHARED_CACHE[:context] = RailsAiContext.introspect
            SHARED_CACHE[:timestamp] = now
            SHARED_CACHE[:fingerprint] = Fingerprinter.compute(rails_app)
            SHARED_CACHE[:context].deep_dup
          end
        end

        def reset_cache!
          SHARED_CACHE[:mutex].synchronize do
            SHARED_CACHE.delete(:context)
            SHARED_CACHE.delete(:timestamp)
            SHARED_CACHE.delete(:fingerprint)
          end
        end

        # Reset the shared cache. Used by LiveReload to invalidate on file change.
        def reset_all_caches!
          reset_cache!
          session_reset!
          AstCache.clear
        end

        # ── Session context helpers ──────────────────────────────────────

        def session_record(tool_name, params, summary = nil)
          SESSION_CONTEXT[:mutex].synchronize do
            key = session_key(tool_name, params)
            existing = SESSION_CONTEXT[:queries][key]
            if existing
              existing[:call_count] = (existing[:call_count] || 1) + 1
              existing[:last_timestamp] = Time.now.iso8601
              existing[:summary] = summary if summary
            else
              SESSION_CONTEXT[:queries][key] = {
                tool: tool_name.to_s,
                params: params,
                call_count: 1,
                timestamp: Time.now.iso8601,
                summary: summary
              }
            end
          end
        end

        def session_queries
          SESSION_CONTEXT[:mutex].synchronize do
            SESSION_CONTEXT[:queries].values.dup
          end
        end

        def session_reset!
          SESSION_CONTEXT[:mutex].synchronize do
            SESSION_CONTEXT[:queries].clear
          end
        end

        # Standardized pagination: slice items with offset/limit and produce a consistent hint.
        # Returns { items:, hint:, total:, offset:, limit: }
        def paginate(items, offset:, limit:, default_limit: 50)
          offset = [ offset.to_i, 0 ].max
          limit  = limit.nil? ? default_limit : [ limit.to_i, 1 ].max
          total  = items.size
          sliced = items.drop(offset).first(limit)

          hint = if sliced.empty? && total > 0
            "_No items at offset #{offset}. Total: #{total}._"
          elsif offset + limit < total
            "_Showing #{offset + 1}-#{offset + sliced.size} of #{total}. Use offset:#{offset + limit} for next page._"
          else
            ""
          end

          { items: sliced, hint: hint, total: total, offset: offset, limit: limit }
        end

        # Structured not-found error with fuzzy suggestion and recovery hint.
        # Helps AI agents self-correct without retrying blind.
        def not_found_response(type, name, available, recovery_tool: nil)
          suggestion = find_closest_match(name, available)
          # Don't suggest the exact same string the user typed — that's useless
          suggestion = nil if suggestion == name
          lines = [ "#{type} '#{name}' not found." ]
          lines << "Did you mean '#{suggestion}'?" if suggestion
          lines << "Available: #{available.first(20).join(', ')}#{"..." if available.size > 20}"
          lines << "_Recovery: #{recovery_tool}_" if recovery_tool
          text_response(lines.join("\n"))
        end

        # Fuzzy match: find the closest available name by exact, underscore, substring, or prefix
        def find_closest_match(input, available)
          return nil if available.empty?
          downcased = input.downcase
          underscored = input.underscore.downcase

          # Exact case-insensitive match (including underscore/classify variants)
          exact = available.find do |a|
            a_down = a.downcase
            a_under = a.underscore.downcase
            a_down == downcased || a_under == underscored || a_down == underscored || a_under == downcased
          end
          return exact if exact

          # Substring match — prefer shortest (most specific) to avoid cook → cook_comments
          substring_matches = available.select { |a| a.downcase.include?(downcased) || downcased.include?(a.downcase) }
          return substring_matches.min_by(&:length) if substring_matches.any?

          # Prefix match
          available.find { |a| a.downcase.start_with?(downcased[0..2]) }
        end

        # Cache key for paginated responses — lets agents detect stale data between pages
        def cache_key
          SHARED_CACHE[:fingerprint] || "none"
        end

        # Case-insensitive fuzzy key lookup for hashes keyed by class/table names.
        # Tries exact, underscore, singularize, and classify variants. Returns matching key or nil.
        # Shared by get_model_details, get_callbacks, get_context, generate_test, dependency_graph.
        def fuzzy_find_key(keys, query)
          return nil if query.nil? || keys.nil? || keys.empty?
          q = query.to_s.strip
          return nil if q.empty?
          q_down = q.downcase
          q_under = q.underscore.downcase

          keys.find { |k| k.to_s.downcase == q_down } ||
            keys.find { |k| k.to_s.underscore.downcase == q_under } ||
            keys.find { |k| k.to_s.downcase == q.singularize.downcase } ||
            keys.find { |k| k.to_s.downcase == q.classify.downcase }
        end

        # Extract method source from a source string via indentation-based matching.
        # Returns { code:, start_line:, end_line: } or nil. Shared by get_callbacks, get_concern.
        def extract_method_source_from_string(source, method_name)
          source_lines = source.lines
          escaped = Regexp.escape(method_name.to_s)
          # ? and ! ARE word boundaries, so skip \b after them
          pattern = if method_name.to_s.end_with?("?", "!")
            /\A\s*def\s+#{escaped}/
          else
            /\A\s*def\s+#{escaped}\b/
          end
          start_idx = source_lines.index { |l| l.match?(pattern) }
          return nil unless start_idx

          def_indent = source_lines[start_idx][/\A\s*/].length
          result = []
          end_idx = start_idx

          source_lines[start_idx..].each_with_index do |line, i|
            result << line.rstrip
            end_idx = start_idx + i
            break if i > 0 && line.match?(/\A\s{#{def_indent}}end\b/)
          end

          { code: result.join("\n"), start_line: start_idx + 1, end_line: end_idx + 1 }
        rescue => e
          $stderr.puts "[rails-ai-context] extract_method_source_from_string failed: #{e.message}" if ENV["DEBUG"]
          nil
        end

        # Extract method source from a file path. Reads file safely. Returns hash or nil.
        def extract_method_source_from_file(path, method_name)
          return nil unless File.exist?(path)
          return nil if File.size(path) > RailsAiContext.configuration.max_file_size
          source = RailsAiContext::SafeFile.read(path) || ""
          extract_method_source_from_string(source, method_name)
        end

        # Store call params for the current tool invocation (thread-safe)
        def set_call_params(**params)
          Thread.current[:rails_ai_context_call_params] = params.reject { |_, v| v.nil? || (v.respond_to?(:empty?) && v.empty?) }
        end

        # Helper: wrap text in an MCP::Tool::Response with safety-net truncation.
        # Auto-records the call in session context so session_context(action:"status") works.
        def text_response(text)
          # Auto-track: record this tool call in session context (skip SessionContext itself to avoid recursion)
          if respond_to?(:tool_name) && tool_name != "rails_session_context"
            summary = text.lines.first&.strip&.truncate(80)
            params = Thread.current[:rails_ai_context_call_params] || {}
            session_record(tool_name, params, summary)
            Thread.current[:rails_ai_context_call_params] = nil
          end

          max = RailsAiContext.configuration.max_tool_response_chars
          if max && text.length > max
            truncated = text[0...max]
            truncated += "\n\n---\n_Response truncated (#{text.length} chars). Use `detail:\"summary\"` for an overview, or filter by a specific item (e.g. `table:\"users\"`)._"
            MCP::Tool::Response.new([ { type: "text", text: truncated } ])
          else
            MCP::Tool::Response.new([ { type: "text", text: text } ])
          end
        end

        private

        def session_key(tool_name, params)
          normalized = tool_name.to_s.sub(/\Arails_/, "")
          param_str = params.is_a?(Hash) ? params.sort_by { |k, _| k.to_s }.map { |k, v| "#{k}:#{v}" }.join(",") : params.to_s
          "#{normalized}:#{param_str}"
        end
      end
    end
  end
end
