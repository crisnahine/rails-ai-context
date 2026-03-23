# frozen_string_literal: true

require "mcp"

module RailsAiContext
  module Tools
    # Base class for all MCP tools exposed by rails-ai-context.
    # Inherits from the official MCP::Tool to get schema validation,
    # annotations, and protocol compliance for free.
    class BaseTool < MCP::Tool
      # Shared cache across all tool subclasses, protected by a Mutex
      # for thread safety in multi-threaded servers (e.g., Puma).
      SHARED_CACHE = { mutex: Mutex.new }

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
              return SHARED_CACHE[:context]
            end

            SHARED_CACHE[:context] = RailsAiContext.introspect
            SHARED_CACHE[:timestamp] = now
            SHARED_CACHE[:fingerprint] = Fingerprinter.compute(rails_app)
            SHARED_CACHE[:context]
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
        end

        # Structured not-found error with fuzzy suggestion and recovery hint.
        # Helps AI agents self-correct without retrying blind.
        def not_found_response(type, name, available, recovery_tool: nil)
          suggestion = find_closest_match(name, available)
          lines = [ "#{type} '#{name}' not found." ]
          lines << "Did you mean '#{suggestion}'?" if suggestion
          lines << "Available: #{available.first(20).join(', ')}#{"..." if available.size > 20}"
          lines << "_Recovery: #{recovery_tool}_" if recovery_tool
          text_response(lines.join("\n"))
        end

        # Simple fuzzy match: find the closest available name by substring or edit distance
        def find_closest_match(input, available)
          return nil if available.empty?
          downcased = input.downcase
          # Exact substring match first
          exact = available.find { |a| a.downcase.include?(downcased) || downcased.include?(a.downcase) }
          return exact if exact
          # Prefix match
          available.find { |a| a.downcase.start_with?(downcased[0..2]) }
        end

        # Cache key for paginated responses — lets agents detect stale data between pages
        def cache_key
          SHARED_CACHE[:fingerprint] || "none"
        end

        # Helper: wrap text in an MCP::Tool::Response with safety-net truncation
        def text_response(text)
          max = RailsAiContext.configuration.max_tool_response_chars
          if max && text.length > max
            truncated = text[0...max]
            truncated += "\n\n---\n_Response truncated (#{text.length} chars). Use `detail:\"summary\"` for an overview, or filter by a specific item (e.g. `table:\"users\"`)._"
            MCP::Tool::Response.new([ { type: "text", text: truncated } ])
          else
            MCP::Tool::Response.new([ { type: "text", text: text } ])
          end
        end
      end
    end
  end
end
