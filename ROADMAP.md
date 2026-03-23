# rails-ai-context — Bugs & Improvements Roadmap

> Comprehensive list from 6 testing sessions, ~500+ MCP calls, 522 specs, verified on DailyContentChef (9 tables, 6 models, 18 controllers, 15 Stimulus controllers).
> Current version: v1.2.1 (updated 2026-03-23)

---

## Open Bugs

### MCP Tools

| # | Bug | Severity | Tool | Status |
|---|-----|----------|------|--------|
| B1 | `unless: :devise_controller?` not fully evaluated — OmniauthCallbacksController shows `authenticate_user!` | LOW | controllers | **FIXED v1.2.1** — evaluates condition at introspection time, removes filter for Devise controllers |
| B2 | `self` appears in class methods list — Plan shows `self` as a class method alongside `free`, `pro`, `business` | LOW | model_details | Open |

### Rules Serializer (generated CLAUDE.md / rules files)

| # | Bug | Severity | Status |
|---|-----|----------|--------|
| R1 | User methods list shows ~5 of 18 — missing concern + model-defined methods | MEDIUM | **FIXED v1.2.1** — source-defined methods prioritized, Devise methods filtered |
| R3 | `visuals_needed` shown as `string` not `string[]` in rules | MEDIUM | **FIXED v1.2.1** — array columns now render as `type[]` |
| R4 | payments missing `paymongo_checkout_id` and `paymongo_payment_id` columns in rules | MEDIUM | **FIXED v1.2.1** — external ID columns no longer hidden |
| R5 | users missing `paymongo_customer_id` column in rules | MEDIUM | **FIXED v1.2.1** — same fix as R4 |
| R6 | No column defaults shown in generated rules | MEDIUM | **FIXED v1.2.1** — defaults shown inline as `(=value)` |

---

## Improvements: `rails_analyze_feature`

### Tier 1 — Core (makes the tool 10x more useful)

| # | Improvement | Description | Impact |
|---|-------------|-------------|--------|
| AF1 | **Services discovery** | Scan `app/services/` for classes matching the feature keyword. Show class name, line count, key method names. `feature:"cook"` → finds `ContentChefService`, `GeminiClient`, `OutputParser` | HIGH |
| AF2 | **Jobs discovery** | Scan `app/jobs/` for matching classes. Show queue name, retry config, what service it calls. `feature:"cook"` → finds `CookJob` (queue: default, retries: 3, calls ContentChefService) | HIGH |
| AF3 | **Views + partials discovery** | List matching views with line counts, partial renders, and Stimulus controller references. `feature:"cook"` → shows `cooks/show.html.erb (61 lines) renders: cooks/output, cooks/loading stimulus: cook-status, share` | HIGH |
| AF4 | **Stimulus controllers discovery** | Match Stimulus controllers by name. Show targets, values, actions. `feature:"cook"` → finds `cook_status` controller with `cookId` value and `checkTimeout` action | HIGH |
| AF5 | **Test files discovery** | List matching test files with test counts. `feature:"cook"` → shows `test/models/cook_test.rb (13 tests)`, `test/controllers/cooks_controller_test.rb (21 tests)` | HIGH |

### Tier 2 — Cross-cutting intelligence

| # | Improvement | Description | Impact |
|---|-------------|-------------|--------|
| AF6 | **Related models via associations** | Show models connected through `belongs_to`, `has_many`. `feature:"cook"` → "Related: User (owner), BrandProfile (optional), CookShare (shares)" | MEDIUM |
| AF7 | **Execution flow graph** | Trace the full request lifecycle: controller action → authorization check → model operation → job enqueue → service call → external API → broadcast. No other tool does this. | MEDIUM |
| AF8 | **Permission/authorization mapping** | Map which concern methods guard which actions. `can_cook?` guards `CooksController#create`, `can_use_bonus_modes?` guards `Bonus::BaseController` | MEDIUM |
| AF9 | **Environment dependencies** | Detect ENV vars referenced by the feature. `feature:"cook"` → requires `GEMINI_API_KEY`, Sidekiq running, Redis connected | MEDIUM |
| AF10 | **Channel/websocket discovery** | Find `turbo_stream_from` and Action Cable subscriptions. `feature:"cook"` → uses `turbo_stream_from "cook_#{id}"` for real-time output | MEDIUM |

