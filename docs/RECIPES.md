<div align="center" markdown="1">

# Recipes

**Real-world workflows that show how AI + ground truth changes everything.**

[Quickstart](QUICKSTART.md) · [Tools Reference](TOOLS.md) · [Custom Tools](CUSTOM_TOOLS.md) · [FAQ](FAQ.md)

</div>

---

## Table of Contents

- [Adding a column](#adding-a-column-to-an-existing-table)
- [Fixing a controller action](#fixing-a-broken-controller-action)
- [Building a new feature](#building-a-new-feature-from-scratch)
- [Tracing a method](#tracing-a-method-across-the-codebase)
- [Understanding someone else's code](#understanding-someone-elses-code)
- [Writing tests](#writing-tests-that-match-your-patterns)
- [Debugging views](#debugging-a-view-rendering-issue)
- [Reviewing a PR](#reviewing-a-pr)
- [Safe database queries](#safe-database-queries)
- [Working with concerns](#working-with-concerns)
- [Checking components](#checking-component-patterns)
- [Diagnosing production](#diagnosing-production-issues)
- [Session context](#session-context-across-multiple-questions)
- [Migrating from manual context](#migrating-from-manual-ai-context)
- [Tips](#tips)

---

## Adding a column to an existing table

> [!TIP]
> This is the #1 place AI goes wrong. Without schema access, it guesses column names and types.

**Ask your AI:** "Add a `subscription_tier` column to the users table"

**What happens:**

```
→ rails_get_schema(table: "users")
```

<details>
<summary>Example output</summary>

```
## Table: users

| Column | Type | Null | Default |
|--------|------|------|---------|
| id | integer | NO | |
| email | string | NO | [unique] |
| subscription_status | string | yes | "free" |
| created_at | datetime | NO | |

### Indexes
- index_users_on_email (unique)
```

</details>

AI sees `subscription_status` already exists — asks before proceeding instead of creating a duplicate column.

```
→ rails_get_model_details(model: "User")
→ rails_migration_advisor(action: "add_column", table: "users", columns: "subscription_tier:string")
```

**Without ground truth:** AI writes a migration blindly, possibly duplicating a column or missing an index.

---

## Fixing a broken controller action

**Ask your AI:** "The create action in CooksController is failing"

```bash
rails_get_controllers(controller: "CooksController", action: "create")
# → Source code + inherited before_action filters + strong params + render paths

rails_get_routes(controller: "cooks")
# → Code-ready helpers: cook_path(@record), new_cook_path

rails_get_schema(table: "cooks")
# → Actual column names, types, constraints

rails_diagnose(error: "ActiveRecord::RecordInvalid", file: "app/controllers/cooks_controller.rb")
# → Classification + context + git blame + log correlation
```

AI sees the full picture: the parent controller's `authenticate_user!` filter, the actual strong params whitelist, and the real column names. No guessing.

---

## Building a new feature from scratch

**Ask your AI:** "Build a notifications system"

```
→ rails_analyze_feature(feature: "notifications")
```

<details>
<summary>Example output</summary>

```
# Feature Analysis: notifications

## Models (1)
### Notification
Table: notifications
Columns: user_id:bigint, title:string, read_at:datetime
Associations: belongs_to :user

## Controllers (1)
### NotificationsController
Actions: index, mark_read
Filters: before_action authenticate_user!

## Jobs (1)
### NotificationBroadcastJob
Queue: default | Retries: 3

## Routes (2)
GET  /notifications     → notifications#index
POST /notifications/:id → notifications#mark_read
```

</details>

AI sees what already exists before building anything. Then:

```
→ rails_get_conventions()   # Your app's patterns, not generic Rails
→ rails_get_gems()          # Sees ActionMailer, Sidekiq, etc.
→ rails_get_schema()        # Picks the right foreign keys and types
```

AI scaffolds the feature matching your app's actual patterns — not generic Rails conventions from training data.

---

## Tracing a method across the codebase

> [!TIP]
> `search_code` with `match_type: "trace"` is the single most powerful tool. Use it first when investigating anything.

**Ask your AI:** "Where is `can_cook?` used?"

```
→ rails_search_code(pattern: "can_cook?", match_type: "trace")
```

<details open>
<summary>Example output</summary>

```
# Trace: can_cook?

## Definition
app/models/user.rb:45 in User
  def can_cook?
    role.in?(%w[chef sous_chef]) && active?
  end

## Called from (4 sites)

**Controllers** (2)
  app/controllers/cooks_controller.rb:12  before_action :ensure_can_cook
  app/controllers/recipes_controller.rb:8  if current_user.can_cook?

**Views** (1)
  app/views/cooks/show.html.erb:8  <% if @user.can_cook? %>

**Tests** (1)
  spec/models/user_spec.rb:92  expect(chef.can_cook?).to be true
```

</details>

One call. Definition + source + every caller grouped by type + tests. **Replaces 4-5 sequential file reads.**

---

## Understanding someone else's code

**Ask your AI:** "Walk me through this app"

```bash
rails_onboard(detail: "full")
# → Narrative walkthrough: stack, models, key patterns, conventions, deployment

rails_dependency_graph(format: "mermaid")
# → Visual model relationship graph

rails_get_gems(detail: "full")
# → Every notable gem with version, category, and config location
```

---

## Writing tests that match your patterns

**Ask your AI:** "Write tests for the Order model"

```bash
rails_get_test_info(model: "Order")
# → Existing test files, fixtures, factory definitions

rails_get_model_details(model: "Order")
# → Associations, validations, scopes, callbacks to test

rails_generate_test(file: "app/models/order.rb")
# → Test scaffolding using YOUR framework (RSpec/Minitest) and YOUR patterns (fixtures/factories)
```

AI generates tests that actually run, using your test helper setup, your factory definitions, your assertion style.

---

## Debugging a view rendering issue

**Ask your AI:** "The dashboard view is broken"

```bash
rails_get_view(controller: "dashboard", action: "index")
# → Template source with ivars, Turbo frames, Stimulus controllers, partial locals

rails_get_partial_interface(partial: "dashboard/stats_card")
# → Required locals and methods called on them

rails_get_stimulus(controller: "chart")
# → Correct data-attributes with dashes (not underscores)
```

---

## Reviewing a PR

**Ask your AI:** "Review the changes in this branch"

```bash
rails_review_changes(ref: "HEAD~3..HEAD")
# → Per-file context + structural warnings

rails_validate(files: "app/controllers/users_controller.rb,app/models/user.rb", level: "security")
# → Syntax + semantic + Brakeman scan

rails_performance_check()
# → N+1 risks, missing indexes on changed models
```

---

## Safe database queries

**Ask your AI:** "How many users signed up this month?"

```bash
rails_query(sql: "SELECT COUNT(*) FROM users WHERE created_at > '2026-04-01'")
# → Runs with: regex pre-filter, SET TRANSACTION READ ONLY, 5s timeout, row limit, column redaction
# → Password columns automatically redacted
```

**Ask your AI:** "Explain why this query is slow"

```bash
rails_query(sql: "SELECT * FROM orders JOIN users ON ...", explain: true)
# → Query plan with index usage, full table scan warnings
```

---

## Working with concerns

**Ask your AI:** "What does the Searchable concern do?"

```bash
rails_get_concern(concern: "Searchable")
# → Methods (including class_methods block), source code, which models include it

rails_search_code(pattern: "include Searchable", match_type: "any")
# → Every file that includes this concern
```

---

## Checking component patterns

**Ask your AI:** "What components do we have?"

```bash
rails_get_component_catalog(detail: "standard")
# → ViewComponent/Phlex: props, slots, previews, sidecar assets, usage examples

rails_get_frontend_stack()
# → React/Vue/Svelte, Hotwire, TypeScript, Vite/Webpacker
```

---

## Diagnosing production issues

**Ask your AI:** "Check the app health"

```bash
rails_runtime_info(detail: "full")
# → DB pool stats, table sizes, pending migrations, cache stats, queue depth

rails_read_logs(level: "error", lines: 100)
# → Recent errors with sensitive data redacted

rails_security_scan()
# → Brakeman: SQL injection, XSS, mass assignment vulnerabilities
```

---

## Session context across multiple questions

When AI makes multiple tool calls in a conversation, `rails_session_context` tracks what's been queried:

```bash
# First question: "Tell me about users"
rails_get_schema(table: "users")
rails_get_model_details(model: "User")

# Follow-up: "What context do I have so far?"
rails_session_context()
# → Lists all prior tool calls with params and summaries
```

This prevents redundant queries and helps AI maintain conversation context.

---

## Migrating from manual AI context

If you've been maintaining a hand-written CLAUDE.md, `.cursorrules`, or similar:

**Step 1: Install**

```bash
rails generate rails_ai_context:install
```

**Step 2: Move your custom content**

The gem wraps its generated content in section markers:

```markdown
<!-- BEGIN rails-ai-context -->
... generated content ...
<!-- END rails-ai-context -->
```

Add your custom rules **outside** these markers — they're preserved on regeneration.

**Step 3: Remove manual maintenance**

You no longer need to manually update:
- Schema documentation (the tool reads it live)
- Model association lists (Prism AST parses them)
- Route documentation (introspected from `routes.rb`)
- Controller filter lists (read from the inheritance chain)

Your custom rules (coding style, PR conventions, team preferences) stay. The gem handles the facts.

---

## Tips

1. **Start with `detail:"summary"`** — get the lay of the land before drilling down
2. **Use `analyze_feature` first** — it's the best starting point for any feature work
3. **`search_code` with `match_type:"trace"`** — the single most powerful tool for understanding code flow
4. **Don't read files directly** — let tools give you the structured, verified data
5. **Re-query after edits** — earlier tool output may be stale after you make changes

---

<div align="center" markdown="1">

**[← Tools Reference](TOOLS.md)** · **[Custom Tools →](CUSTOM_TOOLS.md)**

[Back to Home](index.md)

</div>
