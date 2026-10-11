# frozen_string_literal: true

require "did_you_mean"

require "mcp"
require "active_support"
require "active_support/number_helper"

module RailsAiContext
  module Tools
    # Base class for all MCP tools exposed by rails-ai-context.
    # Inherits from the official MCP::Tool to get schema validation,
    # annotations, and protocol compliance for free.
    class BaseTool < MCP::Tool
      # ── Auto-registration ────────────────────────────────────────────
      # Every subclass is tracked automatically via inherited.
      # BaseTool itself is abstract - only concrete tools are registered.
      # Thread-safe: Mutex guards @descendants and @eager_loaded.
      @descendants = []
      @abstract = true
      @registry_mutex = Mutex.new

      def self.inherited(subclass)
        super
        subclass.instance_variable_set(:@abstract, false)
        subclass.singleton_class.prepend(SafeCall)
        # Thread-safe append. Mutex is NOT held during eager_load!'s const_get
        # (which triggers inherited), so no recursive locking risk here.
        BaseTool.registry_mutex.synchronize { BaseTool.descendants << subclass }
      end

      class << self
        include CountPhrase
        include RailsAiContext::OptionText

        attr_reader :descendants, :registry_mutex

        # Mark a tool class as abstract (excluded from registration).
        # Reaches back to BaseTool explicitly: registry_mutex/descendants are
        # ivars on the BaseTool object, and a subclass calling this method
        # has no ivar storage of its own to read them from.
        def abstract!
          @abstract = true
          BaseTool.registry_mutex.synchronize { BaseTool.descendants.delete(self) }
        end

        def abstract?
          @abstract == true
        end

        # Sorted so load order never reaches tool --list or tools/list.
        def registered_tools
          eager_load!
          registry_mutex.synchronize { descendants.reject(&:abstract?) }.sort_by { |tool| tool.tool_name.to_s }
        end

        private

        # The registry mutex is deliberately not held: const_get triggers a
        # Zeitwerk autoload, whose `inherited` callback takes that mutex itself.
        def eager_load!
          return if @eager_loaded

          Tools.constants.each { |const| Tools.const_get(const, false) }
          @eager_loaded = true
        end
      end

      # Shared cache across all tool subclasses, protected by a Mutex
      # for thread safety in multi-threaded servers (e.g., Puma).
      SHARED_CACHE = { mutex: Mutex.new }

      # What a server last saw of its app's files (a Fingerprinter::Snapshot),
      # when the check now running began, and when the last finished one
      # did. The snapshot is nil until a server starts, so a process that is
      # no server (the CLI, rake) never walks the tree. `stale_code` is what a
      # server that cannot reload found changed since it loaded it
      # (CodeReloader.changed_code).
      FILE_CHECK = { mutex: Mutex.new, done: ConditionVariable.new, snapshot: nil, running: nil, finished: nil, stale_code: nil }

      # Session-level context tracking. Lets AI avoid redundant queries
      # by recording what tools have been called with what params.
      # In-memory only - resets on server restart.
      #
      # Bucketed per conversation. Over stdio one process serves one
      # conversation and everything lands in DEFAULT_SESSION; the HTTP
      # transports serve many from one process, so each request's
      # Mcp-Session-Id gets its own bucket and one client's history stays out
      # of another's.
      # A plain Hash, not one with a default block: a default block writes on
      # lookup, so merely reading a session's history created it. `dropped`
      # counts, per session, the queries its record no longer keeps.
      SESSION_CONTEXT = { mutex: Mutex.new, queries: {}, dropped: {} }

      DEFAULT_SESSION = :default

      # The session id comes from a client-controlled header in a process
      # that stays up, so both its length and the number of them are capped.
      # Oldest-first eviction: a conversation nobody has touched in the last
      # MAX_SESSIONS is the one least likely to ask about its own history.
      MAX_SESSIONS = 100
      MAX_SESSION_ID_LENGTH = 200
      # What one session's record holds is capped the same way: its latest
      # queries, each param kept as an answer echoes it. A client sending a
      # 100 KB argument on every call otherwise grew the record without end.
      MAX_SESSION_QUERIES = 200

      # One row of the generated tool guide, declared beside the tool's own
      # description so adding a tool touches one file. `order` fixes where the
      # row lands; the CLI command is derived from tool_name, never spelled.
      GuideRow = Struct.new(:order, :mcp, :cli_args, :summary, keyword_init: true)

      class << self
        include SectionFetch

        def guide_row(order: nil, mcp: nil, cli_args: nil, summary: nil)
          return @guide_row if order.nil?

          @guide_row = GuideRow.new(order: order, mcp: mcp, cli_args: cli_args, summary: summary)
        end

        # Convenience: access the Rails app and cached introspection.
        # Routes through RailsAiContext.default_app so this resolves to the
        # booted app in runtime tier and to a StaticApp in static tier -
        # tools that call rails_app directly (get_concern, analyze_feature,
        # migration_advisor, ...) work in both tiers without their own checks.
        def rails_app
          RailsAiContext.default_app
        end

        def config
          RailsAiContext.configuration
        end

        # Every tool's arguments are checked through ArgumentSchema, so an
        # app whose locale files do not load still gets argument errors.
        def input_schema(*args)
          return super if args.empty?

          value = args.first
          super(value.is_a?(Hash) ? ArgumentSchema.new(value) : value)
        end

        # A bare `Rails.env` raises NameError under --no-boot or early boot death.
        def rails_env_name
          RailsAiContext.environment_name
        end

        # The app's own enqueue helpers (`Jobs.enqueue(:x)`), as the jobs section read them.
        def enqueue_helpers
          jobs = cached_context[:jobs]
          jobs.is_a?(Hash) ? Array(jobs[:enqueue_helpers]) : []
        end

        # Cache introspection results with TTL + fingerprint invalidation.
        # Uses SHARED_CACHE so all tool subclasses share one introspection
        # result instead of each caching independently.
        # One copy per tool call: a tool reads the context from many helpers,
        # and each copy deep-dups every section.
        def cached_context
          RunCache.fetch([ :tool_context ]) { shared_context_copy }
        end

        private def shared_context_copy
          SHARED_CACHE[:mutex].synchronize do
            now = Process.clock_gettime(Process::CLOCK_MONOTONIC)
            ttl = RailsAiContext.configuration.cache_ttl

            # Fast path: within TTL window, trust the cache and skip the
            # fingerprint walk entirely. A server has already dropped it if a
            # file changed: each call asks the files at its start
            # (refresh_if_files_changed!).
            if SHARED_CACHE[:context] && (now - SHARED_CACHE[:timestamp]) < ttl
              return SHARED_CACHE[:context].deep_dup
            end

            # TTL expired: re-validate via fingerprint before re-introspecting.
            # If fingerprint is unchanged, bump the timestamp and reuse the
            # cached context - saves re-running all 40 introspectors.
            if SHARED_CACHE[:context] && !Fingerprinter.stale?(rails_app, SHARED_CACHE[:fingerprint])
              SHARED_CACHE[:timestamp] = now
              return SHARED_CACHE[:context].deep_dup
            end

            # Marked before the walk, not after: a mark taken afterwards
            # covers edits made while the 40 introspectors ran, and the next
            # caller reads a stale context as fresh.
            mark = Fingerprinter.mark(rails_app)
            SHARED_CACHE[:context] = RailsAiContext.introspect
            SHARED_CACHE[:timestamp] = now
            SHARED_CACHE[:fingerprint] = mark
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

        # Every cache that describes the app's files, dropped once a call's
        # check finds them moved.
        def reset_all_caches!
          reset_cache!
          session_reset!
          AstCache.clear
          PathResolver.clear_code_roots
        end

        # Called by every server as it starts - stdio, HTTP, the endpoints
        # inside the app - live reload or not. From here on each call checks
        # the files against what they are now.
        #
        # A server that cannot read its files still serves; it only goes
        # without the check.
        def check_files_per_call!(app)
          snapshot = Fingerprinter::Snapshot.new(app.root)
          snapshot.changed?
          FILE_CHECK[:mutex].synchronize { FILE_CHECK.merge!(snapshot: snapshot, running: nil, finished: nil) }
        rescue StandardError => e
          RailsAiContext.debug_fail(e, nil, label: "check_files_per_call!")
        end

        # Before a call reads anything, it sees every edit made before it
        # began: when a file moved, the app's code is reloaded on the
        # calling thread and the caches dropped. Live reload only tells
        # clients: `listen` delivers a change after its debounce, a second
        # and a half on, and an agent that edits a model and asks about it
        # at once was answered from before the edit.
        #
        # The check is a stat of each watched directory and file
        # (Fingerprinter::Snapshot): about a millisecond on a small app, about
        # 30 at 10,000 files. Only a check that began after a call did can
        # stand in for that call's own, so two calls one after the other each
        # check, and concurrent calls wait for one check together. A tool
        # another tool calls is part of the first call and asks nothing.
        #
        # Outside SHARED_CACHE's mutex, unlike the TTL walk: a code reload
        # waits for running calls to finish, and they may be waiting on it.
        #
        # An app that cannot reload keeps what reflection read at boot, so
        # instead the call notes which of its files changed since they were
        # loaded, for every answer to name (stale_code_note).
        def refresh_if_files_changed!
          return if RunCache.active?

          snapshot = await_check(Process.clock_gettime(Process::CLOCK_MONOTONIC))
          return unless snapshot

          begin
            changed = snapshot.changed?
            react_to_change if changed
            done = true
          ensure
            FILE_CHECK[:mutex].synchronize do
              FILE_CHECK[:finished] = FILE_CHECK[:running] if done
              FILE_CHECK[:running] = nil
              FILE_CHECK[:done].broadcast
            end
          end
        rescue StandardError => e
          RailsAiContext.debug_fail(e, nil, label: "refresh_if_files_changed!")
        end

        # Nil once a check that began after the call arrived has finished,
        # since it saw every edit made before; otherwise the snapshot, for
        # this call to check with. A call that finds a check running waits
        # for it, and then for the next if that one began too early.
        private def await_check(arrived)
          FILE_CHECK[:mutex].synchronize do
            loop do
              return nil unless FILE_CHECK[:snapshot]
              return nil if FILE_CHECK[:finished] && FILE_CHECK[:finished] >= arrived

              unless FILE_CHECK[:running]
                FILE_CHECK[:running] = Process.clock_gettime(Process::CLOCK_MONOTONIC)
                return FILE_CHECK[:snapshot]
              end
              FILE_CHECK[:done].wait(FILE_CHECK[:mutex])
            end
          end
        end

        private def react_to_change
          if CodeReloader.reloadable?
            # A request the app serves already ran Rails' own reloader.
            CodeReloader.reload! unless CodeReloader.inside_app_executor?
          else
            changed = CodeReloader.changed_code
            FILE_CHECK[:mutex].synchronize { FILE_CHECK[:stale_code] = changed }
          end
          reset_all_caches!
        end

        # ── Session context helpers ──────────────────────────────────────

        # Run a block against one conversation's session record. The HTTP
        # transports wrap each request in this; stdio never calls it.
        def with_session(session_id)
          previous = Thread.current[:rails_ai_context_session]
          Thread.current[:rails_ai_context_session] = session_id
          yield
        ensure
          Thread.current[:rails_ai_context_session] = previous
        end

        def current_session
          Thread.current[:rails_ai_context_session] || DEFAULT_SESSION
        end

        # Which conversation a request belongs to, read from the Rack env all
        # three HTTP entry points already hold. The engine controller reaches
        # it through `request.env` rather than naming the header a third time.
        def session_from(env)
          id = env["HTTP_MCP_SESSION_ID"]
          id.nil? || id.empty? ? DEFAULT_SESSION : id[0, MAX_SESSION_ID_LENGTH]
        end

        # One process serves every client on all three HTTP entry points, so
        # a request must run scoped to whoever sent it or the session record
        # pools conversations together.
        # See docs/adr/0003-shared-tool-cache-semantics.md.
        def with_session_for(env, &block)
          with_session(session_from(env), &block)
        end

        def session_record(tool_name, params, summary = nil)
          params = recorded_params(params)
          SESSION_CONTEXT[:mutex].synchronize do
            bucket = touch_session
            evict_oldest_sessions
            key = session_key(tool_name, params)
            # Taken out and put back, so the bucket runs least recently used
            # first and the cap below drops the query asked longest ago.
            existing = bucket.delete(key)
            if existing
              existing[:call_count] = (existing[:call_count] || 1) + 1
              existing[:last_timestamp] = Time.now.iso8601
              existing[:summary] = summary if summary
              bucket[key] = existing
            else
              bucket[key] = {
                tool: tool_name.to_s,
                params: params,
                call_count: 1,
                timestamp: Time.now.iso8601,
                summary: summary
              }
              drop_oldest_queries(bucket)
            end
          end
        end

        # How many queries the calling session's record has dropped to stay
        # within MAX_SESSION_QUERIES.
        def session_dropped
          SESSION_CONTEXT[:mutex].synchronize { SESSION_CONTEXT[:dropped].fetch(current_session, 0) }
        end

        # Each param as an answer would echo it, so the record keeps no more
        # of a 100 KB argument than a reply does.
        def recorded_params(params)
          return echo_input(params) if params.is_a?(String)
          return params unless params.is_a?(Hash)

          params.transform_values { |value| value.to_s.length > ECHO_LENGTH ? echo_input(value) : value }
        end
        private :recorded_params

        # Called with the mutex held.
        def drop_oldest_queries(bucket)
          dropped = SESSION_CONTEXT[:dropped]
          while bucket.size > MAX_SESSION_QUERIES
            bucket.shift
            dropped[current_session] = dropped.fetch(current_session, 0) + 1
          end
        end
        private :drop_oldest_queries

        # Deep copies: the entries stay live inside the record and keep being
        # mutated by later calls, so handing the originals out would let a
        # caller's snapshot change under it.
        def session_queries
          SESSION_CONTEXT[:mutex].synchronize do
            (SESSION_CONTEXT[:queries][current_session] || {}).values.map(&:dup)
          end
        end

        # Every conversation's record: for a change that makes every earlier
        # answer stale (live reload), and for a test that starts clean.
        def session_reset!
          SESSION_CONTEXT[:mutex].synchronize do
            SESSION_CONTEXT[:queries].clear
            SESSION_CONTEXT[:dropped].clear
          end
        end

        # The calling conversation's record alone, which is what a client's
        # `action: "reset"` asks for. One HTTP process serves every client,
        # and clearing them all let one client empty the others' records.
        def current_session_reset!
          SESSION_CONTEXT[:mutex].synchronize do
            SESSION_CONTEXT[:queries].delete(current_session)
            SESSION_CONTEXT[:dropped].delete(current_session)
          end
        end

        # Re-inserting moves this session to the back, so hash order is
        # least-recently-used rather than oldest-created. Without it a
        # conversation that has run for hours is evicted ahead of a hundred
        # idle newcomers - backwards, and worst on the long-lived transports
        # that made bucketing necessary. Called with the mutex held.
        def touch_session
          queries = SESSION_CONTEXT[:queries]
          queries[current_session] = queries.delete(current_session) || {}
        end
        private :touch_session

        # The front of the hash is now the least recently used session.
        # Called with the mutex held.
        def evict_oldest_sessions
          queries = SESSION_CONTEXT[:queries]
          SESSION_CONTEXT[:dropped].delete(queries.shift.first) while queries.size > MAX_SESSIONS
        end
        private :evict_oldest_sessions

        # Standardized pagination: slice items with offset/limit and produce a consistent hint.
        # Returns { items:, hint:, total:, offset:, limit: }
        # `noun` names what is being counted and `truncated` marks a total that
        # is itself a cap, so the hint cannot restate a cut list as a whole one.
        def paginate(items, offset:, limit:, default_limit: 50, noun: nil, truncated: false)
          offset = [ offset.to_i, 0 ].max
          limit  = limit.nil? ? default_limit : [ limit.to_i, 1 ].max
          total  = items.size
          sliced = items.drop(offset).first(limit)

          counted = noun ? count_phrase(total, noun) : total.to_s
          counted = floor_phrase(counted) if truncated

          hint = if sliced.empty? && total > 0
            "_No items at offset #{offset}. Total: #{counted}._"
          elsif offset + limit < total
            "_Showing #{offset + 1}-#{offset + sliced.size} of #{counted}. Use offset:#{offset + limit} for next page._"
          else
            ""
          end

          { items: sliced, hint: hint, total: total, offset: offset, limit: limit }
        end

        # Structured not-found error with fuzzy suggestion and recovery hint.
        # Helps AI agents self-correct without retrying blind.
        def not_found_response(type, name, available, recovery_tool: nil, note: nil)
          # Don't suggest the exact same string the user typed - that's useless
          suggestions = find_closest_matches(name, available) - [ name ]
          lines = [ "#{type} '#{echo_input(name)}' not found." ]
          if suggestions.size == 1
            lines << "Did you mean '#{suggestions.first}'?"
          elsif suggestions.any?
            lines << "Did you mean one of: #{suggestions.join(', ')}? Give the full name."
          end
          lines << "Available: #{available.first(20).join(', ')}#{"..." if available.size > 20}" if available.any?
          lines << "_Recovery: #{recovery_tool}_" if recovery_tool
          lines << "" << note if note
          empty_response(lines.join("\n"))
        end

        # Unbooted, a test/dummy's enclosing engine is not a views root.
        def static_engine_views_note
          root = rails_app.root.to_s
          return nil unless RailsAiContext.static_tier? && RailsAiContext::PathResolver.test_root(root) != root

          "_The views of the engine this app runs in are read only with the app booted._"
        end

        # A tool ran, answered honestly, and found nothing. Renders exactly
        # like text_response - the mark rides in `_meta`, where a composing
        # tool can read it and a reader never sees it.
        def empty_response(text, suffix: nil)
          marked_response(text, :empty, suffix: suffix)
        end

        # The mark is the contract between a sub-tool and a composer: the
        # answer says whether it found anything, and no composer decides that
        # by matching the sentence the sub-tool happened to render.
        def empty?(response)
          marked?(response, :empty)
        end

        # A trace that found call sites but no `def`. The answer is real, so
        # it is not empty; the fact rides in `_meta` beside `empty` so a
        # composer asks instead of matching the sentence this tool renders.
        def definition_missing_response(text)
          marked_response(text, :definition_missing)
        end

        def definition_missing?(response)
          marked?(response, :definition_missing)
        end

        def marked_response(text, key, suffix: nil)
          answered = text_response(text, suffix: suffix)
          MCP::Tool::Response.new(answered.content, error: answered.error?, meta: { key => true })
        end

        def marked?(response, key)
          response_meta(response)[key] ? true : false
        end
        private :marked_response, :marked?

        def response_meta(response)
          meta = response.meta if response.respond_to?(:meta)
          meta.is_a?(Hash) ? meta : {}
        end

        # A sub-tool's text. A response can carry no text content at all, so
        # the composers do not index into `content` themselves.
        def response_text(response)
          first = response.content.first
          text = first.is_a?(Hash) ? first[:text].to_s : ""
          # The composing tool's own response carries the banners, once.
          [ static_tier_banner, stale_code_banner ].compact.reduce(text) { |stripped, banner| stripped.gsub(banner, "") }
        end

        # One-line banner listing introspectors that failed during context
        # generation. Aggregate tools append this so AI clients know which
        # sections are missing rather than empty.
        def introspection_warnings_note(ctx)
          warnings = ctx.is_a?(Hash) ? ctx[:_warnings] : nil
          return nil unless warnings.is_a?(Array) && warnings.any?

          failed = warnings.map { |w| w[:introspector] }.compact.join(", ")
          "\n\n---\n_Partial context: introspection failed for #{failed}. " \
            "Data from those sections is missing, not empty._"
        end

        # Short honest line for a context section that could not be produced
        # because the app isn't booted, as opposed to one that ran and found
        # nothing. Tools check this before rendering "not found"/empty copy
        # so a missing runtime capability never reads as a confirmed
        # negative (e.g. "No notable gems found" when gems were never
        # inspected at all).
        def unavailable_note(section_data)
          return nil unless section_data.is_a?(Hash) && section_data[:unavailable]

          Confidence.unavailable(section_data[:unavailable])
        end

        # A blank name is not a name: looked up, it matched a file called
        # helper.rb through a `_helper` probe and crashed on the empty path it
        # left. Every by-name lookup answers it before looking; nil for a real
        # name or none.
        def blank_name_response(param, value, kind: param)
          return nil unless value.is_a?(String) && value.strip.empty?

          text_response("The #{kind} name is blank. Give one, or omit `#{param}` to list them all.")
        end

        # A listing that drops a base class says so, or a reader goes looking for it.
        def bases_note(kind, names)
          names = Array(names).compact
          return nil if names.empty?

          "_Base classes not counted as #{kind}: #{names.join(', ')}. " \
            "Ask for one by name for what it defines._"
        end

        # A key the introspector named as unanswered has no finding behind it,
        # so a negative or empty rendering would state a fact nobody checked.
        def unanswered?(data, key)
          Array(data[:unavailable_sections]).map(&:to_s).include?(key.to_s)
        end

        def unavailable_text
          unavailable_note(unavailable: Introspectors::StaticTier.unavailable_reason)
        end

        # API-only apps legitimately have no views, partials, Stimulus, or
        # Turbo surface; a bare empty listing is indistinguishable from a
        # full-stack app that has none yet, so name the reason.
        def api_only_app?
          api = cached_context[:api]
          return api[:api_only] == true if api.is_a?(Hash) && api.key?(:api_only)

          app = rails_app
          if app.respond_to?(:config) && app.config.respond_to?(:api_only)
            return app.config.api_only == true
          end

          # Static tier: no booted config to ask, but the flag is declared in
          # config/application.rb. Without this the view tools fall back to
          # "none found", which reads as "not built yet" for an app that has
          # no view layer by design.
          AppKind.api_only?(app.root)
        rescue StandardError
          false
        end

        # Short honest line for a view/frontend section that doesn't apply on
        # an API-only app, or nil when the app has a view layer. Tools check
        # this before rendering "no X found" copy so a legitimately absent
        # surface never reads as "not built yet".
        def api_only_note(section_label, dir: nil)
          return nil unless api_only_app?
          # rails new --api keeps app/views when it keeps Action Mailer.
          return nil if dir && File.directory?(File.join(rails_app.root.to_s, dir))

          "Not applicable: this is an API-only app (config.api_only), so #{section_label} does not exist."
        end

        # One banner per response in static tier: consumers must never
        # mistake static analysis for runtime-confirmed data. Rides the
        # suffix mechanism so it survives truncation.
        def static_tier_banner
          note = static_tier_note
          return nil unless note

          "\n\n---\n_#{note}_"
        end

        # The same, once app code changed under a server that cannot reload:
        # what reflection read is the code as it booted, whatever the file
        # says now. Validations and callbacks are read off the source, so
        # they follow the edit; associations and enums do not.
        def stale_code_banner
          note = stale_code_note
          note && "\n\n---\n_#{note}_"
        end

        def stale_code_note
          files = FILE_CHECK[:stale_code]
          return nil if files.nil? || files.empty?

          named = files.size > 3 ? "#{files.first(3).join(", ")} and #{files.size - 3} more" : files.join(", ")
          "App code changed since this server booted (#{named}); RAILS_ENV=#{RailsAiContext.environment_name} " \
            "does not reload code, so what reflection reads, such as associations and enums, is as of boot. " \
            "Restart the server to see the #{files.size == 1 ? "edit" : "edits"}."
        end

        # The banner without its markdown wrapper, so a JSON body can carry
        # the same sentence under a key instead of a footer that would stop it
        # parsing.
        def static_tier_note
          return nil unless RailsAiContext.static_tier?

          reason = RailsAiContext.static_reason_brief
          # Only a boot that actually ran can be called a failure; the other
          # kinds describe the tree or the flag they were asked for.
          headline = case RailsAiContext.static_kind
          when :requested, :source_only then "Static mode (#{reason})"
          else reason ? "App boot failed (#{reason})" : "Static mode"
          end
          "[STATIC] #{headline}. Serving static analysis; runtime-only data is marked " \
            "[UNAVAILABLE]. Run `#{RailsAiContext.doctor_command}` for details."
        end

        # Tools that only make sense against a booted app must refuse in the
        # static tier instead of half-running against whatever a failed boot
        # happened to load (live DB access from a "static" response
        # contradicts the tier banner in the same reply).
        def static_tier_refusal(capability)
          return nil unless RailsAiContext.static_tier?

          reason = RailsAiContext.static_reason_brief
          remedy = case RailsAiContext.static_kind
          when :requested then "Rerun without `--no-boot`."
          when :source_only then "This tree has no `config/environment.rb`; add one (or run from the app root) for runtime data."
          else "Fix the boot failure (see `#{RailsAiContext.doctor_command}`)."
          end
          text_response(
            "[UNAVAILABLE: static tier] #{capability} requires a booted Rails app" \
            "#{reason ? " (static tier active: #{reason})" : ""}. #{remedy}"
          )
        end

        # The params a caller sent that this tool does not declare. The CLI and
        # the MCP wrapper both refuse them, in their own words, off this one
        # answer. server_context is the SDK's, not the caller's.
        def unknown_param_names(keys, properties)
          keys.map(&:to_s) - (properties || {}).keys.map(&:to_s) - [ "server_context" ]
        end

        # Fuzzy match: find the closest available name by exact, underscore, substring, or prefix
        def find_closest_match(input, available)
          find_closest_matches(input, available).first
        end

        # Longer than any model, controller, table or file name an app has.
        MAX_NAME_LENGTH = 256
        ECHO_LENGTH = 80

        # The caller's input as an answer repeats it: a 100 KB argument came
        # back whole in a "not found", a 100,321-character reply.
        def echo_input(value)
          text = value.to_s
          text.length > ECHO_LENGTH ? "#{text[0, ECHO_LENGTH]}... (#{text.length} characters)" : text
        end

        def name_too_long?(value)
          value.to_s.length > MAX_NAME_LENGTH
        end

        # Every name that matches as well as the best one does. A bare
        # `ReportsController` names three real controllers under different
        # namespaces, and answering with one of them arbitrarily hides the
        # other two behind a truncated `Available:` list.
        def find_closest_matches(input, available)
          return [] if available.empty?
          # A blank query matches everything via substring ("".include? anything),
          # so it would otherwise surface an arbitrary "Did you mean" suggestion
          # for input that isn't a typo at all - just missing.
          return [] if input.to_s.strip.empty?
          # No name is this long, and spell-checking a 100 KB string against
          # every model took seconds to find nothing.
          return [] if input.to_s.length > MAX_NAME_LENGTH

          exact = exact_matches(input, available)
          return exact if exact.any?

          spelled = spelling_matches(input, available)
          return spelled if spelled.any?

          # Containment catches an abbreviation (`prod` for production). Shortest first, so `post`
          # does not answer with `post_comments`.
          downcased = input.downcase
          containing = available.select { |a| a.downcase.include?(downcased) || downcased.include?(a.downcase) }
          containing.any? ? [ containing.min_by(&:length) ] : []
        end

        # Full names, then last segments: a wrong namespace is a near miss on the segment.
        def spelling_matches(input, available)
          checker = ::DidYouMean::SpellChecker
          found = checker.new(dictionary: available).correct(input.to_s)
          return found if found.any?

          # A spell checker never suggests the word you typed, so the segment
          # spelled right under the wrong namespace is matched before asking it.
          needle = input.to_s.split("::").last.to_s
          by_segment = available.group_by { |name| name.split("::").last }
          near = by_segment.keys.select { |segment| segment.casecmp?(needle) }
          near = checker.new(dictionary: by_segment.keys).correct(needle) if near.empty?
          near.flat_map { |segment| by_segment[segment] }
        end

        # Case-insensitive on the full and demodulized name, never a substring: a substring hit is
        # another thing's answer. Two namespaces holding one short name match nothing.
        def find_exact_match(input, available)
          matches = exact_matches(input, available)
          matches.first if matches.one?
        end

        # Whole segments, never a substring: `posts` is not `blog_posts`. `tail:` makes the match
        # end the path, so `admin/orders` is not `admin/orders/ai_data`.
        def path_segments_match?(path, name, tail: false)
          needle = name.to_s.downcase.split("/").reject(&:empty?)
          segments = path.to_s.downcase.split("/")
          return false if needle.empty? || needle.size > segments.size
          return segments.last(needle.size) == needle if tail

          segments.each_cons(needle.size).any? { |run| run == needle }
        end

        # The full name wins over a demodulized one: `Mailer` names the
        # top-level Mailer, not Dashboard::Mailer beside it.
        def exact_matches(input, available)
          return [] if input.to_s.strip.empty?

          wanted = [ input.downcase, input.underscore.downcase ]
          forms = ->(name) { [ name.downcase, name.underscore.downcase ] }
          full = available.select { |a| forms.call(a).intersect?(wanted) }
          short = available.select { |a| forms.call(a.split("::").last).intersect?(wanted) }
          (full.any? ? full : short).sort_by { |a| [ a.length, a ] }
        end

        # Cache key for paginated responses - lets agents detect stale data between pages
        def cache_key
          SHARED_CACHE[:fingerprint]&.digest || "none"
        end

        # Payload keys, so the rule lives beside the payload readers that need
        # it; tools reach it here without qualifying the module.
        def fuzzy_find_key(keys, query)
          Payload.fuzzy_find_key(keys, query)
        end

        # `\b` is a word/non-word transition, so it cannot fire beside a pattern
        # edge that is already non-word: `reblog?\b` never matches `def reblog?`
        # and `\b@user` never matches `@user = 1`. Escape the pattern, then add
        # each boundary only on the side whose edge is a word character.
        def leading_boundary(pattern)
          pattern.match?(/\A\w/) ? "\\b" : ""
        end

        def trailing_boundary(pattern)
          pattern.match?(/\w\z/) ? "\\b" : ""
        end

        # "self.x" asks for the class method; the file's own class answers before a nested
        # module (a concern's ClassMethods), which answers only when the class has none.
        def extract_method_source_from_string(source, method_name)
          name = method_name.to_s
          scope = name.start_with?("self.") ? :class : :instance
          bare = name.delete_prefix("self.")
          resolver = Introspectors::ActionResolver
          methods = resolver.methods_in(source)
          named = methods.select { |m| m[:name] == bare && m[:scope] == scope }
          method = resolver.own_methods(named, resolver.default_owner(source, methods)).first || named.first
          method && resolver.body_of(source, method)
        rescue => e
          RailsAiContext.debug_fail(e, nil, label: "extract_method_source_from_string")
        end

        # Extract method source from a file path. Reads file safely. Returns hash or nil.
        def extract_method_source_from_file(path, method_name)
          source = RailsAiContext::SafeFile.read(path) or return nil
          extract_method_source_from_string(source, method_name)
        end

        # First fixture key for a table (reading the fixture file when the
        # cached fixture names miss it), or nil when no fixture exists. Every
        # surface that writes a fixture call asks here, so none of them can
        # invent a key the app does not have.
        def fixture_key_for(table, tests_data)
          fixture_names = tests_data[:fixture_names] || {}
          keys = fixture_names[table] || fixture_names[table.to_sym]
          if keys.is_a?(Array)
            named = keys.map(&:to_s).find { |key| RailsAiContext::FixtureKeys.name?(key) }
            return named if named
          end

          real_root = File.realpath(rails_app.root.to_s)
          fixture_file = File.join(real_root, "test", "fixtures", "#{table}.yml")
          return nil unless File.exist?(fixture_file)

          real = safe_glob_realpath(fixture_file, real_root, real_root) or return nil
          content = RailsAiContext::SafeFile.read(real) or return nil
          labels = RailsAiContext::FixtureKeys.parse(content)&.keys || content.scan(/^([a-z_]\w*):/i).flatten
          labels.find { |key| RailsAiContext::FixtureKeys.name?(key) }
        rescue SystemCallError => e
          RailsAiContext.debug_fail(e, nil, label: "fixture_key_for")
        end

        # Fixture set from `set_fixture_class`, then the table name, then the pluralized class
        # name (a model with table `node` can keep its fixtures in nodes.yml).
        #
        # @return [Array(String, String), nil] [fixture set, key]
        def model_fixture(model_name, table, tests_data)
          sets = fixture_class_sets(model_name) + [ table.to_s, model_name.to_s.underscore.pluralize ]
          sets.uniq.each do |set|
            key = fixture_key_for(set, tests_data)
            return [ set, key ] if key
          end
          nil
        end

        # The helpers a suite loads, where `set_fixture_class` is called.
        FIXTURE_HELPER_GLOBS = %w[
          test/test_helper.rb test/support/**/*.rb
          spec/rails_helper.rb spec/spec_helper.rb spec/support/**/*.rb
        ].freeze

        def fixture_class_sets(model_name)
          root = rails_app.root.to_s
          helpers = FIXTURE_HELPER_GLOBS.flat_map { |glob| Dir.glob(File.join(root, glob)) }.uniq.sort
          helpers.flat_map do |helper|
            hits = RailsAiContext::Introspectors::SourceIntrospector.walk(helper, {
              sets: -> { RailsAiContext::Introspectors::Listeners::GenericMacroListener.new(:set_fixture_class) }
            })[:sets]
            hits.flat_map do |hit|
              hit[:options].select { |_set, klass| klass.to_s.delete_prefix("::") == model_name.to_s }.keys.map(&:to_s)
            end
          end
        rescue => e
          RailsAiContext.debug_fail(e, [], label: "fixture_class_sets")
        end

        # A callback target is a method name, an inline block, or a callback
        # object. Only the first is a symbol, so only the first takes a colon.
        # A block has no name, so it keeps the payload's marker wherever a
        # name is what the line lists.
        def callback_target(method)
          method = method.to_s
          return method if inline_block_callback?(method)

          method_name?(method) ? ":#{method}" : method
        end

        # The `if:`/`unless:` a callback carries. Without it a conditional
        # callback reads as one that always runs.
        def callback_condition_tail(conditions)
          return "" unless conditions.is_a?(Hash) && conditions.any?

          " (#{conditions.map { |key, value| "#{key}: #{option_text(value)}" }.join(', ')})"
        end

        def inline_block_callback?(method)
          method.to_s == RailsAiContext::Introspectors::Listeners::CallbacksListener::INLINE_BLOCK
        end

        # A constant (`AuditTrail`) is a callback object, not a method.
        def method_name?(method)
          method.to_s.match?(/\A[a-z_]\w*[?!=]?\z/)
        end

        # A callback type as a reader can write it. `after_commit_on_create`
        # is the key this gem synthesizes to order the events of one
        # `after_commit on: [...]`; Rails has no macro by that name, so an
        # agent that copies it gets a NoMethodError.
        def callback_type_label(type)
          event = RailsAiContext::Introspectors::Listeners::CallbacksListener.event(type)
          event ? "after_commit (on: :#{event})" : type.to_s
        end

        # Statically, a config that does not say how Rails orders after_commit
        # and after_rollback leaves those lists in declaration order.
        def commit_order_note(unread)
          return nil if unread.empty?

          "_after_commit and after_rollback for #{unread.sort.join(', ')} are in declaration order: the config does not say " \
            "whether `run_after_transaction_callbacks_in_order_defined` is on, and when it is off Rails runs them last declared first._"
        end

        # One callback record rendered as the line the file declares. The
        # declared macro, not the resolved type: `after_commit_on_create` is
        # a key this gem synthesizes, not something the source says.
        def callback_declaration(callback)
          if callback[:skip]
            kind, event = callback[:type].to_s.split("_", 2)
            return "skip_callback :#{event}, :#{kind}, #{callback_target(callback[:method])}#{callback_options_tail(callback[:options])}"
          end

          # A broadcast macro is its own declaration: the call is the line the file holds.
          return callback[:source].to_s.strip.gsub(/\s+/, " ") if callback[:runs]

          name = callback[:name] || callback[:type]
          method = callback[:method].to_s
          target = inline_block_callback?(method) ? "do" : callback_target(method)
          "#{name} #{target}#{callback_options_tail(callback[:options])}"
        end

        # Without the tail, four `after_commit` lines that differ only in
        # `on:` read as the same declaration four times.
        def callback_options_tail(options)
          return "" unless options.is_a?(Hash) && options.any?

          pairs = options.map { |key, value| "#{key}: #{option_text(value)}" }
          ", #{pairs.join(', ')}"
        end

        # What the session record should remember about this call. SafeCall
        # asks every tool, so no tool has to remember to record anything;
        # override to reshape a value that should not be kept verbatim.
        def session_params(kwargs)
          kwargs
            .except(:server_context)
            .reject { |_, v| v.nil? || (v.respond_to?(:empty?) && v.empty?) }
        end

        # Whether this tool's `detail` is DetailLevel's, read off the schema it
        # already publishes rather than a second list someone has to keep in
        # step. `rails_onboard` spells its own levels (quick/standard/full) and
        # is deliberately not covered.
        def detail_param?
          return @detail_param if defined?(@detail_param)

          properties = (respond_to?(:input_schema) ? input_schema&.to_h : nil)&.dig(:properties)
          declared = properties.is_a?(Hash) ? (properties[:detail] || properties["detail"]) : nil
          enum = declared.is_a?(Hash) ? (declared[:enum] || declared["enum"]) : nil

          @detail_param = Array(enum).map(&:to_s) == RailsAiContext::DetailLevel::ALL
        end

        # Junk and missing values both become the default here, so the
        # nineteen `case detail` branches downstream only ever see one of
        # three strings.
        def normalize_detail(kwargs)
          return kwargs unless detail_param?

          kwargs.merge(detail: RailsAiContext::DetailLevel.normalize(kwargs[:detail]))
        end

        # Normalizing silently would answer a question the caller did not ask
        # and give them no way to notice. SafeCall appends this after the
        # response is built, so it lands past truncation the way the
        # static-tier banner does.
        #
        # The echoed value is shortened: it is caller input, and the response
        # it rides on has just promised a length cap.
        def invalid_detail_note(given)
          return nil unless given

          "\n\n---\n_#{given.to_s.truncate(40).inspect} is not a valid `detail`; showing " \
            "#{RailsAiContext::DetailLevel::DEFAULT}. Valid: #{RailsAiContext::DetailLevel::ALL.join(', ')}._"
        end

        # Helper: wrap text in an MCP::Tool::Response with safety-net truncation.
        # Auto-records the call in session context so session_context(action:"status") works.
        # `suffix:`, when given, is appended after the truncation footer (or after
        # the text itself when untruncated) so callers can attach a short trailing
        # note that must survive truncation instead of being cut off with the tail.
        # In static tier, the tier banner rides along on the same mechanism so
        # every response - caller-suffixed or not - ends with it, and so does
        # the note that app code changed under a server that cannot reload.
        def text_response(text, suffix: nil)
          suffix = [ suffix, static_tier_banner, stale_code_banner ].compact.join
          suffix = nil if suffix.empty?
          text = served_hints(text)

          record_call(text)

          max = RailsAiContext.configuration.max_tool_response_chars
          if max && text.length > max
            truncated = text[0...max]
            truncated += "\n\n---\n_Response truncated (#{text.length} chars). Use `detail:\"summary\"` for an overview, or filter by a specific item (e.g. `table:\"users\"`)._"
            truncated += suffix if suffix
            MCP::Tool::Response.new([ { type: "text", text: cli_form(truncated) } ])
          else
            text += suffix if suffix
            MCP::Tool::Response.new([ { type: "text", text: cli_form(text) } ])
          end
        end

        # A call to one of this gem's tools as an answer writes it:
        # `rails_get_schema(table:"posts")`. Under tool_mode :cli no MCP server
        # is set up, so the answer names the command that runs instead, as the
        # context files do; a lone `detail:"summary"` hint becomes `detail=summary`.
        MCP_CALL = /\b(rails_\w+)\(([^()]*)\)/
        PARAM_HINT = /`((?:\w+:(?:"[^"`]*"|[\w.]+)(?:,\s*)?)+)`/

        # A `_Next:` hint points at other tools, one pointer per tool, joined
        # by ` | ` on one line or onto lines of their own. A tool skip_tools
        # turned off is no next step, so its pointer goes, and a hint left
        # with none goes whole. Every answer passes here, so no tool has to
        # check the served set itself.
        def served_hints(text)
          return text unless text.is_a?(String) && text.include?("_Next: ")

          skipped = RailsAiContext::Server.skipped_tools
          return text if skipped.empty?

          lines = text.split("\n", -1)
          kept = []
          index = 0
          while index < lines.size
            block = [ lines[index] ]
            if block.first.start_with?("_Next: ")
              block << lines[index += 1] while lines[index + 1]&.start_with?(" | ")
              hint = served_hint(block, skipped)
              if hint
                kept.concat(hint)
              elsif kept.last == "" && lines[index + 1].to_s.empty?
                kept.pop
              end
            else
              kept << block.first
            end
            index += 1
          end
          kept.join("\n")
        rescue StandardError => e
          RailsAiContext.debug_fail(e, text, label: "served_hints")
        end

        # The hint's lines with the pointers to skipped tools taken out; nil
        # when none is left.
        def served_hint(block, skipped)
          body = block.join("\n").delete_prefix("_Next: ")
          closing = body[/\.?_\z/].to_s
          pointers = body.delete_suffix(closing).split(/\n? \| /)
          served = pointers.reject { |pointer| skipped.include?(pointer[/\brails_\w+/]) }
          return block if served.size == pointers.size
          return nil if served.empty?

          "_Next: #{served.join(block.size > 1 ? "\n | " : " | ")}#{closing}".split("\n")
        end
        private :served_hint

        def cli_form(text)
          return text unless RailsAiContext.configuration.tool_mode == :cli && text.is_a?(String)

          names = BaseTool.registered_tools.map { |tool| tool.tool_name.to_s }
          converted = text.gsub(MCP_CALL) do
            whole = Regexp.last_match(0)
            name, args = Regexp.last_match(1), Regexp.last_match(2)
            params = names.include?(name) && cli_params(args)
            next whole unless params

            short = name.sub(/\Arails_get_/, "").sub(/\Arails_/, "")
            command = RailsAiContext::InstallMode.tool_command(short)
            [ command, *params ].join(" ")
          end
          converted.gsub(PARAM_HINT) { (params = cli_params(Regexp.last_match(1))) ? "`#{params.join(' ')}`" : Regexp.last_match(0) }
        rescue StandardError => e
          RailsAiContext.debug_fail(e, text, label: "cli_form")
        end

        # `model:"User", files:["a.rb","b.rb"]` as `model=User files=a.rb,b.rb`,
        # quoted for a shell where a value needs it; nil when the text is not
        # keyword arguments.
        def cli_params(args)
          return [] if args.strip.empty?

          call = RailsAiContext::AstCache.parse_string("f(#{args})").value.statements.body.first
          hash = call.is_a?(Prism::CallNode) ? call.arguments&.arguments&.first : nil
          return nil unless hash.is_a?(Prism::KeywordHashNode)

          hash.elements.map do |pair|
            return nil unless pair.is_a?(Prism::AssocNode) && pair.key.is_a?(Prism::SymbolNode)

            value = case (node = pair.value)
            when Prism::StringNode, Prism::SymbolNode then node.unescaped
            when Prism::ArrayNode then node.elements.map { |e| e.respond_to?(:unescaped) ? e.unescaped : e.slice }.join(",")
            else node.slice
            end
            "#{pair.key.unescaped}=#{value.match?(%r{\A[\w.,/:@+-]*\z}) && !value.empty? ? value : "\"#{value.gsub(/["\\$`]/) { "\\#{Regexp.last_match(0)}" }}\""}"
          end
        end

        # Key the static-tier note rides under in a JSON body. Underscored the
        # way JsonBudget's own report key is, so a reader tells it from data.
        STATIC_TIER_KEY = "_static_tier"
        STALE_CODE_KEY = "_stale_code"

        # A JSON body has to parse, so it cannot take the markdown banner and
        # cannot be sliced at the response cap: JsonBudget drops whole
        # elements instead, and the tier note rides under a reserved key.
        def json_response(data)
          note = static_tier_note
          data = data.merge(STATIC_TIER_KEY => note) if note && data.is_a?(Hash)
          stale = stale_code_note
          data = data.merge(STALE_CODE_KEY => stale) if stale && data.is_a?(Hash)

          text = JsonBudget.generate(data, RailsAiContext.configuration.max_tool_response_chars)
          record_call(text)
          MCP::Tool::Response.new([ { type: "text", text: text } ])
        end

        # Helper: wrap text in an MCP::Tool::Response flagged as an error
        # (isError: true) so MCP clients and the CLI treat the call as failed
        # (non-zero exit). Mirrors the SafeCall rescue wrapper. Use for an
        # execution failure, and for a path refused on policy - outside the
        # app, a traversal, a sensitive file - which is a request the tool
        # would not answer. Guidance and "found nothing" stay informational
        # via text_response and empty_response.
        def error_response(text)
          text += [ static_tier_banner, stale_code_banner ].compact.join
          MCP::Tool::Response.new([ { type: "text", text: cli_form(text) } ], error: true)
        end

        private

        # The locale and variant a view file renders for, reading the locales the app makes available.
        def view_alternate_of(path)
          RailsAiContext::ViewFile.alternate_of(path, RailsAiContext::RunCache.fetch([ :view_locales ]) { available_locales })
        end

        def booted_app?
          !RailsAiContext.static_tier? && !rails_app.is_a?(RailsAiContext::StaticApp)
        end

        # Booted, as I18n holds them; unbooted, as the i18n section read them from config or the locale files.
        def available_locales
          return I18n.available_locales.map(&:to_s) if booted_app? && defined?(I18n)

          Array(RailsAiContext::Payload.section(cached_context, :i18n)&.dig(:available_locales)).map(&:to_s)
        end

        # English units whatever the locale, unless the app offers no English at all.
        def human_size(bytes)
          ActiveSupport::NumberHelper.number_to_human_size(bytes.to_i, locale: :en)
        rescue I18n::InvalidLocale
          ActiveSupport::NumberHelper.number_to_human_size(bytes.to_i)
        end

        # Every answered call is recorded so session_context(action:"status")
        # can list it: the call SafeCall says the client made, once, with its
        # own params. A tool another tool called answers it, not the client.
        # SessionContext itself is skipped to avoid recursion.
        def record_call(text)
          call = Thread.current[:rails_ai_context_call]
          return unless call && call[:tool].equal?(self) && !call[:recorded]
          return unless respond_to?(:tool_name) && tool_name != "rails_session_context"

          summary = text.lines.first&.strip&.truncate(80)
          session_record(tool_name, call[:params], summary)
          call[:recorded] = true
        end

        def session_key(tool_name, params)
          normalized = tool_name.to_s.sub(/\Arails_/, "")
          param_str = params.is_a?(Hash) ? params.sort_by { |k, _| k.to_s }.map { |k, v| "#{k}:#{v}" }.join(",") : params.to_s
          "#{normalized}:#{param_str}"
        end

        # Shared utility: safe file reading with size limits.
        def safe_read(path)
          RailsAiContext::SafeFile.read(path)
        end

        # Shared utility: max file size from configuration.
        def max_file_size
          RailsAiContext.configuration.max_file_size
        end

        # Shared utility: check if a relative path matches sensitive file patterns.
        def sensitive_file?(relative_path)
          RailsAiContext::SafePath.sensitive?(relative_path)
        end

        # The refusal every tool that takes a path from the caller answers
        # with, so a script reading the exit status can tell a refusal from an
        # answer. A path that is simply not there is not refused: that is an
        # ordinary empty answer, and each tool words its own.
        #
        # @return [MCP::Tool::Response, nil] the error result, or nil to carry on
        def refuse_unsafe_paths(paths)
          refused = Array(paths).compact.reject { |path| path.to_s.strip.empty? }.filter_map { |path| unsafe_path_message(path) }
          error_response(refused.join("\n")) if refused.any?
        end

        # @return [String, nil] the refusal for a path the caller may not read
        def unsafe_path_message(path)
          case RailsAiContext::SafePath.locate(path.to_s, under: rails_app.root.to_s).refusal
          when :traversal, :outside then "Path not allowed: #{path}"
          when :sensitive then "Path not allowed: #{path} (sensitive file)"
          end
        end

        # Resolve a Dir.glob result to a realpath that is:
        #   (a) separator-aware contained under `real_dir` (blocks sibling bypass)
        #   (b) not a sensitive file via symlink indirection
        # `real_dir` and `real_root` must already be realpath-resolved.
        # Returns the realpath string (use for File.size / safe_read) or nil if rejected.
        # Per CLAUDE.md Security Conventions - callers should perform all subsequent
        # file operations on the returned realpath, not the original glob path.
        def safe_glob_realpath(file_path, real_dir, real_root)
          real = File.realpath(file_path).to_s
          return nil unless RailsAiContext::SafePath.contained?(real, real_dir)
          relative = real.sub("#{real_root}/", "")
          return nil if sensitive_file?(relative)
          real
        rescue Errno::ENOENT, Errno::EACCES, Errno::ELOOP, Errno::ENAMETOOLONG
          # ENOENT: dangling symlink or path deleted between glob and realpath.
          # EACCES: filesystem permission blocks resolution.
          # ELOOP:  circular symlink chain (a → b → a, or node_modules cycles).
          # ENAMETOOLONG: a path component exceeds NAME_MAX.
          # Any of these mean "skip this entry"; surfacing as exception
          # would crash the calling tool.
          nil
        end

        # Run Dir.glob under `dir` with the given glob pattern and return an array
        # of realpaths filtered through `safe_glob_realpath`. Skips files that
        # escape containment (via symlink to a sibling directory) or resolve to
        # a sensitive file. `dir` does NOT need to be realpath-resolved - this
        # helper resolves it. Returns [] if `dir` does not exist.
        #
        # Usage:
        #   safe_glob(app_dir, "**/*.rb", real_root).each do |realpath|
        #     source = safe_read(realpath) or next
        #     ...
        #   end
        def safe_glob(dir, pattern, real_root)
          return [] unless Dir.exist?(dir)
          real_dir = File.realpath(dir).to_s
          Dir.glob(File.join(dir, pattern)).filter_map do |file_path|
            safe_glob_realpath(file_path, real_dir, real_root)
          end
        rescue Errno::ENOENT, Errno::EACCES => e
          RailsAiContext.debug_fail(e, [], label: "safe_glob")
        end

        # Whether the loaded model class defines the method: true, false, or
        # nil when there is no loaded class to ask (the static tier, a name
        # that is not a model). A private method counts as defined, since the
        # error for calling one says so rather than "undefined".
        def live_method_defined?(receiver, method_name)
          return nil if RailsAiContext.static_tier?
          return nil unless defined?(ActiveRecord::Base)

          klass = receiver.to_s.safe_constantize
          return nil unless klass.is_a?(Class) && klass < ActiveRecord::Base

          define_attribute_methods(klass)
          name = method_name.to_s
          klass.method_defined?(name) || klass.private_method_defined?(name)
        rescue StandardError, ScriptError => e
          RailsAiContext.debug_fail(e, nil, label: "live_method_defined?")
        end

        # Attribute methods are defined lazily. A table the database lacks -
        # a migration not yet run - raises here, and the answer still holds
        # for every method that is not an attribute: the columns the schema
        # declares cover those.
        def define_attribute_methods(klass)
          klass.define_attribute_methods
        rescue StandardError => e
          RailsAiContext.debug_fail(e, nil, label: "define_attribute_methods")
        end
      end
    end
  end
end
