# Article [STATIC]

**Table:** `articles`
**File:** `app/models/article.rb` (32 lines)
**Structure:** class definition(1-1) → includes(2-3) → associations(4-6) → macros(7-8) → validations(9-12) → callbacks(13-15) → scopes(16-18) → instance methods(19-22) → private(23-24) → instance methods(25-32)
**Primary key:** `id`

## Columns
- **id** | bigint | primary key | NOT NULL
- **title** | string | NOT NULL
- **slug** | string | NOT NULL
- **body** | text
- **status** | integer | NOT NULL | default: 0
- **published_at** | datetime
- **comments_count** | integer | NOT NULL | default: 0
- **author_id** | bigint | NOT NULL
- **created_at** | datetime | NOT NULL
- **updated_at** | datetime | NOT NULL

## Associations
- `belongs_to` **author** (class: User) (inverse_of: :articles) (fk: author_id)
- `has_many` **comments** dependent: destroy

_Static tier: only the associations the source declares; a gem that adds associations at boot is not listed._

## Validations
- `presence` on author _(implicit from belongs_to)_
- `presence` on title
- `length` on title (maximum: 120)
- `presence` on slug
- `uniqueness` on slug
- `presence` on body (if: :published?)

## Enums
- `status`: draft(0), in_review(1), published(2) [integer]

## Scopes
- `recent` → order(published_at: :desc, created_at: :desc) [STATIC]
- `by_author` → where(author: user) [STATIC]
- `published` → where(status: :published).where.not(published_at: nil) [STATIC]

## Callbacks
- `before_validation`: :assign_slug (on: :create)
- `after_commit (on: :update)`: :notify_author (if: :saved_change_to_status?)

## Concerns
- **Publishable** - publishable?, publish!

## Key instance methods
- `to_param`

_Next: `rails_get_schema(table:"articles")` for columns/indexes | `rails_get_controllers(controller:"ArticlesController")` for actions | `rails_analyze_feature(feature:"Article")` for full-stack view_

---
_[STATIC] Static mode (static mode requested with --no-boot). Serving static analysis; runtime-only data is marked [UNAVAILABLE]. Run `bundle exec rails-ai-context --app-path site/sample_app doctor` for details._

---
_Something wrong, missing or failing in rails-ai-context itself, or an improvement? Ask the user whether to file it at https://github.com/crisnahine/rails-ai-context/issues_
