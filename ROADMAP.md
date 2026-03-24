# rails-ai-context — Roadmap to Perfect AI Context

> Goal: Give AI the fastest, most complete context so it produces 100% correct code on the first try — frontend, backend, tests, everything. Any Rails app, any size.

---

## Table of Contents

1. [New Tools](#1-new-tools)
2. [Existing Tool Improvements](#2-existing-tool-improvements)
3. [New Validation Rules](#3-new-validation-rules)
4. [Meta-Improvements](#4-meta-improvements)
5. [Implementation Priority](#5-implementation-priority)

---

## 1. New Tools

### 1.1 `rails_get_partial_interface`

**Why:** Every partial is an implicit interface. Missing or wrong locals cause runtime NoMethodError. AI currently has to read the full partial source to know what locals it expects.

**Parameters:**
- `partial` (string) — Partial path relative to app/views (e.g., `"shared/status_badge"`, `"cooks/output"`)
- `detail` (string) — `"summary"` | `"standard"` | `"full"`

**Returns:**
```
# shared/_status_badge.html.erb (12 lines)
Required locals: cook (Cook)
Used attributes: cook.status, cook.cooking?, cook.pending?, cook.completed?, cook.failed?

## Usage in codebase
- cooks/index.html.erb:22  → render "shared/status_badge", cook: cook
- cooks/show.html.erb:8    → render "shared/status_badge", cook: @cook
```

**Implementation notes:**
- Parse the partial ERB for local variable references (variables not prefixed with `@`)
- Scan all views for `render` calls that reference this partial to extract usage examples
- Detect which model methods/attributes are called on each local
- If Rails 7.1+ `locals:` magic comment exists, use that as the contract
- For `detail:"summary"`, just show locals and usage count
- For `detail:"full"`, include the full partial source

---

### 1.2 `rails_get_turbo_map`

**Why:** Turbo Frames, Streams, and broadcasts are wired across 3-4 files with string IDs that must match exactly. A single mismatched ID means silent failure — no error, just broken real-time behavior. This is the hardest thing for AI to get right.

**Parameters:**
- `detail` (string) — `"summary"` | `"standard"` | `"full"`
- `stream` (string, optional) — Filter by stream/frame name
- `controller` (string, optional) — Filter by controller name

**Returns (summary):**
```
# Turbo Streams (1 channel)
- "cook_{id}" — broadcast: CookJob → subscribe: cooks/show.html.erb

# Turbo Frames (0)
# Model broadcasts (0)
```

**Returns (full, or filtered by stream):**
```
# Turbo Stream: "cook_{id}"

## Broadcast chain
1. CookJob (app/jobs/cook_job.rb:13)
   → Turbo::StreamsChannel.broadcast_replace_to("cook_#{cook.id}", target: "cook_output", ...)

## Subscription
- cooks/show.html.erb:42 → turbo_stream_from "cook_#{@cook.id}"
- Target DOM ID: #cook_output
- Wrapping element: <div id="cook_output" data-controller="cook-status">

## Templates
- (inline partial in broadcast call: "cooks/output")
```

**Implementation notes:**
- Scan all `.rb` files for `broadcast_replace_to`, `broadcast_append_to`, `broadcast_prepend_to`, `broadcast_remove_to`, `broadcast_update_to`, `broadcast_action_to`, `broadcasts`, `broadcasts_to`
- Scan all `.erb` files for `turbo_stream_from`, `turbo_frame_tag`
- Scan models for `broadcasts`, `broadcasts_to`, `broadcasts_refreshes`, `broadcasts_refreshes_to`
- Match broadcast channel names to subscription channel names
- Match broadcast `target:` to DOM element IDs in views
- Flag mismatches as warnings

---

### 1.3 `rails_get_service_pattern`

**Why:** Services contain the core business logic. Every app structures them differently (initialize+call, class method, Result objects, etc.). AI needs to follow the app's exact pattern.

**Parameters:**
- `service` (string, optional) — Specific service name. Omit for pattern summary.
- `detail` (string) — `"summary"` | `"standard"` | `"full"`

**Returns (summary — no service specified):**
```
# Service Pattern
- Location: app/services/
- Count: 5 services
- Convention: Initialize with keyword args → #call instance method
- Return style: void (mutates record in place)
- Error handling: rescue → update record with error state

# Services
- ContentChefService (107 lines) — AI content generation
- GeminiClient (45 lines) — Gemini API wrapper
- GeminiKeyValidator (22 lines) — API key validation
- OutputParser (38 lines) — Parse AI response
- PaymongoClient (56 lines) — Payment gateway wrapper
```

**Returns (specific service):**
```
# ContentChefService (107 lines)
File: app/services/content_chef_service.rb

## Interface
Initialize: (user:, cook:)
Public method: #call
Returns: void (mutates cook in place)

## Side effects
- cook.update!(status: "cooking")
- cook.update!(raw_response:, strategy_brief:, creative_direction:, organic_content:, ...)
- cook.update!(status: "completed", confidence_score:, tokens_used:, generation_time_ms:)

## Error handling
- rescue StandardError → cook.update!(status: "failed", error_message: e.message)

## Dependencies
- GeminiClient.new(api_key:, model:)
- OutputParser.new(raw_response)

## Called from
- CookJob#perform (app/jobs/cook_job.rb:11)

## Constants
- PROMPT_VERSION = "v7"
- SYSTEM_PROMPT = config/prompts/content_chef_v7.md

## Tests
- test/services/content_chef_service_test.rb
```

**Implementation notes:**
- Scan `app/services/` directory
- Parse each service for: `initialize` params, public methods, what it calls on injected objects
- Detect return style: explicit `return`, void, Result object pattern
- Detect error handling: rescue blocks, what happens on failure
- Cross-reference: who calls this service (grep for class name)
- Detect the common pattern across all services and present it as "Convention"

---

### 1.4 `rails_get_job_pattern`

**Why:** Background jobs have queue names, retry counts, guard clauses, and specific patterns. Getting any of these wrong means silent failures in production.

**Parameters:**
- `job` (string, optional) — Specific job name. Omit for all.
- `detail` (string) — `"summary"` | `"standard"` | `"full"`

**Returns (specific job):**
```
# CookJob
File: app/jobs/cook_job.rb
Queue: default
Retries: 3
Performs: cook_id (Integer)

## Flow
1. Guard: return if cook.completed?
2. Call: ContentChefService.new(user: cook.user, cook: cook).call
3. After: Turbo::StreamsChannel.broadcast_replace_to("cook_#{cook.id}", ...)

## Pattern (for new jobs, follow this)
- Accept ID, not ActiveRecord object (serialization safe)
- Guard clause first (idempotency)
- Delegate to service object
- Broadcast result via Turbo Streams

## Tests
- test/jobs/cook_job_test.rb (9 tests)
```

**Returns (summary — no job specified):**
```
# Jobs (3)
- CookJob — queue: default, retries: 3, calls: ContentChefService
- ResetDailySuggestJob — queue: default, resets: ai_suggests_today
- ResetMonthlyUsageJob — queue: default, resets: cooks_this_month

## Convention
- Accept IDs, not objects
- Guard clause for idempotency
- Delegate to service
- Broadcast via Turbo after completion
```

**Implementation notes:**
- Scan `app/jobs/` directory
- Parse: `queue_as`, `retry_on`/`discard_on`, `perform` method signature
- Detect guard clauses (return if / return unless at start of perform)
- Detect what service/method is called
- Detect Turbo broadcasts
- Cross-reference: who enqueues this job (grep for `perform_later`, `perform_async`)

---

### 1.5 `rails_get_helper_methods`

**Why:** AI writes raw logic in views when a helper already exists. Or calls a helper that doesn't exist. Or doesn't know what Devise/Pagy helpers are available.

**Parameters:**
- `helper` (string, optional) — Specific helper module name
- `detail` (string) — `"summary"` | `"standard"` | `"full"`

**Returns:**
```
# Application Helpers

## ApplicationHelper
- render_markdown(text) → Renders markdown string to sanitized HTML
  Used in: cooks/_section.html.erb, cooks/_output.html.erb

## Framework Helpers (always available in views)

### Devise
- current_user → User (signed-in user)
- user_signed_in? → Boolean
- user_session → Hash

### Pagy
- pagy_nav(@pagy) → HTML pagination nav

### Turbo
- turbo_stream_from(*streamables) → subscribes to Turbo Stream channel
- turbo_frame_tag(id, **options, &block) → wraps content in Turbo Frame

### Rails built-in (commonly used in this app)
- pluralize(count, singular) → "3 cooks"
- number_with_delimiter(number) → "1,200"
- time_ago_in_words(time) → "3 hours ago"
- link_to, button_to, form_with, etc.
```

**Implementation notes:**
- Scan `app/helpers/` for custom helper methods
- Parse method signatures and any inline comments/docs
- Cross-reference: which views call each helper
- Include framework helpers that are actually used in this app's views (detect from view scans)
- Don't include every Rails helper — only ones actually used or commonly needed

---

### 1.6 `rails_get_concern`

**Why:** Concerns provide methods that controllers and models use. AI sees `include PlanLimitable` but doesn't know the full API surface without reading the file. Concern methods are frequently called in views and controllers.

**Parameters:**
- `name` (string, optional) — Concern name. Omit for list.
- `type` (string) — `"model"` | `"controller"` | `"all"` (default: `"all"`)

**Returns (specific concern):**
```
# PlanLimitable (app/models/concerns/plan_limitable.rb, 65 lines)
Type: Model concern
Included in: User

## Public methods
- effective_plan → Plan (returns user's plan or falls back to Plan.free)
- can_cook? → Boolean (cooks_this_month < effective_plan.cooks_per_month)
- can_create_brand_profile? → Boolean (brand_profiles.count < effective_plan.brand_profiles_limit)
- can_use_bonus_modes? → Boolean (effective_plan.bonus_modes?)
- can_recook? → Boolean (delegates to can_cook?)
- can_ai_suggest? → Boolean (ai_suggests_today < effective_plan.ai_suggests_per_day)
- increment_cook_count! → void (increments cooks_this_month, saves)
- increment_suggest_count! → void (increments ai_suggests_today, saves)
- plan_active? → Boolean (plan_expires_at.nil? || plan_expires_at > Time.current)
- upgrade_to!(plan, expires_at:) → void
- downgrade_to_free! → void
- allowed_gemini_models → Array<String>

## Called from
- CooksController#create → can_cook?, increment_cook_count!
- CooksController#suggest_all → can_ai_suggest?, increment_suggest_count!
- BrandProfilesController#create → can_create_brand_profile?
- Bonus::BaseController → can_use_bonus_modes?
```

**Returns (list):**
```
# Model Concerns (1)
- PlanLimitable → included in: User — 12 public methods

# Controller Concerns (0)
```

**Implementation notes:**
- Scan `app/models/concerns/` and `app/controllers/concerns/`
- Parse `included` block, `class_methods` block, instance methods
- Detect which models/controllers include each concern (grep for `include ConcernName`)
- Cross-reference: where each concern method is called (grep across controllers, views, other models)
- Show method signatures with brief description derived from method body

---

### 1.7 `rails_get_callbacks`

**Why:** Callbacks cause invisible side effects. If AI adds a `before_save` without knowing one exists, they conflict. If AI creates a record in a test without knowing callbacks fire, assertions break. Callbacks are the #1 source of "magic" behavior that confuses AI.

**Parameters:**
- `model` (string, optional) — Specific model. Omit for all.
- `detail` (string) — `"summary"` | `"standard"` | `"full"`

**Returns:**
```
# BrandProfile — Callbacks (execution order)
1. before_save :ensure_single_default
   → If is_default changed to true, sets all other user's profiles to is_default=false
   → Side effect: UPDATE brand_profiles SET is_default=false WHERE user_id=? AND id!=?

# Cook — No custom callbacks

# Payment — No custom callbacks

# Plan — No custom callbacks

# User — No custom callbacks
  (Devise manages lifecycle callbacks internally)
```

**Implementation notes:**
- Parse model files for: `before_validation`, `after_validation`, `before_save`, `after_save`, `before_create`, `after_create`, `before_update`, `after_update`, `before_destroy`, `after_destroy`, `after_commit`, `after_initialize`, `after_find`, `after_touch`, `around_save`, `around_create`, `around_update`, `around_destroy`
- Show in execution order (Rails callback order)
- Include callbacks from included concerns
- For `detail:"full"`, include the callback method body
- Detect side effects: other records modified, external calls, enqueued jobs

---

### 1.8 `rails_get_env`

**Why:** AI needs to know what environment variables, credentials, and external dependencies exist. When writing a new integration or debugging config issues, this is essential.

**Parameters:**
- `detail` (string) — `"summary"` | `"standard"` | `"full"`

**Returns:**
```
# Environment & Credentials

## Required credentials (from credentials.yml.enc)
Keys: gemini_api_key, paymongo_secret_key, sentry_dsn, secret_key_base
(values hidden — only key names shown)

## Environment variables (from .env, .env.example, Dockerfile, config/)
- REDIS_URL — used by: cable.yml, sidekiq.yml
- DATABASE_URL — used by: database.yml (production)
- RAILS_MASTER_KEY — decrypts credentials
- RAILS_ENV — standard Rails
- PORT — Puma/Dockerfile

## External service dependencies
- Gemini API (Google) — called by: GeminiClient
- PayMongo API — called by: PaymongoClient
- Redis — used by: Action Cable, Sidekiq, cache
- PostgreSQL — primary database
- Sentry — error tracking

## Per-user configuration
- users.gemini_api_key (encrypted) — per-user Gemini API key, falls back to platform key
```

**Implementation notes:**
- Parse `config/credentials.yml.enc` key names only (use `Rails.application.credentials` if available, or parse the YAML structure)
- Scan for `ENV[`, `ENV.fetch(` across all Ruby files
- Scan Dockerfile for `ENV` and `ARG` directives
- Scan `.env.example` or `.env.sample` if exists
- Detect external HTTP calls (Faraday, Net::HTTP, HTTParty) and map to services
- Cross-reference: which files use each env var

---

### 1.9 `rails_get_context` (Composite Tool)

**Why:** Most real tasks require 3-5 tool calls. This tool assembles cross-layer context in a single call, optimized for the specific task. This is the endgame tool.

**Parameters:**
- `controller` (string, optional) — Controller name
- `action` (string, optional) — Action name (requires controller)
- `model` (string, optional) — Model name
- `view` (string, optional) — View path
- `feature` (string, optional) — Feature keyword (like analyze_feature but with more depth)
- `include` (array of strings) — What to include: `["view", "stimulus", "routes", "tests", "callbacks", "concerns", "turbo", "partials"]`

**Example call:**
```
rails_get_context(controller: "CooksController", action: "create", include: ["view", "stimulus", "routes", "tests"])
```

**Returns:**
```
# CooksController#create — Full Context

## Source (lines 23-46)
[action source code]

## Private methods called
- cook_intake_params (line 80) → permits: product_details, target_audience, flavor, ...
- auto_create_brand_profile (line 92) → creates BrandProfile from cook intake if user has none

## Route
POST /cooks → cooks#create (route helper: cooks_path)

## Before filters
- authenticate_user! (from ApplicationController)
- check_plan_expiry! (from ApplicationController)

## Instance variables set
- @cook (Cook, built from current_user.cooks)

## Renders
- Success: redirect_to @cook → cooks/show (GET /cooks/:id)
- Failure: render :new, status: 422
  - View: cooks/new.html.erb (316 lines)
  - Needs: @brand_profiles, @cook
  - Stimulus: brand-selector, dish-builder, intake-form, ai-suggest

## Model context
- Cook: validates mode (in MODES), status (in STATUSES), intake (presence), intake_has_product_details
- Strong params → schema match: all permitted columns exist ✓

## Side effects
- current_user.increment_cook_count! (updates cooks_this_month)
- CookJob.perform_later(@cook.id) (async AI generation)
- auto_create_brand_profile (conditional)

## Tests (6 covering this action)
- test "create builds cook and enqueues job"
- test "create assigns brand profile scoped to current user"
- test "create ignores brand profile from other user"
- test "create fails without product_details"
- test "create rejected at cook limit"
- test "create increments cook counter"
```

**Implementation notes:**
- This tool orchestrates calls to other tools internally and assembles the result
- It should be smart about what to include based on the action type (create → show strong params and validations; index → show scopes and pagination; show → show view details)
- The `include` parameter lets AI request only what it needs
- Cross-reference everything: controller → model → view → stimulus → routes → tests
- Detect side effects: method calls that modify state, enqueue jobs, send emails, broadcast

---

## 2. Existing Tool Improvements

### 2.1 `rails_get_schema`

| Improvement | Why | Details |
|---|---|---|
| Show default values in `standard` mode | AI needs defaults when writing code but has to upgrade to `full` just for that, wasting tokens | Add defaults inline: `status:string [default: "pending"]` |
| Annotate encrypted columns | Model knows `encrypts :gemini_api_key` but schema doesn't flag it. Saves a model lookup | `gemini_api_key:text [encrypted]` |
| Annotate enum-backed columns | If a model declares constants or inclusion validations for a column, show the values | `mode:string [values: standard, meal_prep, full_funnel, ...]` |
| Show column-to-model mapping in standard mode | When looking at a table, knowing which model maps to it avoids a separate model lookup | Already done in full mode — add to standard |

---

### 2.2 `rails_get_model_details`

| Improvement | Why | Details |
|---|---|---|
| Filter out framework-generated methods | User model returns 25+ Devise methods (`find_for_database_authentication`, `params_authenticatable?`, etc.). This is pure noise. AI might try to modify or call these. | Only show methods defined in the actual file. Tag concern methods: `can_cook? [PlanLimitable]` |
| Show scope definitions (lambda body) | Currently shows `recent`, `completed` but not what they do. AI needs to know to chain correctly or avoid duplication | `recent → order(created_at: :desc)`, `completed → where(status: "completed")` |
| Show custom validation logic | Currently shows `Custom: intake_has_product_details` with no detail. AI writing tests needs to know what triggers it | `intake_has_product_details → errors.add(:intake, "...") unless intake&.key?("product_details")` |
| Tag methods by source | AI can't tell which methods come from the model vs concerns | Group: "App-defined methods" vs "From PlanLimitable" vs "From Devise" (or just omit framework) |
| Show association options | `belongs_to :plan` doesn't show `optional: true` in the summary. This matters for validations and form building | `belongs_to :plan [optional]` — already partially done but inconsistent |
| Show counter_cache, touch, inverse_of | These association options have side effects the AI needs to know about | Include in association detail |

---

### 2.3 `rails_get_routes`

| Improvement | Why | Details |
|---|---|---|
| Show route helpers in code-ready format | AI writes `cook_path(@cook)` in templates. Lead with what gets typed in code | `recook_cook_path(@cook) → POST /cooks/:id/recook → cooks#recook` |
| Annotate authentication status | Routes that skip auth are public-facing. AI needs to know without checking the controller | `[public]` for routes with `skip_before_action :authenticate_user!`, `[no CSRF]` for `skip_before_action :verify_authenticity_token` |
| Show response formats | If an action responds to turbo_stream or JSON, the AI needs to know to create the right templates | `POST /cooks → create [html]`, `POST /cooks/generate_dish → generate_dish [turbo_stream]` |
| Show parameter constraints | Routes with constraints like `{ id: /\d+/ }` affect URL generation | Include constraints inline |
| Group member vs collection routes | Helps AI understand resource structure | Already somewhat grouped by controller — make member/collection explicit |

---

### 2.4 `rails_get_controllers`

| Improvement | Why | Details |
|---|---|---|
| Show private methods called by an action | When viewing `create`, AI sees `auto_create_brand_profile` called but can't see its source without another tool call. This eliminates ~50% of follow-up calls | Include referenced private method source in the same response |
| Show which view the action renders | `index` renders `cooks/index.html.erb`. `create` (failure) renders `:new`. Saves a `rails_get_view` call | Map each code path to its rendered template |
| Show instance variables set | `index` sets `@pagy, @cooks`. `new` sets `@brand_profiles, @selected_brand, @prefill` | Parse the action body for `@var =` assignments |
| Show response formats | Does the action `respond_to :turbo_stream`? Render JSON? Just HTML? | Detect `respond_to` blocks, `render json:`, `render turbo_stream:` |
| Show redirect/render map for all paths | Success → redirect, Failure → render, Blocked → redirect with alert | Map each conditional branch to its outcome |
| Show the full filter chain with inheritance | Include filters from parent controllers (ApplicationController) | Show: `authenticate_user! (ApplicationController) → check_plan_expiry! (ApplicationController) → set_cook (CooksController, only: show/destroy/recook)` |

---

### 2.5 `rails_get_view`

| Improvement | Why | Details |
|---|---|---|
| Show instance variables used | Template uses `@cooks`, `@pagy`. Cross-reference with controller to ensure they're set | Parse ERB for `@variable` references |
| Show partial locals contract | `render "shared/status_badge", cook: cook` — show that `cook` is required by the partial | For each `render` call, show the locals passed. For the partial itself, show what locals it expects |
| Show Turbo Frame IDs | `turbo_frame_tag "cook_output"` — critical for Turbo wiring | Detect all `turbo_frame_tag` calls and their IDs |
| Show `turbo_stream_from` channels | `turbo_stream_from "cook_#{@cook.id}"` — critical for real-time | Detect all `turbo_stream_from` calls |
| Show conditional render tree | `if cook.cooking? → render "loading"`, `elsif cook.failed? → render "error"` | Parse `if/elsif/else` blocks that contain `render` calls |
| Show form fields and patterns for all form templates | Already done for `_form.html.erb` partials (fields list). Do it for all templates with forms | Detect `form_with`/`form_for` blocks, extract field names, types, and classes |
| Show DOM IDs that are targeted by Turbo/Stimulus | `<div id="cook_output" data-controller="cook-status">` — these IDs are part of the wiring contract | Parse for `id=` attributes, especially those inside Turbo Frame tags or with data-controller |

---

### 2.6 `rails_get_stimulus`

| Improvement | Why | Details |
|---|---|---|
| Show wiring in HTML data-attribute format | AI needs `data-controller="cook-status"` and `data-cook-status-cook-id-value="123"`, not JS property names. This eliminates naming conversion errors | Generate copy-paste ready HTML attributes for each controller |
| Reverse view lookup | `cook_status` is used in... where? AI needs to find existing usage to match the pattern | Scan all views for `data-controller="cook-status"` references |
| Show fetch/API endpoints | `dish_builder` makes `fetch(this.urlValue)` calls. AI needs to know what endpoints the Stimulus controller talks to | Parse JS for `fetch(`, `this.urlValue`, `XMLHttpRequest`, etc. |
| Show outlet connections | If a controller declares `static outlets = ["other-controller"]`, show the relationship | Parse `static outlets` declarations |
| Show event listeners | Custom events dispatched or listened to: `this.dispatch("changed")`, `addEventListener` | Parse for `dispatch`, `addEventListener`, custom event names |
| Show CSS classes toggled | `this.element.classList.add("hidden")` — AI needs to know what CSS classes the controller manipulates | Parse for `classList.add/remove/toggle` calls |

---

### 2.7 `rails_get_test_info`

| Improvement | Why | Details |
|---|---|---|
| Support `service:"ContentChef"` and `job:"Cook"` filters | Currently only model and controller filters work. Services and jobs need test discovery too | Add `service` and `job` parameters |
| Show fixture contents with relationships | `pending_cook` belongs to which user? Has which brand_profile? AI needs this to write correct assertions | Parse YAML fixtures, resolve references, show key attributes |
| Show coverage gaps proactively | `rails_analyze_feature` already does this ("no test file found"). Surface it in test_info too | At top level: "Missing tests: BrandProfilesController, SubscriptionsController, PaymongoClient" |
| Show fixture relationships as a graph | `chef_one → has: pending_cook, completed_cook, failed_cook, default_profile` | Group fixtures by their owner/parent |
| Show shared test helpers | What setup methods are available? What do they do? | Parse `test_helper.rb` and any `support/` files for shared methods |
| Show test database strategy | Transactional fixtures? DatabaseCleaner? Parallel tests? | Detect from test_helper.rb configuration |

---

### 2.8 `rails_get_edit_context`

| Improvement | Why | Details |
|---|---|---|
| Method-aware boundaries | If searching `near:"def create"`, return the entire method (up to matching `end`), not just N context lines. Currently cuts off mid-method | Parse Ruby AST to find method boundaries. Return the complete method body |
| Multiple matches with occurrence selector | If `scope` appears 3 times in a file, show all matches or let AI pick with `occurrence:2` | Return all matches with index, or add `occurrence` parameter |
| Show callers within the file | If looking at `def auto_create_brand_profile`, show which methods call it | Grep the same file for method name references |
| Cross-layer context mode | When editing a controller action, also show: route, rendered view, stimulus controllers, instance variables expected by view | This is essentially what `rails_get_context` does — consider making edit_context delegate to it when file is a controller |
| Show related tests | If editing `def create` in CooksController, show which tests cover it | Match test names containing "create" in the corresponding test file |

---

### 2.9 `rails_validate`

| Improvement | Why | Details |
|---|---|---|
| Validate Stimulus controller references | `data-controller="nonexistent"` in a view — flag if the controller JS file doesn't exist | Scan ERB for `data-controller=` values, check against `app/javascript/controllers/` |
| Validate partial existence | `render "cooks/missing"` — flag if `_missing.html.erb` doesn't exist | Scan for `render` calls, resolve partial paths, check file exists |
| Validate route helper existence | `cook_path(@cook)` in a view — flag if route helper doesn't exist | Scan ERB for `_path` and `_url` calls, cross-reference with routes |
| Validate instance variables | View uses `@foo` but controller action never sets it | Parse controller action for `@var =`, parse view for `@var` usage, flag mismatches |
| Validate strong params vs schema | `permit(:nonexistent_column)` — flag columns that don't exist in the table | Cross-reference permitted params with schema columns |
| Validate Turbo Stream targets | `broadcast_replace_to "x"` but no `turbo_stream_from "x"` in any view | Cross-reference broadcast calls with subscriptions |
| Validate partial locals | `render "foo", bar: x` but partial uses `baz` — flag mismatch | Cross-reference render call locals with partial variable usage |
| Validate concern method calls | Code calls `can_cook?` but model doesn't include the concern that defines it | Cross-reference method calls with available methods from included concerns |
| Validate association chains | `current_user.cooks.brand_profile` — invalid chain (cooks is has_many, can't call singular on it) | Parse association chains and verify each step is valid |
| Validate `respond_to` with template existence | `respond_to :turbo_stream` but no `.turbo_stream.erb` template exists | Check for matching template files |
| Validate job class in perform_later | `NonexistentJob.perform_later` — flag if job class doesn't exist | Cross-reference perform_later calls with job classes |
| Validate mailer method calls | `UserMailer.welcome.deliver_later` — flag if `welcome` method doesn't exist | Cross-reference mailer calls with mailer methods |

**Implementation notes:**
- These should all be under `level: "rails"` (not syntax level)
- Each check should be individually toggleable if needed
- Return warnings, not errors — some "mismatches" may be intentional
- Performance: cache schema, routes, and controller data to avoid re-parsing

---

### 2.10 `rails_search_code`

| Improvement | Why | Details |
|---|---|---|
| Fix `match_type:"class"` behavior | Currently prepends `^\s*(class\|module)\s+` to the pattern. If AI passes `"Controller"`, it searches for `class Controller` literally (no results). Should be smarter | If pattern doesn't contain wildcards, treat it as a substring: `class \w*Controller` |
| Add `match_type:"call"` | Find method invocations only, excluding the definition | Pattern becomes `(?<!def\s)method_name` — finds call sites, not definitions |
| Add `match_type:"route_helper"` | Find route helper usage across views and controllers | Searches for `pattern_path` and `pattern_url` calls |
| Group results by file | Currently flat list. Grouping reduces visual noise | Add `group_by:"file"` option |
| Show total match count | "Showing 30 of 87 results" — AI knows if it should narrow search | Always include total count in response |
| Semantic file type aliases | `file_type:"views"` → `*.erb`, `file_type:"controllers"` → `app/controllers/**/*.rb` | Map common Rails concepts to glob patterns |
| Add `exclude_path` parameter | Exclude test files, node_modules, vendor, etc. | `exclude_path: "test"` |

---

### 2.11 `rails_security_scan`

| Improvement | Why | Details |
|---|---|---|
| Add dependency audit (bundler-audit) | Known CVEs in gems is the #1 security issue in Rails apps. Currently invisible | Run `bundle audit check` or parse advisory DB |
| Check for exposed secrets | Hardcoded API keys, tokens, passwords in non-encrypted config files | Scan for patterns like `api_key = "..."`, `password: "..."` in non-credentials files |
| Show CORS configuration | Misconfigured CORS is extremely common. If `rack-cors` is configured, show the policy | Parse CORS initializer |
| Check authentication coverage | Which controllers/actions skip authentication? Are any unintentionally public? | Cross-reference `skip_before_action :authenticate_user!` with controller actions |
| Check CSRF protection gaps | Which controllers skip CSRF? Is it intentional? (webhooks = yes, other = suspicious) | Flag `skip_before_action :verify_authenticity_token` with context |
| Overall security score | Quick health check: "7/10 — missing CSP, no rate limiting on login" | Compute weighted score from all checks |
| Check mass assignment | Params permitted that shouldn't be (like `role`, `admin`, `plan_id`) | Flag sensitive column names in `permit()` calls |

---

### 2.12 `rails_analyze_feature`

| Improvement | Why | Details |
|---|---|---|
| Show data flow chain | `Controller#create → CookJob.perform_later → ContentChefService.new.call → GeminiClient → OutputParser` | Trace the call chain from controller through services, jobs, external calls |
| Show broadcast/subscription topology | If the feature uses Turbo Streams, show the full broadcast chain with channel names and targets | Integrate with turbo_map logic |
| Show middleware that applies | Rate limiting, authentication, CSRF — which middleware touches this feature's routes? | Cross-reference routes with middleware stack and skip_before_action |
| Show background job chains | `create → CookJob → (on complete) → broadcast` — show async flow | Detect job callbacks, after_perform hooks |
| Show related mailers | If the feature sends emails (welcome, notification, etc.) | Scan for mailer calls in the feature's code |
| Show related channels | Action Cable channels related to the feature | Scan for channel subscriptions/broadcasts |
| Show API endpoints | If the feature has API controllers, show them separately | Detect API-namespaced controllers |
| Deeper test coverage analysis | Per-method coverage: "create has 6 tests, generate_dish has 0 tests" | Cross-reference test names with controller actions |

---

### 2.13 `rails_get_config`

| Improvement | Why | Details |
|---|---|---|
| Show credentials keys (not values) | AI needs to know what credentials exist without reading the encrypted file | Parse credential structure, show keys only: `paymongo: { secret_key: [set], public_key: [set] }` |
| Show environment differences | "Production uses redis for cache, development uses null_store" — config differences cause deployment bugs | Compare config across environments |
| Show Active Job queue configuration | Queue names, adapter settings, retry policies | Parse `config/sidekiq.yml`, queue_adapter settings |
| Show Action Cable channels | What channels exist, what they subscribe to | Scan `app/channels/` for channel classes |
| Show background job schedules | Cron jobs, recurring tasks (if using sidekiq-cron, whenever, etc.) | Detect and parse schedule configuration |
| Show rack middleware order | Full middleware stack in order — some issues are order-dependent | Show complete middleware chain |

---

### 2.14 `rails_get_gems`

| Improvement | Why | Details |
|---|---|---|
| Show outdated gems | Compare installed vs latest available. "devise 5.0.3 → 5.1.0 available" | Run `bundle outdated` or compare with rubygems API |
| Show security advisories | Flag gems with known CVEs | Cross-reference with ruby-advisory-db |
| Show which gems have initializers | "devise → config/initializers/devise.rb" — done for some but not all | Scan initializers directory, match to gem names |
| Show gem groups | Development-only vs production gems | Parse Gemfile groups |
| Show unused gems | Gems in Gemfile that aren't require'd anywhere | Cross-reference with code usage (grep for gem's main module) |

---

### 2.15 `rails_get_conventions`

| Improvement | Why | Details |
|---|---|---|
| Show app-specific patterns (most important) | Auth pattern, flash pattern, error handling pattern, controller create/update pattern | Detect common patterns by analyzing controller code |
| Detect anti-patterns | Fat controllers (>200 lines), god models (>300 lines), business logic in views | Compute metrics, flag outliers |
| Show code metrics | Average/max model size, controller size, test-to-code ratio, service count | Aggregate file stats |
| Show naming conventions | "Services use `*Service` suffix, Jobs use `*Job` suffix" — detected from actual code | Analyze class name patterns |
| Show authorization pattern | How does this app check permissions? Pundit policies? Manual checks? Where in the action? | Detect `authorize`, `can_*?`, `current_user.admin?` patterns |
| Show error handling pattern | How does this app handle 404s, 500s, API errors? Raise? Redirect? | Detect rescue_from, redirect patterns for not-found |
| Show redirect/flash pattern | `redirect_to path, notice: "..."` vs `flash[:success]` — which does this app use? | Analyze flash usage across controllers |

**Example output for patterns section:**
```
## App Patterns (follow these for consistency)

### Authorization
- Check: current_user.can_cook? / can_create_brand_profile? / can_use_bonus_modes?
- Deny: redirect_to [path], alert: "You've reached your [limit]. Upgrade your plan for more."
- Location: top of action, before any logic
- Never: raise, render 403, Pundit

### Create action
1. Permission check (can_X?) → redirect with alert if denied
2. Build from current_user.associations.build(params)
3. if @record.save → redirect_to @record / path
4. else → render :new, status: :unprocessable_entity
5. Optional: enqueue background job after save
6. Optional: auto-create related records

### Flash messages
- Success: redirect_to path, notice: "Record created/updated/deleted!"
- Failure: redirect_to path, alert: "Description of limit or error."
- Never: flash.now with redirect, flash[:error]

### Error handling (record not found)
- Pattern: redirect_to [index_path] (not raise RecordNotFound)
- Example: set_cook → redirect_to cooks_path if cook not found
```

---

### 2.16 `rails_get_design_system`

| Improvement | Why | Details |
|---|---|---|
| Output canonical patterns only | 6 button variants confuse AI. Show one canonical, note variants exist | Mark one as canonical (most frequently used), list variant count |
| Full HTML copy-paste blocks | Just CSS classes isn't enough. AI needs the complete element including tag, type, common attributes | `<button type="submit" class="...">Label</button>` and `<%= link_to "Label", path, class: "..." %>` |
| ERB copy-paste blocks | Rails apps use ERB helpers, not raw HTML for forms. Show the ERB version | `<%= f.text_field :name, class: "...", placeholder: "..." %>` |
| Detect inconsistencies | Same semantic component with different classes across views | "Button (primary) has 6 variants across 12 views — consolidate?" |
| Show accessibility patterns | `aria-*` attributes, `role` attributes, `sr-only` classes used in views | Flag components missing accessibility attributes |
| Show empty state patterns | How does this app handle empty collections, no results, blank pages? | Detect empty state blocks and show the pattern |
| Show loading state patterns | Spinners, skeletons, disabled buttons during submission | Detect loading/spinner patterns |
| Show flash/notification pattern | How flash messages are displayed (partial, classes, auto-dismiss?) | Show the flash partial structure and classes |
| Show modal pattern | How modals work in this app (Stimulus-driven? Turbo Frame? CSS-only?) | Detect modal implementation pattern |
| Show form error display pattern | How validation errors are shown (inline? top of form? Toast?) | Detect error display pattern from form templates |

---

## 3. New Validation Rules

These should all be under `rails_validate(level: "rails")`. Each catches a specific class of runtime error that syntax checking misses.

| # | Rule | What it catches | Implementation |
|---|---|---|---|
| 1 | Stimulus controller existence | `data-controller="nonexistent"` → silent JS failure | Scan ERB for data-controller values, check JS files exist |
| 2 | Partial existence | `render "cooks/missing"` → MissingTemplate error | Resolve partial paths from render calls, check files |
| 3 | Route helper existence | `nonexistent_path` → NoMethodError | Scan ERB/Ruby for `_path`/`_url` calls, cross-ref routes |
| 4 | Instance variable consistency | View uses `@foo`, controller never sets it → nil | Parse controller @var assignments, view @var usage |
| 5 | Strong params vs schema | `permit(:ghost_column)` → silent data loss | Cross-ref permitted params with schema columns |
| 6 | Turbo Stream channel match | broadcast to "x" but nothing subscribes → silent fail | Cross-ref broadcast calls with turbo_stream_from |
| 7 | Partial locals match | `render "p", a: x` but partial uses `b` → NameError | Cross-ref render locals with partial variable usage |
| 8 | Concern method availability | Calls `can_cook?` but model missing concern → NoMethodError | Cross-ref calls with included concern methods |
| 9 | Association chain validity | `user.cooks.brand_profile` → NoMethodError | Parse dot chains, verify each step is valid association/method |
| 10 | Template existence for respond_to | `respond_to :turbo_stream` but no `.turbo_stream.erb` → MissingTemplate | Check template files match respond_to formats |
| 11 | Job class existence | `FakeJob.perform_later` → NameError | Cross-ref perform_later with app/jobs/ classes |
| 12 | Mailer method existence | `UserMailer.fake.deliver_later` → NoMethodError | Cross-ref mailer calls with mailer class methods |
| 13 | Stimulus target existence | `data-target="nonexistent"` in view → silent fail | Cross-ref data-*-target values with static targets in JS |
| 14 | Stimulus action existence | `data-action="click->ctrl#nonexistent"` → silent fail | Cross-ref action names with methods in JS controller |
| 15 | Stimulus value type match | `data-*-value="abc"` for a Number value → NaN | Cross-ref value types from JS with attribute values in HTML |
| 16 | Mass assignment of sensitive columns | `permit(:admin, :role, :plan_id)` → privilege escalation | Flag known sensitive column names in permit calls |
| 17 | N+1 query detection (static) | Loop with `cook.user.name` without includes/preload | Detect association access inside loops without eager loading |
| 18 | Turbo Frame ID match | `turbo_frame_tag "edit"` but link targets `turbo_frame: "editor"` → full page load | Cross-ref frame IDs with turbo_frame: link options |
| 19 | Flash key consistency | Controller uses `flash[:notice]`, view checks `flash[:success]` → message lost | Cross-ref flash keys between controllers and view display logic |
| 20 | Helper method existence | View calls `nonexistent_helper` → NoMethodError | Cross-ref helper calls with defined helpers in app/helpers/ |

---

## 4. Meta-Improvements

### 4.1 Token-optimized response format

**Problem:** Tools output hints like `_Next: rails_get_schema(table:"users") for columns..._` and `_Use this exact code as old_string for Edit..._`. AI already knows these things. Every hint line is ~20 wasted tokens. Across 10 tool calls, that's 200+ tokens of noise.

**Fix:** Add `format: "ai"` parameter (or make it the default) that strips:
- Next step suggestions
- Tool usage hints
- Edit instructions
- Decorative markdown that doesn't add information

Only return data. Every token should help produce correct output.

---

### 4.2 Freshness indicators

**Problem:** AI doesn't know if the context it's reading is stale. A model might have been modified in the current branch but not committed.

**Fix:** Add to every tool response:
```
# Cook model
Last modified: 3 days ago (committed)
# or
Last modified: uncommitted changes present ⚠️
```

This tells AI: "re-read this file directly if you need the absolute latest."

---

### 4.3 Confidence signals

**Problem:** AI doesn't know which parts of the codebase have test coverage and which are risky to change.

**Fix:** Add to relevant tool responses:
```
# CooksController#create
✓ 6 tests cover this action
⚠️ auto_create_brand_profile path: 0 tests
⚠️ brand_profile_id validation path: 1 test (partial)
```

AI knows where to be extra careful and where existing tests provide safety.

---

### 4.4 Caching strategy

**Problem:** Multiple tool calls often re-parse the same files (schema, routes, models). This adds latency.

**Fix:**
- Cache parsed results with file modification time as cache key
- Invalidate cache when file changes (use LiveReload fingerprinter)
- Share cache across tool instances within the same MCP session
- Pre-warm cache for commonly accessed files on server start

**Already partially implemented** — extend to cover all tools and ensure cache invalidation is reliable.

---

### 4.5 Error recovery and graceful degradation

**Problem:** If a tool encounters a parse error in one file, it shouldn't fail entirely.

**Fix:**
- Parse errors in individual files should be reported as warnings, not failures
- Return partial results with a note about what couldn't be parsed
- Example: "Schema parsed 4/5 tables successfully. brand_profiles: parse error at line 23"

---

### 4.6 Universal `include`/`exclude` filtering

**Problem:** Different tools have different filtering mechanisms. Some use `detail` levels, some use specific parameters.

**Fix:** Consider a universal `include` parameter across all tools:
```
rails_get_model_details(model: "User", include: ["associations", "validations", "methods"])
rails_get_model_details(model: "User", exclude: ["framework_methods"])
```

This gives AI fine-grained control over what context it receives, reducing token waste.

---

## 5. Implementation Priority

### Phase 1: Highest Impact (Fixes the most common AI errors)

These changes directly prevent wrong code output:

1. **Filter out framework-generated methods** in `rails_get_model_details`
   - Impact: Eliminates noise in every model lookup
   - Effort: Medium (need to diff file-defined vs inherited methods)

2. **Instance variable tracking** in `rails_get_controllers` (what action sets) and `rails_get_view` (what template uses)
   - Impact: Prevents the #1 cause of broken views
   - Effort: Medium (parse ERB for @var, parse Ruby for @var =)

3. **Show private methods called by an action** in `rails_get_controllers`
   - Impact: Eliminates ~50% of follow-up tool calls
   - Effort: Low (grep action body for method calls, include their source)

4. **Stimulus wiring in HTML attribute format** + reverse view lookup in `rails_get_stimulus`
   - Impact: Eliminates all Stimulus naming errors
   - Effort: Medium (generate data-* attributes, scan views for usage)

5. **Partial locals contract** in `rails_get_view`
   - Impact: Prevents all partial rendering errors
   - Effort: Medium (parse ERB for local var usage, cross-ref render calls)

6. **Scope definitions** in `rails_get_model_details`
   - Impact: AI can chain scopes correctly
   - Effort: Low (already have scope names, just include the lambda body)

### Phase 2: New Essential Tools

7. **`rails_get_partial_interface`** — Every partial is an implicit API
   - Impact: Prevents missing/wrong partial locals
   - Effort: Medium

8. **`rails_get_turbo_map`** — Turbo is the hardest thing for AI to wire
   - Impact: Prevents all Turbo Stream/Frame mismatches
   - Effort: High (scan multiple file types, match string IDs)

9. **`rails_get_concern`** — Concerns are invisible API surfaces
   - Impact: AI knows exact method signatures from concerns
   - Effort: Low (parse concern files, cross-ref includes)

10. **`rails_get_callbacks`** — Callbacks cause invisible side effects
    - Impact: Prevents callback conflicts and test surprises
    - Effort: Low (parse model files for callback declarations)

### Phase 3: Cross-Layer Validation

11. **Stimulus controller existence check** in `rails_validate`
    - Impact: Catches silent JS failures
    - Effort: Low

12. **Partial existence check** in `rails_validate`
    - Impact: Catches MissingTemplate errors
    - Effort: Low

13. **Route helper existence check** in `rails_validate`
    - Impact: Catches NoMethodError in views
    - Effort: Medium

14. **Instance variable consistency check** in `rails_validate`
    - Impact: Catches nil rendering silently
    - Effort: Medium

15. **Strong params vs schema check** in `rails_validate`
    - Impact: Catches silent data loss
    - Effort: Low

### Phase 4: Pattern Intelligence

16. **App-specific patterns** in `rails_get_conventions`
    - Impact: AI follows this app's patterns, not generic Rails
    - Effort: High (heuristic pattern detection across controllers)

17. **`rails_get_service_pattern`** — Business logic conventions
    - Impact: New services follow established patterns
    - Effort: Medium

18. **`rails_get_context`** (composite tool) — Single call for complete context
    - Impact: Reduces tool calls per task by 60-80%
    - Effort: High (orchestrates all other tools)

### Phase 5: Advanced Intelligence

19. **`rails_get_helper_methods`** — Available helpers
20. **`rails_get_job_pattern`** — Job conventions
21. **`rails_get_env`** — Environment and credentials
22. **Design system canonical patterns** with full HTML copy-paste
23. **Freshness indicators** on all tools
24. **Confidence signals** (test coverage per code path)
25. **Token-optimized `format: "ai"` mode**
26. **Advanced validate rules** (Turbo Frame match, N+1 detection, Stimulus target/action validation)
27. **`rails_search_code` improvements** (match_type fixes, grouping, totals)
28. **`rails_security_scan` improvements** (dependency audit, CORS, auth coverage)
29. **`rails_get_gems` improvements** (outdated, CVEs)
30. **`rails_get_config` improvements** (credentials keys, env diffs)

---

## Summary

| Metric | Current | After Phase 1-2 | After All |
|---|---|---|---|
| Tool calls per typical task | 5-8 | 2-4 | 1-2 |
| AI code accuracy (estimated) | ~80% | ~92% | ~99% |
| Token waste per session | ~30% | ~15% | ~5% |
| Cross-layer validation | Syntax only | 5 checks | 20 checks |
| New tools | 0 | 4 | 9 |
| Wiring error prevention | Manual | Partial | Complete |

The goal is: **one tool call gives the AI everything it needs to write perfect code. Every token in the response directly prevents a specific class of error.**