### Tier 3 — Agent workflow optimization

| # | Improvement | Description | Impact |
|---|-------------|-------------|--------|
| AF11 | **Mailer/notification discovery** | Scan `app/mailers/` for matching classes and their delivery triggers | LOW |
| AF12 | **Concern tracing** | When a feature uses concerns, list which concerns and their methods. `feature:"User"` → PlanLimitable adds 12 methods | LOW |
| AF13 | **Callback chains** | Show before/after hooks that fire. `feature:"brand"` → `before_save :ensure_single_default` on BrandProfile | LOW |
| AF14 | **"How to extend" hints** | Based on existing patterns, suggest where to add a new action, new validation, new partial. "To add a new cook mode: add to MODES constant (line 7), add view in bonus/" | LOW |

---

## Improvements: `rails_get_design_system`

### Tier 1 — Missing component patterns

| # | Improvement | Description | Impact |
|---|-------------|-------------|--------|
| DS1 | **Modal pattern** | Extract overlay + card pattern from `_share_modal.html.erb`. Show: `fixed inset-0 bg-black/50 z-40` overlay + `bg-white rounded-2xl shadow-lg max-w-md w-full p-6` card | HIGH |
| DS2 | **Badge/tag pattern** | Extract from mode badges: `text-xs font-medium px-2.5 py-1 rounded-full bg-{color}-100 text-{color}-700`. Show color variants (indigo, green, yellow, red) | HIGH |
| DS3 | **Status indicator pattern** | Extract from `_status_badge.html.erb`. Show as a reusable shared partial reference: `render "shared/status_badge", cook: cook` | HIGH |
| DS4 | **Flash/toast patterns** | Extract from `_flash.html.erb`. Show success (`bg-green-50 border-green-200 text-green-700`), error (`bg-red-50 border-red-200 text-red-700`), notice variants | HIGH |
| DS5 | **List item pattern** | Extract the repeating card-per-item layout from cook index: `bg-white rounded-xl p-5 shadow-sm border border-gray-100 flex items-center justify-between gap-4` | HIGH |
| DS6 | **Secondary button** | Extract: `bg-gray-100 text-gray-700 px-4 py-2 rounded-xl text-sm font-semibold hover:bg-gray-200 transition cursor-pointer`. Currently only primary + danger listed | MEDIUM |
| DS7 | **Shared partials section** | List all `app/views/shared/` partials with one-line descriptions. Agents should reuse these before creating new markup: `_flash.html.erb`, `_navbar.html.erb`, `_status_badge.html.erb`, `_upgrade_nudge.html.erb` | MEDIUM |

### Tier 2 — Decision guidance

| # | Improvement | Description | Impact |
|---|-------------|-------------|--------|
| DS8 | **"When to use what" decision guide** | Not just class strings but rules: "Page needs a form? → Copy Form Page example. Need confirmation? → `data: { turbo_confirm: 'message' }`. Showing status? → `render 'shared/status_badge'`" | HIGH |
| DS9 | **Loading/spinner pattern** | Extract from `_loading.html.erb`: `animate-spin` emoji + progress bar (`bg-orange-500 h-2 rounded-full animate-pulse`) | MEDIUM |
| DS10 | **Confirmation dialog convention** | Document the Turbo Confirm pattern: `data: { turbo_confirm: "Are you sure?" }` on `button_to` for destructive actions | MEDIUM |
| DS11 | **Form error pattern** | Show what validation errors look like: field highlighting, error message placement, `field_with_errors` wrapper behavior | MEDIUM |
| DS12 | **Spacing system rules** | Explain WHEN to use each spacing: `space-y-3` for list items, `space-y-4` for form fields, `space-y-6` for form sections, `gap-2` for button groups, `mb-6` for section separators | LOW |

### Tier 3 — Framework adaptability

