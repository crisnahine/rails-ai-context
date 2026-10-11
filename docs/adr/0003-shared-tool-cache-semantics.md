# The two shared tool caches: what is a defect and what is intended

Status: accepted

`Tools::BaseTool` keeps two process-global structures - `SHARED_CACHE` (one introspection result for every tool) and `SESSION_CONTEXT` (what has been called with what). Both are read by four entry points - stdio, the Rack middleware, the engine controller and the standalone HTTP server - three of which serve many clients from one process. This records what the audit found, so the next reader does not re-derive it from the mutex.

## Defects, fixed

**One client's session record was served to another.** `SESSION_CONTEXT[:queries]` was a single flat hash. Over stdio that is right - one process is one conversation - but the middleware, the engine controller and the standalone HTTP server each serve every client from one process, so `rails_session_context` listed calls the asking client never made. The record is now bucketed per conversation: all three HTTP entry points wrap each request in `BaseTool.with_session(<Mcp-Session-Id>)`, and stdio falls through to a single default bucket, unchanged.

**The scope ended before the tool ran.** The SDK answers a request inside a session with a streaming body, and the tool runs when the web server calls that body - after the entry point has returned, so the scope around `handle_request` was already gone and the middleware and the standalone server recorded every client in the default bucket again. `McpEdge.serve` hands the web server a body that re-enters the client's session. The engine controller calls the body itself, inside its own scope.

**One client's reset emptied every client's record.** `action: "reset"` cleared the whole hash. It clears the calling conversation's bucket now (`current_session_reset!`). `session_reset!` still clears them all, for a change that makes every earlier answer stale: live reload.

**`session_queries` handed out live entries.** It returned `values.dup`, a shallow copy, so the entry hashes stayed live inside the record and kept being mutated by later calls - a caller's snapshot changed under it. It now copies each entry.

**The record grew without bound, keyed by a client-controlled header.** Bucketing per conversation introduced a hash whose keys come from `Mcp-Session-Id`, in a process that stays up. Three things were wrong at once: the hash had a default block, so merely *reading* a session's history created a bucket; nothing capped the id's length; and nothing evicted. Reading no longer writes, ids are truncated to `MAX_SESSION_ID_LENGTH`, and the number of remembered conversations is capped at `MAX_SESSIONS`.

**A composite tool's inner calls were recorded as the client's.** `rails_get_context`, `rails_diagnose` and `rails_review_changes` answer by calling other tools, and every call recorded itself, so one `rails_get_context` read as four calls the client never made, and the first inner call took the outer call's params with it. SafeCall now marks the outermost call on the thread, and only that call is recorded, once, with its own params.

Eviction is least-recently-used, not oldest-created. Recording re-inserts the session so hash order tracks use. Ordering by creation instead would evict the conversation that has run for hours ahead of a hundred idle newcomers - backwards, and worst on exactly the long-lived transports that made bucketing necessary.

## Intended semantics, not defects

**The fingerprint walk happens under the mutex, not outside it.** The whole read path in `cached_context` - TTL check, fingerprint comparison, re-introspection - is inside one `synchronize`, so concurrent callers serialize instead of racing to introspect. Twenty threads arriving together produce exactly one introspection. The cost is that a fingerprint walk (~12ms in dev-mode installs, ~0.5ms in production) blocks other tool calls for its duration. That is the trade we want: a lock-free fast path would let several threads run the full 40-introspector walk at once, which is far more expensive than the wait it avoids.

**`deep_dup` also happens under the mutex.** Every caller gets an independent copy, so a tool that mutates its context cannot corrupt the next tool's view. Copying inside the lock adds to hold time, and moving it outside would hand out the cached object itself between the read and the copy. Isolation is worth more than the contention; the copy is cheap next to the introspection it protects.

Both are pinned by `spec/lib/rails_ai_context/tools/shared_cache_concurrency_spec.rb`, which also drives the middleware and the engine controller concurrently against both caches.

**Every server checks the files outside the mutex, at the start of each call.** Within the TTL the fast path trusts the cache, so something has to drop it on an edit before a call reads it. Live reload cannot: `listen` delivers a change after its debounce, and with no `listen` in the bundle nothing delivers it at all. So `refresh_if_files_changed!` checks the files itself (`Fingerprinter::Snapshot`, a stat of each watched directory and file), and on a change reloads the app's code and resets the caches. That check cannot share the mutex: the code reload waits for running calls to finish, and those may be waiting on the mutex. Only a check that began after a call arrived can stand in for the call's own - an earlier one may have passed a file before it was edited - so calls made at once wait for one check together, and calls one after another each check. Sharing any check made within ten walks' time, as the first version did, answered a call made right after an edit from before it.