| # | Improvement | Description | Impact |
|---|-------------|-------------|--------|
| DS13 | **Auto-detect CSS framework** | Detect Tailwind vs Bootstrap vs custom CSS/Sass. Adapt extraction strategy per framework. Currently hardcoded for Tailwind — broken for all other setups | HIGH |
| DS14 | **Bootstrap support** | Scan ERB for Bootstrap classes (`btn-primary`, `card`, `modal`, `form-control`). Parse `_variables.scss` for custom theme. Show Bootstrap component examples from actual views | HIGH (for Bootstrap apps) |
| DS15 | **Custom CSS/Sass support** | Parse `.scss/.css` files for class definitions. Group by file (buttons.scss → Button patterns). Detect BEM naming. Show CSS custom properties (`--color-primary`) | HIGH (for custom apps) |
| DS16 | **Parse Tailwind `@apply` directives** | If app has `@apply` rules in CSS, extract those as named component classes | MEDIUM |
| DS17 | **Detect DaisyUI / Flowbite / Headless UI** | If Tailwind plugin libraries are installed, include their component patterns alongside raw Tailwind | MEDIUM |
| DS18 | **Parse `tailwind.config.js` custom theme** | Extract custom colors, fonts, spacing from the config file. Show `primary: '#FF6B00'` if customized | MEDIUM |
| DS19 | **Animation/transition inventory** | List all `transition`, `animate-*`, `duration-*` patterns with usage context | LOW |
| DS20 | **Icon size conventions** | Document when to use which size: `w-3.5 h-3.5` (inline with text), `w-4 h-4` (buttons), `w-5 h-5` (standalone), `w-10 h-10` (feature icons) | LOW |
| DS21 | **Remove oklch noise from summary** | Token colors (oklch values) waste tokens in summary. Move to `detail:"full"` only. Summary should show Tailwind class names only | LOW |

---

## Improvements: Rules Serializer

| # | Improvement | Description | Impact |
|---|-------------|-------------|--------|
| RS1 | **Include all concern methods** | User methods list should include all PlanLimitable methods (12+), not just 5 | HIGH — partially fixed in v1.2.1 (source methods prioritized), full concern method extraction still open |
| RS2 | **Detect array columns** | Show `visuals_needed:string[]` not `visuals_needed:string` | ~~MEDIUM~~ **FIXED v1.2.1** |
| RS3 | **Include all non-system columns** | payments should show `paymongo_checkout_id`, `paymongo_payment_id`. users should show `paymongo_customer_id` | ~~MEDIUM~~ **FIXED v1.2.1** |
| RS4 | **Show column defaults** | Inline defaults: `mode:string(default:"standard")`, `status:string(default:"pending")` | ~~MEDIUM~~ **FIXED v1.2.1** |

---

## Improvements: `rails_validate`

| # | Improvement | Description | Impact |
|---|-------------|-------------|--------|
| V1 | **Smarter JSONB strong params skip** | Currently skips ALL params check for models with ANY JSONB column. Could be smarter: only skip params matching JSONB column names, check the rest | LOW |
| V2 | **Route-action check suggests fix** | When `show` action missing but route exists, suggest: "Add `def show; end` to BrandProfilesController or remove `show` from `resources :brand_profiles`" | LOW |

---

## Improvements: `rails_get_model_details`

| # | Improvement | Description | Impact |
|---|-------------|-------------|--------|
| MD1 | **Filter `self` from class methods** | Plan shows `self` as a class method — should be filtered out | LOW |

---

## Summary

| Category | Total | Fixed | Open | Tier 1 (HIGH) | Tier 2 (MEDIUM) | Tier 3 (LOW) |
|----------|-------|-------|------|--------------|-----------------|--------------|
| Open Bugs | 7 | 6 | 1 | 0 | 0 | 1 (B2) |
| analyze_feature | 14 | 0 | 14 | 5 | 5 | 4 |
| design_system | 21 | 0 | 21 | 9 | 6 | 6 |
| Rules serializer | 4 | 3 | 1 | 1 (RS1 partial) | 0 | 0 |
| validate | 2 | 0 | 2 | 0 | 0 | 2 |
| model_details | 1 | 0 | 1 | 0 | 0 | 1 |
| **Total** | **49** | **9** | **40** | **15** | **11** | **14** |

### Killer differentiators (no other tool does these)

1. **Execution flow graph** (AF7) — trace a full request from HTTP to database to broadcast in one call
2. **"When to use what" decision guide** (DS8) — not just patterns but rules for choosing the right one
3. **Auto-detect CSS framework** (DS13-DS15) — works for Tailwind, Bootstrap, custom CSS, any Rails app
4. **Services + Jobs + Views + Tests in feature analysis** (AF1-AF5) — full-stack feature discovery in one call
5. **Environment dependency detection** (AF9) — know what needs to be running before you touch a feature
