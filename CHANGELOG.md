# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- **`model_details` lists more of what a model declares.** Under Macros:
  `attribute` (with its type and default), `alias_attribute`, `has_rich_text`,
  `strict_loading_by_default`, `implicit_order_column`, `locking_column`,
  `store_full_sti_class`, `attr_readonly` and `query_constraints`, in both
  tiers; a setting assigned inside a method or a nested class is not listed as
  the model's. An STI model names its parent (or a base its subclasses) and its
  type column, honoring `inheritance_column`, and only where the table has that
  column (the static tier reads the schema dump). A model whose base class calls
  `connects_to` gets a Database line with the call as written and the class it
  comes from, in `model_details` and `get_context`; a call under a condition
  says `(only if ...)`, and otherwise the model's columns come from the schema
  of the database it writes to. (#294, #390, #395)
- **`model_details` lists a model's `default_scope`** at the top of Scopes,
  declared as the macro or as `def self.default_scope` in the model's own class
  (not a class or module nested in its file), with `all_queries: true` when
  declared. A base's default scope comes first, in the order Rails stacks them.
  (#295)
- **`model_details` reads common model gems.** An `aasm` machine shows its
  states, initial state, events and transitions, and `has_paper_trail`,
  `friendly_id`, `mount_uploader`, `monetize` (with the attribute it adds),
  `pg_search_scope`, `acts_as_list` and other gem macros get a line each, as
  written. The static tier lists the `belongs_to` that `acts_as_tenant`
  declares. A macro written inside a method body or a nested class is not
  credited to the model, and `aasm.current_state` in a method opens no second
  machine. (#389)
- **`model_details` lists each index a Mongoid document declares**, as written,
  and the fields and indexes its included concerns declare. (#412)
- **In an Apartment app, `model_details` says where a model's table lives**: in
  the shared schema (`excluded_models`) or in each tenant's schema, whatever the
  `Apartment.configure` block calls its parameter. A list built with `+=` or
  `<<` is named as computed. (#415)
- **The schema lists views, materialized views and SQLite virtual tables** in
  both tiers (scenic's schema.rb, structure.sql, the connection), labelled in
  the listings. The table view shows a view's SQL or a virtual table's module,
  with its columns by name alone, and the indexes declared on a materialized
  view. Views and virtual tables are not counted as tables with no model file,
  and a table the dumper could not write is listed with its reason. Known limit:
  booted on Rails 7.x with SQLite older than 3.37, a virtual table's shadow
  tables still list as tables. (#354)
- **`job_pattern` shows more of how a job runs.** A job's page shows its
  `queue_with_priority`, `enqueue_after_transaction_commit`, Solid Queue
  `limits_concurrency` and its enqueue, perform and `after_discard` callbacks;
  `retry_on` keeps its `queue:`, `priority:` and `jitter:`, and a Sidekiq
  worker's `sidekiq_retry_in` and `sidekiq_retries_exhausted` blocks are listed
  under its retries (the worker listing names such a block by its macro only). A
  priority given as a lambda reads as computed. A job that includes
  `ActiveJob::Continuable`, itself or through a base, is marked so, with the
  steps its `perform` runs in order. (#392, #409)
- **`job_pattern` names the queues Solid Queue's workers poll** in
  `config/queue.yml` and flags every job queue no worker polls, in the listing
  and on the job's own page, when the app runs Solid Queue (its config sets
  `active_job.queue_adapter = :solid_queue`, or sets no adapter and the Gemfile
  has `solid_queue`). (#396)
- **delayed_job's `handle_asynchronously` methods are listed** with their
  options, in `job_pattern` and `model_details`, where `job_pattern` used to say
  No jobs found. A method a concern wraps is listed under each model that
  includes the concern, directly or through another concern. (#410)
- **`mailers` lists Action Mailbox and more mailer settings.** The mailboxes,
  the routing rules in the order Rails tries them with the mailbox each sends
  to, and each mailbox's processing callbacks. Each mailer shows its own
  `default`, `layout`, helpers and callbacks, the template formats of each
  action and its preview class; the full listing names the queue `deliver_later`
  uses, the interceptors and observers the config registers, and the mailer
  preview paths. (#386, #393)
- **`env` lists environment variables from more places**: the env Kamal's
  `config/deploy.yml` sets at the top level, for each role
  (`servers.<role>.env`) and for each `env.tags` tag (secret names, never
  values, and clear values, except one holding a URL or a key-like token, or
  under a secret-named variable, which shows as hidden, and one an ERB tag sets, which says so; a
  `config/deploy.<destination>.yml` is named as not read), the setting keys in
  the config gem's `config/settings.yml` and `config/settings/<env>.yml` when
  the bundle has the config gem, each `Anyway::Config` class's attributes with
  the env names they read (values left out), the ENV names `Rails.app.creds` and
  `Rails.app.envs` read on Rails 8.2 (`require(:stripe_api_key)` is
  `STRIPE_API_KEY`, nested keys joined by `__`), and the ENV names read in
  `config.ru`, `db/seeds.rb`, `db/seeds/` and the Ruby scripts in `bin/`. (#397,
  #398, #404, #417)
- **`config` lists what runs in front of Rails and what CurrentAttributes
  holds**: the middleware `config.ru` adds (with the `if` it runs under, and the
  `map` it sits inside when that map runs the app itself) and the `map` mounts
  that run their own Rack app, in the static tier too, and each
  CurrentAttributes class's attributes, their defaults and its reset hooks.
  (#398, #399)
- **`env_config` lists the config keys `config/application.rb` sets for every
  environment** (`config.x` included) and, for each `config_for` call (a name,
  or `Rails.root.join` of literal parts), the keys its YAML file gives the
  running environment, or the environment a literal `env:` names. A file on
  `sensitive_patterns`, outside the app, or over `max_file_size` is named with
  that reason and its keys are not read. (#394)
- **`active_support` lists the ActiveSupport::Notifications events the app
  subscribes to** (`subscribe`, `monotonic_subscribe`, and a Subscriber's
  `attach_to`, inside the class with or without `self.`, or called on it
  afterwards) with the file and line of each, in both tiers. An `attach_to`
  lists one `<method>.<namespace>` event per public method the subscriber
  defines in that file, and says so in words when it defines none. (#387)
- **`onboard` lists the app's own tooling**: its custom rake tasks (Rakefile,
  `lib/tasks`, `rakelib`) with their arguments, the description `rake -T` prints
  and the file, one entry for a task defined in several places (the first 15 at
  standard detail, every one at full), its own generators (`bin/rails generate
  service`), the `lib/templates` files that replace a built-in generator's
  template, and the Railties under `lib/` with their initializers. (#385, #400)
- **`onboard` and the gems resource read more Ruby version sources.** A Ruby
  engine other than CRuby is named from `.ruby-version`, `.tool-versions`, the
  Gemfile `ruby` line or the lockfile ("declaring JRuby 9.4.8.0 (Ruby
  3.1.4p0)"), where a `jruby-` `.ruby-version`, or a bare `jruby` one, gave no
  Ruby at all. A version pinned in mise (`mise.toml`, `mise.local.toml`,
  `.mise.toml`, `mise/config.toml`, `.mise/config.toml`, `.config/mise.toml` or
  `.config/mise/config.toml`) is read when no other file names one. (#420, #421)
- **`controllers` and `view` say which layout a controller renders in**
  (declared, inherited, set by an app concern it includes, or found by name),
  and `controllers` lists the `allow_browser`, `protect_from_forgery`,
  `add_flash_types`, `default_form_builder` and `wrap_parameters` settings it,
  its ancestors and their app concerns declare. (#337)
- **`controllers` lists the filters authorization gems add**: cancancan's
  `load_and_authorize_resource`, `load_resource`, `authorize_resource`,
  `check_authorization` and `skip_authorization_check`, and acts_as_tenant's
  `find_tenant_by_subdomain`, in both tiers; one passed `prepend: true` is
  listed first, where cancancan adds it. Each is read only when the lockfile
  resolves that gem and no class on the chain defines a class method of the same
  name. A responders class-level `respond_to :json` shows its formats in both
  tiers, and a subclass shows the formats its ancestors declare, as responders
  copies them. (#406, #407)
- **`view` marks template and partial variants and locales**:
  `show.html+mobile.erb` is the `mobile` variant of `show`, and
  `show.fr.html.erb` its `fr` locale. (#408)
- **`routes` lists the endpoints of a mounted Grape API** under its mount: verb,
  full path with prefix and version, and declared params, with a `route_param`'s
  param and a params block before a namespace given to every endpoint inside it.
  Read from `app/api` and `lib/api` in both tiers; an edit there refreshes the
  MCP server's cached answer. (#411)
- **`service_pattern` reads more service shapes.** It reads `app/interactions`
  and `app/interactors` as well as `app/services` (so does the generated files'
  Services line), lists an interactor organizer's steps in order, and shows an
  Initialize line and an Inputs section for a service whose constructor comes
  from T::Struct `const`/`prop`, Dry::Struct `attribute`, dry-initializer
  `param`/`option` or the attr_extras initializers. Dry::Struct attributes and
  dry-initializer params and options an app superclass declares are included,
  marked with the class they come from. (#402, #403)
- **`conventions` and `analyze_feature` list the models an admin gem exposes**:
  ActiveAdmin (with the params it permits), Administrate, Avo (2 and 3 resource
  naming), Madmin and Trestle. (#405)
- **`conventions` lists `.standard.yml`, `.erb_lint.yml` (or the older
  `.erb-lint.yml`), `sorbet/config` and `Steepfile`** under Notable config
  files, beside `.rubocop.yml`. (#422)
- **The package manager is found at the JS workspace root.** `frontend_stack`
  and `conventions` name it when the lockfile sits in a workspace root above the
  app (never above the git root), and `frontend_stack` says which directory that
  is. (#401)

### Changed

- **A configured frontend directory outside the app root is read for its
  manifests.** A `frontend_paths` entry such as `../web-client`, and the JS
  workspace root above the app, are read for `package.json`, lockfiles and the
  presence of a bundler config only, plus a configured entry's `tsconfig.json`
  and the configs it extends inside that directory. `frontend_stack` reports the
  framework, build tool, package manager and TypeScript settings and names the
  directory instead of calling the app API-only; an entry inside the app root
  gets the same build tool and package manager answer. docs/SECURITY.md lists
  this read under "Frontend roots outside the app". (#377, #401)
- **An app with no lockfile of its own reads the bundle `config/boot.rb` points
  at.** In an engine's `test/dummy`, static `onboard`, `gems`, `env` and the
  Rails version read the Gemfile and lockfile its `BUNDLE_GEMFILE` names when
  they sit inside the app's git repository; outside one, they say that bundle is
  not read and name it. docs/SECURITY.md lists this read, and the engine source
  a booted `test/dummy` reads, under "The bundle config/boot.rb declares" and
  "The engine an app's test/dummy runs in". (#381, #423)
- **The controllers payload carries `rate_limits`**, one entry per `rate_limit`
  call, in place of `rate_limit` and `rate_limit_parsed`. `controllers` prints
  every limit a controller declares, whole when the call spans lines, and in a
  controller's own detail each limit an ancestor declares, named by the class
  that declares it. (#332)
- **A booted filter an outside module defines carries that module as
  `from_concern`.** With `include ActiveStorage::SetBlob`, `set_blob` reads
  `(from ActiveStorage::SetBlob)` and is never labelled as not declared in the
  controller chain; an `on_load` filter beside it still is. (#293)
- **A strong params entry's `nested` list keeps a doubly-wrapped list as an
  inner array.** `params.expect(thing: [items: [[:sku, :qty]]])` carries
  `"items" => [["sku", "qty"]]`, where it was flattened to the single-hash
  `["sku", "qty"]`, and the `controllers` summary prints it as
  `items: [[:sku, :qty]]`. (#333)
- **The views payload no longer carries `conditional_layouts`.** Each controller
  entry carries `layout` and `settings` instead. (#337)
- **The mailboxes payload drops each mailbox's `routing` list** (`{pattern,
  action}`). A mailbox carries `routed_from`, the patterns that send to it, the
  section gains a top-level `routes` list (`{pattern, mailbox, file}`) in the
  order Rails tries them, and a mailbox's `file` is relative to the app root
  (`app/mailboxes/replies_mailbox.rb`), not to `app/mailboxes`. (#386)
- **A job's `callbacks` in the jobs payload holds the declarations as written**
  (`before_perform :log_start`) in place of the bare macro names
  (`before_perform`). (#392)
- **A Mongoid model's payload always carries `collection:`**, the `store_in`
  name or the one Mongoid derives (`admin_shelves`), where it was set only for
  `store_in`. An embedded document carries `embedded_in:` (its parent class)
  in its place, and a subclass of a document (`class Ebook < Book`) is a
  Mongoid model with its root's collection and fields and `parent_model:`,
  where it was read as an ActiveRecord model with an `ebooks` table. (#382)
- **`schema --table` JSON for a name that holds different tables in two
  databases is `{table:, databases: {<name> => table}}`** instead of one table's
  keys at the top level. (#356)
- **Views are counted apart from tables.** Schema entries carry `kind:` (`view`,
  `materialized_view`, `virtual_table`) in JSON, `total_tables` leaves views
  out, and the schema headers read `116 tables and 2 views`. `onboard` counts
  tables only. (#354)
- **`encryption_details` options are the source text.** Each `encrypts` entry
  carries every option as the file writes it (`"true"`, not `true`), a
  `normalizes` entry carries its `with:` lambda and other options as written,
  and `generates_token_for` its `expires_in` as written. (#391)
- **`concern` lists only what an includer gains under Class Methods**:
  `class_methods do`, `module ClassMethods`, and a `def self.x` written in
  `included do`. The module's own `def self.x` and `class << self` methods move
  to a new Module Methods section, and its `def self.included(base)` (or
  `extended`, `prepended`) hook is listed under neither. A `def self.x` or
  `class << self` written inside `class_methods do` belongs to ClassMethods
  alone, so neither section lists it. (#312)
- **The tests payload's `factories` carries `unread: true`** when a test helper
  loads factories from a path built at run time. Its `count` is then the files
  of the paths that were read, and nil when none was; `test_info` and `onboard`
  print no file count in that case. (#373)
- **`search_docs` no longer accepts `source: "api"`**, which never had entries.
  The valid sources are all, guides, stimulus, turbo and hotwire. (#322)

### Fixed

- **Three crashes on older or unusual setups are gone.** After a boot that fails
  inside a Rails 7.0 app's activesupport (Logger not loaded), the static tier
  answers instead of every tool crashing. Booted tools no longer fail with
  "wrong number of arguments" on a Rails 7.0 app whose bundle locks zeitwerk
  2.5; the gem now accepts zeitwerk 2.5. CLI tools no longer crash with
  Encoding::CompatibilityError on a non-ASCII argument under a C or other
  non-UTF-8 locale. (#272, #273, #275)
- **A Sinatra app with `config/environment.rb` and `app/` is not read as a Rails
  app**; both tiers answer "No Rails app found". With no lockfile, a Gemfile
  that names neither rails nor railties decides the same before anything boots,
  so the tree's own `bundler/setup` never runs and never writes a lockfile into
  it. A tree whose `config/environment.rb` loads but defines no Rails
  application, with no lockfile to decide, reports a failed boot and answers
  from the static tier. (#274)
- **An app without Active Record says so.** `schema` says introspection does not
  apply, `onboard` no longer says "on unknown", and `model_details` says there
  is no Active Record model by that name. A sequel-rails app gets "this app uses
  Sequel; ActiveRecord schema introspection does not apply" instead of id-only
  tables replayed from Sequel migrations, and a replay behind an empty schema.rb
  says the dump declares no tables. (#364, #383)
- **Gems are read from `gems.rb` and `eval_gemfile` files.** An app on `gems.rb`
  and `gems.locked` reads its gems, Rails version and Ruby version in `gems`,
  `onboard` and `doctor` as one on `Gemfile` does, and gems declared in a file
  named by `eval_gemfile` are read, so `env`, `gems`, `helper_methods` and the
  app-kind checks see them. (#418, #419)
- **A new Rails 8 app reads right.** `onboard` names the adapter database.yml
  declares when there are no tables yet, where it said "on unknown"; `schema`
  lists the solid_queue, solid_cache and solid_cable tables from their own dump
  files and says the primary database has no tables yet. `onboard --detail full`
  says "Dockerfile: present." and "Deployment: kamal.", names a `Procfile.dev`
  on its own line instead of reporting a Procfile, and no longer prints an empty
  "File Storage & Rich Text" heading. The migrations list names a migration
  `active_storage:install` or `action_text:install` copied by its class, without
  the scope suffix. (#276, #280, #281, #284)
- **`config` reports the Action Cable adapter of the current environment**
  (solid_cable in a default Rails 8 production, not the development block's
  async) and keeps the Database line when the environment lists several
  databases. `observability` reports Rails 8.1's event reporter (`Rails.event`)
  as available, with its subscriber count. (#285, #286)
- **`test_info` reads Rails 8.1 test setups.** It and `onboard` name
  `config/ci.rb` (`rails_ci`), Buildkite, Jenkins and Bitbucket Pipelines as CI,
  and `test_info` lists the steps `bin/ci` runs. It lists `test/test_helpers`
  (where the authentication generator puts `SessionTestHelper`) as test helpers,
  no longer lists `test/helpers` helper tests as helpers, and shows the
  `parallelize`, `fixtures` and `driven_by` calls. (#277, #287)
- **Rails 8 generated authentication reads right.** `controllers` no longer
  drops the authentication filter from every controller: a `skip_before_action`
  inside a class method (`allow_unauthenticated_access`) applies only where a
  controller calls that method, with the options the call passes, also through a
  class method of its base, or of a concern either one includes, that calls it.
  `conventions` builds the controller test's sign-in from the call the app's
  tests make (`sign_in_as`), and signs in the app's own users fixture where the
  tests sign in a variable set elsewhere. (#288, #289)
- **`read_logs` reads the level a formatter writes**, never a word in the
  message, and reads Sidekiq's 6/7, 8 (colored) and JSON formats and
  rails_semantic_logger's one-letter level. It filters by level only when most
  lines carry a severity; otherwise (Rails' default dev and 8.0+ production
  formatter) it shows every line and says it cannot filter by level. It reads a
  rotated log (`file: "development.log.0"`) and lists rotated logs under the
  available files. (#278, #343)
- **Static `routes` draws more of what Rails draws.** Shallow nesting,
  `path_names`, a `new do` block, every path of a multi-path route (Rails 8.1
  refuses that form, so on 8.1 it counts as not expanded), routes inside
  `controller :x do`, `options` routes, and the routes of a method defined in a
  route file, where it is called. A resource whose options are a variable, and a
  call it cannot expand (`load`, `use_doorkeeper`, `ActiveAdmin.routes(self)`,
  also inside a `constraints` or `authenticate` block), count as not expanded
  instead of listing seven actions or vanishing; `direct` and `resolve` are no
  longer counted, and a lambda mount counts as the booted tier counts it. Routes
  an initializer adds with `Rails.application.routes.prepend` or `.append` are
  listed first and last, as Rails draws them, including one registered inside
  `after_initialize`, which Rails runs before it draws the routes; one
  registered inside another `on_load` hook counts as not expanded, since that
  hook may run after the draw. The framework count says it covers only the app's
  route files, and that routes Rails' own engines and gems draw are read only
  with the app booted; `onboard`, the rake summary and the generated context
  files say so beside their route count too. (#283, #325, #326, #328)
- **A route, mount or filter under a condition carries it.** Static `routes`
  marks a route under `if`/`unless`, a `case` branch or an `&&`/`||` guard
  (`case Rails.env`, `Rails.env.development?`, `ENV[...]`) with that condition.
  A mounted app in the `routes`, `engines` and `onboard` lists and the generated
  context files, and a controller filter or skip declared under one
  (`before_action :x if Rails.env.test?`), carry it too, on both tiers; a skip
  under one leaves the filter in the chain, and the generated files no longer
  count such a filter as global. (#327)
- **`routes --detail full` prints each route's constraints and defaults** beside
  its path, as `bin/rails routes` does, on both tiers, and escapes the `|` in a
  merged `PATCH|PUT` or `via:` verb so each route stays one table row. (#279,
  #329)
- **Engine routes are counted.** Run from a mountable engine's root, `routes`
  and `onboard` list and count the engine's own routes instead of 0, including
  an engine whose namespace does not match its path (`PgHero::Engine` in
  `lib/pghero/engine.rb`). `engines` counts a loaded engine's routes the way
  `routes` does, PATCH and PUT as one, and counts its redirects and lambdas
  beside them (`23 routes, 2 redirect or lambda routes`). (#379, #380)
- **Booted from a mountable engine's `test/dummy`, the engine's own code is
  read.** `model_details`, `controllers` and the other class listings include
  the engine's own models and controllers, name their files relative to the app
  root (`../../app/models/...`), and list and render the views and layouts in
  the engine's `app/views`; `test_info`, `analyze_feature` and `generate_test`
  read the engine's test suite. With `--no-boot` the test tools read it too when
  the engine's bundle is inside the app's git repository. When it is not, the
  test framework reads "not read" in `test_info`, `onboard` and the generated
  context, where it said "no tests yet", and a `test_info` model or controller
  search says the engine's suite was not searched. `controllers` with
  `--no-boot` from a `test/dummy` says the engine above it is not read, where it
  listed no controllers and said nothing, and `view` and `partial_interface` say
  the engine's views are read only with the app booted. (#381)
- **`view` lists more templates.** Templates with no handler extension
  (`pwa/service-worker.js`, `pages/about.text`), which Rails renders with its
  raw handler, are listed and shown, each fenced by what renders it. View paths
  `config/application.rb` adds to `config.paths["app/views"]` are read, so a
  template under `app/views/custom` is listed as `posts/show` and an overlay
  such as `enterprise/app/views` is listed at all; `helper_methods` and
  `stimulus` read those paths too. On an API-only app that keeps the two mailer
  layouts `rails new --api` creates, `view` lists them instead of saying
  `app/views` does not exist. (#282, #338, #346)
- **`partial_interface` reads strict locals and implicit renders right.** A
  strict locals comment that ends in `-%>`, has a default with parentheses, or
  is the empty `locals: ()` (now said to accept no locals) is read. `render
  @posts` is credited to the partial Rails renders: under the view's controller
  namespace unless `prefix_partial_path_with_controller_namespace` is off
  (booted, as ActionView::Base holds it; unbooted, as `config.action_view`,
  ActionView::Base or an `on_load(:action_view)` block sets it in
  config/application.rb, the environment file or any initializer), or at the
  path a model's `to_partial_path` returns when it returns a string literal.
  `render @post.comments` goes to the partial of the records the association
  the model declares holds (its `class_name:` when it has one), a chain on a
  receiver that is no model (`current_user.posts`) goes to the partial of the
  records it names, a trailing call on a collection (`@posts.first`,
  `@posts.recent`) keeps that collection's records, and a chain the app's
  models cannot resolve, or a `through:` association that names its
  `source:`, is credited to no partial. The `view` tool's `renders:` list
  reads the call the same way. (#323, #324)
- **`schema` shows more of each column and table**, in both tiers: precision,
  scale, limit, the unsigned flag and collation, the table comment, unique
  constraints, a MySQL text or blob column's size (`size: medium`), index
  options (using, include, order), foreign key actions with the deferrable mode
  and `validate: false`, the enabled extensions, the primary key (a composite
  one as its columns, in `model_details` too, which also names a key the model
  sets with `self.primary_key =`, and the table's beside it when they differ),
  and with `--table` the check constraints (a MySQL one without the parentheses
  MySQL adds), the enum types its columns use with their values, and generated
  columns with their expressions. A `t.virtual` column is typed by its `type:`
  in every static source, migration replays included. (#290, #291, #292, #352)
- **`db/structure.sql` reads like schema.rb.** A structure.sql app gets the
  column types schema.rb gives the same table (hstore, citext, enum with its
  type, jsonb, timestamptz, binary, time, integer with its limit, unsigned),
  plus table and column comments, and its extensions; an index shows its method,
  order, operator class, prefix lengths and INCLUDE list, and a table its unique
  constraints. On SQLite, a table with a multi-line foreign key or a dump with
  no semicolons is read whole, and `sqlite_sequence` is not listed as a table.
  On MySQL, a `FULLTEXT KEY` or `SPATIAL KEY` line is an index with its type,
  not a column. (#348, #349, #350)
- **MySQL column types read as the dumper writes them.** A schema.rb column
  written as `t.column "kind", "enum('a','b')"` is listed with that type instead
  of dropped, and the booted tier names MySQL enum, set and timestamp columns
  the same way. (#351)
- **A schema.rb dumped with more than one schema names a public table by its
  bare name** (`users`, not `public.users`), so `--table users` and the `User`
  model find it; foreign keys, indexes and enum types follow. (#353)
- **The static tier reads the database the app configures.** The adapter comes
  from `DATABASE_URL` or `<NAME>_DATABASE_URL` when set, and from a `url:` in
  database.yml, as Rails merges them, and the replayed schema types its implicit
  primary keys by that adapter. The schema comes from the dump the app
  configures: database.yml's `schema_dump` name and `schema_format = :sql`
  (database.yml on Rails 8.0.3 and later, else
  `config.active_record.schema_format`, which Rails applies after every
  initializer, and only then `ActiveRecord.schema_format`); the doctor, schema
  version, tool guide, onboarding setup command and missing-table messages name
  the same file, a configured dump over `max_schema_file_size` is reported as
  too large, and a change to any `.sql` dump under `db/` refreshes the MCP
  cache. (#355, #357)
- **A table in a secondary database is found** by `schema --table`,
  `model_details`, `analyze_feature`, `diagnose`, `migration_advisor`, the
  controllers schema hint and the model resource. The table view names every
  database that holds it, and where one name holds different tables in two
  databases it shows each database's columns and models. `migration_advisor`
  passes `--database <name>` so the migration lands in that database's
  migrations_paths, and leaves out `foreign_key: true` on a reference between
  tables in different databases. A replica or a `database_tasks: false` entry is
  not listed as a database of its own. (#356)
- **Migration replay follows what Rails runs.** It reads migrations in
  subdirectories of `db/migrate` and in the migrations_paths database.yml sets
  (for the primary and for a secondary with no dump yet), and the migrations
  listing, the pending check and `doctor` read the same directories; a migration
  file symlinked from outside the app is not read, and a secondary database's
  line in `schema` names its pending migrations. A `revert` block is undone (a
  nested one runs forward), and `revert SomeMigration` counts as a statement it
  could not follow. One column is kept when both branches of an `if` declare it,
  temporary and `if_not_exists` tables are skipped, `as:` and `execute "CREATE
  TABLE"` tables are read (a heredoc over several lines too), check constraints
  are replayed, `rename_index` is followed, and `Migration[5.0]` tables get
  integer keys. An `execute` whose CREATE TABLE is built at run time counts as
  not replayed. (#360, #361, #362, #363)
- **Static primary keys and table names read as Rails reads them.** A primary
  key written as `id: { type: :string, limit: 36 }` is typed `string, limit:
  36`, and a model whose class, base class or app sets `pluralize_table_names =
  false` reads its singular table with its columns. (#358, #359)
- **`model_details` prints every association option** (`as:`, `counter_cache:`,
  `touch:`, `inverse_of:`, `extend:`, `before_add:`, the foreign key a
  `has_many` or `has_one` declares and the rest) and an extension block's
  methods; `callbacks` lists association callbacks; and `--no-boot` reads
  `required: false` as optional and `query_constraints:` as the foreign key (a
  `has_many` prints the option). (#296)
- **`model_details` reads more model declarations.** A `validate do ... end`
  block is a custom validation with its `on:`/`if:`/`unless:` and first line. An
  enum shows its `default:` and, with a prefix or suffix, the methods Rails
  defines (`kind_lead?`). A prefixed delegate names the methods it defines
  (`owner_name`) and `private: true` is marked. Each store column is listed once
  with its accessors, including the names `prefix:` and `suffix:` give. Columns
  dropped with `self.ignored_columns` are left out and listed on an "Ignored
  columns" line. `encrypts`, `normalizes`, `serialize` and `generates_token_for`
  show every option (`expires_in: 2.days`, or `never`), and a named
  `has_secure_password :recovery_password` keeps its name. A Mongoid document's
  schema hint in `controllers` names its collection and `_id` key instead of an
  empty table, and a field shows its default. An array constant wrapped in
  `Ractor.make_shareable` is listed under Constants. A validation, association,
  scope or enum written in a method nothing calls is not listed. (#302, #305,
  #306, #307, #309, #382, #391, #414)
- **`delegated_type`, `has_secure_token` and `accepts_nested_attributes_for` are
  read.** The static tier lists the polymorphic `belongs_to` that
  `delegated_type` declares, both tiers name its types (booted asks the model's
  `<role>_types` when the source names them through a constant, and the static
  tier names that constant as not read), and `model_details` lists
  `has_secure_token` and `accepts_nested_attributes_for` under Macros. (#365)
- **`callbacks` and `model_details` read callbacks as Rails registers them.** A
  callback the model removes with `skip_callback`, by name or by callback
  object, is not listed (a conditional skip shows as the negated condition). A
  callback object (`after_commit AuditTrail`, `before_validation
  PostNormalizer.new`) prints as the class or expression the model passes. A
  concern's `prepended do` block applies only to a class that prepends it, and
  its `included do` block only to one that includes it. (#303, #304, #310)
- **Models outside `app/models` are found**, in both tiers: in another `app/*`
  directory such as `app/domain`, or under a path `config/application.rb` adds
  to `eager_load_paths` or `autoload_paths`, when its superclass is a model. A
  class there that is not a model is left out even when it does not load, and
  the lib subdirectories `autoload_lib(ignore:)` names are not read. The static
  tier also finds models under a symlinked directory or file in `app/models`
  that points inside the app, a model assigned `Class.new(ApplicationRecord)`
  with what its block declares (the `self.table_name` it sets included), and
  merges a module prepended after the class body (`Note.prepend(EE::Note)`,
  GitLab's `prepend_mod_with("Note")`). (#344, #347, #413, #416)
- **Booted `model_details` no longer credits every model with a gem's base
  mixins**, such as Kaminari's two modules and `page` and `default_per_page` on
  the app's abstract base, or on a model that subclasses ActiveRecord::Base
  itself, which Kaminari reaches the same way. (#371)
- **Method listings read more of how Ruby defines methods**, in `model_details`,
  `concern`, `service_pattern` and every tool that reads a file's methods. A
  `private` inside `class << self` or a `concerning` block no longer hides the
  public methods and actions after it. `def Widget.x` is a class method,
  `private_class_method` methods are private, a `def self.x` after `private`
  stays public, and a `module_function` method is a module method
  (`self.total(items)`). Methods defined with `alias`, `alias_method`, `attr_*`,
  `define_method`, `class_attribute` and `cattr_*`/`mattr_*` are listed, an
  inline `private attr_reader :x` or `protected attr_writer :y` keeping its
  visibility, and `service_pattern` writes the class-side reader, writer and
  predicate a `class_attribute` defines with `self.`. A method in a scope or
  association extension block, a `concern :Name do` block, or a `Struct.new`,
  `Data.define`, `Class.new` or `Module.new` block is not the enclosing class's;
  one assigned to a constant is that constant's, and a `Module.new` held in a
  local is the enclosing class's, where it is included. (#297, #298, #308, #388)
- **A one-line or endless method is cut at its own line.** `callbacks` and
  `concern --detail full` show `def strip_name; end` or `def wrap_save = yield`
  under `(line N)` instead of running to the end of the class, and `search_code`
  trace cuts such a body the same way. (#301)
- **`search_code` finds more definitions.** Definition and trace modes find
  `private def x`, `def Widget.x`, `ruby2_keywords def x` and other modifier
  forms; trace counts a call inside an endless def body as a call site; class
  mode finds `class Billing::Ledger`, `class ::Top` and a constant assigned
  `Data.define`, `Struct.new`, `Class.new` or `Module.new`. (#300)
- **A compact class name resolves its superclass as Ruby does.** `class
  Api::UsersController < BaseController` gets the top-level `BaseController` as
  its parent and its filters, on both tiers. The static model list, job chains,
  service and component base detection, mailer chains and `generate_test` read a
  compact class the same way, so `class Admin::Thing < Base` is not a model when
  `Base` is a plain class. (#299)
- **`concern` lists a class that prepends the concern** under Included By.
  (#311)
- **`controllers` lists block, lambda and object filters, in the order Rails
  adds them to the chain** (after filters run last-declared first). A block or
  proc filter (`proc {}`, `Proc.new {}`) reads `block (line N)` and a lambda
  (`-> {}`, `lambda {}`) `lambda (line N)`, or `(line N of <file>)` when
  written outside the controller's own file (a concern's class method, an
  ancestor), each with its own `only:`/`except:`, in both tiers; every name a
  `before_action :a, :b` call gives is listed in the order Rails runs them (a
  lambda where it stands, the block last); the static tier reads
  `prepend_after_action`, `prepend_around_action` and `append_around_action`,
  each prepended filter at the front of the chain; `skip_forgery_protection`
  shows as the `verify_authenticity_token` skip it is. An object filter
  (`around_action TimingFilter.new`) reads `TimingFilter (object)` in both
  tiers, where the booted tier printed a memory address. The booted tier leaves
  out a block filter Rails or a gem adds (`allow_browser`, `rate_limit`), even
  when the bundle is installed under the app root. The static tier names a gem
  module the controller or one of its app bases includes
  (`include ActiveStorage::SetBlob`) as an included module not read, where a
  filter it adds would be missing, and leaves out a Rails module whose include
  adds no filter (`ActionController::Live`). `http_basic_authenticate_with` is a
  before filter with its `only:`/`except:`, never its credentials. (#293, #332,
  #335)
- **`controllers` reads strong params and delegated actions.**
  `params.expect(user: [tags: []])` reads as an array of scalars, and the
  summary lists nested keys, arrays and `key: {}` hashes beside the flat
  permits, a hash that names its keys with only those keys. An action defined
  with `def_delegators`, `def_delegator` or `delegate` is counted, so
  `controllers` and `validate` no longer report a route to one as missing.
  (#333, #334)
- **`helper_methods` lists the view helpers declared with `helper_method`** in a
  controller, a controller concern or a lib module the controller includes, each
  with the class or module that declares it. (#336)
- **`test_info` reads fixtures and factories where Rails and factory_bot load
  them.** Fixture files that open with an ERB line or use the `DEFAULTS` alias
  are read, subfolder sets such as `admin/posts` stay apart, `_fixture` and the
  labels its `ignore:` names are dropped, and directories a helper adds to
  `fixture_paths` are read (inside `RSpec.configure do |config|` too, on
  `ActiveSupport::TestCase` by name, and as a path built from `__dir__` or
  `__FILE__`); an RSpec `spec/fixtures` no helper loads gives no sets, and a
  file it cannot parse lists its labels. A fixture file that links out of the
  app or to a sensitive file is not read, here or by `generate_test` and
  `conventions`, and a file over `max_test_file_size` is named as too large. A
  label or value ERB computes (`row_<%= i %>`) is shown as ERB, and such a label
  is never written as a fixture key. Factories are found in `factories.rb`,
  `factories/`, `test/factories.rb`, `spec/factories.rb` and each pack's
  `spec/factories` and `test/factories` (both suites' when both exist). A helper
  that sets or appends to `FactoryBot.definition_file_paths` is followed when it
  then calls `FactoryBot.find_definitions` (added to the defaults
  factory_bot_rails already loaded) or `FactoryBot.reload` (in place of them);
  `config.factory_bot.definition_file_paths` is not read. Fabrication's
  fabricators are listed, `onboard` names Fabrication as the data setup of a
  fabricators-only suite, the generated context lists the fabricators directory,
  and a Cucumber `features/` tree is counted. (#313, #373)
- **`i18n` reads the locale files Rails loads.** `.rb` locales are read for
  their keys (the plural rule and transliteration settings under `i18n.plural`
  and `i18n.transliterate` are not counted as keys), `.yaml` files Rails ignores
  are not counted, files `config.i18n.load_path` adds or replaces (`+=`, `<<`,
  `=`) are listed and counted in both tiers, a sensitive file a `load_path` glob
  reaches is never read, and the Fallbacks section shows on a booted app whose
  `config.i18n.fallbacks` sets only default locales. (#314, #315)
- **Initializers in subdirectories of `config/initializers` are read** for the
  default locale, middleware, tagged logging, OmniAuth providers, component
  preview paths, CORS, Rack::Attack, inflections and the shard selector, and
  `config` lists them by their path, as Rails loads them at any depth. (#316)
- **`env` and `env_config` list what the app reads.** The environment variable
  catalog drops `RAILS_EAGER_LOAD` and `RAILS_EVENT_REPORTER`, which Rails never
  reads, and adds `SECRET_KEY_BASE_DUMMY`, `RAILS_DEVELOPMENT_HOSTS`,
  `RAILS_GROUPS`, `RAILS_CACHE_ID`, `RAILS_APP_VERSION` and
  `SOLID_QUEUE_IN_PUMA`. Credentials that decrypt to nothing are said to hold no
  keys. External services called as `Net::HTTP.get(URI("..."))`,
  `Net::HTTP.start("host")`, `Faraday.get("...")`, `RestClient`, `HTTP`
  (http.rb), `Excon`, `Typhoeus` or `URI.open`, and HTTP clients in `lib/` or
  `config/`, are listed; a loopback, private or unspecified (`0.0.0.0`) IP, a
  file name handed to a client, and a call in a comment or a string are not.
  `env_config` lists keys set with `<<`, `+=`/`||=`/`&&=`, an index write
  (`config.action_dispatch.default_headers["X-Frame-Options"] = "DENY"`), a
  write through an index read (`config.paths["app/views"] << "x"`), a method
  call or a block, and not a call whose value is used (`x =
  config.root.join("tmp")`), a method argument named `config`, or another
  library's config (`OmniAuth.config.test_mode`). (#317, #318, #319, #320)
- **`active_support` lists files that sign with
  `Rails.application.message_verifier`**, `message_verifiers` or
  `ActiveStorage.verifier`, and not a file that only rescues
  `MessageVerifier::InvalidSignature` or names one in a comment or a string.
  (#321)
- **`search_docs` finds the 21 Rails guides the index lacked** (upgrading,
  engines, autoloading, error reporting, generators, core extensions and more).
  A guide newer than the app's Rails links to main and says so, since the app's
  stable branch has no file for it. (#322)
- **`frontend_stack` names the asset pipeline and CSS and build tools.** A
  Propshaft or Sprockets pipeline is named (with Sprockets' `manifest.js` link
  lines), an app with no JavaScript build is said so, and an app is called
  API-only only when `config.api_only` is set. webpack, rollup or bun is named
  as a jsbundling-rails app's build tool, and `conventions` names Rollup and
  reads bun from the text `bun.lock`. `conventions` and `frontend_stack` name
  Tailwind CSS or Bootstrap on a `rails new --css` app. (#339, #340, #341)
- **`validate` checks Ruby syntax with the app's own Ruby grammar** (the running
  Ruby when booted, the declared one with `--no-boot`, or the running Ruby when
  the app declares none), so a file valid on Ruby 3.3 is not failed for a rule
  3.4 added. Ruby 3.1 and 3.2 are checked as 3.3, the oldest grammar prism has.
  An app that declares JRuby or TruffleRuby and no Ruby version is checked with
  the running Ruby's grammar, and a syntax error says so. (#342)
- **`autoload` lists every root Rails autoloads from**: app/models, app/lib,
  app/services and the rest, other engines' app/* directories, a directory an
  initializer adds with `push_dir` (with the namespace it loads under),
  autoload-once paths added through `config.paths`, and directories a loader
  keeps out of eager loading. (#345)
- **`job_pattern` reads more queues and schedules.** Channels show their
  streams, timers and actions without booting, a `periodically` timer with a
  block is listed in both tiers, and the connection says what it is
  `identified_by`. A job's schedule comes from the task that runs it (Solid
  Queue `config/recurring.yml` with its environment, sidekiq-cron,
  sidekiq-scheduler, GoodJob `config.good_job.cron` including `merge!`,
  whenever's `config/schedule.rb`); a job named only in a comment is not
  scheduled, and `--detail full` lists every recurring task, on an app with no
  job classes too. A schedule an ERB tag builds reads as computed. Without
  booting, queues are named as ActiveJob names them, with `queue_name_prefix`,
  `queue_name_delimiter` and `default_queue_name` applied, and a job with no
  `queue_as` is on the default queue in both tiers. A Resque job's `@queue` (or
  `def self.queue` when it sets none) and a Que job's `self.queue =` are read,
  Que::Job subclasses are listed with their `run` signature, and `run` is the
  entry point of a Que job only. (#330, #331, #366, #374)
- **`api` names the serialization layer and OpenAPI specs right.** Blueprinter
  blueprints, Alba resources and RABL templates are named; an Active Job
  argument serializer and a mixin module the serializers include are not counted
  as response serializers. A file is an OpenAPI spec only when its top-level
  `openapi` or `swagger` key holds a version number, found in `public/`, `doc/`,
  `app/` and `config/` as well; a docs site's `_config.yml` and locale files are
  not listed. A spec over the per-file read limit is still listed: the check
  reads only the first 64KB of each candidate. `gems` says rswag-api serves
  specs from its configured `openapi_root`, and names
  `config/initializers/rswag_api.rb` when the app has it. (#367, #368, #375)
- **`onboard` names auth and serialization like the other tools.** An
  "Authentication & Authorization" section covers Rodauth, Action Policy and
  Rails 8 generated authentication; the Devise model is named with its modules,
  those a concern's `included` block adds too; the authentication gem is still
  named when the only auth finding is policy classes. The API section names the
  serialization as `api` does and is left out when there is none. `gems` lists
  `action_policy` and `rolify` under auth. (#369)
- **`conventions` names more model patterns**: full-text search, tree structures
  and soft deletes from `pg_search_scope`, `multisearchable`, `has_ancestry`,
  `has_closure_tree` and `include Discard::Model`, multi-tenancy from
  activerecord-multi-tenant, and a `discarded_at` column as soft delete. (#370)
- **`component_catalog` reads more components.** The usage example for a
  `renders_many` slot calls the singular setter (`c.with_item do`), and the
  one for a polymorphic slot calls each setter its `types:` define. A component
  in the layout
  `phlex:install` generates types as Phlex, read from its root even outside
  `app/components` (`app/views/components`), and is named by the constant that
  renders it (`Components::Badge`). (#372, #378)
- **`performance_check` no longer suggests `counter_cache: true`** on a
  `belongs_to` whose count column `counter_culture` already keeps. (#376)
- **Rake tasks are read whole.** Tasks after a brace-form `namespace(:x) { }`
  are not put inside it, `task "a:b"` names and `multitask` are listed, and the
  Rakefile and `rakelib/*.rake` are read; a rake file symlinked out of the app
  is not. (#384)

## [5.31.0] - 2026-10-05

### Changed

- **A committed placeholder is not a secret.** A file whose name ends in
  `.example`, `.sample`, `.template` or `.dist` (`.env.example`) is readable by
  `rails_get_edit_context` and the other file tools, although the default
  `.env.*` pattern matches it, and `doctor` no longer lists it as unread or
  says to gitignore it. A `sensitive_patterns` entry that names the file
  exactly, with no glob characters, still blocks it, and so does a path
  pattern with a `/` (`.ssh/*` keeps `.ssh/id_rsa.template` blocked).
  Redaction treats the four suffixes alike. `rails_search_code` now drops
  sensitive files from ripgrep's output where it used to exclude them by glob,
  so a sensitive file ripgrep cannot open is not reported as an error and does
  not send a no-match search through the Ruby fallback. (#267)
- **`rails_query` on a SQLite file stops at `query_timeout`.** The query runs
  in a child process with its own read-only connection, which is stopped at the
  deadline. sqlite3 2.x's `statement_timeout=` interrupts any statement of more
  than a few thousand steps whatever the value, and the extension holds the GVL
  while a statement runs, so no in-process limit exists. The child takes the
  app's `extensions:` and waits on a locked database as the app would. An
  in-memory database, a platform without `fork`, or a query that needs a
  function, virtual-table module, collation or encryption key only the app's
  own connection has runs in-process; the table and EXPLAIN answers then say it
  ran without a time limit, and CSV output stays plain data. (#256)
- **`rails_get_callbacks` lists callbacks in the order Rails runs them**: base
  classes first, a concern's callbacks where its `include` line stands, then
  the model's own, and a `before_` or `around_` callback with `prepend: true`
  first. `after_commit` and `after_rollback` list last declared first, as
  Rails runs them, unless `run_after_transaction_callbacks_in_order_defined`
  is on (`load_defaults 7.1` or later). The static tier reads that from
  `config/application.rb` and the initializers, the last line that sets it
  winning, and when the config does not tell, `rails_get_callbacks` and
  `rails_get_model_details` say so. A method declared twice under one callback
  type shows the declaration Rails keeps, the later one, which corrects the
  5.30.0 entry that said each declaration is shown. A declaration inside a
  method body counts where the class calls the method, and not at all when
  nothing does, so an uncalled method that redeclares a callback no longer
  hides it. A call counts written bare or as `self.name`, made inside a class
  method it runs, or made from a concern's `included` block. A module joins a
  class chain once, at the first place the chain adds it: the outermost class
  that adds it, at its first include there, which can be a call to a class
  method that includes it. A Concern's `included` block runs there only; a
  plain `self.included` hook runs on every include. A call runs the definition
  Ruby's lookup finds as of the call: a module the class prepends to its
  singleton class, the class's own class methods, then the modules it extends
  and its concerns' class methods, the last added first, then the same for
  each base, then what every model has: class methods an initializer writes in
  `ActiveRecord::Base.class_eval` or a reopened base, the file Rails loads
  later winning (Canvas's `validates_locale` adds its `before_validation` to
  Account, User and Course), then the modules mixed into the base. One an
  initializer writes on `ApplicationRecord` replaces ApplicationRecord's own.
  A class's own class methods are its `def self.`, an `alias_method` in
  `class << self` (it runs what its original name ran at the alias), and those
  a Concern's `included` block or a hook writes on the class (`def self.x` or
  `class << self`, in the block, in `base.class_eval` or in `class << base`),
  each from its line where that code runs. A module counts from the line
  adding it, where that line runs: an `extend`, `singleton_class.include` or
  `singleton_class.prepend` (which counts as prepended) in the class, in a
  hook or in a Concern's `included` block, and an `extend` in a class method a
  call reaches (an `acts_as_x` that extends its methods, whose `self.extended`
  hook then runs); a plain module's nested `ClassMethods` counts only when
  something extends it. A module a hook includes runs its own hooks. Two
  concerns' modules of one name (each concern's `ClassMethods`) stay two: each
  name is the constant it resolves to where it is written, and one that
  resolves to nothing no longer hides the other. A `super` runs the next
  definition, at the `super`. An instance method or a nested class's method of
  the same name never runs. A module a class method includes joins only when a
  call reaches that method, and only calls after it see its methods. A nested
  class's callbacks are its own, and a module nested in the model's file reads
  like any concern: `include` runs its `included` block, `extend` its methods
  and `self.extended` only. A module a plugin's lib loads by a glob `require`
  is read from beside the file naming it, and from its definition rather than
  an empty namespace stub above it, so OpenProject's journalized models list
  `save_journals`. A Mongoid document's own callbacks list in the same run
  order, one in a class method where the document calls it. Neither tier
  evaluates `send`, `define_singleton_method` or a module included in
  `class << self` for this, so the list can miss what they register or show
  the definition they replace. (#253)
- **A lambda or Proc given to `queue_as` reads as what ActiveJob does with
  it.** ActiveJob never calls it; it names the queue after the Proc's text.
  Both tiers now say so, with the source, where the booted tier printed the
  Proc's address and the static tier called it computed. A `queue_as` block is
  the computed case and now shows its source too; a block argument
  (`queue_as(&pick)`) reads as computed in both tiers. The 5.30.0 entry used
  `queue_as -> { ... }` as its example of a computed queue; that was wrong.
  (#271)
- **An MCP stdio session carries nothing but JSON-RPC on stdout for its whole
  life.** Output written during a tool call (a logger built on first use, as
  Sidekiq's is, `puts`, a child process) goes to stderr; only boot was guarded
  before. (#255)
- **The booted `rails_security_scan` parses in its own process.** Brakeman's
  forked parse workers could not return a parse error from an app that loads
  web-console, and the scan failed where the static tier scanned. (#257)

### Fixed

- **A concern's declarations name the module the include resolves to.**
  `rails_get_callbacks` on OpenProject's WorkPackage lists
  `after_save :save_journals` from `Acts::Journalized::SaveHooks`, where it
  said `SaveHooks`.
- **A module declared in its outer module's file is read from there.**
  Canvas's `Role::AssociationHelper` lives in role.rb, and its `included`
  hook adds `before_save :resolve_cross_account_role` to Enrollment and its
  subclasses, AccountUser and RoleOverride; the static tier called the
  module unread and missed the callback. `rails_get_callbacks`,
  `rails_get_model_details` and the controller filters and actions find it
  there and read that module, not the outer class.
- **`rails_get_callbacks` lists models of one callback count by name**, so a
  model gaining a callback no longer moves the sections around it.
- **A model macro written over `*args` reads each call's own arguments.**
  The list binds to the call's positionals past the method's other
  parameters, less the options hash the body takes off the end
  (`args.extract_options!`), plus literals its leading statements push. A
  block over the list is read once per item, so Canvas's
  `validates_locale :locale, :browser_locale, allow_nil: true` lists an
  inclusion validation on each field with its own `if: :<field>_changed?`, in
  place of the macro's own row and one on a computed `field`. An options
  hash, list or parameter the method changes in place (`options[:x] = 1`,
  `options[:x] ||= 1`, `reverse_merge!`, `delete`) is not read as the call's
  value. A declaration it decides, the method name included (`before_save
  name` after `name.strip!`), is held back and listed under "Not decided from
  the source (the method name or a condition)", the heading that was "Only
  under a condition the source does not decide".
- **A `load_defaults` written after `belongs_to_required_by_default = false`
  turns the default back on** in the static tier, as Rails does, so the
  implicit presence of a required `belongs_to` is listed. A literal assignment
  used to win wherever it stood. A value the source cannot evaluate
  (`ENV.fetch(...) == "true"`), app-wide or in the class, makes the presence
  conditional on it, named in the answer. A literal `nil` reads as off, as
  Rails reads it, here and for the commit-order setting. A `belongs_to` with
  `required: nil` is optional, and `required:` decides over `optional:` when
  both are written, as in Rails.
- **`rails_get_callbacks` prints `on:`** for validation callbacks and any
  callback whose type does not already name the event, before `if:` and
  `unless:`. (#252)
- **`rails_performance_check` with `model` and `category` counts only what it
  lists.** (#265)
- **`rails_search_docs` caches a fetched guide whole.** A guide with non-ASCII
  text failed to write in the booted tier and left an empty file that read as a
  cached guide for 24 hours; the write is now binary and atomic, and an empty
  cache file is a miss. (#266)
- **`rails_search_code` trace finds one definition and no sibling of itself**:
  `qa_ping` no longer matches `def qa_ping?`, `qa_ping!` or `qa_ping=`, and
  `def self.qa_ping` is left out of its own sibling list, where a setter now
  appears. Every method-body lookup (concerns, callbacks, actions, conventions)
  ends a name the same way, and ripgrep and the Ruby fallback agree on
  non-ASCII text, where any character outside ASCII is part of the name, as
  Ruby reads it. (#258)
- **`rails_search_code` call sites skip comment lines** with the rule trace
  uses, by file type: `#` in Ruby, `//` and `/*` in JS and TS, `/*` in CSS and
  `//` too in SCSS, Sass and Less, `-#` in Haml, `/` in Slim. A stylesheet
  line that starts with a `#id` selector is not a call site either. A line
  holding a live ERB tag is a call site, and a spaced setter call
  (`obj.qa_ping = 1`) is not a call of `qa_ping`. (#269)
- **Both search backends read the same excludes file.** The Ruby fallback read
  `core.excludesFile` from the repository's own config, which ripgrep does not.
  It now reads what ripgrep 15 reads: `~/.gitconfig`, then the XDG git config,
  then the default ignore file. (#268)
- **A `db/structure.sql` table that `INHERITS` reads its parent's columns
  first, then its own**, with multiple parents, chains, a parent defined later
  in the file, and `ALTER COLUMN ... SET NOT NULL`/`SET DEFAULT`. A parent in
  another schema resolves; one the file does not define is named. An index, key
  or foreign key lands on the table its statement names, schema included. The
  one-line form read its column type as `integer) INHERITS (...`. (#259)
- **A Stimulus controller under `app/javascript/controllers` keeps its
  identifier** when another `controllers` directory holds the same path, and a
  nested `controllers` directory stays in the name (`admin--controllers--x`).
  (#264)
- **`query_allowed_columns` exempts a column from result redaction too**, as
  it does from the pre-query check. Columns declared with `encrypts` stay
  redacted. (#270)

## [5.30.2] - 2026-10-01

### Changed

- **`generate_root_files: false` leaves out `.cursorrules` too, and always
  writes `.ai-context.json`.** `.cursorrules` is the same compact file as
  `CLAUDE.md` at the repo root, so it is a root file and now reports "Not
  applicable (root files disabled)". `.ai-context.json` is data for tools, not
  an instruction file, and is written whatever the key says.
- **`serve --port` has no default of its own.** An explicit `--port` wins, then
  `http_port` from the config, then 6029. The config key never reached `serve`
  before, although `docs/STANDALONE.md` documents it, and the
  `streamable_http` alias ignored `--port`.
- **A PostGIS connection is labelled PostgreSQL everywhere.** The booted schema
  said PostGIS and the static tier PostgreSQL for the same app. The raw adapter
  name stays in `.ai-context.json` as `adapter_source`.
- **The booted schema header lists pending migrations**, as the static tier
  already did.

### Fixed

- **No machine path in an introspector's error.** A model file that could not
  load put the absolute path of the app into `rails_get_model_details`,
  `CLAUDE.md`, the models rules file and `.ai-context.json`, and the controller,
  component, middleware, migration and rake-task errors did the same. Every
  section's errors are now written relative to the app root, the resolved
  `/private/tmp` form included.
- **A declared, unmigrated table names the migration that adds it.** The booted
  answer said the table was missing from the database and stopped there. Rails
  7.2+ refuses to load a migration dated in the future, which also emptied the
  pending list; the list now comes from the applied versions and the files.
- **An unreadable model file still counts as the model file for its table**,
  instead of listing the table under "Tables with no model file".
- **The static tier carries each `belongs_to` foreign key.** Static
  association records had none unless the source spelled one, so
  `rails_get_model_details`, the context files and `.ai-context.json` left it
  out, and `rails_validate` stayed silent on an unindexed key where the booted
  tier warned. A polymorphic key indexed as `[type, id]` counts as indexed.
- **A composite foreign key in `db/structure.sql` is read**, pg_dump and
  mysqldump both, and renders as a column list like the schema.rb one.
- **Minitest tests from `rails_generate_test` can pass.** Absence,
  confirmation, acceptance and exclusion validations asserted on a valid
  fixture; each now sets up an invalid record, or emits `skip` where it cannot.
- **A mount at a computed path prints no path.** `mount X => ENV.fetch(...)`
  printed `` at `[INFERRED]` ``, a bare constant printed its name as the path,
  and a gem engine mounted that way read as "not mounted by the app's routes".
  A path written without its leading slash gets one, as Rails does.
- **Static routes say which engine tables they could not read.** An engine
  whose routes live in its gem (PgHero, LetterOpenerWeb) dropped out of the
  static answer with no note; it is listed under "Mounted engines whose routes
  were not read". A constant the app defines counts as an engine only when it
  subclasses `Rails::Engine`. An engine mounted at several paths is one line
  naming each.
- **Booted filter attribution matches the static tier.** An inherited
  `after_action` lost its "from" credit when the child declared a
  `before_action` of the same name, filters from a controller concern were not
  credited to it, and a concern's `only:`/`except:`/`if:`/`unless:` and its
  `skip_*_action` calls never reached the booted record. A body that
  re-declares a concern's filter owns it, and a concern an ancestor already
  includes stays the ancestor's.
- **An ERB comment is not read for instance variables**, while a Ruby comment
  line inside a multi-line code tag no longer hides the code after it.
- **`rails_get_partial_interface` finds `render(partial: ...)`** with
  parentheses, on one line or several, counts a nested render once, and a
  multi-line snippet stops at the call's end.
- **Jobs on Rails 7.0 to 8.1.** A job with no `queue_as` read as "computed by a
  block", since ActiveJob's default queue is a lambda; it now shows the
  resolved default. The booted tier dropped every `retry_on`/`discard_on`, and
  a job in a code root Zeitwerk does not manage.
- **A mailer outside `app/mailers` is a mailer in the booted tier too**, and
  `rails_get_service_pattern` no longer answers a mailer, concern or mixin by
  name when its listing leaves them out.
- **`app/concerns` reads as `other`** when the app root directory is itself
  named `app`, as in Docker's `/app`.
- **The static default locale reads `Rails.application.config.i18n`** in an
  initializer, where the last assignment wins.
- **A bad value for a required enum fails the call.**
  `migration_advisor --action bogus` said "action is required" and exited 0;
  it says `bogus` is not a valid `action`, names the allowed values and exits 1.
- **`rails_diagnose` never suggests a path it refused**, refuses it with or
  without `--line`, and prints the tier footer once.
- **`rails_validate` names a `belongs_to` whose key column the table lacks**
  instead of calling that column unindexed, and says nothing about a table's
  indexes when its schema calls a helper the reader cannot interpret (Canvas's
  `t.replica_identity_index`), since that helper may add the index.
- **A multi-name `t.references :a, :b, :c` adds every column**, with its index
  and foreign key, in the schema.rb reader and the migration replay. The replay
  also records `foreign_key: true` on a single reference, which it dropped.
- **A declaration inside a block the model may not run is kept but not
  trusted.** `has_details_table do belongs_to :parent end` put a `parent_id`
  key on the model's own table, and `rails_validate` checked it there. Such
  declarations are still listed, and `rails_validate`'s schema, column and
  `:dependent` checks skip them. `with_options`, `included`, `class_methods`,
  `concerning`, `state_machine` and `aasm` blocks run on the model and are
  trusted as before.
- **A foreign key given as a constant or an expression is not read as a column
  name**, and a composite key stays a column list in both tiers instead of the
  text of a Ruby array.
- **Every column type reads as a column in the static schema**, `t.vector`,
  `t.citext`, `t.enum`, the range and PostGIS types included, and so does a
  column whose options sit in braces. They were left out of the table.
- **`attr_reader` and `alias_attribute` names count as attributes** for
  `rails_validate`'s "column not found" check.
- **Filters inherited through a Devise or Doorkeeper controller.** The static
  walk stopped at the gem class, so a controller under `Devise::` or
  `Doorkeeper::` lost every filter its app base declares and was credited with
  a concern that base already includes. It now continues at the base the gem's
  initializer names (`parent_controller`, `base_controller`).
- **In-repo route files are read statically.** A mounted in-repo engine's own
  routes are listed under its mount, and a file that draws, appends or prepends
  to the app's routes adds to the app's table; only an unmounted engine's file
  still counts as not read.
- **A failed boot names missing gems once.** A bundle missing many gems listed
  every name three times; the banner now gives the count and the first few,
  and `doctor` and `DEBUG=1` keep the full list.
- **A test file over `max_test_file_size` is named as too large**, not missing.
- **`rails_runtime_info` says how many rows it left out** of the unused-index
  list and the summary table sizes, which it cut at 10 and 5 with no note.
- **`rails_query` on MySQL** reads a `MAX_EXECUTION_TIME` interruption as the
  timeout, and names `INTO OUTFILE`/`DUMPFILE` as a disk write.
- The defaults in `configuration.rb`'s comments match the values it sets.

## [5.30.1] - 2026-09-28

### Fixed

- **A PostgreSQL partitioned table is one table wherever its partitions can be
  told apart.** The booted schema listed each partition as a table of its own,
  repeating the parent's columns, indexes and keys, and one app went from 98
  tables to 211. The schema.rb and structure.sql readers did the same with the
  partitions Rails and pg_dump write out, and schema.rb's copies of the parent's
  foreign keys and check constraints came with them. A foreign key to a
  partitioned table, which PostgreSQL clones once per partition, is listed once.
  A schema.rb from before Rails 8 does not mark partitions, so the booted schema
  asks the primary database which tables are partitions. Everything else that
  reads such a file, the static tier and a secondary database's dump included,
  still lists them. A table that inherits another through `INHERITS` is not a
  partition and keeps its own entry. (#250)
- **Database stats and `rails_runtime_info` count a partition as part of its
  parent.** Row counts and table sizes, which listed the parent at zero or left
  it out, add each partition's rows and bytes to it, and index usage, which
  listed an index once per partition, names it once. All three break ties by
  name. On PostgreSQL 10 and 11, which lack `pg_partition_root`, they still list
  each partition. (#250)
- **A foreign key over more than one column reads as a column list.**
  `rails_get_schema` and `rails-schema.md` printed a Ruby array literal for its
  columns, `["event_id", "event_day"]`, and now write `(event_id, event_day)` →
  `events.(id, day)`. `rails_validate` warned that such a key had no index even
  when one led with its columns, with a generator command Rails cannot run, and
  now suggests one `add_index` over the columns. A foreign key to a partitioned
  table spans more than one column whenever the partition column is not its key.
- **A PostGIS app gets PostgreSQL's answers.** `activerecord-postgis-adapter`
  reports `PostGIS` for what is a PostgreSQL connection, and matching only
  `postgresql` sent `rails_query` down the unguarded path with no READ ONLY
  transaction and no statement timeout, skipped database stats and
  `rails_runtime_info`'s table sizes and index usage, and dropped
  `rails_migration_advisor`'s Strong Migrations warning for an `add_index`
  without `algorithm: :concurrently`.

## [5.30.0] - 2026-09-28

A pass over the whole tree for code that did not need to exist, with one base
class for the introspectors and one for the serializers, and one reader where
several files each kept a copy. Then four real-app QA passes in every tier
(Mastodon, Discourse, OpenProject, Canvas, Forem, Whitehall, Consul,
OpenFoodNetwork, Huginn, Errbit, Diaspora, Plots2 and a private API app) and
five review rounds found the wrong answers below. Their fixes grew `lib/` by
about 8,500 lines, most of it reading what the gem used to guess.

### Added

- **`rails_get_engines` and the generated files name the app's own in-repo
  engines, plugins and modules**: an "In-Repo Engines" section with each
  one's path and the models the model scan found under it (unavailable, not
  zero, when the model scan failed), and
  in the compact files one Stack line, `- In-repo engines: 4 (catalog,
  dfc_provider, order_management, web)`, capped at five names.

### Changed

- **`.github/copilot-instructions.md` is built the way CLAUDE.md is.** It was
  the one root file off the shared compact renderer. It now carries the same
  sections (Async, Migrations, Commands, Rules), per-model counts, "Key models
  (N total)" with 15 models where it listed 25, and the `Generated by
  rails-ai-context` line; "Conventions" becomes "Rules". Its tool reference is
  the compact list plus the roster of every tool name, where it had a
  Copilot-only table with one described row per tool and a "detail parameter -
  ALWAYS start with summary" section. The file is capped by `claude_max_lines`
  and ends with the trim note when it runs over. Its docs promised a 500-line
  cap that nothing enforced.
- **`claude_max_lines` counts content lines, the `BEGIN`/`END` markers
  included, and must be positive.** Blank lines between sections do not spend
  the budget, so a file that fit before still fits and still ends with the
  full MCP tools guide. A file over the budget keeps its Commands, Warnings,
  Rules and MCP tools sections whole and trims the data sections above them,
  with the trim note at the cut and no heading left without its body; it
  trimmed from the end, so the tool list and the last rules were what went. A
  budget too small for those sections alone still trims from the end. Zero or
  a negative number raises `ArgumentError` when set in Ruby, the way
  `cache_ttl` and `max_tool_response_chars` already do; in
  `.rails-ai-context.yml` it warns and keeps the default of 150.
- **The four compact files print their sections in one order**: Stack, Key
  models, Gems, Architecture, Commands, Warnings, Rules, Tools. AGENTS.md moves
  its MCP tools guide from the middle to the end and its Warnings block above
  Rules, which is where CLAUDE.md already had them.
- **`views.layout_mapping` is gone from `.ai-context.json`.** It globbed the
  layouts a second time to hold the names `views.layouts` already carries.
- **`rails_read_logs` and `rails_runtime_info` print sizes through
  ActiveSupport**: binary units and three significant digits, so read_logs
  says "2.29 MB" where it said "2.4 MB", runtime_info says "1 GB" where it said
  "1.0 GB", and a count under a kilobyte reads "512 Bytes" where it read
  "512 B". Both print in English whatever the app's `I18n.locale` is, and in
  the app's own locale only when it offers no English at all. The two tools
  used to disagree on what a megabyte was.
- **`rails-ai-context tool --list` trims each description at a word boundary
  to at most 79 characters, ellipsis included**, and a cut that lands on
  trailing punctuation drops it before the ellipsis.
- **`tools/list` is sorted by MCP tool name, and `rails-ai-context tool --list`
  prints its short names in that order.** That is the order v5.29.0 happened
  to print; it no longer depends on which tools a process loaded first.
- **A failed section is recorded in one place.** The introspection loop turns
  a failed section into its `{ error: }` entry and prints a warning, so a
  section that used to fail without a warning now shows one, and `doctor`
  names the exception class ("database_stats: StandardError: Database not
  found"). The entry itself is unchanged. Only `credentials` still records its
  own failure, to keep the exception message out of the output.
- **`init` and `version` answer an unexpected error like every other
  command**: `Error: <message>` on stderr and exit 1. One rescue around
  Thor's command invocation replaced eight copies; Thor's own refusals keep
  their wording. With `DEBUG` set, the first 15 backtrace frames follow the
  `Error:` line.
- **The doctor's view-size hint names only `config.max_view_total_size`**, the
  setting its check compares against, and the generated initializer's comment
  for `max_view_file_size` says no check reads it. The option is still
  accepted.
- **The gem requires `thor >= 1.2`.** Thor 1.0 and 1.1 raise `NameError` on
  require under every Ruby this gem supports.
- **The packaged gem leaves out `demo/`**, 525KB of GIFs the README loads from
  GitHub, `gemfiles/`, the CI's own Gemfiles, and `docs/social-preview.html`, a
  one-off screenshot page. The .gem drops from about 1.29MB to about 780KB.
- **The security policy says only the latest 5.x release gets fixes**, in
  place of a version table that stopped at 5.7.x.
- **The release runs the same Ruby and Rails matrix as CI**, from one shared
  workflow whose test legs get read-only repository access. It used to skip
  Ruby 3.2 with Rails 8.0 and 8.1, which CI already ran green.
- **Introspection reads each source once where it used to read it again**:
  auth, Active Storage, turbo views, seeds, conventions, job channels, the
  Gemfile, ActiveRecord and Mongoid models, each migration the schema replays,
  `db/migrate`, and the doctor's view count. Where one walk now answers several
  lists (Active Storage's attachments, validations and variants), a walk that
  fails leaves those lists empty together.
- **With `DEBUG` set, a skipped scan prints `<label> failed: <message>`**, the
  shape every other debug line in the gem already had.

- **A static route count says how many in-repo engine route files it did not
  read**, everywhere a route count is printed: `rails_get_routes`, CLAUDE.md,
  the rule files, `rails_onboard` and the rake summary. An engine draws its
  routes into its own table and the app mounts it at boot, so the static tier
  cannot place those paths.
- **`rails_get_i18n` and the generated files say what the in-repo engines'
  own locale directories hold that they did not read**: the tool and the
  full file count the files, and the compact files' I18n line ends
  `; 29 in-repo engine locale dirs not read`.
- **The component catalog reads every `app/components`**, packs and in-repo
  engines included, and its header counts what it could not place, as in `998
  components (862 ViewComponent, 0 Phlex, 136 of no known base class)` on
  OpenProject, which read 559 from its root tree alone, with a base that other
  components inherit from (Consul's two `BaseComponent`s) named on a bases
  line and not counted; the generated files print the same line from the same
  numbers. `component:` takes a name with or without its namespace or
  `Component` suffix, and a short name several components share lists them and
  asks for the full one.
- **`rails_get_active_support` lists validator classes apart from concerns**,
  so its concern total matches `rails_get_concern`, and a concerns directory
  holding only validators says so.
- **A condition prints the line the file holds.** A callback, concern
  callback, validation or controller filter whose condition is a lambda, a
  proc or a method call prints that source on one line where it printed
  `[INFERRED]`, and a symbol prints as a symbol (`if: :published?` and
  `on: :create`, where they read `if: published?` and `on: create`), in a
  list as well (`if: [:a?, :b?]`). A
  callback with `if:` or `unless:` now names the condition in
  `rails_get_model_details` and `rails_get_callbacks`, each declaration its
  own when one method is declared twice, and a filter that runs names its
  own condition in every surface that lists filters, where only a skip's
  printed. The same
  goes for any validation option that is not a literal (a regexp, a
  constant) and for an option nested in another one, as in
  `inclusion: { in: proc { ... } }`.
- **`rails_dependency_graph` draws no node for an association whose
  `class_name` is computed at runtime**, where it drew one named `_INFERRED_`,
  leaves them out of its association count, and names up to ten of them in
  a note that says how many the count leaves out. The same goes for an
  association it cannot name. Its footer says how many edges the page drew
  beside the associations they came from, so the numbers reconcile with the
  diagram.
- **An association whose name is computed is marked `(computed)` wherever it
  prints** (`` `owner_name` (computed) ``, and
  `` `:"#{name.underscore}_search_data"` (computed) ``), where it printed
  `[INFERRED]` (six times in Discourse's CLAUDE.md). No tool reads it as a
  literal: `rails_dependency_graph` draws no node for it,
  `rails_generate_test` writes no matcher for it, where it wrote a spec that
  did not pass, and the related-model and N+1 checks name no model for it. A
  computed `class_name` or `through:` prints its source too.
- **A `class_name` written with a leading `::` names the class it names**
  (`class_name: "::Token::API"`), in every tool and generated file.
- **The generated files rank "Key models" by association count**, most
  connected first and then by name, through the same function `rails_onboard`
  uses, and the heading says so. A subclass ranks by the associations it adds
  to its parent, so one that only repeats them sinks and one with many of its
  own (OpenProject's `User`) stays: Huginn's list was `Agent` and 14 of its
  subclasses, with no `User`, `Event` or `Scenario`, and Discourse's was
  headed by `Chat::NullUser`. They listed the first 15 by name, and
  `rails_onboard` broke ties in file order.
- **The controller count beside a route count reads "routed controllers"** in
  CLAUDE.md, AGENTS.md, `rails_onboard` and `rake ai:inspect`, since it counts
  the controllers the routes name, not the controller files.
- **A Stimulus controller is named by its Stimulus identifier**, from its path
  under the `controllers` directory (`users--tools--ajax`), and a lookup takes
  the identifier, the file path with slashes or underscores, or the file name
  (`ajax_controller.js`), a file name several controllers share listing them
  all. Its "Used in" list reads the same files that confirm a name, views
  first. Outside the rails-new `app/javascript/controllers` home the app's own
  loader decides the name, so a name the app registers in its JavaScript
  (`application.register("x", Klass)`, `preregister('x', Klass)`, literal
  strings, the class as the whole argument, a module imported through the
  app's alias table in tsconfig or jsconfig `compilerOptions.paths`, read
  through `extends`, or a literal vite, webpack or rspack `resolve.alias`
  (matched as the bundlers match, an exact key exact), test files not counted)
  is used, and otherwise a derived name is checked against the identifiers the
  app writes in any template or Ruby file under its code roots and `lib`
  (`data-controller`, a target, an action, a `content_controller`-style
  helper, a `data: { controller: }` hash in a component, form object or model)
  and takes the one they use; one nothing confirms carries a note that it is
  inferred. No two controllers share an identifier across code roots: an
  in-repo plugin's `foo_controller.js` beside the app's reads `chat--foo`,
  marked inferred. A controller the app registers from an installed package
  (Errbit's `reveal` from `@stimulus-components/reveal`) is listed as
  registered from that package, where `rails_get_stimulus` said none while
  `rails_get_view` showed it. OpenProject's 161 read the names its code writes
  (`admin--custom-fields`, not the path's `dynamic--admin--custom-fields`),
  and the few nothing confirms are marked inferred, named by their directory's
  rule when the app shows one (a loader importing the directory by a derived
  path, or confirmed neighbours that all drop its segment), so OpenProject's 8
  read `generic-dialog-close`, not `dynamic--generic-dialog-close`. The empty
  answer names the directories searched, and `rails_get_conventions` labels
  the pattern `Stimulus controllers` with no directory after it.
- **The frontend framework is picked by config files and component counts**, a
  tsconfig read with its comments, trailing commas and `extends` (a `tsc
  --init` file read `TypeScript: disabled`), and a second framework the app
  also uses is named. An Angular app that also depends on React read as React,
  and so did a Preact or Solid app that lists `react` for compatibility. Each
  framework reports its own version, and a frontend root counts the components
  its framework writes (OpenProject's `frontend` has 305 `*.component.ts`; it
  read 3).
- **`rails_get_test_info` names both frameworks** (`rspec, minitest`) when an
  app runs both.
- **The conventions' Locales line names the locales each file declares** (a
  `validates_timeliness.en.yml` read as a locale named
  `validates_timeliness`), a class named from the root scope (`class ::Foo`
  inside a module) is the top-level constant, and an unread `database.yml`
  default is never shown as another site's default.
- **The generated files' Multi-Database section labels each adapter the way
  every other surface does** (`PostgreSQL`, `MySQL by database.yml default`),
  where it printed the raw adapter name, and prints `unknown` for one it
  cannot read instead of nothing.
- **`rails_get_partial_interface(partial:)` given a bare name that several
  partials share lists them**, where it answered with the first by path, and a
  call to a helper the app defines (in `app/helpers` of any code root, or a
  module those helpers include from any autoload root; a module's class
  methods are not helpers) is not one of a partial's locals: Discourse's
  `layouts/head` listed `canonical_link_tag` and three more.
- **A context run reads more of the app, for more time where there is more to
  read.** Where a kind of code lives is resolved once per root, each file is
  parsed once per run and answered from its stat after that, a mixin is walked
  once for every model that includes it, and a CLI tool call loads only the
  tool it names; none of it outlives a run, so a directory created while a
  server runs is seen by the next one, and a file's stat stands in for reading
  it only once the file is two seconds older than the read, so a same-size
  edit right after a parse on a coarse Linux clock is read again. The CLI
  picks between a built-in tool and a custom one of the same name as the MCP
  server does: the built-in, unless `skip_tools` names it. On the static tier,
  `context --format all` takes about the same CPU as 5.29.0 on Canvas (17.4s
  against 18.1s), Mastodon (2.8s against 2.7s) and Errbit, a sixth more on
  Huginn (1.1s against 1.0s), a quarter more on a private API app (3.1s
  against 2.5s; booted 5.4s against 4.7s), where the `Services:` line reads
  all its services, and half again on OpenProject (9.4s against 6.4s), whose
  30 in-repo modules are now read for models, Stimulus identifiers, concerns,
  mailers and model bases.
- **The generated files' `Async:` line counts Sidekiq workers** beside jobs and
  mailers, and `rails_get_job_pattern` names the directories it read under
  every listing and also searches `app/sidekiq` for what enqueues a job. The
  `Jobs:` line lists what the job scan found, jobs and workers alike, up to 12
  names and a count of the rest, where it globbed `app/jobs/*.rb`.
- **A worker entry says what a job entry says**: its line count, the
  `retry_on` and `discard_on` it declares and what it calls. Where a base
  class owns `perform` and the worker defines `execute`, as Discourse's jobs
  do, `execute` is read instead.
- **A class in a job directory that reaches neither ActiveJob nor Sidekiq but
  defines `perform` is listed as `[unknown base]`**, as a Resque job is, and
  counted under an `unknown` queue rather than the default one, in both tiers.
- **A job's "Enqueued By" list names only the files that enqueue that job, and
  every one of them.** It is read off the call nodes, with one enqueue rule
  shared by the job and service side effects, the controller render map and
  `rails_search_code`'s "Calls internally", so a call in a comment does not
  count and Sidekiq's `perform_in`, `perform_at` and `perform_bulk` and
  ActiveJob's `perform_all_later` do (a private API app listed 3 of the 6
  files that enqueue one of its workers); a call through the app's own
  `enqueue`, `enqueue_in` or `enqueue_at` helper counts, the job named by a
  symbol, a string or the class (Discourse's `Jobs.enqueue(:process_post)`
  lists `app/models/post.rb`, where Discourse jobs had no callers); all of
  `app/` and `lib/` is searched, rake tasks, `bin/` and `script/` programs and
  all of `db/` included, and a list capped at twenty says how many more there
  are; a job named relative to the caller's namespace (`SyncJob` inside
  `module Admin`, in a method or a class-body block such as a callback) is
  credited to the job Ruby resolves it to, a compact `class A::B` nesting only
  itself as Ruby does, not a top-level one of the same short name; and a job
  nothing enqueues says so in one line where the section was left out. A call
  on another job whose name ends the same way (`Admin::SyncJob.perform_async`
  for `SyncJob`) counted, and the job's own file was left out by a substring
  of its name, which dropped any file whose name contained it and kept the
  job's own file under a folder spelled with an acronym; the file is now left
  out by the constant it declares.
- **A job shows the queue and Sidekiq options it inherits from the app's own
  base classes**, its own settings winning key by key, each inherited one
  named once with its base and its value when short. Diaspora's `Mail::*`
  workers showed no queue where `Mail::NotifierBaseWorker` sets `queue: low`,
  Mastodon's `Fasp::*` workers none where their base sets `fasp`, and
  Whitehall's `PublishingApi*Job`s none where theirs sets `publishing_api`.
- **A job queue computed by a block or an expression says so, with its
  source**: `queue_as -> { ... }` read `dynamic` in the booted tier and showed
  no queue without boot.
- **A class is a job base only when its own chain reaches ActiveJob or a
  Sidekiq mixin.** OpenProject's `Meetings::PDF::Common::Styles::Base`, a PDF
  style class under `app/workers`, was listed as a job base.
- **A mailer kept in `app/services` is a mailer and not also a service**, and
  a service not found is offered the constants the files declare
  (`ActivityPub::...`, where it offered `Activitypub::...`).
- **A module other classes in the app include, extend or prepend is not a
  service object**, unless it has an entry point of its own (a class method
  other than the `included`, `extended` or `prepended` hook,
  `module_function`, `extend self`). Whitehall's `AssetManager::ServiceHelper`
  was listed as a service, as were 11 mixins in a private API app and 11 in
  OpenProject; the generated `Services:` line follows.
- **`rails_get_service_pattern` and `rails_get_helper_methods` find a service
  or helper by the name the app writes when its path uses a registered
  acronym.** Mastodon's 20 `ActivityPub::...` services, in `activitypub/`,
  answered not found and suggested `Activitypub::...`.
- **The generated files' `Services:` line reads the same scan
  `rails_get_service_pattern` lists from**, so a service in a subdirectory, a
  pack or an engine appears; it globbed `app/services/*.rb`, which gave a
  private API app, whose services are all namespaced, no line at all. It and
  the `Jobs:` line show 12 names and say how many more there are, in every
  tier: the static tier dropped both with the conventions it cannot read.
- **A blank name given to a by-name lookup is answered as blank**, naming what
  the tool looks up ("The concern name is blank"), in the helper, service,
  job, mailer, component and concern tools: Discourse's
  `rails_get_helper_methods(helper: "")` crashed on a file named `helper.rb`.
  A string passed on the command line or in a direct call where a tool takes a
  list (`files`, `include`, `checks`) is a one-item list, or a list when
  comma-separated, where it failed with `undefined method 'any?'`; over MCP
  the schema asks for the list itself.
- **The generated Commands section and `rails_onboard`'s Getting Started name
  only commands the app has**, from one decision: `bin/dev` where it exists,
  otherwise `bin/rails server`, and `bin/rails db:migrate` where the app has
  `bin/rails` and `db/migrate`, and Getting Started builds the database from
  the app's schema or migrations, never with `db:setup`, which also runs the
  seeds. A private API app was told to run `bin/dev`, which it does not have.
- **The booted schema names a bigint column `bigint`**, as `db/schema.rb`
  does; a private API app's `filesize` column read `integer`. A PostgreSQL
  array column keeps its array flag in both tiers and in schema hints, its
  default read as `[]` where the booted tier printed `{}`, a booted expression
  index reads as a key list, as the dumps give it (`rails_migration_advisor`
  crashed on any table that has one), and schema hints print a structure.sql
  app's primary key as `id` (a composite one as `a, b`), where Discourse's
  read ``(pk: `["id"]`)``.
- **Static routes read the route files `config.paths["config/routes.rb"]`
  registers**, in order (an assignment, `<<`, `concat`, `Rails.root.join`, a
  literal `Dir[...]` glob, kept inside the app), and name a mounted app built
  by a call (`Flipper::UI.app`). OpenFoodNetwork read 69 of its 340 app
  routes, and its Rswag, DfcProvider, Flipper UI and Sidekiq mounts were
  missing. A file pulled in by `draw` is read inside the scope its `draw` sits
  in, and again under each scope that draws it: Forem's `draw :api` inside
  `namespace :api` put `/articles/search` under the web `articles` controller
  without `/api`, and its v0 routes were dropped. `match ... via:` is one
  route answering each verb it names (`GET|POST`, `ANY` for `via: :all`, a
  `via:` from an enclosing scope too), where static routes dropped it. Routes
  take the controller from `scope(controller:)` or their own `controller:`
  (Canvas read 297 made-up controllers such as `accounts/:account_id`), routes
  drawn through an app class (`ApiRouteSet::V1.draw(self)`) take the path and
  name prefixes it returns (Canvas's 971 `/api/v1` routes), a path under an
  optional scope is written as Rails normalizes it, and a route name another
  file already took is left off, as Rails does; a singular `resource` names
  its show route and a root route takes its `as:` as Rails does, an engine
  lists what it could not expand and every path it is mounted at, a controller
  filter lists engine rows like the app's own, and every route count says how
  many more routes sit in engine tables.
- **The auth section's CORS flag is the api section's decision** (a
  commented-out `cors.rb` is not configured in either), so `.ai-context.json`
  no longer says OpenProject has no CORS beside its `rack-cors.rb`.
- **The locale note counts every in-repo gem, engine or plugin with
  `config/locales`**, those without `app/` too (Discourse: 46 directories,
  where it said 28).
- **The booted database and connection-pool sections list replicas**
  (`configs_for` with `include_hidden: true`), as the static tier does.
- **`rails_security_scan` and `doctor` read the app's `Gemfile.lock` before
  saying its bundle lacks brakeman.** `doctor` checks every file the tools
  refuse, names each one it finds, fails on one never committed on purpose
  that is not ignored and warns on the rest.
- **`rails_validate` and `rails_generate_test` decide whether a controller has
  an action with one reader**, over its ancestors, included modules,
  `define_method` names and templates at every ancestor's view prefix; the
  route-to-action check calls an action missing only when the app's source
  holds every ancestor and mixin, and otherwise names the unread gem or
  ancestor and says the action is unverified; a namespaced controller is
  checked at all, and a route to a method ending in `?` or `!` finds it
  (Mastodon's `requests#merged?` was flagged).
- **An engine's root, an initializer's source and an autoload directory in the
  context are app-relative, or the gem and version**, the gem's own
  initializers and autoload directories are left out, and is left out rather
  than written as an absolute path from the generating machine.
- **Routes an app draws into an engine (`Spree::Core::Engine.routes.draw`) are
  listed with that engine**, under the path the app mounts it at and named
  through its route proxy (`spree.admin_orders_path`, after the mount's `as:`
  or the engine's `engine_name`), and are not in the app's route count on
  either tier. Booted, the listing is each mounted engine's whole table, read
  under its mount the way `bin/rails routes` prints it; statically, it is what
  the app's route files draw into the engine. Controller actions, route-helper
  validation and generated tests read these routes too.
  `rails_get_routes(controller: "spree/admin/orders")` answers with OFN's 15
  such routes, a short name such as `orders` lists them beside the app's own
  matches, and the listing names the 219 it draws into Spree apart, PATCH and
  PUT merged as in the app count.
- **A mounted app is listed once per app and path, with its path** (the
  compact `Mounted:` line names each app once, with its path count, before its
  five-name cap), when the mount sits in a `scope path: nil` or in both
  branches of an `if`: Discourse's "Mounted Apps (4)" listed `Sidekiq::Web`
  and `Logster::Web` twice each with no path.
- **`rails_get_env` and the context file's `env` section read ENV names from
  one scan**, and a default is redacted by the source rule, so an empty one,
  an address, a URL or a hostname prints as written where it read
  `[FILTERED]`, which includes the ERB in `config/database.yml` and every
  other `config/**/*.yml`, skipping `<%#` comments. Config YAML on
  `sensitive_patterns` is read for the names in its ERB tags only, never a
  value or a default; credentials and keys are still never opened.
  `rails_get_env` gains 19 names on a private API app, 13 on Mastodon
  and 9 on Huginn (its `DATABASE_HOST`, `DATABASE_PORT`, `DATABASE_SOCKET`).
- **A connected app with no tables yet is described as connected**, where the
  schema note said "no DB connection, no schema.rb".
- **`rails_security_scan` reports brakeman's error message**, where it quoted
  the last backtrace frame.
- **A commented-out Gemfile line is not a gem** wherever the Gemfile is read:
  `rails_get_env`'s services, `rails_get_helper_methods` and the Mongoid check
  read it through one AST reader.
- **A loaded engine's model count counts models**, by the rule the models
  section uses, where it counted every `.rb` under the engine's `app/models`:
  Active Storage read 15 and has 3, Solid Queue read 26 and has 11.

### Fixed

- **The static tier lists the filters a controller's concerns declare.** An
  `include` adds its concern's `before_action`s where the line stands, and
  each prints the concern it came from (`_(from Localized via
  ApplicationController)_`), in `rails_get_controllers`,
  `rails_analyze_feature` and the generated "Global before_actions".
  Mastodon's `AboutController` listed none of `WebAppControllerConcern`'s
  four filters or the `set_locale` its parent's `Localized` wraps every
  action in, and `FollowerAccountsController` had no `set_account`. An
  included module whose file is not in the app is named as not read.
- **An included module is found in any `app/*` directory**, as Rails autoloads
  it, for a model as for a controller: Consul's `Budget::Investment` carries
  the `after_save` its `Budget::Reclassification` declares, OpenProject's
  `WorkPackage`, which read 0 validations and 17 unread concerns, reads its
  `app/models/work_package/validations.rb`, and a model that includes a helper
  from `app/helpers` no longer reports it as not read.
- **A partial index prints its WHERE clause.** The static tier carries the
  `where:` of a schema.rb index, the WHERE of a structure.sql `CREATE INDEX`
  and the `where:` a replayed migration passes, and `rails_get_schema` and
  `.claude/rules` print it: Forem's `canonical_url` reads `[unique where
  (published IS TRUE)]` and Discourse's `unique_index_categories_on_slug` ends
  `where ((slug)::text <> ''::text)`, where both read as unique over the whole
  table; a column two partial unique indexes cover shows each condition.
- **"Missing FK Indexes" reports a column only when an association or a
  foreign key uses it.** Any `*_id` column whose type matched some table's
  primary key counted, so an app with one string key reported every external
  id: a private API app listed 111, among them `users.stripe_customer_id` and
  integer ids other services assign. A column now counts when an association
  names it (a `belongs_to`, a `has_many` or `has_one` from the other side, or
  a `has_and_belongs_to_many` join table, named the way Rails names it), when
  an `add_foreign_key` names it in schema.rb, structure.sql or the migrations,
  or when `acts_as_tree`, `acts_as_nested_set` or `has_closure_tree` declares
  it as the parent key. The associations are the ones the models section
  lists, so a model's concerns and inherited bases count, and so do models
  that subclass `ActiveRecord::Base`. Against 5.29.0: a private API app lists
  6 where it listed 111, all six real; Mastodon 16 where it listed 20;
  Diaspora 15 where it listed 13; OpenProject 43 where it listed 36; Discourse
  166 where it listed 2, because its models subclass `ActiveRecord::Base` and
  none were read before. `rails_performance_check` and the "Performance: N
  issues detected" line in the generated files follow (135 to 30 on a private
  API app). A `has_and_belongs_to_many` record in the models section now
  carries a declared `join_table` and `association_foreign_key` on both tiers,
  so a custom join table is read by name booted as well as static.
- **The gem's own warnings never reach the JSON-RPC stream.** While the stdio
  transport owns stdout, including while live reload starts, a warning goes to
  stderr rather than `Rails.logger`, which an app may have pointed at stdout.
- **CLAUDE.md, AGENTS.md and .cursorrules keep the blank lines between
  sections.** The line cap split every line on newlines, and
  `"".split("\n", -1)` is `[]`, so each blank separator vanished.
- **`rails_validate` no longer pins the whole app's missing foreign-key
  indexes on one file.** At `level: "rails"`, a model file it could not map to
  a model matched every finding of a check that filtered on a key the
  performance introspector never emits, so that check is gone; it never fired
  for a mapped model. The check that reports a model's own missing
  foreign-key index is unchanged.
- **`rails_get_stimulus` lists HAML and Slim views under "Used in views".** It
  only ever globbed ERB.
- **`multi_database.replicas` lists the `replica: true` entries of
  `config/database.yml` when the app is not booted**, where it was always
  empty.
- **A partial is a template.** `views.partials` listed any file or directory
  under `app/views` whose name began with an underscore (an image named
  `_logo.png` was a partial), and `rails_get_partial_interface` offered the
  same names as available partials.
- **A custom middleware reports the class its file is named for.** A helper
  class nested in it or declared beside it could answer `has_call_method` and
  `initializes_app` in its place.
- **An escaped symbol reads as the characters it names.** A symbol written
  `:"first\tname"` was reported as its raw source text, backslash and all:
  column, index and table names, enum names, `attribute` names and types,
  callback, association and scope names, keyword option keys and values,
  `params.require` keys, permitted strong-params keys, `action_name ==` filter
  conditions, CORS origins and resources, model constant arrays, route
  `namespace` and `scope` segments, and rake task names and their arguments.
- **`config/database.yml` is read as YAML in the static tier.** It was scanned
  line by line, and the scan disagreed with the file format on every shape
  that is not the generated one: an entry sharing its adapter through `<<:
  *default` came back with only its name, a database called `replica` (as
  Mastodon names its read replica) was read as a config key of the one before
  it, so the primary was labelled the replica and the app read as
  single-database, and an env given only a `url:` listed no database at all.
  The file is now parsed by `YAML` with aliases on, after its ERB tags are
  replaced without being run, and the databases come out of the env hash by
  the same rule Rails applies: every value a Hash means one database per key,
  anything else is a single primary. An adapter the file computes in ERB is
  reported as the literal the ERB falls back to, labelled so (`MySQL by
  database.yml default`), or as unknown when there is none; it is never picked
  from the Gemfile when the app bundles more than one adapter gem, as Huginn
  does. Without a committed `config/database.yml`, the adapter is read from
  the schema first, a structure.sql dialect and then column types only one
  database has (`jsonb`, arrays, `hstore`; `mediumtext`), then from the app's
  `database.yml.*` example files, then the Gemfile, so Canvas reads PostgreSQL
  where it read `PostgreSQL or SQLite`; `postgis` reads as PostgreSQL, and
  when nothing decides, the reason names only the files the app has. With
  nothing to decide between them, the answer names the candidates (`MySQL or
  SQLite`, and in `rails_get_schema` `MySQL or SQLite, database.yml does not
  say which`). A file that is not valid YAML reports no databases instead of a
  misreading. A boot that fails part way now falls back to the file for the
  database and replica lists, where it reported none. By the same rule, an env
  that mixes plain keys with a nested `secondary:` hash is one database, as
  Rails reads it, so that nested entry is no longer reported as a replica.
- **An association reads the options of a `with_options` block around it.**
  The static tier ignored the block, so `rails_get_model_details`,
  `rails_dependency_graph` and `.ai-context.json` named classes the app does
  not have (Mastodon's `EmailDomainBlock` parent and child read as `Parent`
  and `Child`, `Appeal`'s reviewers as `ApprovedByAccount`), and
  `rails_validate` reported a `has_many` inside `with_options dependent:
  :destroy` as missing `:dependent`; Mastodon's `Account` drew 42 such
  warnings. It follows ActiveSupport: a block without a parameter passes its
  options to the associations inside it, a block with one (`do |assoc|
  assoc.has_many ... end`) passes them only to the calls on that parameter,
  and the association's own options still win over the block's.
- **`rails_validate` compares an escaped symbol by its real characters.** A
  `validates`, `permit` or callback symbol written with an escape no longer
  reads as a missing column.
- **`rails_get_gems` names a config file only when the app has one**, and
  finds an initializer with a load-order prefix
  (`config/initializers/3_omniauth.rb`, `009-omniauth.rb`). It printed
  `config/initializers/omniauth.rb`, `config/initializers/redis.rb` and
  `config/storage.yml` whether or not they existed.
- **`rails_get_service_pattern` leaves concerns out.** A module under a
  `concerns` directory at any depth of a services root, or one that extends
  `ActiveSupport::Concern`, was counted and listed as a service object,
  while `rails_get_concern` already listed it as a concern; the generated
  `Services:` line follows.
- **When no services directory is found, the answer names every place the scan
  reads**, in-repo engines, plugins, modules and `extra_app_paths` included;
  it named only `app/services`, packs and engines.
- **`rails_search_code` hides a generated file the same way on both
  backends.** Without ripgrep, the Ruby fallback matched only the exact paths
  the installer writes, so a nested `AGENTS.md`, `CLAUDE.md`, `.cursorrules`,
  `opencode.json` or `.ai-context.json` that ripgrep hid showed up in results.
- **A HAML or Ruby-hash `data-controller` names its controllers.** A view
  written `%div{ "data-controller" => "hello" }` carried no Stimulus
  controller in `rails_get_view` or in the cross-controller composition list,
  while the `data-controller="hello"` spelling did.
- **A view symlinked out of `app/views` stays out of the turbo payload.** The
  frame and stream scans already skipped one; `permanent_elements`,
  `turbo_drive_settings` and the Turbo Native conditionals counted it.

- **A `retry_on` or `discard_on` prints as one entry with its options**, in
  the same words wherever a job or worker is listed, asked for by name, or
  read from `.ai-context.json`, even when it is written across lines. The
  payload's job and worker records carry one `retries` list in place of
  `retry_on` and `discard_on`.
- **`config/sidekiq.yml` is read as YAML**, so a path named in a comment and
  an environment key are no longer listed as queues (OpenFoodNetwork read
  `default, mailers, config`), and a weighted queue (`[critical, 8]`) is
  named by its queue.
- **A page past the end of a list says only that.** `rails_get_i18n` and
  `rails_get_mailers` asked for such a page said the app had no locale files
  or no mailers, beside the count that proved otherwise.
- **`rails-ai-context tool env_config --environment production` shows that
  environment.** The binary took the flag as `RAILS_ENV` only, so the tool
  named it as current and listed every environment. After the name of a tool
  that declares an `environment` parameter, the flag is now that tool's filter
  and leaves `RAILS_ENV` alone, so a booted app is not booted into an
  environment it has no database for (`--environment prod` exited 1 with "The
  `prod` database is not configured" and now answers "Did you mean
  'production'?"); `RAILS_ENV` stays settable through the variable, or with
  `--environment` before the command name.
- **The route total agrees across surfaces.** `.ai-context.json` and the
  generated files counted one route twice where two controllers answer on
  the same path and action (Forem's two API versions), so they read 769
  beside `rails_get_routes`' 765 plus 3 framework routes.
- **A share short of the whole never prints as 100%.** Translation coverage,
  the doctor readiness score, connection-pool use and the cache hit rate are
  floored, so a locale missing one key reads `99.9%` where it read `100.0%`
  beside the line naming the missing key.
- **An authorization library is named only when the app bundles it.** A
  bare `app/policies` directory reads "policies in app/policies" with the
  policy classes listed, and an `Ability` class without cancancan is named
  as that file, where OpenProject, which bundles neither, read
  `Auth: Pundit`.
- **A Brakeman finding from `rails_validate` prints under the file it
  belongs to**, where every finding landed under the last file listed.
- **The ActiveStorage stack line counts models and attachments apart** (`14
  models with 26 attachments` on a private API app, which read `26 models with
  attachments`).
- **`doctor` finds the brakeman `rails_security_scan` runs**, including one
  installed outside the app's bundle, where it said brakeman was missing
  beside a scan that ran.
- **`rails_get_config`'s middleware section splits the app's own classes
  from what it adds to the stack**, the way the generated files do, where it
  listed every gem middleware as custom.
- **The static schema reads the migrations it was missing.** The replay
  follows the files a migration requires under its own `db/`, an in-repo
  engine's included (`require`, `require_relative`, `Dir[...]`, with
  `__dir__`, `File.join`, `File.expand_path` and `Rails.root` read as literal
  paths, never outside a `db/` directory) and replays every `db/migrate` the
  repository owns, its in-repo engines' included. A `create_table` that names
  its table through its class takes the file's name when a class declared
  there agrees (an acronym the app inflects, such as `OAuth`, included), a
  call to a `create_table` wrapper the migrations define is read as one, and
  an index the migration leaves unnamed takes the name Rails gives it. A
  reference (`t.references`, `t.belongs_to`, `add_reference`) gets the index
  Rails gives it and a polymorphic one its type column, a column declared with
  `index:` gets its index, an explicit `type:` gives the reference its type,
  and `rename_column` and `rename_table` rename the indexes Rails named for
  them. A reference's index follows the Rails version its migration names (a
  polymorphic pair's name changed in 6.1; a 4.2 migration adds none unless
  asked), and a column whose name is computed is left out and counted. The
  replay reads `remove_reference`, `remove_index`, `remove_foreign_key` and
  `remove_columns` by Rails' own lookup (a dropped column takes its indexes
  and foreign key), applies `change_table` to the table it names, where a
  column it added could land on the last table the file created, replays a
  migration's private methods where `up` or `change` calls them, reads
  `db/post_migrate`, and replays a helper from an included module when its
  body is one schema statement, counting any other helper call (and a class
  method on the app's own constants, such as a column dropper) in the note. A
  positional `change_column_default :t, :col, value` is read as well as the
  `from:`/`to:` form. `create_join_table` called on the migration object a
  table file is given is replayed; `t.timestamps` and `add_timestamps` keep
  `null:` and `default:`, a `create_table` block's `t.timestamps index: true`
  gives Rails' two indexes, and timestamps allow NULL in a migration older
  than 5.0; a proc default reads as its source, as schema.rb and structure.sql
  give it. `rails_get_schema` prints where the answer came from at every
  detail level, including how many names were read from files and how many
  `create_table` calls stayed unnamed. OpenProject goes from 37 tables and 39
  indexes to 208 and 556, and `rails_get_schema(table: "work_packages")`
  answers where it said the table did not exist.
- **A route target with a leading slash is absolute**, as Rails reads it:
  OpenProject's `controller: "/admin/settings/..."` inside its admin
  namespaces read `admin/settings/admin/settings/...`.
- **`app/concerns` is read as a concerns directory**, in the root tree, packs
  and in-repo engines, as Rails autoloads it. Huginn keeps its model concerns
  there and read 1 concern where it has 28, and `rails_get_model_details`
  called 8 of `Agent`'s concerns unread; `rails_get_concern(type: "other")`
  lists them. `type:` takes every type the listing prints, in either spelling
  (`service`, `LibStatic`), and only types that hold a concern are listed, and
  a type the app lacks is answered with the ones it has, where the CLI dropped
  such a value and listed every concern. A module a concern declares inside
  itself and mixes in (`DryRunnable::Wrapper`) is looked up from the enclosing
  namespace outward, and a mixin in an autoload root the app declares
  (`autoload_lib`, `autoload_paths`) is read like any concern, so Discourse's
  `RateLimiter::OnCreateRecord` adds its callbacks to `Post` and `Topic`. A
  macro, callback or mixin inside a method of such a module applies only to
  the classes that call that method, in their own body or through a concern's
  `included do` block, as at runtime: every OpenProject model that includes
  the module holding `acts_as_watchable` would otherwise show `watchers` and
  `favorites`. The macros are read with the call's literal arguments (a
  parameter the method reassigns or a block shadows keeps its own value),
  taking the `if`, `unless` or `case` branch they decide (a private API app's
  own macro called with `:picture, has_one: true` gives `has_one :picture`,
  not a `name` pair); a declaration only a condition the literals cannot
  decide holds is not listed or counted, and is named with its condition under
  "Only under a condition the source does not decide" (OpenProject's
  `WorkPackage` showed a `has_many custom_comments` it does not have). A
  called method the reader cannot read costs only itself, named as unread; a
  literal hash argument binds as keywords (`validates_translation :summary,
  presence: true`) and is read through `merge`, `slice`, `except` and
  `reject`, so Consul's translated validations read as `presence` and `length`
  under their condition, an unused `options = {}` no longer swallows the next
  declaration, a parameter reassigned in a block keeps its own value, and what
  a macro method declares inside a block it evaluates on another receiver
  (`translation_class.instance_eval { validates ... }`) is named under
  "Declared on another class" with the condition it runs under, and not
  counted as the model's (Consul's `Proposal` read 20 validation lines, 10 of
  them its translation class's). What a mixin hook declares (`def
  self.included(base)` and the like, in `class_eval`, as `base.has_many`,
  `base.scope` or `base.delegate`, or through a helper it calls) applies to
  every includer, each hook only for its own way of mixing in (`included` on
  include, `prepended` on prepend, `extended` on extend). A module the app
  mixes into `ActiveRecord::Base` or `ApplicationRecord` from an initializer,
  `lib`, `lib_static` or a plugin's `init.rb` (a reopened class,
  `send(:include)`, an `on_load` hook, a required file) is every model's
  mixin, read again on each run so `watch` and the MCP server see one added
  later, a model's own `extend` of an app module is read the same way
  (Canvas's `resolves_root_account` gives `belongs_to :root_account`), a
  module the model's own file declares is not reported unread (OpenProject's
  `WorkPackage` gains `journals`, `attachments` and `custom_values`), a mixin
  in a path gem inside the repo is read like the app's own code (Canvas's
  `gems/broadcast_policy` and `gems/workflow`), and one from a gem installed
  outside the repo is named as unread. One rule answers which classes mix in a
  module, for concerns, services and join tables alike, and a subclass
  inherits what its parent's concerns call into (OpenProject's
  `WorkPackage::InexistentWorkPackage` lacked the `journals` its parent has).
- **Index hints follow how an index is used**, their clauses parted by
  semicolons so a clause listing several columns reads as one, each clause
  printed once. A column is `[indexed]` only when it leads an index and
  `[unique]` only when a unique index covers it alone; one that trails another
  key reads `[in index after x]` and one in a composite unique index `[unique
  with <partners>]`, each partner set once. Each column of a composite unique
  index read `[unique]` and every column of a composite index `[indexed]`.
  `rails_performance_check` uses the same rule `rails_validate` does, so a
  foreign key that only trails another column is reported as unindexed and a
  polymorphic pair must lead an index together, and `rails_migration_advisor`
  warns of a duplicate index only when the name `add_index` would generate
  exists.
- **The `structure.sql` reader keeps an expression index key whole** and the
  keys after it, and no longer reads `DESC`, `NULLS LAST` or an operator
  class as a column: Discourse's `(COALESCE(parent_category_id,
  '-1'::integer), name)` read as four columns with `name` lost. It also
  reads each column's default, the way the `schema.rb` reader reports one
  (a literal as its value, a cast string as the string, json and arrays as
  Rails dumps them, an expression as `-> { "CURRENT_TIMESTAMP" }`, a serial
  key's `nextval` as none): Discourse's schema had no default hints at all
  and now has 583.
- **Both search backends return the same lines.** The Ruby fallback matched
  case-insensitively, searched only a list of extensions and read
  `excluded_paths` as path prefixes, so on a private API app one model name
  gave 6653 lines with ripgrep and 50113 without it. It now searches every
  non-hidden, non-binary file, case-sensitively, and reads `excluded_paths` as
  gitignore patterns; `search_extensions` defaults to unset and, when set,
  still narrows the fallback.
- **The Ruby search fallback reads what ripgrep reads, and fast.** It reads
  the ignore files of every directory above the app (the git ones as far as
  the nearest `.git`, a worktree's or submodule's `.git` file included),
  matches ignore patterns case-sensitively, leaves symlinks alone, walks the
  tree once without entering an ignored directory, and decides a binary file
  from its first 64 KiB: 14.5 s to 2.5 s on a private API app and 27.5 s to
  8.6 s on Canvas, with the same lines ripgrep returns. A ripgrep match in a
  file that is not UTF-8 is reported as a match, where it came back as one
  fake `error:0: invalid byte sequence` row.
- **`rails_search_code` never answers "No matches" while matches exist.** A
  `limit` smaller than one match and its context lines held only context, so
  the page came back empty; it now starts at the next match and says so.
- **A standalone install lets the app's `Gemfile.lock` win.** An app locking
  an older `json` than the one this gem's dependencies pulled in failed to
  boot and fell back to the static tier. Every gem the binstub activated for
  itself now leaves `$LOAD_PATH` before `Bundler.setup` and comes back behind
  the app's gems but ahead of Ruby's own lib directories, so a gem with a
  default-gem twin (prism, json) never loads half from each; after a boot that
  fails before the app's bundle is set up, the load path goes back to its
  pre-boot order, and after one that fails later, such as an initializer that
  raises, the app's bundle stays in front, so ActiveSupport finishes loading
  and mcp never loads from two versions (every tool and the MCP server
  answered with a load error there). When the app locks one of this gem's
  dependencies at a version outside its requirement, a warning names it. A
  standalone install no longer points at commands it does not have: `doctor`'s
  fixes, the "to regenerate" line of the full-mode context files and the
  `session_context` note name `rails-ai-context context`, `init` and `tool`
  there, and `rails ai:context`, the install generator and `rails ai:tool`
  where the app bundles the gem. `tool --list` honours `--no-boot`, and the
  CLI no longer warns `could not restore gemspec(s): json-schema` on every
  run: it re-registers the gemspecs it activated for itself rather than a
  hand-kept list.
- **The test framework is read from the suite the app has**: Ruby spec and
  test files, their helpers and `spec/factories`, not from whether a `spec/`
  directory exists. With no tests anywhere, the answer says so and names the
  framework the bundle holds (`no tests yet (rspec-rails in the bundle)`),
  where it said the app ran rspec or minitest. Whitehall's and Plots2's
  `spec/` hold only JavaScript tests, so minitest apps read as RSpec and
  `rails_generate_test` wrote them an RSpec spec. `doctor` reads the same
  answer (`minitest test suite found`, or `No test suite found` where it said
  `No test directory found`), and an app that runs both is told to run `bundle
  exec rspec` where it was told `rails test`.
- **Tests are found and written where the app keeps them.**
  `rails_get_test_info(model:)` and `(controller:)` look in the directories
  the app's tests live in, so Whitehall's `test/functional` and
  `test/unit/app/models` tests are found, where the tool said "No test file
  found" for files its own no-argument answer counted, and
  `rails_generate_test` writes into the directory most of the app's model or
  controller tests share, under the file-name suffix most of them use, falling
  back to the convention when there are none, and names the subject's existing
  test rather than writing a second one. A controller's lookup also lists the
  system, feature, request and integration tests named for it or reaching its
  routes, each labelled by kind (Mastodon's `AboutController` said "No test
  file found" beside `spec/system/about_spec.rb`). A model's tests are looked
  for only where the app keeps model tests: a private API app's
  `rails_get_test_info(model: "User")` answered with a serializer spec sharing
  the basename, where its model spec is `spec/models/user_model_spec.rb`. A
  generated controller test asserts what each action answers, `create`,
  `update` and `destroy` included, `respond_with` read by format and verb as
  the responder answers and an early bare `return` counted as an answer (an
  API `create` rendering `status: :created` or a `head :no_content` destroy no
  longer gets the scaffold's redirect), read from its body and its
  `respond_to` block for the format the test sends, the branch valid params
  take where a save splits it (a redirect as `:redirect` with its target when
  the test can name it, `head` as its status, a JSON or plain render with its
  media type, a conditional or unreadable action only as not a server error,
  with a comment saying why), where it asserted `:success` for Plots2's
  redirecting `verify_email`. A controller under a gem's controller (Devise)
  keeps its routed actions, unverified; RSpec controller specs include
  `Devise::Test::ControllerHelpers` (Devise setup in `spec/support` counts), a
  test of a Devise controller sets `devise.mapping` from Devise's route names,
  a `Post` model gets `let(:post_record)` so the `post` request method is not
  shadowed, a destroy test builds its record before reading its id, a redirect
  target is asserted only when it names a route, and `rails_generate_test`
  looks for an existing test where `rails_get_test_info` does. A namespaced
  model is built from the controller's namespace outward (OpenFoodNetwork's
  `LineItemsController` got a skip), an `on:` validation is checked in its
  context and a conditioned one is skipped with its condition named, and a
  glob segment is passed. It covers only the actions the controller has (its
  own and inherited public actions, template-backed ones, and names a
  `define_method` or a concern may build), naming each routed action it leaves
  out, so a `resources` route no longer gets a `show` test for a controller
  with no `show`. It passes every required path segment and builds its record
  under its route parent (Whitehall's contacts under organisations raised
  `UrlGenerationError`), leaves optional segments out, fills a custom segment
  from the column of the same name on the record or its parent (Plots2's
  `graph/file/:uid/:id` gets `uid: @csvfile.uid`), and skips with the segment
  named when it cannot fill one; one written among an app's controller specs
  is a `type: :controller` spec. A generated minitest controller test uses the
  test class and data style (factories or fixtures) most of the app's
  controller tests use, each test's superclass read through Prism and followed
  through an app base class in the test tree (`::ActionController::TestCase`
  counts), and a model's fixtures are found under its pluralized class name or
  its `set_fixture_class` mapping (read from the test and spec helpers and
  support files), a namespaced model's under the names Rails gives them
  (`admin_users(:one)`, where it wrote `admin/users(:one)`): Plots2's `Node`,
  whose table is `node`, got a TODO beside a `nodes.yml`.
- **`rails_get_test_info` counts the examples a test file runs, and lists
  exactly those** (`it`, `specify`, `scenario`, `test`, `def test_*`,
  one-liners too, never a `describe` or `context` line: a private API app's
  `User` spec read 283 tests and runs 136), `rails_onboard` counts factory
  definitions and the files they sit in ("203 factories in 134 files", a floor
  marked "+" where a name is computed in a loop), and a fixtures directory
  that also holds `file_fixture` files reads "1 YAML fixture set, 485 other
  files" where it read "1 file".
- **`rails_get_test_info` renders each factory file's traits as a list item**
  (`- **users.rb:** admin, with_posts`), where it printed a Ruby array.
- **The declared Ruby version falls back to `.ruby-version` and the `ruby`
  line of `.tool-versions`** when neither the lockfile nor the Gemfile names
  one, and the gems payload says which source answered
  (`declared_ruby_version_source`).
- **The Rails version is read from `railties`** when an app bundles it without
  the `rails` gem, as Discourse does.
- **`--no-boot` reads the `config/database.yml` section for `RAILS_ENV` or
  `RACK_ENV`**, where it always read `development`.
- **Code in an in-repo engine, plugin or module is read like `app/`**:
  models, controllers, views, concerns, services, jobs, mailers, helpers and
  serializers under `plugins/*`, `modules/*` and `gems/plugins/*`. A view
  there reaches `rails_get_view`, `rails_get_partial_interface`,
  `rails_get_turbo_map` and the view lookups, and can be read by path
  (OpenProject: 318 to 492 templates). A directory
  counts when it has its own `app/` with a Rails directory in it and a
  gemspec, a `plugin.rb` or an `engine.rb` says Ruby loads it. Discourse goes
  from 223 to 359 models and OpenProject from 169 to 274, and
  `rails_get_schema` stops calling a plugin's table model-less and pointing at
  the Gemfile.
- **A model reads the table prefix its namespace gives it**, from a `def
  self.table_name_prefix` on the namespace or an engine's `isolate_namespace`,
  as Rails' `full_table_name_prefix` does; an explicit `self.table_name =`
  still wins, read as the literal when its only interpolations are
  `table_name_prefix` and `table_name_suffix` (the class's own, else
  `config.active_record`'s), and a derived name takes
  `config.active_record.table_name_prefix` and `_suffix` when nothing nearer
  sets one. A class nested in a concrete model takes that model's singular
  table as a prefix, as Rails' `compute_table_name` does: OpenProject's
  `Project::Phase` reads `project_phases` where it read `phases`, and its
  `Principal`, `User`, `Group` and four more read `users` where they read
  `principals`. 51 of OpenFoodNetwork's models (its Spree models and their
  calculators) read `orders` where the table is `spree_orders`, and
  Discourse's `DiscourseRssPolling::RssFeed` read `rss_feeds`, so
  `rails_get_schema` called their tables model-less.
- **`rails_get_schema` names the gem that owns a table with no model file**,
  one line per gem the lockfile or Gemfile has (good_job, doorkeeper,
  friendly_id, closure_tree, paper_trail, acts-as-taggable-on, pghero, the
  Solid gems, Active Storage, Action Text, Action Mailbox, noticed,
  delayed_job), where it listed the table as model-less. Both lists, and the
  warning for a table with no model file, cover the whole schema at every
  detail level, where they covered only the current page of the standard view
  (a private API app's standard view named only one table), and `format:"json"`
  returns them in `tables_without_model_file` and `gem_owned_tables`. A
  `has_and_belongs_to_many` `join_table:` built from the table name prefix and
  suffix reads as the table it names, so a join table is not called model-less
  either.
- **A migration's literal `execute("DROP TABLE ...")` drops the table from the
  replayed schema**, MySQL's backtick-quoted names included. OpenProject's
  `meeting_contents` and `meeting_content_journals` were listed, and four
  missing-index suggestions came with them.
- **Jobs are read from `app/jobs`, `app/workers` and `app/sidekiq` alike.** An
  app with its workers in the Sidekiq 7 generator directory, or its ActiveJob
  classes in `app/workers`, answered "No jobs found" (Whitehall has 31,
  OpenProject 103 with its modules). A class is a worker when a Sidekiq mixin
  is anywhere up its chain and a job when its chain reaches ActiveJob,
  wherever it lives, so a Sidekiq job under `app/jobs` shows the queue its
  `sidekiq_options` names rather than the default. An abstract base, one
  another job inherits from and whose name says it is a base (`Jobs::Base`,
  `ApplicationWorker`), is no longer counted as a job, in either tier. A job
  is named by the constant its file declares
  when that names its own namespace: Discourse's read `Regular::AnonymizeUser`
  for `Jobs::AnonymizeUser`.
- **A mailer is listed wherever it lives and whatever it declares.** One
  outside `app/mailers` is found by its parent chain anywhere under `app/`
  (Canvas keeps `Mailer < ActionMailer::Base` in `app/models` and got "_No
  mailers found._"), a chain is followed through the app's autoload roots to
  `ActionMailer::Base` or a gem mailer, a class under `app/mailers` whose
  chain reaches no mailer is not one (Diaspora listed twelve header builders
  with `Actions: set_headers`), and one with no action of its own is listed
  with the parent it takes its actions from and any class methods it has
  (Whitehall's `MultiNotifications`, Consul's `DeviseMailer` and Diaspora's
  `DiasporaDeviseMailer`). A mailer a gem defines is not listed as the app's,
  and an ActionMailer setting such as `mailer_name` is not a mailer's
  interface.
- **A by-name lookup answers the name it was given, or says it has no such
  thing** and suggests the closest, by Ruby's own spell checker over full
  names and last segments, where it offered whatever shared the first three
  characters. `rails_get_mailers(mailer:)`,
  `rails_get_i18n(locale:)` and `rails_get_env_config(environment:)` matched
  substrings and answered with another thing's data under the name asked for:
  `Mailer` got `UserMailer`'s actions, `prod` got production, and `e` got the
  first locale by name. `rails_get_routes(controller:)` answers the
  controller whose trailing segments the name spells, where `users` swept in
  `admin/users/roles`, and its miss message lists at most 20 controllers.
  `rails_get_turbo_map(controller:)` matches whole path segments, so
  `blog_posts/` views no longer count as `posts`, and
  `rails_get_test_info(controller:)` no longer offers a top-level request spec
  as a namespaced controller's test. A short name two namespaces share
  (`ReportMailer` for `Admin::ReportMailer` and `Staff::ReportMailer`) names
  both and asks for the full one.
- **The booted tier leaves out a model a gem defines**, wherever the bundle is
  installed (a private app counted `PaperTrail::Version`, 139 where the static
  tier said 138), its Concerns list is what the model's source includes and
  what a gem macro includes into that model alone, labelled by the macro
  (`devise :a, :b` read statically as Devise's modules), without the modules
  gems put into every model, a booted mailer lists only the actions a mailer
  class defines, conventions claim model concerns only from a concerns file
  that is a module, and `rails_onboard` names Mongoid for a Mongoid app, where
  Errbit read "on unknown".
- **Neither tier lists a mailer's or a controller's action callbacks,
  predicates or bang methods as actions**, nor a controller method that needs
  an argument, which Rails could not dispatch. The booted tier listed what
  `action_methods` returns; a private API app's `BaseController` listed its own
  `before_action` target and a predicate. A controller lists the actions it
  inherits from every app base, whatever the base is called and however its
  name is qualified (OpenProject's
  `CustomFields::Hierarchy::ItemsBaseController`, written inside
  `Admin::Settings`), in its actions and its filter chain; an inherited public
  method that no route names for the controller is a shared helper and not an
  action (paper_trail's `info_for_paper_trail` read as an action of every EF
  api controller), and an unrouted base controller lists only the actions its
  subclasses are routed for, a controller under `app/controllers` no route
  names lists only what it defines itself, a controller lists the public
  actions an included app concern offers (Whitehall's
  `Admin::ContactTranslationsController` lacked `create`, `update` and
  `destroy`), and the booted tier drops a method that needs an argument and
  settles inherited actions by the routes, as the static tier does; a routed
  action with a template and no method is an action (OpenFoodNetwork's
  `Admin::OrderCyclesController` lacked `incoming`, `outgoing` and
  `checkout_options`); and a file under `app/controllers` not named
  `*_controller.rb` is a controller only when it subclasses one, so
  OpenProject's Grape API classes stay out.
- **A Stimulus controller outside `app/javascript/controllers` is found**:
  under `app/webpacker`, `app/frontend`, `frontend`, `client`, component
  sidecars in `app/components`, and the same homes in packs and in-repo
  engines and plugins, named `*_controller` or `*.controller`, in JS or TS.
  Outside the rails-new home a file counts only when it imports from
  `@hotwired/stimulus` or `stimulus`, or extends a class that does (an app
  file reached relatively or through the app's alias table, or an installed
  Stimulus package), so an AngularJS `*.controller.js`, OpenProject's Angular
  `activity-base.controller.ts` or a React `*_controller.tsx` does not. Forem
  read 1 of its 23, OpenFoodNetwork 0 of 73, OpenProject 0 of 161.
- **Editing a Stimulus controller outside `app/javascript/controllers`, or a
  job in `app/workers` or `app/sidekiq`, invalidates the cached context**, so
  tools stop answering from stale data.
- **The app's architecture lists `stimulus` and `hotwire` wherever it keeps its
  Stimulus controllers.** OpenFoodNetwork and OpenProject read as having none.
  A React component named `*_controller.tsx` still does not count.
- **`rails_get_stimulus` counts a view as a use only when its markup names the
  controller** in a `data-controller` attribute, a target, an action or a
  `content_controller`-style helper. An i18n key or a word in prose with the
  same text counted.
- **`rails_get_turbo_map` says how many Turbo Stream responses it showed of
  how many**, and points at `detail:"full"` for the rest, where entries
  dropped off after 15 with no sign; one declared in a controller concern is
  named without the `Concerns::` segment the autoload root does not carry.
- **The generated files promise Stimulus auto-registration only where
  stimulus-loading does it**, for controllers in `app/javascript/controllers`;
  anywhere else they say a new controller is registered the way the
  existing ones are.
- **A markup comment is not markup.** A HAML `-#` comment, with the lines
  indented under it, and an ERB `<%# %>` comment are no longer read for
  partials, instance variables, Stimulus identifiers, slots, fields or helper
  calls: OpenFoodNetwork's `create_linked_variant.turbo_stream.haml` listed a
  partial named `the`, from `-# Pre-render the form`.
- **A `render` call's partial is read with or without parentheses**, wherever
  its keyword sits: `render(partial: 'x')`, `render 'x'`, `render(template:
  'x')`, `render collection: @items, partial: 'x'`, the `:partial =>` form and
  calls over several lines, in ERB, HAML and Slim; a JavaScript `.render(...)`
  in an inline script and a partial name built at runtime are not read. A
  `partial:` inside `locals:` or a component's constructor is not the call's
  partial, and an escaped quote in an earlier argument no longer hides it; a
  turbo frame id or stream name holding a comma inside a string is read whole,
  and a Stimulus `static values` default holding a brace, a paren or a regex
  literal is read whole, in source order. OpenFoodNetwork's views gained 51
  partial references and Consul's 23.
- **A layout's yields are read in ERB, HAML and Slim**: the unnamed one as
  `(main)`, `yield(:x)`, `(yield :x).presence` and `content_for?(:x)`, read
  only where Ruby runs (ERB tags, HAML code lines and attribute hashes, Slim
  code and attribute values), and a `content_for` that sets content, with a
  block or a value, parenthesised or not, is not a yield. Canvas's six layouts
  reported none.
- **A Stimulus action descriptor is read with its options, event filters and
  neighbours** (`click->x#open:prevent`, `keydown.enter->`, `resize@window->`,
  several descriptors in one `data-action`), read only from an action value (a
  `data-action` attribute, an `action:` in a data hash, an action-named key or
  Ruby variable such as `confirm_actions:` or `hiddenFieldAction:`), so an
  apostrophe in page text no longer hides the actions after it, and prose, a
  Ruby comment or a Rails route list (`%w[posts#create]`) confirms nothing,
  where OpenFoodNetwork's `bulk-form` and `modal` uses were missed.
- **`url_for(controller: "x")` is not a Stimulus controller** in view answers.
- **`data-turbo` counts read the HAML and Ruby-hash spellings**
  (`"data-turbo": "false"`, `'data-turbo' => 'false'`), not only
  `data-turbo="false"`.
- **A model whose `inclusion: { in: [...] }` list mixes strings with `nil` no
  longer fails** `rails_get_model_details` and `rails_context` with
  `ArgumentError: comparison of String with nil failed`. Whitehall's `Edition`
  and its 13 STI subclasses failed.
- **A validation or callback inside `with_options` carries the block's
  options**, so a validation scoped `on: :publish` no longer reads as always
  required, and a macro sent to the block's parameter is kept.
- **A scope written `scope :x, lambda { ... }` or with a `do ... end` block
  shows its body** and is marked verified where it was empty and `[INFERRED]`.
  Every scope body prints on one line, folded the way Ruby's lexer reads its
  newlines, a string literal written across lines respelt as the same string
  on one line: statements are separated by `;`, a call split at the dot joins
  back, and a comment inside it is left out. A body carrying a heredoc prints
  as the file wrote it.
- **A Mongoid app counts `embeds_many` and `embeds_one` as associations
  everywhere, and lists only documents as models.** `rails_dependency_graph`
  draws their edges, and Errbit's `App` read "1 association" beside 5 edges; a
  plain Ruby class under `app/models` (Errbit's `ErrorReport` and `Issue`) is
  not a model.
- **Both tiers list every declared validation the same way, with its
  conditions**: `validates_with`, `validates_date`, `validates_translation`
  and the rest, each with its `if:`, `unless:` and `on:`, and the presence
  validation Rails adds for a required `belongs_to`, marked `_(implicit from
  belongs_to)_` by `optional:`, `required:`, `belongs_to_required_by_default`
  (read from `config/application.rb` and every initializer) and
  `load_defaults`; an `optional:` written as an expression prints it and makes
  the implicit presence conditional on it, and a hand-written presence rule on
  the same name shows in its place. A validator no source line declares is
  listed too: the booted tier adds each reflection validator no line covers,
  marked by what added it (`has_secure_password`, `devise :validatable`, a gem
  module), and the static tier reads `has_secure_password` and `devise
  :validatable` as the validators they add, `has_secure_password`'s by the
  Rails version `Gemfile.lock` names (`length` and `confirmation` before 7.1,
  `confirmation` from 7.1, and an assumption named when the lockfile says
  none), so a private API app's `User` shows its password `confirmation`. A
  validation whose attribute is computed, as in a loop, says so, and a custom
  `validate :method` prints its `on:`, `if:` or `unless:` condition in both
  tiers. A private API app's booted `Document` dropped its `if:` conditions
  and printed its `validates_with` line as `document on`, the static tier
  left `validates_with` out (Plots2's `User` read 0 validations), and a
  hand-written presence rule on a `belongs_to` name was labelled implicit.
- **An inheritance column set to `nil`, `false` or `:_type_disabled` reads as
  STI off**, where the conventions claimed STI. A validator option set to
  `false` (`presence: false`) is no validation, in both tiers; a class's own
  `belongs_to_required_by_default` beats the app's and passes to its
  subclasses (OpenFoodNetwork's `Subscription` showed 7 implicit presence
  lines); a computed enum prints its source marked computed, and a frozen
  literal one its values; and one `after_commit` declared for several events
  is one callback showing its events.
- **`rails_validate` judges only the `has_many` associations the model's file
  declares**, and treats encrypted attributes (`has_encrypted`, `encrypts`,
  `attr_encrypted`) and store keys as attributes with no column of their own,
  so it no longer asks for `dependent:` on paper_trail's `has_many :versions`.
- **`rails_dependency_graph` resolves an association's class from the owner's
  namespace outward, as Rails' `compute_type` does**, a leading `::` meaning
  top level (kept as written in both tiers), and the missing FK index check,
  both habtm join-table readers and the counter-cache check resolve it the
  same way; every tool that derives a model from a name spells it as the app
  does, acronyms included (`analyze_feature` named models that do not exist);
  two associations of one kind to one class each get an arrow labelled by
  name; and a through association that names no association of its model, or
  whose name is computed at run time, draws no node and is named in a note
  saying which: Consul's `Budget` pointed at a top-level `Investment`,
  `Ballot`, `Group` and `Heading`, and OpenFoodNetwork's `Spree::Order` at
  `Payment`, `Shipment` and `Adjustment`. It draws a through edge per join
  model, where Mastodon's `Account` lost its through `Follow`, `Block` and
  `Mute` edges behind the first one; a through association with `source_type:`
  points at the class `source_type` names; and the "pass model:" hint is left
  out when a model was passed.
- **A block callback a concern declares is kept beside the model's own block
  callback of the same kind**: Discourse's `Topic` lost the `after_create do`
  of `RateLimiter::OnCreateRecord`.
- **A static route honours the action its `action:` option names** (`get
  :delete, action: :deletion_dialog` read as `delete`).
- **A component is typed by following its superclass chain through the app's
  own base classes**, so one two or more steps from `ViewComponent::Base` or a
  Phlex base is no longer "unknown", and a sidecar file that reopens its parent
  namespace is named for the class the file is named for. A component nested
  in a module is listed by its full constant (`Admin::RowComponent`, where
  three different classes all read `RowComponent`), which renames most of
  OpenProject's catalog.
- **A concern that nests its own `ActiveModel::Validator` is a concern**, not
  a validator, and every surface that lists concerns or helpers names each one
  by the constant its file declares, in-repo plugins included (Discourse's
  `DiscourseSubscriptions::Group` read `Group`, and
  `rails_get_helper_methods(helper: "DiscourseChatIntegration::Helper")`
  answered not found): `rails_get_active_support` read `Featurable` for
  `Edition::Featurable`, and an inflected namespace (`SDG::TagList` in
  `concerns/sdg/tag_list.rb`) is no longer spelled `Sdg::TagList`.
- **A module that extends `ActiveSupport::Concern` is a concern wherever the
  app autoloads it from**, and the default `excluded_concerns` patterns each
  match a whole namespace, so an app module named only like a framework's
  (Whitehall's `ActiveRecordLikeInterface`) is listed, not hidden; listed with
  its path under a type naming its root (`Service Concerns`), in
  `rails_get_concern` and `rails_get_active_support` alike: OpenProject read
  82 concerns and has 329, Canvas 9 and 26, a private API app none and 2.
- **A concern's includes and methods are its own body's**, not those of
  classes nested in its file: Huginn's `LiquidDroppable` read `Includes:
  Enumerable` and its nested `Drop` classes' `to_s`, `each` and `as_json`, and
  `Agents::ImapFolderAgent` was credited with `Scrubbed`. A concern whose
  methods are all private reads `0 public methods (N private)` and lists them,
  where it read `0 methods`.
- **A concern's "Included By" lists the classes whose `include` resolves to
  it** from their own namespace, each once, named by its constant, searching
  every autoload root and naming them when it finds none: Mastodon's
  `Admin::ExportControllerConcern` listed 9 includers, 7 of them including
  `Settings::ExportControllerConcern`, and Discourse listed
  `SubscriptionsController` twice.
- **Component previews are read from the directories the config sets**
  (`view_component.previews.paths`, `preview_paths`, `preview_path`) as well
  as the defaults, and a preview links to its component by path or by the one
  component it renders: OpenProject read no component with a preview, and 39
  have one.
- **A boot error no longer repeats in full under every answer.** The footer
  and each `[UNAVAILABLE]` note keep its first 140 characters, and the whole
  error stays in the startup banner and `doctor`. On Discourse it was 61% of
  the output.
- **`rails_get_view` does not count a partial under `app/views/layouts` as a
  layout.** Forem read 19 layouts where it has 4.
- **An abstract base is not counted as a service, a job or a mailer.** A class
  other classes inherit from and whose name says it is a base
  (`ApplicationService`, `BaseService`, `Jobs::Base`, `ApplicationMailer`)
  leaves `rails_get_service_pattern`, `rails_get_job_pattern`,
  `rails_get_mailers` and the generated files by one rule in both tiers, and
  one sentence above each listing names what it left out; a base answers when
  asked for by name with what it hands down, printed without the comments
  written inside a call and never counting a call inside a method as a
  declaration: a job base its queue, options, retry policy, mixins, throttle
  and callbacks, a mailer base its layout, helpers, defaults, callbacks and
  mixins as the file writes them, and either one the methods it defines and
  the classes that inherit it. Mastodon's generated files listed `BaseService`
  as a service, and Consul's and OpenProject's `ApplicationMailer` helpers
  read as emails.
- **A class file is named by the constant it declares.** A model, job or
  service whose file declares a namespaced constant at a path that does not
  spell it is listed under that constant, where it was dropped or named from
  the path: Discourse's `DiscourseGithubPlugin::GithubCommit` and six other
  plugin models were missing, and `Jobs::DiscourseChatAddTypeField` read
  `Onceoff::AddTypeField`.
- **A bare superclass resolves from the enclosing namespace outward**, as
  Ruby resolves it, so `module Bim::Bcf; class NonExistentComment < Comment`
  inherits `Bim::Bcf::Comment`, and a class that shares a name with a model in
  another namespace is no longer counted as a model.
- **What a job or service hands work to is read from the call nodes**, so
  `.run`, `.perform_now`, any bang method (`GithubBadges.grant!`), a receiver
  written `::Fully::Qualified` and a call split across lines are listed under
  its calls, and a call written in a comment or a string is not.
- **`rails_get_api` reports a CORS initializer whose origins come from a block
  or an expression**, where it said "not detected", and says when the block is
  exactly the request `Origin` header echoed back, which allows any origin. A
  `resource` path that is not a literal prints as its source. A CORS
  initializer with no `allow` block is reported with the middleware it
  inserts, or as a file whose `Rack::Cors` or `allow` block is commented out;
  a file that only has `cors` in its name is not a CORS initializer. An `else`
  branch reads "otherwise" and each `elsif` keeps its own condition, where a
  private API app's second `allow` block read `* if else Rails.env.staging?`.
- **CORS and Rack::Attack are found under the initializer name the app gave
  them** (`rack-attack.rb`, `rack-cors.rb`, `008-rack-cors.rb`), where only
  `cors.rb` and `rack_attack.rb` were read.
- **A notable gem's note names a config file only when the app has it.** It
  points at the file the app does have, or drops the clause naming the path
  and keeps the description; it named `config/initializers/cors.rb`,
  `app/assets/config/manifest.js` and `app/javascript/controllers/` on apps
  without them.
- **`rails_get_api` reads Grape versions under `app/api/v*` and `lib/api/v*`**
  and names the directories each version came from.
- **An ActiveRecord attribute coder in a `serializers/` directory is not
  reported as the app's serialization layer.**
- **GraphQL counts leave out base classes**, judged from the class the file
  is named for rather than from a `base_` file name: a class that declares
  `graphql_name` is concrete, and a base is one others inherit from, or one
  named like a base that subclasses graphql-ruby and adds nothing to the
  schema. The enums, inputs, scalars and connections that subclass
  graphql-ruby directly still count (Canvas: 176 types, 102 mutations). An
  app with no `queries/` directory is pointed at its query root file rather
  than told "0 queries".
- **Middleware changes are read wherever the app makes them**: through
  `Rails.configuration.middleware`, `Rails.application.middleware` and
  `app.middleware`, the app's own `MyApp::Application.config.middleware` and
  `config.middleware` (an engine's own stack, `MyEngine.config.middleware`, is
  left alone), with `insert`, `insert_before`, `insert_after`, `unshift`,
  `swap`, `move_before`, `move_after` and `delete`, in `config/application.rb`
  and `config/environments/*.rb` as well as the initializers. A class the app
  owns is listed with its file, under the name its file declares, wherever the
  app autoloads it from (`lib/middleware`, `app/lib/middlewares`) or wherever
  its config or initializers declare it with a `call` method (Mastodon's
  `TelemetryLoggingMiddleware`, Discourse's `Discourse::Cors`);
  `config.exceptions_app` is named apart from the stack; one it does not own
  is listed under "Stack changes from the app's config" as inserted, moved,
  swapped in or removed, each with the file that does it. Discourse read no
  custom middleware and 1 insertion; it has 16 classes and 27 stack changes
  (19 inserted, 2 swapped in, 1 moved, 5 removed).
- **The autoload roots include the ones `config/application.rb` adds**
  (`autoload_paths`, `eager_load_paths`, `autoload_lib`, `config.paths.add`),
  when they are written as literal paths inside the app, so a class there is
  found as the app's own. OpenProject keeps middleware in `lib_static`.

### Removed

- **Internal helpers nothing in the gem called**: `DetailLevel.at_least?`,
  `SchemaHint#verified?`, `#column_names` and `#association_names`,
  `Fingerprinter.watched_files`, `Payload.mailer_file`,
  `Payload.rails_engines` and `Payload.databases`, `SafePath::REFUSALS`,
  `ViewFile::Result` (a view lookup returns `SafePath::Resolution`, which has
  the same fields), `Introspectors::ListenerRegistration.register`,
  `Listeners::MongoidFieldsListener` (the generic macro listener reads
  Mongoid's macros), and `StackOverviewHelper#database_adapter_label`. None
  was documented.

### Security

- **Secret files a Figaro, direnv or config-gem app keeps are refused like the
  rest.** `config/application.yml`, `.envrc`, `config/settings.local.yml`,
  `config/settings/*.local.yml`, `config/secrets*.yml`,
  `config/secrets*.yml.enc`, `*.p8` and `*.env` (a compose `env_file:` such as
  `docker/secrets.env`) join the sensitive-file list, and `rails_search_code`
  refuses one given as its `path` (a file path is now taken, as ripgrep takes
  it), so `rails_get_edit_context` and `rails_search_code` no longer return
  the values in them. On a private API app both returned JWT signing secrets
  from `config/application.yml`.
- **The Ruby search fallback skips what ripgrep skips**: sensitive files, and
  whatever `.ignore` and `.rgignore` files ignore, and inside a git repository
  whatever the root and nested `.gitignore` files, `.git/info/exclude` and the
  global excludes file ignore, with ripgrep's precedence: any `.rgignore` over
  any `.ignore` over any `.gitignore`, then `.git/info/exclude`, then the
  global excludes file, the deepest file deciding only within one type, and a
  directory they ignore never entered. Without ripgrep on the PATH the
  fallback returned lines from gitignored secret files; it now returns
  ripgrep's rows, context lines and line cap, matching each line without its
  newline.
- **Every line `rails_search_code` and `rails_get_edit_context` return passes
  through redaction, and redaction filters secrets, never code.** A string
  literal of eight or more characters under a secret-named key (Ruby, YAML,
  JSON written `"key":"value"`, or a setter on any receiver such as
  `config.secret_key_base = '...'`), four or more under a password-type key
  (`password`, `passwd`, `pass`, `pin`, `passphrase`), letters-only and
  digits-only ones included, and the unquoted value of a secret-named
  `NAME=value` in any file (shell, Dockerfile, compose, env or code; inside a
  string or URL only the value is replaced, and a setter symbol, a regex
  lookbehind or an interpolation is left alone), a value in an example file
  (`*.example`, `*.sample`, `*.template`, and YAML ones like `*.yml.example`)
  unless it is plainly a placeholder, a cipher key name (`cbc_key`,
  `hmac_key`) counted as secret-named, a credential-looking value under any
  other `*_KEY` name (a 16+ character run mixing letters and digits, or a
  known token format, never a cache, i18n or storage key), a literal assigned
  through `ENV["NAME"] =`, `||=` or another op-assign or held by an instance
  variable or constant, a literal passed through a call or block that names a
  secret (`ENV.fetch` default, `let(:api_key) { }`, `default:` under a secret
  option), never a ternary's branches, a PGP private key block, Anthropic and
  OpenAI keys, unless it is plainly not a credential (a message, URL, path,
  placeholder, version, date, header, env or parameter name, or a
  translation), and a value in a known credential format (AWS keys, JWTs,
  vendor tokens) read `[FILTERED]` in any file; a PEM private key is filtered
  whole, across lines too and with armor headers before its body, with the
  line count kept, while a BEGIN marker named in a regex or string with no key
  body after it is code. `rails_search_code` shows a match that falls only
  inside a filtered value as the context row a wrong guess would show, so a
  pattern cannot confirm a secret's prefix. Log lines read `NAME=value` with
  the source pattern and decide each name and value pair once; they also
  filter a connection URL's password and a PEM body on the lines after its
  marker. Both tools redact the whole file before they cut a window or a row,
  so a window or a context line inside a key still hides it. Code is returned
  as written: a call that passes a token along (`issue(token:
  TokenService.run(user: @user).result)`) or reads one (`password:
  params[:password]`) is never rewritten. A `password_confirmation` literal is
  filtered like the password, in logs and config too, and log redaction keeps
  the quotes and the variable name around `[FILTERED]`.

## [5.29.0] - 2026-09-23

Twenty-three QA reports against v5.27.0, each one a wrong answer a reader
could act on, plus what eight review rounds found in the fixes themselves.

### Added

- **Model payloads carry method counts and the model's own methods
  uncapped.** `instance_method_count`, `class_method_count` and
  `source_instance_methods` sit beside the capped `instance_methods` and
  `class_methods` lists, on both tiers, so a reader can tell a cut list from
  a whole one.
- **The schema payload carries `declared_tables`**, what `db/schema.rb`
  declares, on both tiers: nil for an app whose tables come from
  `structure.sql` or the migrations.

### Changed

- **"Mounted Engines" is "Mounted Apps" everywhere it is printed**: the
  `engines`, `routes` and `onboard` tools, the generated context files, and
  the MCP `rails://engines` resource name. The stack overview line reads
  `Mounted:` rather than `Engines:`. Half of what the list holds are plain
  Rack apps. The payload key stays `mounted_engines`.
- **A mount whose path the source does not spell out carries `path: nil`**
  rather than the string `"unknown"`, and is printed without a path.
- **`routes` reads a blank `controller` as no filter**, and a name that
  normalizes to nothing (`_controller`) as matching nothing, where the empty
  string used to match every route key.

### Fixed

- **A Sidekiq worker answers to its own name, and the bracket carries the
  limit that governs it.** `job:"Billing::Invoices::CreateWorker"` answered
  "No jobs found" for a worker the same tool had just listed, because the
  single-job lookup read the ActiveJob list only. It reads both lists now, and
  a name in neither is a not-found that names what exists. The listing prints
  its "workers the introspector did not see" caveat whenever it prints
  workers, rather than only when `config/sidekiq.yml` happens to exist, and a
  `sidekiq_throttle` prints under the worker it throttles - 438 of 522 workers
  on one app declared one and none of them showed it.
- **onboard's async section reads the workers out of the hash it already
  had.** The section counted jobs, mailers and channels, so an app whose
  background work is 522 Sidekiq workers read as "4 mailers." and the section
  disappeared entirely when workers were the only async code. The "not
  covered" line no longer prints next to a worker list it contradicts.
- **What an ActiveInteraction declares is read in one place.** A filter
  declared inside another filter's block (`string :title` inside `hash
  :order_params do`) is a key of that hash, not an input of the class:
  `service_pattern` showed four inputs where `.filters` has two, and
  `generate_test` passed the other two to `.run`, which drops them silently. A
  subclass of the app's own base interaction is an interaction too, with its
  parent's filters first, so `generate_test` stops emitting `.call`, which
  `ActiveInteraction::Base` does not define. `GenericMacroListener` records
  each call's own offset and its enclosing call's, which is what both tools
  pair filters by.
- **generate_test names the constant the file declares.** A path camelizes
  through Ruby's inflector, which has not read the app's
  `config/initializers/inflections.rb` on the static tier, so
  `ai_reports/build.rb` gave `AiReports::Build` where the app defines
  `AIReports::Build` - a constant nothing defines, in a spec that dies on
  load.
- **service_pattern looks for callers where the app keeps code.** The scan
  named six `app/` directories, so a caller in `app/tools` or under `lib/` was
  invisible. It reads every `app/` and `lib/` tree, plus whatever else a
  booted app autoloads from, and says when the twenty-entry cap or its own
  file ceiling left the list partial.
- **schema tells a missing migration from a typo.** Booted, a table declared
  in `db/schema.rb` and absent from the connected database answered "Did you
  mean 'comments'?". The payload carries the declared tables beside the live
  ones, so the answer names the migration that has not run, and the listing
  header says the two counts disagree instead of pairing a live table count
  with the file's version stamp.
- **A validator under app/models/concerns is not a concern.** The type came
  from the directory alone, so 37 `ActiveModel::Validator` subclasses on one
  app were listed as model concerns used by nothing. They are listed as
  validators - following the app's own validator base class, not one level of
  compare - and looked up by the `validates_with`, or the validation option,
  that wires them, in a model or in a concern's `included` block. The keys
  `validates` reads for itself (`on:`, `if:` and the like) name no
  validator.
- **dependency_graph counts both header numbers over the same models.** The
  model count was app-wide and the association count covered the fifty nodes
  that survived the cap. Both are app-wide now, and the truncation note says
  how many of the associations the cut graph draws.
- **get_context reads the views Rails would resolve.** It handed `GetView`
  the last segment of the controller path, so `Api::V1::Admin::OrdersController`
  picked up `app/views/orders`, a directory of templates a background service
  renders. The answer names the directory its views came from, and a
  flat-directory fallback is labelled as one.
- **analyze_feature finds a test by its path.** A spec whose feature word is a
  directory (`spec/services/billing/invoices/create_spec.rb`) was dropped,
  while the gap checker beside it already matched on the path. The suite's
  own words stay out of the match - the `spec/` root, the type directory it
  files a test under (`models/`, `requests/`), and the `_spec` suffix - so
  `--feature models` is not every model spec.
- **routes answers an exact controller key with its own routes.** A substring
  filter returned a nested sibling's routes too (`api/v1/admin/orders` swept
  in `api/v1/admin/orders/ai_data`), and `get_context` inherited it. A short
  name still matches every controller that carries it.
- **A template at the root of app/views is listed.** Its filename became a
  directory group that matched nothing, so the header counted a file the body
  never printed, and the controller-miss hint suggested a directory that does
  not exist.
- **A word in a quoted string is not an instance variable.** `view` reported
  a chat handle inside a Ruby string literal as a template's ivar; the reader
  strips string literals and keeps interpolation, in ERB tags and in the
  Ruby template handlers (Jbuilder, Builder, `.ruby`), and `get_view`'s
  hydrator reads through the same method. Whichever quote opens first owns
  the literal, so an apostrophe inside `"Don't"` does not swallow the ivar
  beside it.
- **env_config tells a re-assignment from a tuple.** Two unconditional
  assignments of one key rendered as `:file, :test`, which reads exactly like
  `:mem_cache_store, { pool_size: 5 }`. The winner is named, with what it
  overrode.
- **env keeps one default per call site.** One label for every site said a
  variable was optional while one of its reads was `ENV.fetch` with no
  default, which raises `KeyError`. A fetch whose fallback is an expression
  says its default is computed at runtime rather than claiming it has none,
  and an `ENV["X"]` read says it is nil when unset, apart from the fetch
  that raises.
- **A Rack app attached with `match ... to:` is found.** `mount` is that call
  with a name derived, and the exact-path form is what an app writes when an
  unanchored mount would swallow a sibling path. It reaches `engines` and
  `routes`, which names the mounted apps it counts instead of calling them
  engine mounts, and the booted tier lists every Rack endpoint rather than
  `Rails::Engine` subclasses alone. A mount inside a `namespace` or `scope`
  carries that prefix; one whose enclosing scope, or its `path:`, is an expression is listed
  with no path rather than an unprefixed one, and every list prints it
  without one. `engines` follows every file `config/routes.rb` draws,
  through the walk the static `routes` answer uses, so on the static tier
  the two name one set of mounted apps; booted, `routes` reads the live
  route table. `engines`, `onboard`, the MCP resource and the
  generated context files head the same list "Mounted Apps", because half of
  what it holds are not engines. On the static tier a `match ... to: SomeApp`
  is counted once, as the mount it is, rather than also as a construct the
  walk could not expand, and so are `get "/status" => StatusApp` and
  `mount ActionCable.server => "/cable"`, which the walk did not see at all.
- **config calls a zero-byte initializer empty** rather than "all commented
  out".
- **Smaller corrections in the same pass.** `validate_semantics` asks the
  loaded model class before calling a callback method missing, and on the
  static tier makes no claim once the payload's method list was cut at its
  cap, so an inherited method past the cap is no longer reported as missing.
  `get_controllers` points
  `rails_get_view` at the controller's full path rather than its last segment,
  which is the directory Rails resolves. The stack overview's `Engines:` line
  is `Mounted:`, because half of what it lists are plain Rack apps.
- **diagnose stops reading a display cap as a model's whole interface.** A
  method past the thirtieth was reported as not existing, in the same answer
  whose Method Trace printed its definition. Booted, diagnose asks the loaded
  model class, which knows a concern's methods and a gem's as well as the
  model's own. Statically, the model's own methods travel uncapped beside the
  capped display list, and where a concern or a parent could define the
  method the answer declines rather than guesses. `model_details` says how
  many of the model's methods it is showing.
- **A CamelCase controller name resolves everywhere.** The needle was
  downcased without being underscored, so "GiftCards" never equalled the
  route key's own "gift_cards": `Payload.find_controller` missed it, and every
  tool that resolves a controller through it missed it too. One normalization
  now serves the payload, the routes tool and the MCP resource, and the
  resource answers a name that resolves to nothing with an error naming what
  exists rather than a zero-route success document.
- **security_scan runs the brakeman the machine has.** The app's bundle
  narrows the load path, so a machine with brakeman installed was told to add
  it to the Gemfile while the other tier scanned the same app. When the
  in-process require fails and the gem is installed, the scan runs it as its
  own process outside the bundle - reading the report from a file of its own,
  since a gem manager's binstub can print to stdout first - and renders the
  result the same way, with a line saying which brakeman answered and from
  where. When the outside run writes no report, the answer carries the last
  line brakeman printed about why. With no brakeman anywhere, the message
  says that instead of guessing, and the availability answer is keyed by
  tier rather than decided once per process.
- **An exact search with a space keeps its context lines on ripgrep 13.**
  The literal was escaped with Ruby's `\ `, which ripgrep 13 (Ubuntu 22.04,
  Debian 12) rejects, so the search fell back to the Ruby scan and dropped
  context lines and files with no listed extension. The space goes through
  unescaped now, which both engines read the same way.

## [5.28.0] - 2026-09-22

Thirty-six changes an architecture survey of v5.27.0 asked for, nine of them
defects where a user got a wrong answer, plus what three review rounds found in
the fixes themselves.

### Added

- **Services, helpers, jobs and concerns are found wherever the app keeps
  them.** The four tools globbed `app/<kind>` off the app root, so a packwerk
  app whose services live under `packs/billing/app/services` was told it had no
  services directory and may not use the pattern. Directory discovery reads
  `PathResolver.dirs_for`, which already resolved packs, engines and
  `extra_app_paths` for the payload side. `ConcernPaths.resolve` and
  `ActiveSupportIntrospector` read the same resolver, so a concern's listing,
  its lookup and its "Used By" line now agree on one app. Counts move on any
  app with packs or engines. Each walk names the directory a file came from, so
  two files of the same basename under different roots no longer collide, and a
  tool that finds nothing names all three directory patterns it searched
  instead of the conventional one alone.
- **`RailsAiContext.debug_fail`.** About 258 rescue bodies in `lib/`
  hand-rolled the same three lines: rescue the error, write a `DEBUG`-gated
  warning to stderr, return a fallback. They call one method now, with every
  message string and every fallback value unchanged. `exe/rails-ai-context`
  shims it beside `log_warn`, because the standalone install path loads seven
  files by hand and a converted rescue inside `install_mode.rb` would otherwise
  raise `NoMethodError` after the removed-tool cleanup had already deleted
  files.
- **`PackageJson`.** GemLock's twin for the node side: `package.json` parsed
  once per root, `dependencies` merged with `devDependencies`, capped by
  `configuration.max_file_size` rather than by a constant no caller can reach,
  and empty for anything it cannot read. A scope named after the package
  counts, so an app reaching tailwind through `@tailwindcss/vite` keeps its
  answer.

### Removed

- **`config.job_processor`, gone from `.ai-context.json` and from
  `get_config`.** `ConfigIntrospector` parsed `config/sidekiq.yml` a second
  time to publish it, and nothing read it: no renderer, no spec, no template.
  The two readers disagreed, so a `:queues:` block written with weights,
  `- [critical, 2]`, lost `critical` on the config side and kept it on the jobs
  side, and one sidekiq.yml shipped two queue lists in one payload. The same
  concurrency and queues stay under `jobs.sidekiq_config`, which
  `get_job_pattern` already consumes, and `config.queue_adapter` still names
  the adapter. Both sections sit in the standard and full presets, so no preset
  loses the fact.
- **`action_bindings` and `outlet_controllers`, gone from every Stimulus
  controller entry.** Filling `action_bindings` read every ERB, HAML and Slim
  file under `app/views` and `app/components` on every generation, and
  `outlet_controllers` restated the outlets list one line above it. Nothing in
  `lib/` read either key: `get_stimulus` renders outlets, and the compact
  serializer touches the section through `controllers` and `total_controllers`.
  Both keys leave the artifact, and one full pass over the view and component
  trees leaves every generation.
- **`Serializers::SectionGuard`, `DetailLevel::SCHEMA_ENUM` and
  `Install::Program.select_tool_mode`.** SectionGuard was 15 lines forwarding
  to `Tools::SectionFetch.usable?`; both callers sat in `SchemaAdapter`, which
  is not a serializer, and `RouteCoverage` already called SectionFetch
  directly. SCHEMA_ENUM went with its last reference when
  `DetailLevel.schema(description)` replaced the same four-line input-schema
  hash in 21 tools; every published schema is byte-identical, and
  `rails_onboard` keeps its own literal because its levels are quick, standard
  and full. `select_tool_mode` was a shim for `select_setup(surface).tool_mode`
  with no caller left in `lib/`, and it cannot express the MCP-config-only
  mode. `ModelIntrospector#sti_bases` and
  `ControllerIntrospector#extract_permit_details` go with them; only their own
  recursion and their own specs were calling them.

### Changed

- **`.github/instructions/rails-context.instructions.md` prints every gem
  category.** `.first(6)` on the grouped Hash returned the first six pairs, so
  the seventh category onward was dropped with nothing saying so, while
  `.cursor/rules/rails-project.mdc` rendered the same grouping uncapped. One
  payload, two gem lists.
- **`.cursor/rules/rails-project.mdc` bolds `Global before_actions:`** like the
  Claude and Copilot files. The three serializers each hand-wrote the same
  ten-step overview and had drifted; `StackOverviewHelper#overview_lines`
  states the body once and each renderer keeps only its frontmatter, title and
  MCP hint.
- **Puma settings are read inside blocks.** The hand-rolled recursion stopped
  at the top level, so a `workers` line guarded by an environment conditional,
  which is what the generated `puma.rb` ships, was invisible and the answer
  read as no workers configured. `MethodCallListener` sees a receiverless call
  at any depth. The cost of the widening is that nesting no longer hides a
  setting, so a name set twice reports the last one wherever it sits. Also
  `threads ENV.fetch("RAILS_MIN_THREADS") { 5 }, ENV.fetch("RAILS_MAX_THREADS")
  { 5 }` reports 5 and 5 where it reported nothing, and the digit match is
  anchored away from word characters, so `ENV.fetch("PORT_2", 3000)` no longer
  reads as 2.
- **`get_conventions`' frontend stack string reads parsed dependencies.**
  `detect_frontend_stack` matched bare substrings against the raw file, with no
  quotes at all, so `vite-plugin-ruby` on its own reported Vite. The markers
  carry alternates where an exact name would have lost an answer the substring
  caught: svelte or `@sveltejs/kit`, `@hotwired/turbo` or
  `@hotwired/turbo-rails`.
- **`api_introspector`'s codegen list reads parsed dependencies.** It searched
  the file for the quoted tool name, so `openapi-typescript`, `orval` or
  `@graphql-codegen/cli` named anywhere in `package.json`, an `overrides` block
  included, counted as a client generator the app runs.
- **`rails_generate_test` resolves a controller by the rule
  `rails_get_controllers` uses.** It camelized the string and looked the result
  up, so with `Admin::GiftCardsController` as the only gift-card controller,
  `rails_get_controllers(controller: "gift_cards")` resolved and
  `rails_generate_test(controller: "gift_cards")` answered "not found".
  `Payload.find_controller` answers for both, with the camelize kept as the
  fallback for a payload carrying no controllers at all.

### Fixed

Nine defects the survey confirmed against v5.27.0, and the defects three review
rounds found in the work that fixed them.

- **`onboard(detail: "quick")` no longer prints a guessed domain noun.** Eleven
  ordered regexes read model, job and service names and stated the result as
  plain fact with no confidence marker, so one model named `Message` made an
  app "a messaging app". Quick mode now states what it measured: versions,
  table, model and job counts, the frontend and the test framework.
- **`api_namespaces` invented a namespace and missed one.** The two tiers
  derived the list their own way. The booted regex kept a trailing slash on
  `/api/users`, matched unanchored so `namespace :admin { namespace :api }`
  reported `/api/v1` for an app that serves `/admin/api/v1`, and dropped a
  route sitting at exactly `/api`. The static spelling got the segment boundary
  wrong, so `/apidocs` reported `/api`. Both tiers read one anchored form.
- **Turbo drive settings were double-counted for layouts.** `app/views/layouts`
  was walked again after `app/views/**/*` had already reached it. The permanent
  element pass threw its duplicate away through `uniq`; the drive settings did
  not, so one attribute in a layout and one in a view printed as 3.
- **The asset pipeline reported the wrong bundler and CSS framework.** Three
  readers asked whether a package was present by searching the raw file for its
  quoted name, so an app pinning CVE fixes in an `overrides` block was told
  esbuild is its bundler and postcss its CSS framework, while the one reader
  that parsed the file called the same app vite. Both answers landed in one
  payload.
- **`analyze_feature`'s Jobs, Mailers and Channels sections came from a glob.**
  Each job's queue was read off its own `queue_as`, so a job inheriting the
  queue from `ApplicationJob` was reported on a queue it does not use. The
  three sections read the payload now, which carries what the booted tier
  resolved, mailer actions and channel stream methods included. A section whose
  payload entry is not there, because the `:jobs` introspector is off, is left
  out rather than rendered from a directory walk.
- **`performance_check` attributed queries to methods that are not actions.** A
  `def` inside a nested class became a call site, and a one-line
  `private def set_post` leaked its body into the action above it.
  `ActionResolver` answers what an action is here, as it does everywhere else.
  A second collision went with it: each body was found by searching the whole
  file for the first `def <name>`, so a nested class defining the same name
  earlier handed back its body and the real action was never scanned. The body
  is cut from the lines the owner-filtered walk recorded, and `get_controllers`
  and `get_context` share the seam. An empty owner filter falls back to the
  line scan rather than answering nothing, and `def self.index` no longer
  stands in for `def index`.
- **A model whose only rule is `validate :method` printed its bullets under the
  wrong heading.** `## Validations` was emitted only when the reflected list
  had entries, and the custom bullets come from a second list that is disjoint
  from it on both tiers, so they landed under Associations.
- **Two ERB readers missed `<%== ... %>` and read a commented ivar as used.**
  `check_instance_variable_usage` and `extract_local_variable_references` each
  carried their own copy of the tag regex, byte for byte the same and neither
  matching `ErbSource::TAG`. Both read `<%[=\-]?`, one optional character, so
  `<%== title %>` parsed as a body of "= title" and the local never reached a
  partial's expected locals. The comment skip was a second answer too:
  `get_partial_interface` re-implemented it and `validate_semantics` never had
  one, so `<%# @ghost %>` was reported as an ivar used in the view and not set
  in the controller. Both readers ask `ErbSource` now.
- **`rails_get_controllers` refused a name the VFS resource accepts.** VFS
  resolved five ways, the tool two, so `controller: "gift_cards"` failed
  against `Admin::GiftCardsController` while the resource answered off the same
  payload. Both read `Payload.find_controller`, so a route key, an unambiguous
  basename and the singularize and classify spellings now resolve in the tool
  too.
- **Two files behind one name no longer hide each other.** Once services,
  helpers and concerns were read from packs and engines, a name could have more
  than one file behind it. The ambiguous-service list printed
  `app/services/<path>` for files that live under a pack, so two candidates
  printed as two identical lines naming a file that exists in neither, and the
  suggestion that followed handed back the name it had just refused. Paths
  print from the app root, and a narrowing suggestion is offered only when some
  candidate's relative path is unique. `rails_get_helper_methods` rendered the
  first match as the whole module and listed the others under "Also defined
  in" even when they declare different modules, so a file declaring
  `Reports::DashboardHelper` was named under an `Admin::DashboardHelper`
  heading; matches are split by the module each file declares.
  `rails_get_concern` broke on the first directory that resolved, so an app
  with both `app/models/concerns/trackable.rb` and
  `app/controllers/concerns/trackable.rb` saw only the controller one. Every
  "available" list is deduplicated where it is built.

## [5.27.0] - 2026-09-22

### Added

- **MCP-only install (`--mcp-only`, `config.context_files`).** Some apps keep
  their own `CLAUDE.md`, `AGENTS.md`, rules files and Copilot instructions and
  want the server and nothing else. There was no supported way to ask for it:
  every install entry point ended by generating context files. The install
  menu now has a third answer, `rails generate rails_ai_context:install
  --mcp-only` and `rails-ai-context init --mcp-only` take it non-interactively,
  and the choice is recorded in the initializer and the YAML like the tool
  mode. With it off, `ai:context` writes nothing and exits 0, `ai:watch` writes
  nothing, `ai:doctor` raises no context-file warning, and the `.ai-context.json`
  line is left out of `.gitignore` because nothing writes that file. A command
  that names a file still writes it: `ai:context:claude` and
  `context --format claude` both work.
- **Sidekiq workers in `job_pattern`.** A class that includes `Sidekiq::Job` is
  not an ActiveJob descendant and does not live in `app/jobs`, so both job
  passes missed it and no tool in either tier could describe the biggest code
  area of an app that runs its background work that way. Workers are read from
  `app/workers` in both tiers, with each one's `sidekiq_options` and `perform`
  signature. The conventions directory structure counts every directory the app
  keeps under `app/` rather than a fixed list.
- **ActiveInteraction services.** `service_pattern` lists a service's declared
  filters with their types and defaults, names `ActiveInteraction::Base` as the
  dominant pattern when it is, and `generate_test` writes `.run` with those
  filters rather than a `.call` the base class does not define.
- **Notable gems that shape an app.** `active_interaction`, `paper_trail`,
  `rack-cors`, `figaro`, `webauthn`, `stripe`, `plaid`, `braintree`,
  `lockbox`, `blind_index`, `neighbor`, `pgvector`, `interactor`,
  `trailblazer-operation` and the Sidekiq add-ons (`sidekiq-pro`,
  `sidekiq-scheduler`, `sidekiq-cron`, `sidekiq-unique-jobs`,
  `sidekiq-throttled`).

### Changed

- **`config.ai_tools = []` writes no context files.** It used to write every
  tool's files, which is the opposite of what the value says and of what
  `ContextFileSerializer` has always done with `format: []`. Only an unset
  selection means "all". The install flow never produced an empty list, so this
  reaches hand-edited configs only.
- **The inherited filter list is emitted root first.** Rails runs the root's
  callbacks first, and the static tier printed the nearest parent's first, so a
  chain read as authentication running before the current user is loaded.
- **A filter no ancestor's body declares names no class.** `sentry_around_action`
  and `set_paper_trail_whodunnit` arrive through a gem's
  `on_load :action_controller` block; crediting them to the nearest app
  controller sent an agent to a file that never mentions them. They now carry
  `provenance` instead of `from`.
- **Model callbacks print the macro Rails has.** `after_commit_on_create` is a
  key this gem synthesizes to order the events of one `after_commit on: [...]`;
  copying it got a `NoMethodError`. Every renderer prints
  `after_commit (on: :create)`.
- **`sanitize_options` keeps Array, numeric, boolean, nil and Symbol option
  values.** They were stringified, so `in: %w[draft sent]` reached
  `generate_test` as one String and `in_array` got a quoted list. A consumer
  reading `validations[].options`, `.ai-context.json` included, sees the
  change: `dependent: :destroy` is the Symbol `:destroy` rather than
  `"destroy"`, and `allow_nil: false` is `false` rather than the truthy String
  `"false"`.
- **Only a handler extension counts as a template.** A JPEG or a seed file under
  `app/views` was counted as a template and had ivar names read out of its
  bytes.

### Fixed

Defects found by a tenth QA round of v5.26.0 against a private Rails 8.0.5.1
API-only app (issues #184 to #222), each rebuilt on a minimal fixture before
filing.

- **One dangling reflection cost the whole model.** A `has_many :through` naming
  an association the model does not declare loads fine and only raises when
  something touches it, so `class_name` ended in `nil.klass` and the per-model
  rescue replaced the model - its callbacks, its table heading, its graph node -
  with a single error line. The rescue is per association now, and the
  reflection is marked `[UNAVAILABLE: through :x is not an association]`.
- **The MCP transport lost its stdout across a Bundler re-exec.** `exec` closed
  the saved descriptor, so the new image saved fd 1, by then pointing at stderr,
  and wrote every JSON-RPC response there. A client launched from outside the
  app got no answer to `initialize`.
- **`dependency_graph` drew nodes no app defines.** A `through` hop was the
  association name camelized (`PrimaryBuyer`, `InvoicePdfAttachment`), the
  static target ignored `source:`, and a derived name knew none of the app's
  acronyms. It also cut the graph at 50 models without saying so.
- **`service_pattern` named a service after a word in a comment.** The regex ran
  over raw source, never matched `module`, and its basename fallback dropped
  every namespace. The lookup matched by basename before exact path, so only
  the alphabetically first `create.rb` could be looked up, and "Called By" was a
  substring search that listed a non-caller and dropped the real one.
- **Static route helper names did not exist.** Hyphens were kept
  (`api_v1_gift-cards_redeem_path` is a subtraction in Ruby), a dotted path was
  used in the name where Rails uses none, and a name that cannot be one was
  kept anyway. A booted redirect route appeared in no row and no count.
- **`get_context` for one action listed every strong-params method in the
  controller**, so `create_params`' permit list read as the fields `deactivate`
  accepts.
- **Controller Schema Hints reported services, serializers and plain constants
  as missing models.** Only names that resolve to a model are kept now, and the
  rest are dropped without a line.
- **`env` read only `.rb` files**, so ENV names in `config/*.yml`, ERB views and
  rake tasks were missing with nothing saying a file type was skipped. Category
  matching was unanchored (`PORT` inside `PORTAL`), and a `nil` default printed
  as `[FILTERED]`.
- **`env_config` reported the first assignment in a file**, so it printed the
  branch that is not running and disagreed with `config` on the same app.
- **`gems` reported a Minitest suite in a `test/` directory that is not there**,
  from a lockfile entry every Rails app resolves through activesupport, and
  pointed at a `config/sidekiq.yml` without checking that it exists.
- **`generate_test` wrote specs that cannot run.** Shoulda matchers were emitted
  into apps that do not bundle the gem, a namespaced controller produced
  `create(:api/v1/admin/order)`, the example sent GET whatever the route's verb,
  and a controller with no file was answered with "no routes found".
- **`performance_check` suggested indexes and counters the app cannot use.**
  Every unindexed `*_id` column was a missing foreign key index whatever its
  type, and a counter the app maintains itself was offered a `counter_cache`
  that double-counts every create.
- **`query` answered an unknown column with "Database not found" and exit 0.**
  Postgres words a missing column, table and database the same way.
- **`view` counted images and text files as templates**, read ivars out of
  binary data, and read the CSS rule `@page` as an ivar.
- **`partial_interface` could not resolve a `.text.erb` partial** by the Rails
  name its own "Available" list had just printed, and cut a local's method calls
  at ten with no marker.
- **`api` merged every CORS allow block and environment branch into one origin
  list**, so the line read as the API allowing `*` on every resource.
- **`active_support` listed validator classes as "plain module" concerns.**
- **`validate` flagged an `acceptance:` virtual attribute as a missing column**
  and suggested a migration for a column nobody needs.
- **`search_code --match-type trace` reported no internal calls** for a body
  whose calls take no parentheses, counted a comment mentioning the method as a
  call site, and tagged `app/services/models/...` as a Model.
- **Static answers missed an app's inflections.** A route group found no
  controller for `api/v1/ai_matches`, and a service file with no `class` line
  was named by its camelized basename.
- **The `controllers/{name}` resource refused a short name** the `routes/{name}`
  resource accepts, and the controller answer pointed at a model that does not
  exist.
- **`ai:watch` rewrote every tool's files** whatever the configuration asked
  for.

## [5.26.0] - 2026-09-11

### Added

- **`docs/RELEASING.md`.** Every release rediscovered the same list by reading
  the release workflow: the changelog heading the notes are extracted from, the
  two files carrying the version, and the end-to-end run the gate wants against
  the exact commit before a tag will publish. Its first step picks the version
  from the Changed section, which nothing downstream checks. `CONTRIBUTING.md`
  points at it.

### Fixed

Defects found by a ninth QA round of v5.25.0 against Mastodon (issues #160
to #181), the sibling defects behind them, and what nine review rounds and
repeated from-scratch verification found in the fixes themselves. Most of the
entries below are older than the twenty-two reports; the reports are where the
looking started. One entry is a consumer-visible key rename and is under
Changed.

- **`excluded_association_names` was ignored everywhere except the booted
  ActiveRecord path.** The key had one call site, inside the reflection-only
  association extractor, so a `--no-boot` answer and every Mongoid answer
  listed the associations the config asked to hide, with nothing saying the
  key had been skipped. One predicate now reads the key for all three
  builders, comparing the name as text because the listener names an
  association with a Symbol and reflection with a String.
- **The static model builder dropped every attribute macro it parsed.**
  `static_model_details` assembled its hash by hand and passed the listener's
  raw records straight through, so `encrypts`, `normalizes`, `serialize`,
  `store`, attachments and delegations vanished from `get_env`, `get_schema`,
  `onboard` and `get_model_details` with no marker, and the `enums` key
  carried records where consumers destructure an attribute-to-values Hash. It
  merges the same two mappers the booted builder merges, builds enums in the
  booted shape with String keys on both levels, and derives
  `custom_validates`. The encryption and normalizes renderers read keys the
  builder never emitted and printed `- **** ...`; they read `field` and
  `transformation` now, and a transformation the parser could not resolve is
  marked rather than named. Options are spelled as `key: value` pairs, so the
  line reads the same on every Ruby, and a plain `encrypts` with no options
  prints the attribute alone.
- **A callback declared as an anonymous block was listed as a callback named
  `do`, and the two tools that list one did not agree.** The word the
  declaration line is composed from was reused wherever the tools print a comma
  list of callback target names, so `after_create do ... end` read as a method
  called `do` in the callbacks listing, in the model details and in the feature
  analysis. A block is listed by the payload's own `[inline_block]` marker now,
  the same marker in all three. The concern declaration lines still read
  `after_create do`, because that is what the file says, and `generate_test`
  names one "runs its inline block" rather than writing the marker into an
  example name.
- **One commit event's two spellings were printed apart, with the second below
  `after_rollback`.** `after_create_commit :x` and `after_commit :y, on:
  :create` run at the same point, and the gem keeps each declaration as the
  file wrote it, but the synthesized key was missing from the execution order
  so it sorted to the end. Mastodon's `Status` printed the second half of
  three events after the rollback callbacks.
- **Callbacks were named after the wrong thing, and `around` callbacks
  disappeared.** The concern section re-parsed the file with a line regex
  whose colon was optional, so `after_create do` printed as `after_create :do`
  and `around_create Some::CallbackObject` as `around_create :Some`. The
  listener kept only symbol arguments, so a callback whose target is a class
  object was dropped in both tiers. Callbacks now print the declared macro, a
  lambda reports as a block, and `after_touch`, `after_initialize` and
  `after_find` join the execution order. Both tiers read the declarations off
  the model's own source, so the booted answer keys `after_create_commit` the
  way the static one does and keeps a `before_save do ... end`: Rails' event
  chains carry the framework's own registrations and hold no block callbacks,
  so they are not read.
- **`rails_get_concern` listed only thirteen callback macros.** Its parser
  named the macros it knew, so `after_commit`, `after_rollback`,
  `after_touch`, `after_initialize`, `after_find` and the `*_commit` family
  were filed under the concern's Macros section and dropped from its Callbacks
  section. It walks the source with the same listener the model and callback
  tools use, and renders each declaration through the one helper they share.
- **The static tier answered `0 assoc` for a model whose associations all live
  in concerns.** It walked the model file alone, so Mastodon's `Account`
  reported no associations where 68 are declared across the 21 concerns it
  includes, and nothing marked the gap. Both tiers now walk the included
  concern files with the same listeners and merge what they declare, tagged
  with the concern that declared it, following a concern that includes another
  and deduping on the model's own declaration. A concern whose file cannot be
  found is named under Concerns as not read, and `find_file` prefers the
  owner's concerns directory and walks the enclosing namespaces outward so a
  namespace-relative `include` resolves the way Ruby resolves it. The "From
  Concerns" section of `rails_get_callbacks` attributes each callback to the
  concern that declared it, with the options it was written with, and at
  `detail: "full"` the body is printed once, in the ordered list, read from
  the concern file. On the booted tier an unread concern is marked for the
  keys it costs (scopes, callbacks and macros), since reflection already
  answered the rest. A concern shared by many models is walked once per run.
- **An STI child that declared nothing answered "0 assoc, 0 val" in the static
  tier.** The static model walk followed the superclass chain for the table
  but not for the macros, so a child class inherited its base's table and none
  of its associations, validations, scopes, callbacks or macros, and the
  schema heading named it with zero counts beside its base. It now merges each
  STI base's declarations the way it merges a concern's, the nearer
  declaration winning over the further one.
- **An STI child's booted answer dropped every declaration its base made.**
  The static tier merged an STI base's scopes, callbacks and attribute macros
  into the child while the booted tier read the child's own file alone, so a
  child that declared nothing answered no scopes and no callbacks under
  `[VERIFIED]` while the static tier named them, and the running child carries
  both. Reflection inherits associations, validations and enums only, so the
  booted tier walks the base chain the way it walks the concerns and
  overwrites those three from reflection afterwards. The base source is read
  through the run's cache, so a base with many children is walked once.
- **One unreadable STI base wiped out its children's whole entries.** The
  booted walk read the base file with no size check and no rescue, so an
  oversize or unreadable base collapsed the child to a single error line,
  losing its table name, associations, validations, enums, callbacks, scopes
  and methods. A base the walk cannot read now costs that base's own
  declarations, and its name goes into the unread list.
- **An STI base whose file could not be read was reported as an unread
  concern.** Both tiers put it in the list the concern walk fills, and that
  list is only printed inside the Concerns section, so a child with no
  concerns said nothing about the base at all and a child with one called the
  base a concern. An unreadable base comes back under its own key now and is
  named under the table line.
- **An association written `dependent: nil` was lifted onto the record as an
  empty string.** The static tier kept the key on presence alone, so
  `generate_test` wrote `it { is_expected.to have_many(:replies).dependent(:)
  }` into the file the tool tells you to paste, and that line does not parse;
  the model details printed a blank `dependent:` for the same row. Mastodon
  declares it nineteen times. A nil value is dropped now, the way the booted
  tier already dropped it, and `optional: false` and `polymorphic: false` keep
  their keys.
- **A model whose own file could not be read lost its whole entry.** The
  constants walk parsed the model file a second time with no size check, so an
  unreadable or oversize file raised past the source walk and the entry became
  one error line. Both reads ask the same question about what the introspector
  will open, and a file declined once is not opened again.
- **A booted model was read out of whichever file Ruby happened to record the
  constant in.** Letting a gem's model keep the gem's own path also believed a
  location that is neither the app nor a gem: where Zeitwerk sets the constant
  rather than letting the file define it, Ruby records Zeitwerk's own
  `cref.rb`, and the walk read that. This repository's own dummy model
  answered no callbacks, no scopes and no enums, reported Zeitwerk's internal
  module as an unread concern, and wrote a path into a gem as the model's
  file. A location inside the app is the model's own file; one outside it is
  believed only when the app has no file of its own, which is what a gem's
  model looks like.
- **A model or controller the walk could not read was written into the
  generated files as an entry with nothing in it.** The Claude rules said "0
  assocs, 0 validations", the Cursor and Copilot rules said "(0 actions)", the
  four root files printed a bare name, and the markdown format dropped the
  entry under a heading that still counted it, while the tool answering the
  same question already said the file could not be read. Every listing names
  the entry with its reason now, the count still includes it because the app
  has it, and the wording lives once so the generated files and the tool
  listings give the same answer.
- **An unreadable model file took its STI children down with it, in silence.**
  The file was dropped from the walk, so its children lost the only route they
  had to `ApplicationRecord`, and an app whose models all descend from one
  such base answered that it had no models at all. The file stays in the walk
  with the reason it could not be read, the children resolve their base and
  its table again, and the listing prints the entry with an `[UNAVAILABLE]`
  marker.
- **A static model entry said [STATIC] while the records inside it said
  [VERIFIED].** Associations, validations, scopes and methods carried the
  source listener's own mark, so `get_model_details` printed a scope as
  verified directly under a static header and every association row written
  into `.ai-context.json` carried the same contradiction to whatever reads
  that file. Every record in a static entry carries the
  entry's mark now. A scope whose body the parser could not resolve keeps its
  lower [INFERRED]. A hydrated Schema Hints block follows the same rule: it
  headed a static model [VERIFIED] because it keyed the tag on whether a
  schema table was found, so on one static run `controllers` and
  `model_details` headed the same model differently.
- **`dependency_graph --show-sti` was a silent no-op without a booted app.**
  The static model walk resolves the inheritance chain to share an STI base's
  table and macros, and never reported it, so the flag added a section booted
  and changed nothing static. Static model entries carry the same `sti` hash
  the booted tier reports.
- **A second `validates` on the same attribute and kind was dropped.**
  `rails_get_model_details` collapsed validations on kind and attribute alone,
  so a model that validates one attribute twice under different conditions
  lost the second rule; Mastodon's `Account` lost its local-username length
  limit and its `uri` exclusion. The options are part of the key now, and only
  a byte-identical repeat is collapsed.
- **`rails_get_model_details` printed `validates` as the kind of a
  validation.** A rule written `validates :followers_url, absence: true` names
  its kind in the option, and the reader saw the macro name instead;
  `validates :uri, absence: true, exclusion: { in: [''] }` lost its absence
  rule into the exclusion row. The kind list was a closed allow-list with no
  `absence` in it. Rails treats every key that is not `if`, `unless`, `on`,
  `allow_nil`, `allow_blank`, `strict` or `message` as naming a validator, so
  the walk does too, which also gives an app's own validator its real name.
- **Rails' anonymous join class for a `has_and_belongs_to_many` was reported
  as one of the app's models.** Rails names it through a singleton `name=`, so
  it answered `HABTM_Tags` while living at `Account::HABTM_Tags`, and the
  booted walk kept it: an invented `app/models/habtm_tags.rb`, a `belongs_to`
  to a class named nowhere, and a `[VERIFIED]` block for a model that does not
  exist. Two owners of the same association name also collapsed onto one
  entry. A class whose name is not the constant it lives at is no longer a
  model, so Mastodon's model count drops from 117 to 114.
- **A gem's model was written into `.ai-context.json` with an app path that
  does not exist.** Doorkeeper's three models were recorded at
  `app/models/doorkeeper/access_grant.rb` and friends, the invented path the
  containment check exists to prevent. The gem's own path is carried now, with
  the install prefix dropped, so the entry reads
  `doorkeeper-5.8.2/app/models/doorkeeper/access_grant.rb`; a class Ruby knows
  no source for carries no file at all.
- **A gem-owned model's file could not be told from an app file.** It was
  written as a gem-relative path into a field every other model fills
  app-relative, and resolved against the app root it names a file that is not
  there. A gem path in that field carries a `gem:` prefix now.
- **A model file the app cannot load was answered as no such model, with its
  table listed as orphaned.** Zeitwerk never loads a file with a syntax error,
  so reflection never saw the class and the booted walk dropped it. The name
  is kept now, with the load error and with the table the static walk reads
  off the same file.
- **The static tier derived every table from the file name alone.** An
  explicit `self.table_name =`, a `table_name_prefix` declared by the
  enclosing module and an STI child's parent table were all ignored, so
  Mastodon's `Admin::ActionLog` answered `action_logs` and rendered no
  columns, and `admin_action_logs` had no model in the schema listing.
  `TableName` reads those declarations out of source and the model walk
  composes them in Rails' own order. The readers that turned a model name into
  a table go through the same module now, so `rails_get_schema(table:
  "Admin::ActionLog")` finds the table and `rails_migration_advisor` stops
  rejecting `admin/action_logs` as an invalid name.
- **`remove_column` advice could name an STI child's file.** The
  `ignored_columns` step took the first model recorded against the table, and
  every class in an STI family records the same one, so `AdminUser` could win
  over `User`. The conventional name wins when it is one of the owners.
- **A model nested inside a module body lost its explicit `self.table_name` in
  the performance check.** The declaration was looked up under the bare class
  name while the file writes a qualified one, so the N+1 and counter-cache
  checks read the wrong table or skipped the model. The declared constant is
  resolved first, the way the model walk names a file.
- **A model written inside a `module` body was named by its bare class name in
  the performance report.** The counter_cache and eager-load sections printed
  `ActionLog` for a model the app calls `Admin::ActionLog`, so filtering
  `performance_check` by the real constant answered "no issues" for a row the
  same report had just listed. Every row carries the qualified declared name,
  and the places that need a bare word (the `belongs_to` symbol in the
  suggestion, the sibling model lookup and the controller scan) demodulize it.
- **The counter-cache suggestion named a class a namespaced app cannot
  resolve.** The row's model key carried the qualified constant while the
  suggestion guessed a bare name off the association, so the two halves of one
  row disagreed. It names the model the introspector already resolved, and
  falls back to the guess only when nothing in the app answered.
- **An n+1 row named the wrong model when two models shared one short name.**
  The lookup keyed models on the name without its namespace, one entry per
  key, so an app with both `Billing::Invoice` and `Legacy::Invoice` kept only
  the one written last and pinned every bare `Invoice` row to it. The key is
  still the bare word, since that is what a controller writes, but the lookup
  holds every model of that name and the controller file's own lexical scopes
  choose among them, outermost last. A name no scope resolves is left out
  rather than guessed.
- **A counter_cache suggestion named a model that does not exist.** The row
  derived the far side of a `has_many` from the association name, so `has_many
  :remarks, class_name: "Comment"` sent the reader to a `Remark`, and
  Mastodon's `Poll` named `Vote` and `Voter` for `PollVote`. It reads the
  association's own `class_name` now, drops the row when no model in the app
  answers it, skips a `has_many ... through:` because there is no `belongs_to`
  on the far side to carry the counter, and names a polymorphic inverse by the
  association's `:as` option.
- **Two n+1 findings on one association printed as one line twice.** The
  controller and the action appeared only at full detail, so the default
  listing showed identical rows and the section count did not reconcile with
  what a reader could see. Every row carries its call site now.
- **"Orphaned tables" named tables that have a model.** On Mastodon the
  warning listed seven tables of which one was real: four belong to Doorkeeper
  and PgHero, whose models live in the gem, and two are
  `has_and_belongs_to_many` join tables Rails builds no model for by design.
  Join tables are recognised from the association records and left out, and
  the line claims only what it can prove, that no model file in this app
  declares the table.
- **Routing concerns dropped their routes, and `with_options` and `module:`
  named controllers that do not exist.** A `concern :x do ... end` body was
  stored nowhere, so the controllers declared only inside it had no static
  routes and no marker either. The body is kept now and re-walked at each
  `concerns:` site with the scope as it stands there, the way Rails re-runs it
  on the mapper. `with_options` is an OptionMerger, not a routing method, so
  it became a frame of default options that every call inside merges under its
  own - which is what stops six of Mastodon's account routes being filed under
  a controller named `@:username`, and stops `with_options only: [:index]`
  expanding a resource into all eight RESTful rows. Those defaults reach a
  `namespace` or `scope` inside the block too, where a `module:` or `as:` from
  them replaces the block's own name, as `defaults.merge!(options)` does in
  the mapper. `module:` on a resource moves the controller and never the path,
  so `admin/distributions` is `admin/announcements/distributions` and
  `admin/terms_of_service/distributions` again. `as:` and `param:` on a
  resource are read too, so the new rows carry the helper name and the member
  segment the app actually has (`/users/:account_username`, not
  `/users/:account_id`). On Mastodon the static total falls, 658 routes to 657
  and 22 undisclosed dynamic constructs to 21: 69 real rows arrive and 76
  fabricated ones go.
- **A collection route helper was named after the resource pluralized.**
  `resources :following` named the index route `followings` and `resources
  :photos, as: :image` named it `images`, neither of which any app defines.
  Rails builds the collection name from the `as:` value, or the resource name,
  exactly as written, and appends `_index` when that name is already singular.
  The static walker does the same now, so Mastodon's `resources :following`
  reports `following_index`. A collection block under a singular `resource`
  stays singular.
- **`controllers` with `detail:"full"` crashed on an app whose controller had
  two strong-params methods under a parent other than
  `ApplicationController`.** The grouping fingerprint sorted the hashes the
  introspector records for each params method, which raised `ArgumentError:
  comparison of Hash with Hash failed`. `SectionFacts` now holds one reader
  for those method names and one for rescue handlers, and the four sites that
  rendered them call it. A `rescue_from` reads as `ActiveRecord::RecordInvalid
  -> not_found` instead of a hash dump, in the listing and the
  single-controller answer.
- **A controller that inherits its actions listed none in the static tier.** A
  subclass with an empty body, or one defining only private helpers, reported
  no actions at all, so `action:` answered "not found" for an action its
  parent defines and the routes reach. Both tiers now fill an empty action
  list from the nearest app ancestor the listing already holds, walked by the
  parent name each entry carries. The walk stops at the app base, so a base
  class's shared helpers still do not read as actions. A parent spelled
  relatively inside a `module` body (`class ProfileController <
  BaseController` under `module Settings`) is resolved from the enclosing
  namespace outward, the way Ruby resolves it.
- **A controller with no public actions had no actions line at all in the full
  listing or the single-controller answer.** A reader could not tell a class
  that defines no action of its own from one the walk did not look at. Both
  say `(no public actions)` now, the phrase the standard listing already used.
  A controller the walk could not read keeps its one "could not be read" line
  and does not gain a second.
- **A bare parent class bound to a top-level class before the enclosing
  namespace.** A controller written as `module Settings; class
  ProfileController < BaseController` was keyed to a top-level
  `BaseController` when one existed, where Ruby resolves
  `Settings::BaseController`, so the inherited actions and the whole inherited
  filter chain came from the wrong ancestor. The lookup tries the enclosing
  namespaces innermost first and falls back to the bare name last, the order
  concern lookup already used. A parent already spelled with a namespace is
  still taken as written.
- **A controller with no public actions rendered as a name and a trailing
  dash.** The listing and `analyze_feature` now say `(no public actions)`; on
  Mastodon that covers six base controllers.
- **A controller file the walk could not read was listed as a controller with
  no actions.** The listings rendered an entry carrying an error as `(no
  public actions)`, and the summary listing as `0 actions`, while asking for
  that one controller answered that it could not be read. Every listing states
  the error now, from the one phrase the serializers share.
- **A compressed controller group was headed by a namespace no controller is
  in.** `rails_get_controllers(detail: "full")` built the heading from the
  first segment of the first member's name, so five top-level controllers were
  filed under `CustomCssController::*` and `OAuth::UserinfoController` under
  `Api::*`; 38 of Mastodon's 309 controllers appeared only inside such a
  heading and their real constant was nowhere in the answer. The heading now
  names the longest namespace every member shares, or just the count when they
  share none, and the group lists every member by its full constant.
- **`excluded_filters` was honoured only where reflection ran.** The key was
  read in one place, inside the reflection branch, so a `--no-boot` run and
  any booted controller reflection did not load kept listing the names an app
  had asked to hide. The source parser applies it too. A filter the controller
  explicitly skips is still shown as a struck-through `~~name~~ _(skipped)_`
  line, which is a fact about the class rather than a filter that runs.
- **A skipped filter was listed as one the action runs.** The static walk
  folded `skip_before_action` into a plain `before` kind, so `tool controllers
  detail=full` printed "before authenticate_user!" for a controller whose file
  skips it, while the booted tier struck the same filter through. The record
  now carries the skip, one renderer draws the listing for the tool and the
  generated markdown, and an ancestor's own skip no longer reaches a child as
  an inherited filter - Mastodon's Api::V1 controllers listed
  `require_functional!` that way. A skip that names `only:` or `except:`
  covers those actions only, so an action the skip does not name still lists
  the filter it runs. A skip naming actions also keeps the filter in every
  answer that covers the whole controller, saying where it is lost (`skipped
  on: index`, `skipped except: show`), where it used to strike the filter
  through as if it never ran.
- **A per-action filter chain dropped a filter whose only evidence was a skip
  constrained to other actions.** The whole-controller answer kept it and
  named the actions it loses, so one tool contradicted itself on one tier:
  Mastodon's `Auth::RegistrationsController` said `check_self_destruct!
  (skipped on: edit, update)` for the class and said nothing at all for `new`.
  A skip whose `only:`/`except:` leaves the queried action alone now reads as
  evidence the filter runs there, with no skipped tail on the row. A real
  `if:`/`unless:` on the same name, on the class or on an ancestor, still
  wins.
- **A skip of an inherited filter inverted the per-action answer.** The booted
  payload read a `skip_before_action :authenticate!, only: [ :index ]` as a
  constraint on the filter itself, so `authenticate!` was named on the one
  action where it does not run and dropped from the two where it does. A skip
  now only takes filters out, and the class's own body reaches the payload:
  the skips it declares, and which of the reflected names it declares itself.
- **A class that skips a filter still handed it to its children.** The class's
  own skips joined the dropped set after its own filters had been collected,
  so the skip applied to classes above it and not to itself or its children.
  In a booted run its own list is the whole chain, so it contributed the very
  filter it took out. Every class's skips now apply to its own list first,
  minus whatever the same body re-declares after the skip.
- **The static filter chain vanished when the parent was spelled relatively.**
  `class ReportsController < BaseController` inside `module Admin` carries the
  parent as written, and the chain walk looked that up verbatim and stopped on
  the first hop, so a controller lost every inherited filter. A bare parent
  name now resolves against the enclosing namespace, the way inherited actions
  already do.
- **The routes listing named filters the controller skips.** The
  per-controller hint read the payload directly instead of the filter chain,
  so it printed a skipped filter next to a detail view calling the same filter
  skipped, and it cut the list at three with nothing said. It now reads the
  chain and says how many it did not show.
- **A filter was attributed to a class that only inherits it.** In a booted
  run every ancestor carries every inherited name, so `from:` named the
  nearest class holding the filter rather than the one that declared it. It
  now names the first ancestor whose own body declared it.
  `ApplicationController` is not in the listing, so a filter it declares still
  cannot be attributed to it; docs/COMPATIBILITY.md states that.
- **`rails_get_controllers` gave two answers to one question about the same
  controller.** `skip_before_action :require_functional!, unless:
  :limited_federation_mode?` was read as an unconditional skip, so the
  single-controller answer struck the filter through while the grouped listing
  said it runs. A skip carrying `if:` or `unless:` takes the filter out on
  some requests and leaves it on others, so it no longer removes the filter
  from the chain: the filter keeps its place and the line names the condition,
  the way an active filter's `only:`/`except:` tail is rendered, with a lambda
  spelled `[INFERRED]`. The condition is carried down from the ancestor that
  declared the skip. The listings, the routes hint, `rails_analyze_feature`
  and the generated context files resolve their filter line through the same
  reader the single-controller answer uses. The controller walk was also
  missing `skip_around_action` from its macro list, so a conditional skip on
  an around filter had no record at all.
- **The full controller listing grouped unrelated controllers by the parent's
  source spelling.** The static walk stores a superclass as written, so two
  namespaces that each define a `BaseController` looked identical to the group
  key while the rendered chain resolved it. On Mastodon,
  `Admin::DashboardController` and seven `Settings::Exports` controllers
  shared one group headed by a constant the app does not define, and the seven
  were given a filter chain that is not theirs. The key and the `Inherits:`
  line resolve the parent the way the chain walk does. A skip's constraints
  also join the group fingerprint, so a conditional skip no longer matches an
  outright one.
- **The full controller listing copied the whole introspection payload once
  per controller.** Resolving a parent reached for the shared cache inside the
  loop, and every read of that cache deep-copies the entire context under a
  mutex. On Mastodon's 309 controllers the `--detail full` listing made 608
  copies and spent 8.2 of its 8.6 seconds in them. The listing reads the
  payload once and passes it down. Rendered output is unchanged and the run
  takes 4.3 seconds.
- **`rails_get_schema` and `rails_get_routes` copied the whole payload once
  per row.** Every read of the shared cache deep-copies the introspection
  payload under a mutex, and both listings read it inside their loop, over
  tables and over controller headings. Mastodon's 116 tables cost 350 copies
  and 7.5 of an 8.1 second run; its 657 static routes cost 297 copies and 6.0
  of 6.4 seconds. Both read the payload once and pass it down now, and the
  runs take 5.5 and 4.3 seconds with the rendered output unchanged.
- **The same copy-per-row shape was in `rails_get_callbacks` and a
  `rails_search_code` trace.** The full callback listing resolved the model
  file through the shared cache once per callback of every model, 152 copies
  on Mastodon, and a trace read it once per controller file among the call
  sites, 70 for `current_user`. Each reads once for the whole listing now, and
  a single-controller `rails_get_controllers` request went from five reads to
  one.
- **The single-controller answer named a different parent than the listing did
  for the same controller.** It printed the superclass as the source spells it
  while the listing resolved it, so `Settings::Exports::BookmarksController`
  was headed `Parent: BaseController` above a filter chain attributed to
  `Settings::BaseController`. Both read the parent through one resolver now. A
  parent nothing in the payload resolves, a framework or gem base, keeps the
  spelling the source uses.
- **A conditional skip could invent a filter for an action the real
  declaration never covers.** A name the chain walk had seen and then excluded
  for that action was reported as one that runs, with no ancestor named. The
  walk hands back every name the chain declares, its own included, and only a
  skip of a name nothing in the payload declares is still reported, which is
  the concern case it exists for.
- **A filter the class declares itself was reported last, and only when the
  body also carried a skip.** The reported chain was rebuilt whenever the body
  skipped anything, which put every own filter behind every inherited one, so
  a `prepend_before_action` came out at the end and the routes hint's first
  three cut it. The chain keeps its run order whether or not a skip is
  present.
- **Static `get_api` named serializers by camelizing the file path, so an app
  acronym came out miscased.** `ActivityPub::AcceptFollowSerializer` was
  reported as `Activitypub::AcceptFollowSerializer` and
  `REST::AccountSerializer` as `Rest::AccountSerializer`; 137 of Mastodon's
  144 names were wrong. `camelize` reads the global inflector, and the static
  tier never loads the app's `acronym` registrations. The list now comes from
  `SourceScan.classes`, which reads the class each file declares, so it needs
  no inflector, covers packs and in-repo engines, and stops walking
  `app/serializers/concerns` (Mastodon goes from 144 names to 143).
  `MarkdownSerializer#api` writes this list into the generated context file,
  so the wrong names were committed into apps' context, not only printed. The
  jbuilder count in the same method now goes through `PathResolver.view_dirs`
  and sees pack and engine templates. A file under `app/serializers` that
  declares no class (a module, or a file that does not parse) is still listed,
  under its path name.
- **Two serializer files resolving to one constant were listed twice.** The
  listing deduped nothing, so a pack and an app file declaring the same class
  both appeared.
- **Generated migrations were stamped with the gem's Rails version, not the
  app's.** `rails_migration_advisor` read `Rails.version` from its own
  process, so a standalone `--no-boot` run had no such constant and every
  migration came out as `ActiveRecord::Migration[7.1]`, while a run inside a
  bundle reported whichever Rails the gem had loaded. Mastodon is on 8.1.3.1
  and got 7.1, and that bracket is not cosmetic: it selects a migration
  compatibility mode. The version now comes from the app's context, the same
  hash the tool already reads for the database adapter, so both tiers stamp
  the app's own major.minor. When neither the context nor a loaded Rails names
  a version, the tool stamps its supported floor and says so in a Note line
  above the code. That note states only what the tool observed, not a cause it
  never checked.
- **`migration_advisor` printed an empty "Affected Models" section for any
  model whose table is not the camelized form of its class.** The section
  camelized the table back into a model name, so `Admin::ActionLog`
  (`admin_action_logs`) and every `self.table_name` model came back with a
  bare heading while `get_schema` named the model for the same table in the
  same run. The models for a table are now looked up from the table each model
  records, associations are matched against those names, and the heading is
  left out when no model uses the table. `remove_column`'s `ignored_columns`
  step names the model's own file for the same reason.
- **`generate_test` and `get_test_info` wrote test data the app does not
  have.** A Devise app with no factory_bot got `let(:user) { create(:user) }`,
  a Devise app with no fixtures got `@user = users(:one)`, and the "follow
  this pattern for new tests" template handed out `create(:model_name)`
  regardless. All three now go through the same factory and fixture lookups
  the rest of the generator uses, and emit a TODO naming what is missing when
  there is nothing to build. Request specs also skip the `sign_in` block when
  the controller, or one of its parents, calls `doorkeeper_authorize!`,
  because `sign_in` cannot authenticate a token endpoint. The minitest
  generator asks the same question, so a token-authorized controller gets the
  bearer-token TODO there too instead of a fixture `sign_in`.
- **A generated request spec raised `UnknownAttributeError` before it could
  fail a validation.** `generate_test` built its placeholder record out of the
  controller's permitted params, so on Mastodon's
  `Api::V1::AccountsController` eight of the nine keys handed to
  `Account.create!` were not columns. The record is built from the permitted
  names that are columns, a TODO names the ones left out, and the request
  params still carry every permitted name.
- **`rails_generate_test` rendered an empty `describe "associations" do end`
  in the static tier.** The rspec branch matched the macro against
  `"belongs_to"` and its siblings while the static walk reported it as a
  Symbol, so every row was dropped; the minitest branch interpolates, which is
  why the minitest fixture never saw it. The same mismatch silenced the
  validation matchers, the `fk:` and `[optional]` markers and the
  implicit-presence label in `rails_get_model_details`, and the eager-loading
  candidates in the performance check. Both listeners spell the macro and the
  validation kind the way the booted tier does, and a static association
  record carries `through`, `dependent`, `class_name`, `foreign_key`,
  `polymorphic` and `optional` where every renderer already looks for them.
- **`generate_test` wrote an empty `describe "associations"` block for a model
  whose associations are all `has_and_belongs_to_many`.** The rspec branch
  matched `belongs_to`, `has_many` and `has_one` only, so a habtm row was
  dropped from a mixed model and a habtm-only model got a block that reads
  "nothing to test here". The block opens on the rows it rendered, and habtm
  gets `have_and_belong_to_many`.
- **A generated test named the fixture file's shared-attribute anchor.**
  `users(:DEFAULTS)` names an anchor, not a record, and ActiveRecord drops
  both it and Rails' own `_fixture` key, so the call raises "No fixture
  named". The filter ran only when the cached context missed the table, so an
  app whose context carried `fixture_names`, which is every real app, still
  got the anchor written into a generated test and listed as a fixture by
  `get_test_info`. The rule is one predicate now, and the introspector, the
  cached lookup and the disk read all ask it.
- **The generated minitest scaffolding named test data the app does not own.**
  `get_test_info`'s template emitted `sign_in users(:one)` whenever it saw a
  `sign_in` anywhere in the app's tests, and a fixture call in an app with no
  fixtures at all. The users fixture now comes from the app's own fixture
  files, an app with no users fixture gets a TODO instead of a name, and an
  app with no fixtures gets `ModelName.new`.
- **`get_test_info` counted only the spec directories a hardcoded list
  named.** Mastodon reported 675 of its 1090 spec files and 6 of its 22 spec
  directories; `spec/lib`, `spec/workers`, `spec/serializers` and nine others
  had no row at all. Categories are now read from whatever the app keeps under
  `spec/` and `test/`: one row per top-level directory holding test files, a
  row for files loose at the root, joined locations when a category lives
  under both, sorted by count. One "Test Files" section states each category
  once, with its count and the directories it lives in, and support Ruby that
  sits beside the specs is not counted. The walk runs once per introspection,
  and a directory it cannot read costs the categories rather than the whole
  test section. The separate "Test Counts by Category" section is gone: its
  numbers are the counts in that one section.
- **`search_code --exact-match` treated the pattern as a regex, so `def
  reblog?` also matched `def reblog`.** The pattern is now escaped and matched
  literally. Boundaries are added only on the side whose pattern edge is a
  word character, which also fixes `--exact-match` on `@user`, `match_type:
  "definition"` and `"class"` on predicate and bang names, trace mode listing
  `presave!` as a call site of `save!`, and method source lookup for `[]`,
  `foo=` and `<=>`. Against Mastodon, `def reblog?` now reports the 3 lines
  ripgrep finds instead of 6.
- **`format: "json"` on `rails_get_schema` returned markdown.** The parameter
  is declared, schema-validated and accepted without a warning, but only a
  single table and `detail:"full"` ever produced JSON; every listing returned
  the same bytes as `format:"markdown"`, on the CLI and over MCP. All three
  detail levels return the paginated tables as JSON now. A JSON body also
  stopped carrying the markdown static-tier banner, which made it unparseable:
  the tier note rides inside the document under `_static_tier`, and the
  response cap drops whole elements instead of slicing the text.
- **A JSON request for a page past the end of the schema got prose back.** The
  empty-page return sat above the format guard on all three detail levels, so
  a caller parsing the answer got a sentence. An empty page is an empty tables
  object now.
- **`search_code` counted emitted lines as matches and printed the 200 cap as
  if it were the total.** The header now counts only match lines, so it no
  longer moves with `context_lines`, and it says `first 200 lines scanned`
  when the cap was reached instead of passing the cap off as a total. The page
  size is sized in matches, the pagination hint and the per-file group
  headings carry the same two facts, and trace mode marks a caller list that
  stopped at the cap. Against Mastodon, `def reblog?` with `--context-lines 5`
  reports 3 matches rather than 30, and `def call` reports its 103 matches once
  the context lines no longer fill the cap. At the default two lines of context
  the same search reaches the cap at 40 and says so, which is the floor the cap
  can honestly claim rather than a total.
- **A ripgrep run that failed, or that recovered from an unreadable file,
  answered wrong.** The exit status of the `rg` run was discarded, so a run
  that failed outright looked the same as a run that matched nothing, and a
  run that hit one unreadable file (rg exits 2 and still prints every match it
  found) threw the matches away and reran the search in Ruby without context
  rows. A failed run that left no output, which is what an rg too old for
  `--field-match-separator` produces, now falls through to the Ruby backend; a
  recovered run keeps its matches and the answer says some files could not be
  read. A cut row list is marked `200+` as a floor, a trace prints one
  truncation note, and a page that lands wholly inside one match's context
  answers as an empty page instead of printing rows under "showing 0".
- **The search header blamed unreadable files for any recovered error.** A
  regexp timeout is not a file it could not read. It says the search hit an
  error and may have skipped files.
- **An MCP call with a parameter the tool does not take answered with an
  `ArgumentError` and the gem's install path.** The key reached the tool as an
  unknown keyword, so the response carried the exception, a backtrace frame
  and an absolute path under the machine's `GEM_HOME`, where the CLI refuses
  the same mistake by naming the params the tool takes. The MCP path refuses
  it the same way now, both sides read the unknown keys off one derivation,
  and any frame a real failure names is spelled the way every other path this
  gem reports is.
- **A path refused on policy exited 0 everywhere except `validate`.** A
  traversal, a path outside the app or a sensitive file was refused in the
  text and reported as a successful call by `get_view`, `get_edit_context`,
  `get_concern`, `get_partial_interface`, `search_code` and `read_logs`, so a
  script could not tell a refusal from an answer. A policy refusal is an error
  result on every tool that takes a path now, `isError` over MCP and exit 1
  from the CLI, and a path that is simply not there stays an ordinary answer.
  `read_logs` reduced the name it was given to a basename, so it reported a
  refused path as a log file that is not there; it says which it did.
- **Static `get_i18n` reported the locale files as the app's available
  locales.** Rails builds `available_locales` from `config/locales` only while
  the app leaves the setting alone; once it assigns
  `config.i18n.available_locales`, that list is the answer. Mastodon ships
  files for 106 locales and enables 97, so nine disabled locales were listed
  as available, seven got their own coverage row, and asking for one of them
  by name answered with a full locale report. The static answer now reads the
  assignment from `config/application.rb`, the environment file and the
  initializers, takes the last one Rails would apply, and falls back to the
  files for an app that never sets it or whose value is computed, saying so in
  the field name. Fallbacks left the static answer with it: `I18n.fallbacks`
  belongs to whichever process asks, and no app booted in this one. The
  generated context files carry the same qualifier, so CLAUDE.md and AGENTS.md
  no longer state the file list as the enabled one.
- **One i18n config walk was read in two orders.** The default locale kept the
  first assignment it found while the available locales kept the last, over
  the same files, so an initializer that overrode `config/application.rb`
  changed one section of the report and not the other. Rails hands
  `config.i18n` to I18n once, after every initializer has run, so both keep
  the last assignment. The walk also read every `config/environments` file; it
  reads the running environment's, and the others only when that one is
  absent.
- **The static tier reported a default locale and a locale list Rails does not
  use.** The walk kept the last assignment it found and treated
  `config.i18n.x` and a bare `I18n.x` as the same statement. Rails buffers
  `config.i18n` and applies it to I18n after every initializer has run, so an
  app that sets `config.i18n.default_locale` in `application.rb` and
  `I18n.default_locale` in an initializer was reported with the initializer's
  value. The buffered spelling wins now, and last-wins applies within a
  spelling.
- **With the running environment's file missing, the default locale was
  whichever environment sorted last.** Every `config/environments/*.rb` is
  read as a fallback, and last-wins over a sorted glob let `test.rb` beat
  `production.rb`. Those files are alternatives rather than a sequence, so
  they answer only when they agree.
- **`excluded_concerns` in `.rails-ai-context.yml` did nothing, and a mistyped
  key did nothing quietly.** The key was missing from the YAML allowlist, so a
  standalone user who set it kept the framework defaults and the concern
  stayed in `concern`, `active_support` and `model_details`. It is a YAML key
  now: strings are compiled to patterns once at load, and an invalid one warns
  against the file that named it instead of raising inside an introspector. A
  key the gem does not know warns on stderr naming the file, the key and the
  nearest known key, and the rest of the file still applies. A YAML list
  replaces the framework defaults rather than adding to them, which the
  Filtering table now says. The config loader and the installer's record also
  disagreed on what YAML classes to permit, so one hand-added `generated_at:`
  line voided every key in the file; both read one constant.
- **An unknown config key was answered with an unrelated one.** A three-letter
  key in `.rails-ai-context.yml` matched the first known key starting with it,
  so `max` was told to mean `max_file_size` and `out` to mean `output_dir`.
  The suggestion now also asks that the typed name cover at least half the key
  it matches, so a truncation like `output_di` still points at `output_dir`
  and a short prefix says nothing.
- **Four doc pages described a config precedence the gem stopped having in
  5.25.0.** `docs/STANDALONE.md`, `TROUBLESHOOTING.md`, `FAQ.md` and
  `GUIDE.md` all said the initializer outranks `.rails-ai-context.yml` and
  that the file is skipped whenever one runs, while `docs/CONFIGURATION.md`
  described the merge. The standalone page now says what is true there, that
  the YAML file is the only config source because the gem is not loaded while
  `config/initializers` runs, and the other three point at the page that
  states the merge; a spec pins each page against the loader. An app that
  calls `RailsAiContext.configure` without bundling the gem used to get a
  `NoMethodError` and a pointer to `doctor`, which died the same way; both
  boot-failure surfaces now name the cause and the two ways out, and `doctor`
  warns on an initializer with no guard at all, not only on the bare
  `defined?` form. The `rails ai:*` tasks relay the same hint; it lives on the
  boot result every surface already holds.
- **Doctor answered every introspector failure with the same stimulus
  sentence.** The fix line on the introspector health check was one fixed
  string with nothing interpolated, so an app whose database was unreachable
  was told to look for `app/javascript/controllers/`. The check now quotes the
  first line of each failing introspector's own error, up to three of them
  plus a count of the rest, and keeps the message line to introspector names.
  A raised error's text no longer gets truncated into that name list.
- **One broken app file could kill the whole doctor report.** The health check
  and `Doctor#run` rescued `StandardError` only, so a `LoadError` or
  `SyntaxError` raised while running an introspector or any other check ended
  the command with a backtrace and no diagnosis. Both now also catch
  `ScriptError`, the way `Introspector#call` already did: a broken file costs
  one check, not the report.
- **`doctor` printed two different view counts in one report.** `Views` counts
  every file under `app/views` and `View aggregation size` counts only the
  erb, haml and slim templates, and both said "view file". Each line says what
  it counted.
- **`rails 'ai:preset[bogus]'` printed the preset list and exited 0.** The
  rake task resolved and ran a preset in one branch, so a name no preset
  carries fell through to the same listing a bare invocation prints, and a
  script could not tell a typo from a successful run. An unknown name now goes
  to stderr as `Unknown preset: <what you typed>` with the list of valid ones
  beside it, and the task exits 1. A resolved preset whose run answers false
  exits 1 too, matching `rails-ai-context preset`. Bare `rails ai:preset`
  still lists on stdout and exits 0.
- **`rails-ai-context preset` with no name wrote its listing to stderr.**
  Redirecting it to a file left the file empty, while every other listing path
  in the gem uses stdout. A listing the user asked for now goes to stdout;
  stderr keeps the error framing and the listing that follows a rejected name.
- **A preset whose every tool raised exited 0.** `rails ai:preset` and
  `rails-ai-context preset` reported success on an empty run. A preset that
  produced no output now fails, and the outcome-to-exit-code rule lives in one
  place instead of once per surface.
- **A global option typed before the command name ran nothing and exited 0.**
  Thor read the leading switch as "no command given" and fell back to `help`,
  so `rails-ai-context --app-path /srv/app doctor` printed usage and exited 0
  having checked nothing, and a job wrapping it went green. The binary now
  moves every switch it declares behind the command name before dispatch.
  `--help`, `--version` and an unknown leading switch keep their own answers.
- **`watch --no-boot` died with an uninitialized-constant backtrace.**
  docs/CLI.md listed `watch` among the commands that take the flag, but the
  watcher defaulted to `Rails.application`, which the static tier does not
  have. It takes the same app object every other command uses there.
- **`watch` announced it was watching before it started.** The banner printed
  before the listener was wired up, so a run that then failed on a missing
  `listen` gem had already said it was watching. It prints after the listener
  is running.
- **`serve` announced a live-reload watcher that never started.** The banner
  and the watched directory list printed before the listener, so an app
  without the `listen` gem read both lines and then "Live reload unavailable".
  The watcher itself was fixed for this; this second copy, the one `serve`
  uses, was not. The banner prints after the listener is running.
- **An app that exits during boot answered nothing at all.** The binary set
  `RAILS_ENV` only when `--environment` was passed, so the documented default
  never reached apps that read the variable in `config/boot.rb`. Mastodon
  aborts there, and an abort during boot was the one failure mode the static
  tier did not cover, so the run ended with exit 1 and an empty stdout. The
  binary fills in `development` when nothing else set it, and an initializer's
  `exit` degrades to the static tier like every other boot failure. The rake
  tasks, which boot inside the app's own process, still stop with it.
- **The environment default lost an ambient `RACK_ENV`.** Filling in
  `development` whenever `RAILS_ENV` was unset skipped the second term of the
  chain Rails itself reads, so an app invoked with only `RACK_ENV` set booted
  in the wrong environment, and an empty `RAILS_ENV` was kept where Rails
  treats it as unset. The chain is `RAILS_ENV`, then `RACK_ENV`, then
  `development`, with an empty value read as no value.
- **A refusal on policy exited 0 in the SQL tool and 1 everywhere else.** A
  blocked SQL statement came back as ordinary text, so a script could not tell
  "no, that writes" from a result. It is an error result now. A file or a path
  that is simply not there is still an ordinary answer and still exits 0.
- **`search_code` said it could not find an absolute path instead of refusing
  it.** `--path /etc` was joined onto the app root, so it looked merely
  absent: the tool answered "Path not found" with the app's own top-level
  directories listed back, and exited 0. Nothing escaped the root, but the
  reason was wrong and it was the one refusal shape the other six path-taking
  tools already exit 1 on. It refuses an absolute path or a traversal before
  resolving, with the same message they use.
- **Three tools accepted no arguments and exited 0.** `context`,
  `generate_test` and `session_context` ask for "at least one of" several
  parameters, so the runner's required-parameter check never fired and their
  own guard answered with plain text. They exit 1 now, like the nine tools
  whose required parameter the schema names.
- **`context --format bogus` introspected the whole app before refusing.** The
  format is checked as soon as the command starts.
- **A value-taking flag given no value refused in broken English.** `--limit`
  with nothing after it said "takes a integer value". The article follows the
  type name now, for every type the schema can carry.
- **A tool failure's file and line could hide a real fault.** Resolving the
  app root to relativize the frame swallowed every error, so a bug in the
  resolver read as a missing app. Only a missing app or a missing root is
  absorbed now.
- **A fault resolving the app root escaped the tool safety net.** Turning a
  tool failure into an error result needs the app's root to shorten the
  backtrace frame, and that resolution ran inside the rescue that answers the
  failure, so anything it raised other than a missing constant left the net
  and reached the client as a bare internal error, which the module's own
  contract says must never happen. The frame comes back unshortened now and
  the client still gets the error result.
- **The frame in a failure answer named the machine it ran on when the root
  could not be resolved.** The backstop that keeps that fault inside the
  safety net handed the frame back untouched, so a failure carried an absolute
  install path where a healthy answer carries a gem-relative one. It strips
  the same prefix the no-app branch beside it already strips.
- **The release gate ran a smaller suite than CI.** The `search_code` count
  examples skip without ripgrep, and only the CI workflow installed it, so the
  workflow that publishes ran fewer examples than the one that guards a pull
  request. The release matrix installs it too, and a spec holds the two
  workflows to the same command.
- **Two documentation lines did not match what the code writes.** The `gem:`
  marker paragraph named the gem's install directory as the base its paths are
  relative to, where the path is relative to the directory gems are unpacked
  under and leads with the gem's own directory name. A filter example escaped
  backticks inside a code span, which markdown does not honour, so the span
  closed early; it is fenced the way the example three lines above it already
  was.
- **`docs/CLI.md` documented `tool models`, which is not a tool.** The command
  is `tool model_details`. The page also gained the `facts`, `preset` and
  `tree` sections it was missing, it now says which path refusals exit 1 and
  which absences exit 0, and it names `--app-path` and `--environment`, which
  were documented only in `--help` and decide which app and which database
  configuration get read.
- **A `path:` install printed a git error on every bundler command.** The
  gemspec built its file list with `git ls-files` and left git's stderr
  attached to the caller, so a vendored or `path:` Gemfile entry re-evaluating
  it made the host app print "fatal: not a git repository". The command runs
  with its stderr discarded. The packaged gem carries the same file list as
  before.
- **The trace's route hint never rendered, for any app.** The controller name
  it looked the routes up by was read from a capture group that
  `String#match?` does not set, so it was always nil. A trace over a
  controller call site names the routes that reach it again.
- **`ai:inspect` and the generated context files stated the route count
  differently.** The rake summary printed the raw total where `CLAUDE.md`
  prints the app share and names the rest as framework, so the same number
  read as two answers. Both surfaces use the same phrase now, off the same
  route population.
- **An `--app-path` that does not exist dumped nine frames.** `doctor`,
  `inspect` and `watch` let the `chdir` error escape. The directory is checked
  before the move, and those three print the one-line refusal the other
  commands already printed.
- **An initializer calling `abort` ended the run with no line from this gem.**
  On the rake path the exit still passes through with the app's own message and
  its status, and one stderr line now names this gem as the caller: `App called
  exit(N) during boot.` The binary prints no such line: there the exit is a boot
  failure like any other and the failure summary above the answer says so.
- **A value-taking flag with no value crashed inside the tool.** `tool schema
  --table` became the Boolean `true` and reached the tool as a type it never
  accepts, raising a `NoMethodError` that named an internal frame. It is
  refused by name now, read from the tool's own schema.
- **A bare word where a flag belongs was dropped without a word.** `tool
  schema posts`, a mistype of `--table posts`, returned the full schema
  listing as though nothing had been asked. It is refused, naming the flag it
  was probably meant for.
- **`--limit abc` became 0 and answered a different question.** A value an
  integer parameter cannot hold is warned about on stderr and the tool's own
  default applies, the way an out-of-enum value already behaved.
- **A missing required parameter printed an error and exited 0.** The wording
  is unchanged, but the call is marked failed so a script can act on it. A
  tool that answers with a listing when it has nothing to work on is giving
  guidance, not failing, and still exits 0.
- **A context file an app had nothing to put in was skipped without a word.**
  An app with no models, controllers or schema dump got 11 of the 20 files and
  nothing named the other 9, so a deliberate omission and a failed run looked
  the same. Every unwritten file now comes back with the reason it does not
  apply, on all four surfaces that print a generate result: the CLI and the
  watcher word it `Not applicable: <file> (no models)`, the rake task and the
  installer `➖  <file> (no models)`, off one table. Root files
  switched off with `generate_root_files = false`, and the OpenCode
  `AGENTS.md` files whose directory does not exist, are reported the same way
  instead of vanishing.
- **docs/GUIDE.md counted 29 generated files and listed 18.** The real maximum
  is 20. The per-tool tables were missing `.claude/rules/rails-components.md`
  and `.cursorrules`, and two section headers undercounted by one.
- **Dockerfile `ENV` written across continuation lines was read as nothing.**
  The scan matched one line at a time, so an instruction written as a bare
  `ENV \` followed by indented `KEY=value` lines declared no variables, and
  `ENV A=1 B=2` kept only the first name with the rest swallowed into its
  value. `env --detail full` now joins continuations into whole instructions
  and gives each assignment its own row. Against Mastodon the Dockerfile
  section names all 13 `ENV` variables where it named none before.
- **The gems payload said the app had no Ruby version.** The lockfile reader
  required exactly three spaces before the `ruby` line of the `RUBY VERSION`
  section and current Bundler writes two, so `rails://gems` and
  `.ai-context.json` both carried `"ruby_version": null` on an app whose
  lockfile names one. The reader accepts any indent now, and falls back to a
  plain version literal in the Gemfile when the lockfile has no such section.
  A Gemfile requirement naming a range is left unanswered rather than reported
  as a version.
- **Onboard called the Ruby version declared when nothing declared it.** With
  no `RUBY VERSION` in the lockfile and no `ruby` line in the Gemfile, the
  version reported is the interpreter running the CLI. The static tier's stack
  sentence names no Ruby at all in that case.
- **The static tier stated the interpreter running the tool as the app's Ruby
  version.** An app that declares none, in its lockfile or its Gemfile, got a
  header reading `Rails [UNAVAILABLE: app not booted] | Ruby 3.4.9`: one
  sentence refusing one version and stating the other with confidence. Nine
  serializers, `.ai-context.json` and the `ai:inspect` summary all carried it.
  It answers `[UNAVAILABLE: app declares none]` now, the way the Rails version
  beside it already refuses, and `onboard`'s quick depth says the same as its
  standard depth rather than interpolating the value raw.
- **An app that declares a Ruby version and has no lockfile was reported as
  declaring none.** The reader skipped the Gemfile's `ruby` line whenever
  `Gemfile.lock` was absent, so adding an empty lockfile made the same line
  appear. Which gems resolved and which Ruby the app declares are two facts
  and the second does not wait on the first. The sentence that prints it was
  keyed on the gems section rather than on the value, which refuses for a
  second reason, and it reads the value now.
- **The onboarding brief dropped an app's whole Sidekiq layer without saying
  so.** On an app that runs its background work through workers in
  `app/workers`, the async section counted the mailers and said nothing else,
  so a reader was told an app with 118 workers has almost no async work. The
  section states the same limit the job listing states.
- **An app with no `Gemfile.lock` was reported as a failed introspection.**
  The gems tool answered "Gem introspection failed: No Gemfile.lock found"
  where the schema tool answers the same absence with an `[UNAVAILABLE: ...]`
  marker. A missing lockfile reads as unavailable in both. A lockfile that
  could not be read, or one with no `specs:` section, is still reported as a
  failure.
- **A dependency line was read as the app's Ruby version.** `ruby (>= 2.0)`,
  six spaces into the lockfile's dependency list, answered `(>=`. The
  version-shape guard the Gemfile path already had now covers the lockfile
  line too.
- **One run reported two different Ruby versions with nothing to separate
  them.** `.ai-context.json` named the interpreter that ran while the
  `rails://gems` resource named the lockfile's `RUBY VERSION`. The context's
  `ruby_version` falls back to the app's declared Ruby in the static tier, the
  way `rails_version` already does, and the gems section reports it as
  `declared_ruby_version`.
- **A `Gemfile.lock` that is not a lockfile read as an app with no gems.** No
  gem entries answered as an empty bundle, so every gem-dependent answer said
  the app does not use the gem. A file with no `specs:` section is unknown
  rather than empty, and the reason rides with it; an empty Gemfile still
  locks to a file with a `specs:` section, so no gems stays a real answer
  there.
- **A concern listing emptied by `excluded_concerns` blamed the app.** An app
  whose only concerns were hidden by the setting got the same sentence as an
  app with none. The listing now counts what it skipped and says how many
  concerns the setting hid.
- **A concern listing shortened by `excluded_concerns` said nothing about
  it.** The count was stated only when the exclusions emptied the listing, so
  a shorter answer had no reason beside it.
- **The concern listing called one exclusion two things.** It said "excluded
  by" in one line and "hidden by" seven lines above, for the same key. Both
  say "hidden by" now, the word the configuration docs use.
- **The view heading left layouts out of its numbers.** `232 templates, 117
  partials` never added up to the 359 files under `app/views`, because the 10
  files in `app/views/layouts` were counted nowhere and no section named them.
  An unfiltered listing carries a layout count and points at
  `controller:"layouts"`. The generated context file joined the layout records
  instead of their names and printed a Ruby hash into a file the app commits;
  it names the files now.
- **The views listing read off disk did not answer its own layouts pointer.**
  An app whose payload carries no view templates section printed the line that
  says layouts are listed by `controller:"layouts"`, and then answered that
  instruction with an empty listing. That path lists the layouts now, while a
  `path:` argument still wins over it and an app with no `app/views` still
  gets its API-only note first.
- **The views listing read off disk counted neither partials nor layouts.**
  The fallback listing, used when the payload carries no views section, headed
  itself with a number that did not reconcile with the files under `app/views`
  the way the payload listing's does.
- **Generated context files never said they were produced without booting.** A
  static run writes different numbers (111 models against 114 on Mastodon, 657
  routes against 723) and nothing in CLAUDE.md, AGENTS.md, the rules files or
  `.ai-context.json` let a reader tell which they had. The context records the
  tier it was answered in, every generated file with a header carries one
  `[STATIC]` line under it, and the JSON carries a `tier` key. A booted run
  adds nothing, so an unmarked file is a booted one.
- **Only the overview file said it was generated without booting.** The
  `[STATIC]` notice reached each serializer's overview render alone, so
  `.claude/rules/rails-models.md` said 111 models and
  `.cursor/rules/rails-controllers.mdc` said 309 controllers where a booted
  run says 114 and 321, with nothing in either file naming the tier. Every
  generated file whose numbers come from the app now carries the notice under
  its heading. The MCP tool references list the gem's own tools in either
  tier, so they carry none.
- **The Copilot full-mode header carried two blank lines under the version
  block.** One now, the way the Claude, OpenCode and markdown headers already
  did.
- **The static notice merged into the version line in three of the rules
  files.** Markdown renders two lines with no blank between them as one
  paragraph, so the notice read as part of the generator credit. It goes
  through the same helper the other renders use and keeps its own blank lines.

- **A table prefix the model declares itself was ignored.** `full_table_name_prefix`
  reads the innermost namespace that declares one and falls back to the class,
  so `class Article < ApplicationRecord; def self.table_name_prefix = "blog_"`
  is `blog_articles` at runtime. The walk read the namespaces and stopped, so
  the static answer said `articles` where the booted one said `blog_articles`.
  The namespace still wins where both declare one, which is the order Rails
  resolves them in.
- **The same typo exited 1 from the binary and 3 from the rake task.**
  docs/CLI.md states one rule - a usage error exits 1 - and the binary has
  always kept it. `rails 'ai:tool[schema]' bogus=1` exited 3, and anything else
  that raised out of the task exited 2, both undocumented and unpinned. One
  status now, on both surfaces, with a spec on each.
- **An unreadable file under `app/models` was answered as a model with a
  table.** `app/models` holds POROs too - a form object, a service, a generated
  data class - and a file the walk cannot read might be one, so a derived
  `table_name` claimed more than the tier knows. The entry still names the file
  and why it is empty, and carries a table only where another model's
  inheritance says it is a base.
- **`onboard` wrote `[UNAVAILABLE: app not booted]` mid-sentence.** The Ruby
  half of the sentence had learned to drop its clause rather than print the
  marker; the Rails half was still interpolated raw, so an app whose lockfile
  names no rails wrote the marker into a file it commits. Both halves read
  through one rule now.
- **`polymorphic: false` was in the static answer and absent from the booted
  one.** One model read two ways carried two different key sets into
  `.ai-context.json`. The booted side reads the key the way it already reads
  `optional`.
- **A file declaring only a module was named by camelizing its path.** That is
  wrong for a module in exactly the way it is wrong for a class - an app
  inflection only changes case - so `app/serializers/activitypub/actor.rb` was
  listed under a constant the app does not have. The resolver tries the modules
  the file declares before falling back to the path.
- **A compressed controller group with no namespace was headed by a count.**
  Two such groups in one document carried the same heading and neither named
  anything; the heading names a member now.
- **Three documented claims the code does not keep.** `tree` prints commands
  and not their options, the `rails_search_code` parameter table omitted
  `limit` while the paragraph under it used the name, and the changelog said
  four surfaces print `Not applicable:` where two print the emoji form.

- **Five tools took a path from the caller and answered a refusal with exit 0.**
  `rails_get_test_info` said "the name was refused, it leaves the app root or
  names a sensitive file" and exited 0 as though it had looked; `rails_security_scan`
  filtered brakeman's warnings by an unvalidated path, so `files: ["/etc/passwd"]`
  printed "No security warnings found in /etc/passwd", an answer about a file it
  never opened; `rails_review_changes`, `rails_generate_test` and `rails_diagnose`
  took one the same way. All five refuse now, in the wording the other tools
  already use, through one helper on the base class. The contract's spec no
  longer trusts a hand-typed list either: it asks the tool registry which tools
  declare a path-shaped parameter and fails when one of them is not covered.
- **A model inherited nothing from an abstract base.** Rails runs what a
  superclass declares in every child, abstract or not; only the table stops at
  an abstract base, because a child of one has its own. The walk that merges
  declarations followed the table chain, so a per-connection base like
  `Analytics::Record` gave its children nothing, and the app's own
  `ApplicationRecord` was not walked at all. The booted tier listed the base's
  concerns off the ancestor chain while the static tier listed none, which is
  two answers to one question. Both tiers now walk every class the model
  inherits from, up to `ActiveRecord::Base`. On Mastodon that is 111 of 111
  models naming `Remotable`, which `ApplicationRecord` includes, against 51
  before; the model count, the tables, the callbacks and the scopes are
  unchanged.
- **`excluded_models` removed a class from the walk, not just from the list.**
  The key hides an entry; it does not stop the class being the superclass its
  children inherit a table and declarations from. It is applied where the
  listing is built now, the way `excluded_concerns` is, and so is the app's own
  base. An unreadable base is a gap for its children either way, so they name it
  under `bases_unread` rather than losing its declarations silently.
- **A macro or a callback declared by both a base and its child was reported
  twice.** Associations, scopes and enums were deduped on merge and these two
  were not, so `encrypts :secret` on both sides answered `["secret", "secret"]`.
  Rails keeps one entry for a symbol callback declared twice and two validators
  for a validation declared twice, so the answer now says one and two. One
  source line read twice is a third case: a concern the model and one of its
  bases both include was walked once per class, and `included do` runs once, so
  its validation is reported once.
- **A concrete model named like a base was dropped from the static listing.**
  The rule was the name, and the fact is in the source: `abstract_class?` reads
  `primary_abstract_class` as well as the assignment, which is the form a
  generated `ApplicationRecord` uses, so the name rule is gone and a real model
  called `SecApplicationRecord` is listed again.
- **A filter a controller declares itself was reported as inherited.** The
  chain moved any filter whose name an ancestor also declares into `inherited`,
  which is right for the booted tier - its list carries names it only inherits -
  and wrong for the static one, whose list is the class's own body. Reaching
  `ApplicationController` made it visible on every controller in every app: a
  controller declaring `before_action :authenticate` beside a base that
  declares it too answered `own: []`. A record the body declared stays in
  `own`; only a record with no declaration of its own moves.
- **Two filters that share a name and differ in kind were one filter.** The
  chain keyed entries by name alone, so a base's `after_action :audit` vanished
  when a child declared `before_action :audit`, and the child's own
  declaration was credited to the base. Rails runs both; the chain keys on the
  kind and the name now.
- **`rails_diagnose` refused the whole diagnosis for a path it was only asked
  to quote.** `error:` is the question and `file:` points at code to show, so a
  refused path costs that section and not the answer. The refusal is still said
  out loud, inside the section it belongs to.
- **`rails_get_test_info` answered an absolute name at exit 0.** A model name is
  never a path, and the name was interpolated into `spec/models/<name>_spec.rb`,
  which cannot escape the root but answered "No test file found for
  /etc/passwd" where every other tool refuses.
- **`rails_security_scan` refused the leading slash it has always accepted.**
  `/app/models/user.rb` means "from the Rails root" there and the filter strips
  it; the new guard read it as absolute. It normalizes before guarding now.
- **The booted model listing invented a second model from a camelized path.**
  `app/models/activitypub/activity.rb` was offered as `Activitypub::Activity`,
  which constantizes to nothing, so an app that inflects a namespace got an
  extra entry saying its own file would not load. The listing names a file by
  what it declares, and reads it only where the camelized name is not already
  loaded.
- **`ApplicationController`'s filters reached the generated files and no tool.**
  The listing leaves that class out - it would sit in every row - and the chain
  walk looks each ancestor up in the listing, so the walk ended on the first
  hop for most of an app's controllers. One run said "Global before_actions:
  authenticate_user!, set_locale" in CLAUDE.md, off a regex read of the file,
  and rendered no Filters section at all for a controller that runs both. The
  walk reads that file too now, by the one name Rails fixes, and the overview
  line reads it through the same reader, so the two cannot disagree about one
  file. A parent the listing does not hold and the app has no file for still
  ends the walk.
- **A concern an STI base includes was credited but not named.** The child's
  record carries what the base's concerns declared, tagged `from_concern`, but
  its Concerns section was built from the child's own includes, so a child that
  includes nothing itself listed no concerns while its Callbacks section named
  one. The booted tier lists them, off the ancestor chain, so the two tiers
  answered differently too.
- **An inherited enum overwrote the model's own.** The merge appends the base's
  or the concern's declarations after the model's, and the Hash the consumers
  read is built by iterating that list, so the later entry won - always the
  inherited one. A `Car < Vehicle` that redeclares `status` reported Vehicle's
  mapping, and the values Car runs with appeared nowhere. Associations and
  scopes were already deduped first-wins; enums are now too, which is the rule
  Rails itself follows.
- **One unreadable concern file cost the whole models section.** The concern
  walk guarded a file it could not find and a file too big, and nothing else,
  so a file that stats but does not read raised out of the walk and the only
  rescue above it was the section's. Every model in a `--no-boot` answer came
  back as `error`, carrying the absolute machine path. A directory in place of
  the file does the same as root, where a permission bit does nothing. The
  walk reads through a guard now and the concern lands in the unread list, and
  the static tier answers `{ error: }` for one model and keeps the rest, which
  is what the booted tier already did.
- **A pack or engine model kept Zeitwerk's `cref.rb` as its file.** The
  fallback that keeps a model off the autoload registration site knew
  `app/models` alone, so the same model one directory over answered
  `file: "gem:zeitwerk-2.8.3/lib/zeitwerk/cref.rb"`, no callbacks, no methods,
  and `Zeitwerk::RealModName` as a concern it could not read. It walks every
  model directory now: packs, in-repo engines and the configured extra paths.
- **A concern hidden by `excluded_concerns` took its declarations with it,
  silently.** Both tiers merge what an included concern declares, and the key
  that hides the name also stops the walk reading the file, so the model lost
  that concern's associations, scopes, callbacks and macros with nothing on
  the record saying so. Model output says how many concerns went, in the
  wording the concern listing already uses, and counts only a concern the walk
  would have read. The count and not the names: naming them would undo the
  hiding.
- **The boot exit notice read as the run stopping, on the path where it does
  not.** An app whose `config/environment.rb` calls `abort` printed "App
  exited during boot", then "Serving static analysis", then a full answer at
  exit 0. The notice belongs to the caller that lets the exit stand, which is
  the rake tasks; the binary turns the exit into a boot failure and prints
  that, so it asks for no notice. Both surfaces spell the fact the same way:
  "App called exit(N) during boot."

### Changed

- **What the callback list covers is now stated.** `rails_get_callbacks` said
  "execution order" without saying that the list is what the model file and
  its concerns declare, so a callback a gem registers on `include` read as
  absent rather than out of scope. The description, the rendered headings,
  docs/TOOLS.md and docs/GUIDE.md now say "grouped by type, in Rails event
  order", and docs/COMPATIBILITY.md names the limit: order within a type is
  declaration order, order across types is Rails' event order.
- **The `rails://gems` payload renames `ruby_version` to
  `declared_ruby_version`.** A client reading the old key off that resource
  gets nothing back. The two keys were the same word for two different facts,
  the interpreter that is running and the version the lockfile declares, and
  the context's own `ruby_version` is the first of those.

## [5.25.0] - 2026-09-03

### Added

- **`sprockets-rails`, `sprockets`, `sorcery` and `clearance` join the notable
  gem table**, so `rails_get_gems` lists them and the `rails_get_config` assets
  and auth lines name them from the lockfile rather than from a loaded
  constant.

### Fixed

Defects found by a second survey round over the whole surface, and the
duplicated mechanisms behind them.

- **`max_view_total_size` and `max_view_file_size` said they capped view
  reads.** Only `doctor` reads either one, as the threshold for its view-size
  warning; the config comments and the docs rows now say that.
- **`excluded_concerns` hid a concern from a model's list but not from the
  catalogue.** `rails_get_concern` and the `rails_get_active_support` concern
  registry still listed and counted a concern the key names; all three now
  apply the same predicate.
- **An in-Gemfile app's `.rails-ai-context.yml` was inert.** The generated
  initializer holds a `configure` block, and the YAML was skipped whenever one
  had run, so a booted command took the defaults while `--no-boot` read the
  file and the two disagreed (45 tools against 43 with `skip_tools` set).
  Precedence is a merge: the file is applied once, before
  `config/initializers`, so an initializer may assign a key or edit it in
  place and both survive; a later call from the standalone binary or the
  CLI's boot path is a no-op. A block wins the keys it assigns wherever it
  lives, so one in `config/application.rb` or an environment file, which runs
  before the load, keeps them too.
- **The static tier named the app after its directory.** `onboard` and every
  generated context file were headed "mastodon" for an app that declares
  `module Mastodon`. The name now comes from the module enclosing
  `class Application < Rails::Application` in `config/application.rb`, and
  falls back to the directory only when that file names nothing.
- **The static tier counted every class under `app/models` as a model.**
  Namespace modules, form objects, filters and plain service classes were
  listed and rendered as models of a table (Mastodon answered 195 models
  against 117 booted). A static model is now a class whose superclass chain
  reaches `ApplicationRecord`, a namespaced `*ApplicationRecord` or
  `ActiveRecord::Base`, STI subclasses included.
- **An unreadable `.rails-ai-context.yml` aborted the boot.** A directory or a
  file the process cannot read at that path raised out of the engine
  initializer; it now warns and keeps the defaults, the way broken YAML does.
- **A model under a per-connection abstract base was missing from the static
  list.** The multi-database shape - `class AnimalsRecord < ApplicationRecord;
  self.abstract_class = true` in its own file, then `class Dog <
  AnimalsRecord` - dropped every model on that connection from the static
  list, the count and the schema listing. An abstract base is still walked so
  chains resolve through it; it is left out of the result, as before.
- **`rails_get_api` stated a filesystem finding for a section nobody had
  read.** In the static tier the whole section but the mode was declared
  unavailable, and nothing read that declaration, so an app with
  `app/controllers/api/v1/` was told "not detected (no app/controllers/api/v*
  directories)". Every detection in that section is a file read, so the
  static tier now answers all of them, and a key a section does name as
  unanswered renders as `[UNAVAILABLE: ...]` rather than as a negative
  finding.
- **An existing `.ai-context.json` holding anything but a JSON object
  aborted the whole generation run.** The skip check reads it as a file to
  replace.
- **`rails_get_schema`'s table heading named every model on the table**, so
  an STI table with thirty subclasses filled the cheap summary with one
  heading. It names five and counts the rest, the way the file's other lists
  do.
- **`rails_get_test_info` blamed the app root for a name it refused as
  sensitive.** The refusal names what the check covers: the name leaves the
  app root or names a sensitive file.
- **`rails_onboard`'s Getting Started block told the reader to `cd` into the
  app's class name underscored**, which is not the directory the clone lands
  in. It names the app directory.
- **`init` refused a tree with app source but no `config/environment.rb`
  after it had already written the config files**, leaving it half set up
  with no `CLAUDE.md`. Every command that can serve the static tier now
  reads such a tree, the way `--no-boot` already did.
- **A tree with app source but no `config/environment.rb` printed a boot
  failure before falling back to static analysis.** No boot can succeed
  without that file, so the static tier now takes over at once and its banner
  names the missing file; `doctor` refuses the same tree with that reason.
  The banner calls that tree static mode rather than a boot failure, since
  no boot ran.
- **`rails_runtime_info` and `rails_query` told a tree with no
  `config/environment.rb` to fix a boot failure or drop `--no-boot`**, neither
  of which had happened. Such a tree now reads "This tree has no
  `config/environment.rb`; add one (or run from the app root) for runtime
  data."
- **A source path was contained without a separator and against an
  unresolved root.** The frontend framework introspector's own containment
  check let `/app-old` pass for `/app`. The pre-v5.8.1 bug, still in one
  place.
- **`rails_get_env` printed Dockerfile `ENV` and `ARG` values verbatim at
  detail full.** Every default now leaves through the redaction gate, and a
  surrounding quote pair is stripped, so `ENV FOO="bar"` prints `bar`.
- **`rails_read_logs` matched the `search` term before redacting**, so a
  hidden value could be probed a character at a time. The search runs on the
  redacted text now.
- **The middleware introspector fabricated an empty stack in the static
  tier.** It declares an alternate source and answers only its file facts,
  rather than reporting an app with no middleware.
- **`rails_get_config` and `rails-ai-context facts` read gem keys no
  introspector emits**, so the Auth line and the Key Dependencies section
  never rendered at all.
- **Jobs and mailers carry `file:`.** `rails_get_job_pattern` reads the
  carried file instead of camelizing a basename, and its listing comes from
  the payload, so a job in a pack lists.
- **The auth introspector keyed Devise models by basename**, so
  `app/models/admin/user.rb` overwrote `User`.
- **An out-of-order migration merge was reported as none pending** by the
  migrations section while the schema section counted it. Both derive from
  one applied set now, and an unknown applied set answers no pending key
  rather than "everything" or "nothing".
- **Substring lockfile scans reported `bugsnag-capistrano` as Bugsnag** and
  `database_cleaner-redis` as database_cleaner. One lockfile reader with
  exact names answers every gem question, across the GEM, GIT and PATH
  sections.
- **The hydrators warned about a model they had just resolved in another
  spelling**, and emitted one hint block twice.
- **The channel and mailer eager loads had no per-constant recovery**, so a
  single unloadable file emptied the list.
- **`YAML.safe_load` refused the `&default` anchors** every stock webpacker
  or shakapacker config carries, so the source path fell back to the
  convention.
- **VFS: `controllers/admin/posts` fell into the action handler** and
  `routes/PostsController` returned zero routes.
- **`Payload.section` accepted a refused (`unavailable`) section**, so a
  static-tier context file rendered a bare heading.
- **Every generated file counts the same controller set.**
  `config.excluded_controllers` is honoured everywhere, not only by
  `rails_get_controllers`.
- **The doctor counted models and controllers under `app/` only.** Packs and
  engines count, and the freshness check reads the one watch scope.
- **The watcher stopped noticing `config/routes.rb` and `db/schema.rb`.** The
  fingerprint, the watcher and the doctor share one scope covering `config`
  and `db` whole, and the fingerprint mark is taken before the read it
  protects.
- **The diagnose tool's git probe ran outside a repository** and leaked its
  stderr into the response.
- **`rails_get_stimulus` re-read every controller file** to recompute a
  lifecycle the payload already carried.
- **MCP config removal wrote non-atomically**, the dead `AstCache.invalidate`
  is gone, and the doctor checks that `.codex/config.toml` is gitignored.
- **Composing tools decided whether a sub-tool answered by scraping its prose
  for "not found".** A real answer whose body mentioned those words was
  dropped. Responses carry an empty marker in MCP `meta` now.
- **`rails_get_test_info` guarded a caller-supplied name with its own
  containment.** It reads through the shared guard.
- **The asset pipeline introspector's literal `none` was rendered as if it
  named a pipeline**, so every generated context file carried
  `- Assets: none`. The line shows only the parts that name something, and
  disappears when there are none.
- **`rails_get_view`'s ivar list counted an `@` inside an email address and a
  `@@class_variable`.** Neither is an instance variable.
- **A controller ivar compared, not assigned, was reported as set.** `return
  unless @post == current_user` no longer names `@post`; `||=`, `+=`, `<<=` and
  `>>=` still count.
- **`rails_get_context` resolved an action name case-sensitively** while
  `rails_get_controllers` did not, so `action: "Show"` skipped the ivar
  cross-check.
- **The ivar cross-check ran with no view templates section**, reporting every
  controller ivar as unused in the view. It is skipped instead.
- **`rails_get_turbo_map` printed a Turbo Stream response as a Ruby hash.**
  It renders `PostsController#create`, the way the file's other sections name
  a controller action.
- **A second `context` run rewrote the generated files** for their timestamp
  alone, so a repo that commits the context files saw a diff from a run that
  found nothing new. One rule now covers them all: a file that differs only
  in its `generated_at` key, or in the full-mode header's `> Generated:`
  line, is skipped.
- **The schema listing named one model per table.** A table an STI child or a
  namespaced second model shares listed whichever came first in the payload,
  which could be the emptier one. Every model on the table is listed now,
  the one carrying the most detail first.
- **Every static-tier context file carried `Rails [UNAVAILABLE: app not
  booted]` mid-sentence.** The version comes from the lockfile, and the
  marker is left for a tree whose lockfile does not carry rails.
- **`rails-ai-context preset " FULL "` exited 1 with the listing.** A preset
  name is matched whatever its case or padding.
- **A `--no-boot` run that found no app printed the doctor hint**, which asks
  for a boot error that never happened. `doctor` and `init` also accept a
  tree that has app source but no `config/environment.rb`, and the refusal
  names that file instead of telling the user to go to the app root they are
  standing in.

### Changed

- **`RailsAiContext.generate_context(format: nil)` means the recorded AI-tool
  selection**, and all of them when nothing is recorded. It was `:all`.
- **Static-tier migration names are the class-style name** (`CreatePosts`),
  matching what the booted tier reports.
- **Names in the turbo, auth, attachments and multi-database sections carry
  their namespace** (`Admin::User`, not `User`), and packs and in-repo
  engines count everywhere the app's source is walked.
- **The `.env.example` reader judges a value by its shape and length only.** A
  default in Ruby source or a Dockerfile is condemned by a secret-shaped name
  as well.
- **Turbo wiring lives in the introspector payload with file and line** -
  frames, model broadcasts, explicit broadcasts and stream subscriptions -
  and `rails_get_turbo_map` renders it. A `turbo_frame_tag dom_id(@post,
  :edit)` frame renders as that call, and a symbol `turbo_stream_from :posts`
  now pairs with its broadcast. A subscription argument that carries its own
  commas renders whole: `turbo_stream_from [current_user, :notifications]` and
  `dom_id(@post, :x)` keep every character they were written with.
- **The public-methods lists come from the parser.** `rails_get_concern`,
  `rails_get_helper_methods`, `rails_get_model_details` and
  `rails_get_controllers` read `private def` and `class_methods do`
  correctly.
- **The standalone binary boots through `CLI::EntryBoot`**, and presets run
  through `Presets.run` in both the binary and the rake task.
- **`rails_get_controllers` and the controller-action resource decide which
  filters apply through one module, `ActionFilters`.** Every inherited filter
  carries the `(from Parent)` annotation, after_action and
  except-constrained ones included; a filter constrained with `except:` shows
  that constraint; `skip_after_action` and `skip_around_action` count as
  skips, and a skipped filter is struck through in the whole-controller view
  as well as the per-action one.
- **A config value longer than 40 characters is filtered on every path.** The
  Ruby-source and Dockerfile readers capped at 30 before; `.env.example` was
  already 40.
- **`schema[:pending_migrations]`, reachable through the `rails://schema`
  resource, is a list of `{ version:, name: }` entries** rather than version
  strings.
- **`rails-ai-context://routes/{controller}` prefers an exact route-key
  match**, so `routes/posts` no longer also returns `admin/posts`.
- **`unavailable_sections`, where a section carries it, is a list of
  section keys**, not a reason string. The middleware section's static
  answer is the one that still emits it.
- **The models resource template advertises
  `rails-ai-context://models/{name}`**, and every scheme resolves through the
  VFS rather than an exact-match legacy reader. `rails://models/{name}` is
  still accepted.
- **`controllers[:controllers]` can carry `{ error: "unreadable" }` entries**
  for a file over the size cap or otherwise unreadable, and the listing and
  the count include them.

### Removed

- **`SourceLine`, the hand-rolled Ruby lexer.** Every source read goes through
  Prism.
- **`Fingerprinter.reset_gem_lib_fingerprint!` and `AstCache.invalidate`** -
  no callers.
- **Support for the mcp gem below 0.13.** The gemspec floor is `>= 0.13`, the
  first release whose tool responses carry `meta`.
- **`Presets.names` and `Presets.fetch`** - the listing and the run read
  `DEFINITIONS` directly.
- **`SchemaHintBuilder.build_many`** - no callers.
- **`Fingerprinter.changed?`** - no callers; `stale?` answers the question.
- **The public constant `ChangeWatch::WATCH_DIRS`.**
- **`RailsAiContext.configured_via_block?`** - no callers once the config file
  applies once per configuration and a block wins its keys by name.

## [5.24.0] - 2026-08-17

### Fixed

Defects found by a QA round against GitLab, OpenProject, Canvas LMS,
Discourse and Mastodon. Every one of them exits 0.

- **The commands that read the app degrade the way `tool` does.** `context`,
  `inspect`, `facts`, `preset`, `watch` and `init` called a bare boot guard,
  so on a repo you have just cloned - the case an agent most needs a
  `CLAUDE.md` for, and the case least likely to boot - every tool answered
  and the command that writes the files exited 1 having written nothing.
  `init` was worse: it writes its config files first, so a boot failure left
  the app half set up and called that a failure. They allow the static tier
  now and each takes `--no-boot`; `doctor` still fails, because diagnosing
  the boot is its job. Writing under `--no-boot` then exposed its own bug -
  the context writer asked `Rails.application` for the output directory,
  which raises `NameError` on the path where Rails is never loaded at all.
- **`tool --list` reads the app's config when the app cannot boot.** Boot is
  what normally loads `.rails-ai-context.yml`, so the listing fell back to
  the gem's defaults: on Mastodon it advertised 45 tools while the MCP server
  offered 43 and the CLI itself answered `Unknown tool 'query'` for one it
  had just listed.
- **`search_extensions` is documented as the fallback's list, which is what
  it is.** Making ripgrep honour it did make the two backends agree, and it
  cost the reach that makes the tool useful: on Mastodon `gem 'devise'` went
  from 5 results to none, because a Gemfile carries no listed extension - and
  the same for a Rakefile, a `.md`, a `.sql`. The docs, the attr comment and
  the line the install generator writes now say plainly that the list is the
  Ruby fallback's and that ripgrep searches every file.
- **A table the replay cannot name is not reported.** Canvas has a migration
  that calls `create_table table_name do |t|` with a local computed at run
  time; the replay kept the entry under a nil key, and the first serializer
  to sort the table names took the whole context run down. Reachable only
  once `context` could enter the static tier at all.
- **Coverage says nothing when there is nothing to measure against.** With a
  `default_locale` the app configures but ships no file for, every locale
  scored zero and all of them were named as untranslated.
- **A mixin in a nested concerns directory is not a model.** The skip only saw
  the top-level `concerns/` that Rails autoloads, so OpenProject's
  `app/models/queries/operators/concerns` contributed four mixins to a model
  count of 978 where the app has 974. A nested `concerns/` is an ordinary
  namespace, though, so the directory name alone does not decide it: a file
  there that declares a class is a model like any other.
- **`docs/COMPATIBILITY.md` describes the static tier the gem actually has.**
  It said 6 introspectors answer without a booted app and "the other 34 have
  no static path", naming eight examples - all of which answer. The real
  split is 23 files-only, 9 alternate-source and 8 runtime-only: 32 of 40.
  A guard spec derives all three lists from `INTROSPECTOR_MAP`.

- **A controller is named by the constant its source declares.** Zeitwerk
  resolves a path through the app's own inflector, which the static tier
  never loads, so camelizing the path invented `Activitypub::` for the 12
  controllers Mastodon declares as `ActivityPub::` and `Oauth::` for the 4
  it declares as `OAuth::` - names that appear nowhere in an app that
  registers those acronyms, and a `NameError` for anyone who uses one. The
  path stays the answer where the source does not carry the whole name
  (`application_cable/channel.rb`) and where the declared name does not name
  that file, since Prism recovers a syntax error into a partial tree.
- **An interceptor is told from a mailer by its framework hook.**
  `app/mailers` is also where ActionMailer interceptors live, and every `.rb`
  under it counted: OpenProject's `Interceptors::DefaultHeaders` arrived as a
  mailer with `delivering_email` - a hook the framework calls - listed as an
  email an agent could send, 2 of its 11 entries. What an interceptor has and
  a mailer does not is one of `delivering_email`, `previewing_email` or
  `delivered_email`; requiring a class instead would have dropped GitLab's 20
  `Emails::*` modules, which hold every notification it sends.
- **Migration replay reads what a migration does, not what it undoes.** A
  `def down` says how to reverse the change, so replaying it alongside `up`
  cancelled the migration out. On a migrations-only app the ordinary
  up-creates/down-drops pair erased two tables OpenProject really has (35
  to 37), and the reverse pair would have invented one it dropped. The same
  now holds for the block spellings, `reversible { |dir| dir.down { ... } }`
  and `revert`, and for the `t.timestamps` inside them - those were found by
  a separate walk over the whole file, so a down body's timestamps landed on
  the last table created on the way up.
- **i18n coverage groups the locales below its own rounding floor instead of
  listing them.** A language-name lookup table under `config/locales`
  contributes a top-level key per language, and Rails does load each as an
  available locale. Scoring them produced a row each saying every key was
  missing: on Discourse, 138 of 186 coverage rows described a translation
  effort nobody had started. Those 138 are now summarised in one line, with a
  shared key count stated once. The rows still exist - asking for one by name
  answers with its numbers, so a translation genuinely started below the floor
  is not written off as untranslated. The available list still matches a
  booted Rails, and a locale's keys are read from its own file and any shared
  file together, so one that lives outside the naming convention is scored.
- **A recorded tool selection no longer switches off `.ai-context.json`.**
  The install generator always records one, and every later `rails
  ai:context` passed that list to the serializer. The machine artifact is
  not an AI tool and no install menu offers it, so it silently stopped being
  written on the one install path the docs describe - while the generator
  went on adding it to `.gitignore`.
- **`skip_tools` accepts the symbol spelling its neighbours use.** Every
  other key in the generated initializer takes symbols, and `%i[]` here
  skipped nothing at all: both readers compare against a tool name, which is
  a String.

- **A controller carries the file it was read from.** Reading the name from
  the source fixed the name and broke every path derived from it:
  `ActivityPub::CollectionsController`.underscore is `activity_pub/...` and
  the file is under `activitypub/`, so `rails_get_context` answered "Could
  not extract source code" for a file that exists and asked the routes for a
  controller key Rails does not use. Both tiers emit `file:` - the booted one
  asks Ruby where the class was defined - and the consumers read it through
  `Payload`.
- **The locale files are indexed once, not once per locale.** Asking every
  file about every locale is O(locales x files): on Discourse, 187 over 108,
  it took the i18n answer from 4.6 seconds to four and a half minutes. Each
  entry also records the locales it serves, so asking for one by name finds
  its files even when the filename spells the gem rather than the locale.

- **Every consumer that turns a controller name back into a path reads the
  file it was read from.** Carrying `file:` fixed six of them and left five
  answering a confident negative, which is the answer an agent acts on
  without checking. On Mastodon's 18 inflected controllers: `rails_test_info`
  reported 16 specs that exist as missing, `rails_get_routes` reported 4
  routes that exist as absent, `rails_get_view` 2 views, and
  `rails_generate_test` wrote a spec whose body was `skip "no routes found"`
  for a controller with a route. `rails_analyze_feature` listed them as
  untested. `Payload.controller_route_key` is the one derivation now, and a
  spec drives all five tools with an inflected name.
- **The install path's files require their own stdlib.** `init` loads six
  files before Rails and before the entry file, on purpose - so the entry
  file's `require "set"` never runs for them. `legacy_cleanup`'s `[...].to_set`
  raised `NoMethodError` on Ruby 3.1, where `Set` is not autoloaded, and 3.2+
  hid it: only the CI matrix ever saw it.
- **`rails_runtime_info` reports cache numbers, not the cache object.** The
  MemoryStore branch passed `cache.inspect` straight through, so the answer
  carried `#<ActiveSupport::Cache::MemoryStore entries=0, size=0, options={...}>`
  - the shape this gem has shipped as a defect before. Entries and size are
  now facts, and a store that answers `#stats` gets its hash rendered as pairs
  rather than a Ruby literal.
- **A model's table comes from its file, not from its name.** Naming a model by
  the constant its source declares made `underscore` stop being the way back:
  `OAuthClientConfig` underscores to `o_auth_client_config`, and the file is
  `oauth_client_config.rb`. `rails_model_details` reported the table as
  `o_auth_client_configs`, which no app has, so the columns section vanished
  and the schema hint pointed at nothing - on Canvas that hit
  `OAuthClientConfig`, `OAuthRequest`, `AuthenticationProvider::OAuth` and
  `OAuth2`, on OpenProject `OAuthClient` and `OAuthClientToken`. The file's own
  name already carries the inflection, because Zeitwerk resolved the constant
  from it. `rails_generate_test`, `rails_get_callbacks`, `rails_test_info` and
  the five `rails_validate` checks that key models by path read it too.
- **An abstract base class is not a model in the static tier either.** A
  booted Rails rejects `abstract_class?`, and a namespaced base class is one:
  GitLab's `Ci::ApplicationRecord`, `PackageMetadata::ApplicationRecord` and
  `SecApplicationRecord` were counted, so the same app answered 895 models
  without a boot and 888 with one. OpenProject: 974 against 971.
- **A model carries its file too, and is named by the constant its source
  declares.** `rails_model_details` rebuilt `app/models/<underscored>.rb` from
  the name in four places, so for a model in a pack or an engine the custom
  validations, the source-defined methods, the method signatures and the class
  structure all went quietly missing from an answer that otherwise looked
  complete. The static tier also camelized the path into the name, so an app
  registering an inflection got a constant it does not have - and one the
  booted tier, which reads the real class, would never agree with.
- **`rails_validate_semantics` checks the views under an inflected directory.**
  A view directory names the route key, so camelizing `app/views/oauth/` back
  gave a constant the app never declares and the undefined-ivar check stopped
  running for that whole tree without saying so.
- **A test-gap claim is not made from a scan that stopped early.**
  `rails_analyze_feature` scans the first 500 files per glob; Discourse has
  1,672 specs, so the scan never reached the ones covering the feature and
  every controller in it was reported as having no test. The Tests section
  disclosed the cap, the gaps section asserted through it.
- **"Global before_actions" in the generated files means global.** The scan
  matched `skip_before_action` too, and ignored `only:` / `except:` / `if:`.
  Mastodon's `CLAUDE.md` listed five, of which three were false - including
  `verify_authenticity_token`, which that controller skips.

### Added

- **`--no-boot` on `context`, `inspect`, `facts`, `preset`, `watch` and
  `init`.** The static tier was reachable from `tool` and `serve` only.
- **`--no-boot` reads a repo that has source but no `config/`.** An engine
  keeps its dummy app under `spec/dummy`, so the guard against describing an
  empty directory has to measure source, not boot files.

### Changed

- **The generated initializer has one indent from top to bottom.** The AI
  Tools section was written at the configure body's indent and every section
  after it flush, so the file an app commits changed indent two lines in and
  stayed there.

## [5.23.0] - 2026-08-16

### Fixed

- **`AstCache.parse_string` caches, as its name always said.** Keyed by
  content digest, sharing the store and its eviction; oversize sources
  bypass instead of raising. A controller was parsed up to ten times per
  static run because every extractor received the text and re-parsed it.
- **`rails_validate` says which checks it skipped.** When the AST parse
  fails, the three rules with no regex twin used to vanish silently and a
  partially-checked file read as clean; the response now names them. The
  tool also gains its first spec file.
- **A downstream app exception is the app's again.** The middleware's
  rescue used to convert any error from the app behind it - non-MCP
  requests included - into an MCP error frame. `McpEdge.rack_call` now owns
  the whole Rack-shaped request (path match, session scope, dispatch,
  containment) for the middleware and the standalone server, and the
  pass-through branch runs outside the rescue.

### Changed

- **The cache fingerprint watches what the resolvers read.** Packs,
  engines, `extra_app_paths`, every concern home, the `Gemfile`,
  `config/locales` and `config/environments` now feed the fingerprint, so
  an edit there cannot serve a stale answer that looks fresh.
- **One change-detection loop.** `ChangeWatch` owns the watch list, the
  Listen wiring, the fingerprint gate and the code reload; `Watcher` and
  `LiveReload` keep only their reactions (regenerate files; refresh caches
  and notify clients) and their own missing-`listen` policy.
- **The initializer guard and the `tool_mode` line each have one home.**
  `Install::InitializerFile` holds the guard patterns the generator writes
  and the doctor diagnoses; `SelectionRecord.write_tool_mode` replaces the
  rake task's hand-rolled three-branch rewriter, and only rewrites an
  uncommented line, so the generated commented-out default stays a comment.
- **Split-rule targets derive from the `Install::AiTool` table.** The
  rules serializers read `rules_dir` (and the AGENTS.md pair) from the
  table doctor and cleanup already read, so a moved path changes every
  surface at once.
- **The stack helper writes through `SafeFile.atomic_write`** instead of a
  private copy of it, and its app-tree scans take a root, so they are
  covered by specs for the first time.
- **Every serializer is proven against a context real introspectors
  produced** (`IntrospectedFixture`), so no serializer can read a shape
  production does not make - the class of defect that kept the engines and
  turbo sections dead while hand-built fixtures stayed green.

## [5.22.0] - 2026-08-16

### Fixed

- **A class nested inside a controller, mailer, model or helper file no
  longer contributes its methods to the host's interface.** "Which public
  methods are this class's own" had five transcriptions with five filter
  sets; they now share `ActionResolver`, which filters listener output by the
  owner field the listener always emitted, walks app-owned ancestors, and
  falls back to reflection with the #136 base subtraction. Mailers had kept
  the pre-#136 reflection answer, so a public helper on a non-abstract
  `ApplicationMailer` arrived as a deliverable action; they subtract now, and
  static mailer actions apply the same underscore rule as controllers. (#149)

- **Every generated context file states each fact through one renderer.**
  `SectionFacts` owns the models line, the database line, the associations
  list (eight copies, three of them in tools) and the warnings section -
  which now renders in AGENTS.md and .github/copilot-instructions.md too, so
  a half-failed run cannot look clean in two of four files. AGENTS.md stops
  shadowing the shared architecture and footer renderers with poorer copies,
  and its controller list goes through the shared renderer with named
  actions as a depth choice rather than a fork. `Payload` is the reading
  side of the introspection hash: list readers whose key pairs a spec pins
  against the producing introspector's real output, so the next renamed key
  fails a test instead of silently emptying a section. (#151)
- **API-only apps are told "does not apply", not "not found".**
  `rails_get_helper_methods` and `rails_get_frontend_stack` now consult the
  api-only note like the other eleven call sites. The two hand-rolled
  paginations (`rails_get_schema`, `rails_get_stimulus`) go through the
  shared `paginate`, one offset/limit behavior across all fourteen paginated
  surfaces. (#152)
- **The interactive install is one program with three voices.** The
  generator, the standalone binary and the rake task each held a full copy
  of the prompts, the removed-tool cleanup, the gitignore append and the
  MCP-config write - about 470 lines that had already drifted: two labels
  for one mode, a menu with file lists in two entries and bare names in the
  third, a byte-identical gitignore block three times. `Install::Program`
  now owns the steps and the wording; each entry supplies its say/ask
  surface and keeps only its closing instructions. The rake menu shows each
  tool's files, and every entry uses one mode label.
- **Configuration loads the same way on every entry point.** The engine now
  runs `auto_load!` at boot, so `.rails-ai-context.yml` works on the rake
  tasks, the middleware and the engine controller the way the docs always
  said - initializer first, the loader steps aside when a configure block
  ran. `Configuration#ai_tools` answers from `SelectionRecord` when nothing
  set it, so `rails ai:context` stops re-asking a question the record
  already answers, and the recorded `tool_mode` reaches in-app surfaces
  through the record's new reader. A bad YAML value now warns and keeps the
  default the way bad syntax always did, instead of dying raw out of the
  CLI. (#147, #148)
- **The three static schema sources follow one set of conventions, and every
  schema question can be asked of any of them.** `SchemaReader.for(root)`
  chooses schema.rb, structure.sql or migration replay behind one
  question-level seam, so introspectors asking "does this table carry this
  column" now get answers on structure.sql and migrations-only apps instead
  of nothing. The migration replay is repaired: a replayed `create_table`
  seeds its implicit `id`, `change_column_null` applies in both directions
  (the listener now captures the positional boolean), and `t.references` is
  typed per adapter instead of hardcoded bigint. The conventions live in
  `SchemaConventions`, shared by all three sources the way #140's
  foreign-key fix pioneered; the SQL parser and the replay engine moved to
  `StructureSqlReader` and `MigrationReplay`, and the schema introspector
  halves in size, keeping only presentation. (#150)
- **Every surface answers "which concerns count" and "how many routes" the
  same way.** Five renderers carried five concern filter sets:
  `rails_get_callbacks` hid every namespaced concern unless it started with
  "App", `rails_analyze_feature` hid all of them, and two ignored the
  `excluded_concerns` config. `ConcernMembership` now decides the payload
  sense once, at the introspector seam, for both tiers - the static
  controller answer goes through `MixinsListener`, so `prepend` counts and a
  singleton-class `include` does not, exactly as booted. Route populations
  (app vs framework split, PUT/PATCH dedup) moved beside the coverage suffix
  into `RouteCoverage`, replacing four hand-kept computations, one of them a
  wholesale copy. CLAUDE.md's per-model concern list now names the concerns
  the app defines, namespaced ones included.
- **Mounted engines render again in `rails_onboard` and the context files.**
  `EngineIntrospector` emits `:mounted_engines`; the tool read `:engines` then
  `:mounted`, and the stack line read `:mounted`, so both fell back to "none"
  forever. Both now read the introspector's keys and the element's real
  `engine:`/`path:` shape, and the spec fixtures use that shape instead of one
  production never produced. (#144)
- **The Hotwire stack line and `rails_onboard`'s Real-Time and Frontend
  sections read turbo keys that exist.** `turbo[:frames]`, `[:streams]` and
  `[:broadcasts]` were never emitted (`:turbo_frames`, `:turbo_streams` and
  `:model_broadcasts` are), so the line was dead everywhere and Real-Time
  always fell through to its view-scan fallback. (#145)
- **`rails_get_context` no longer offers a Related Services section it could
  never fill.** The `:services` key it read has no introspector behind it; the
  dead branch is gone. (#146)
- **`rails ai:context` stops re-prompting a YAML-configured app on every
  run.** The rake path now loads `.rails-ai-context.yml` the way the
  standalone binary always did; the initializer still wins when its configure
  block ran. (#147)
- **The standalone binary's `--format` help names opencode and codex.** A
  guard spec pins the help text to `Install::AiTool`, which the Thor class
  body cannot ask at definition time. (#153)
- **`rails ai:serve` and `rails ai:serve_http` boot under the same timeout
  and rescue as the binary.** A hanging initializer used to hang the task
  forever where `rails-ai-context serve` gives up at 60s; both tasks now boot
  through `BootManager.guard`, and `RAILS_AI_CONTEXT_BOOT_TIMEOUT` is parsed
  in one place. (#154)
- **doctor's tool list and `rails_search_code`'s exclusion list derive from
  `Install::AiTool`.** Both were hand-typed restatements sitting below the
  ownership spec's detection floor; the search exclusions now also cover the
  generated `app/models/AGENTS.md` pair they previously missed. (#155)
- **An e2e example asserts `call` and `static_call` answer the same keys.**
  The declaration contract was already enforced (ADR-0002); the shape contract
  was not, so a key added to the booted tier could silently vanish from the
  static one. (#156)

## [5.21.3] - 2026-08-12

### Fixed

- **Foreign keys name the column that was declared, not one invented from the
  target table.** `add_foreign_key "accounts", "accounts", column:
  "moved_to_account_id"` was reported as `account_id`, a column the table does
  not have, and two such keys on one table collided into the same invented
  name. The schema listener dropped `column:`/`primary_key:` entirely, so the
  convention was the only answer; it is now the fallback for the case Rails
  omits the option in. The migration-replay path invented `statuse_id` from
  `statuses` for the same reason. (#140)
- **A service's constructor is read from the service, not from the first
  nested class in the file.** `rails_get_service_pattern` matched the first
  `def initialize(` anywhere in the source, so a nested error class or query
  builder supplied the signature for a service that defines no constructor,
  and an agent reading it wrote `PostStatusService.new(message, accounts)` for
  a class whose real interface is `.new.call(...)`. The constructor now comes
  from the AST walk that already resolves the interface owner, and a
  parenthesis-less `def initialize` is no longer missed. (#141)
- **Autoloader root_dirs are gem-relative, like initializer sources.** #139
  fixed the sources and left `autoload.autoloaders[].root_dirs`, where every
  engine's paths land, still absolute in `.ai-context.json`. Both introspectors
  now share one `PortablePath`, which also collapses a gem the Gemfile takes
  from `path:` or `git:`. A guard spec walks the whole generated context for
  paths from the generating machine. (#142)
- **A model's `*_url` and `*_path` columns are not reported as missing route
  helpers.** `rails_validate` read every receiverless call ending in `_url` as
  a route helper, and an attribute reader has no `def` for the local-method
  escape to find, so `shared_inbox_url` on Mastodon's `accounts` warned as a
  broken route. The check now consults the model's own column list. (#143)

## [5.21.2] - 2026-08-12

### Fixed

- **The static tier no longer drops a model's concerns.** Nothing in the
  listener stack collected `include`/`prepend`, so `rails_get_model_details`
  answered `--no-boot` with no Concerns section at all - not even an
  `[UNAVAILABLE]` marker - for a model that includes one. A new
  `MixinsListener` reads them from the source, filtered to the mixins
  reflection would report so both tiers answer the same question. (#137)
- **Cookie settings that Rails computes per request are named, not
  inspected.** Rails 8 defaults `same_site` to a lambda, which reached
  `.ai-context.json` as `#<Proc:0x...>` - an address that answers nothing and
  moves on every boot, so the file was rewritten on every run even when the app
  had not changed. Callables now render `[UNAVAILABLE: computed at request
  time]`, nested ones included. (#138)
- **Initializer sources are gem-relative instead of absolute machine paths.**
  Every one of them was written into `.ai-context.json` as
  `/Users/<name>/.rvm/gems/ruby-3.4.9/gems/railties-8.0.5.1/...`, which is
  wrong on every other machine, wrong again after a Ruby upgrade, and carries
  the generating developer's home directory into the app's repository. (#139)

## [5.21.1] - 2026-08-12

### Fixed

- **A controller mounted on a gem's base class no longer reports the app's
  helpers as actions.** 5.21.0 left reflection as the answer for a controller
  with an ancestor whose source the app does not own, and `action_methods`
  subtracts inherited methods only as far as the nearest abstract ancestor,
  which is `ActionController::Base`. A gem controller mounted on the app's own
  base class, which is what Doorkeeper's `base_controller` setting produces,
  therefore arrived carrying every public method that base and its concerns
  define: a controller serving 4 routes was reported with 16 entries, 13 of
  them helpers such as `set_locale` and `with_read_replica`. The base
  controller's own `action_methods` is exactly that set, so it is subtracted.
  (#136)

## [5.21.0] - 2026-08-12

### Fixed

- **`get_env` no longer offers a name the app never reads.** An app that builds
  its variable names by interpolation, the normal shape when it carries several
  Redis connections, had `#{prefix}URL` reported as a variable name and
  `defaults[:port]` reported as that variable's default. The scan reads the
  parser now instead of matching whatever sat between two quotes, so a name
  that does not exist until runtime is not offered to someone writing a
  `.env.example`, and a default is printed only when it is a value. Comments
  drop out for free, including one trailing a line that also reads `ENV`.
  (#129)

- **`get_controllers` no longer lists `set_locale` as an action.** A controller
  whose own file defines no public method fell back to `action_methods`, which
  subtracts inherited methods only as far as the nearest abstract ancestor:
  everything `ApplicationController` and its concerns define publicly came back
  as an action, so a two-route controller reported 19 of them. The actions of a
  thin subclass now come from the source of the ancestor that defines them.
  Reflection is left for the case that has no source to read, an ancestor this
  app does not own the file for, which is what a controller inheriting from a
  gem or an engine looks like. (#130)

- **`get_service_pattern` reports the service's entry point, not a nested
  class's.** Nesting a query builder inside the service that uses it is a
  normal way to organise a large one, and the line scan could not see it: it
  named `QueryBuilder#build` as the entry point of a 312-line service, and a
  `private` inside a nested class hid the real `call` that followed the nested
  class's `end`, reporting the service as having no entry point at all. The
  methods now come from the AST, scoped to the class the file is named for.
  (#131)

- **`get_test_info` counts tests, not files.** "Test Counts by Category"
  globbed every `.rb` under a category directory, so four mailer specs sitting
  beside four mailer previews counted as eight tests. Anything a project keeps
  next to its specs inflated the number. (#132)

- **`get_concern` finds every concern the app has.** It searched two hardcoded
  directories while `get_active_support` searched five, so one run answered 80
  concerns and 81 concerns for the same app, and the mailer concern only the
  second one found could not be reached by name through the first. Both now
  read one seam, which discovers `app/*/concerns` the way Rails autoloads it,
  so an app that keeps `app/serializers/concerns` is covered too. Concerns are
  grouped and filterable by the directory that owns them. (#133)

- **Namespaced Pundit policies keep their namespace.** Policy names came from
  the basename, so `app/policies/admin/collection_policy.rb` and
  `app/policies/collection_policy.rb` both read as `CollectionPolicy`. One name
  was listed twice and the other class appeared nowhere in the generated
  context or in `CLAUDE.md`, including the one that defines `destroy?`. (#135)

- **Re-running a release no longer fails on the MCP Registry.** The registry
  answers a repeat version with a 400, and the publish step had no guard, so
  re-running a release that had already succeeded turned the workflow red with
  nothing wrong. It now checks for the version first, the way the RubyGems step
  already did.

### Changed

- **`config.concern_paths` replaces concern discovery instead of adding to
  it.** Left unset, which is now the default, every `app/*/concerns` directory
  is discovered. Setting it means those directories and no others, so it can
  narrow as well as reach outside `app/`.

## [5.20.3] - 2026-08-11

### Fixed

- **`serve --transport http` no longer answers "Session not found" to about half
  of all requests.** Rackup hands Puma the host app's `config/puma.rb`, and a
  real app sets `workers` there, so the transport ran as a cluster - but MCP
  sessions live in one process's memory, and a forked worker cannot answer a
  request whose `initialize` a sibling handled. Puma is now pinned to single
  mode. Both options are load-bearing: refusing the config file still leaves
  `WEB_CONCURRENCY` able to start a cluster on its own, and pinning the worker
  count still lets the file's `pidfile` and `preload_app!` through - the pidfile
  being one this server would otherwise write over the app's own. (#123)

- **A gem's background job is no longer counted as the app's.** `extract_jobs`
  filtered `ActiveJob::Base.descendants` with a list of framework name
  prefixes, which no list can keep up with: on an app with 118 Sidekiq workers
  and no ActiveJob of its own, the generated `CLAUDE.md` read `Async: 1 job`
  and that job was an indexing worker belonging to a gem. Ownership is now
  decided by where the class is defined. A class with no source location is
  kept, because understating what the app runs is the worse mistake. (#120)

- **`get_job_pattern` now names the queues `config/sidekiq.yml` declares.**
  `extract_sidekiq_config` already read them; holding the result back left the
  answer describing `app/jobs/` and nothing else, on an app whose sidekiq.yml
  is the one piece of evidence in reach that async work happens elsewhere. It
  reaches the job listing as well as the empty-directory message - a count of
  what `app/jobs/` holds is still a claim about the app's async work, and on an
  app running most of it through Sidekiq that count is the small half. (#120)

- **The context no longer carries `static_parse` as a database name.**
  `SchemaIntrospector` writes that placeholder when it reads a dump instead of
  the connection, and laundering it at each rendering surface left the ones
  nobody thought of - `.ai-context.json` and `rails://schema` - naming a
  database that does not exist beside a `multi_database` section in the same
  file naming the real one. It is now resolved once, where the context is
  assembled, so nothing downstream has to remember. The raw observation stays
  under `adapter_source`. (#128)

- **The static tier follows `draw` into `config/routes/*.rb`.** An app that
  splits its routing table that way kept most of it in files the parser never
  opened: `--no-boot` answered 94 routes on a 723-route app. Rails resolves
  `draw(:admin)` by literal path, so following it is a plain file read; the
  resolved path is confirmed inside `config/routes/` with `realpath` first, so
  a symlink there cannot reach the rest of the disk. (#127)

- **Every surface that prints a route count says how much of the table it
  could not expand.** `RouteIntrospector` recorded `dynamic_routes` for
  constructs it refused to fabricate (`devise_for`, a `draw` whose target is
  computed or too large to parse) and nothing read it, so `rails_get_routes`,
  `rails_onboard`, `CLAUDE.md`, the Cursor and Copilot rule files, the markdown
  context and the rake summary all quoted a partial count as the whole routing
  table. `RouteCoverage` is the one answer they now share, shaped as a suffix
  so no call site needs a conditional of its own - nine each having to remember
  is what produced this. A `draw` whose routes are in the list does not count,
  whether this pass read the file or an earlier branch did; one stopped by the
  depth cap, or naming a file too large to parse, does. A drawn file that
  cannot be parsed costs its own routes rather than the whole section. (#127)

- **The static tier counts an update route once.** Rails registers PATCH and
  PUT separately for one action and every surface that lists routes merges
  them, but the static total did not - so the generated files said "8 total"
  where `rails_get_routes`, which merges for itself, said 7 on the same
  `resources :posts`. (#127)

### Changed

- `actionmailer` and `puma` are development dependencies now. Without
  ActionMailer loaded, `ActionMailer::Base` is undefined and every assertion
  about mailer actions passed over an empty array; the Puma single-mode pin is
  only testable against Puma's own option semantics. Neither affects the
  gem's runtime dependencies. (#123, #126)

## [5.20.2] - 2026-08-11

### Fixed

- **A long-lived process no longer answers about the app as it was at boot.**
  The MCP server and `watch` invalidated their own caches on a file change but
  never reloaded Rails, and `Zeitwerk#eager_load_dir` does not re-scan a
  directory it has already loaded - so a model written after the server started
  stayed invisible for the life of the process, and the server told callers it
  did not exist. Routes were unaffected because `RouteIntrospector` already
  asked `routes_reloader.execute_if_updated`. Both change handlers now run
  Rails' own reloader first, gated on `config.enable_reloading` (the flag that
  decides whether Rails unloads anything - `eager_load` does not), and every
  tool call and every resource read now runs inside the executor so a reload
  cannot unload constants while one is reading them. A failing reload leaves
  the process alive, and a tool failure is not reported to the host app's
  error reporter - it is handled here and returned as an isError result.

- **A `validates_with` validator no longer replaces the whole model answer.**
  `ActiveModel::Validator` has no `#attributes` - only `EachValidator` does -
  so one of them anywhere on a model turned `rails_get_model_details`,
  `rails_get_callbacks` and `rails://models/X` into a single
  "Error inspecting X" line. (#121)
- **Static-tier callbacks are reported.** The two tiers handed back different
  types for one key: a Hash keyed by callback type when booted, a flat Array
  from the listener otherwise. Every consumer filters on `is_a?(Hash)`, so
  `--no-boot` answered "No models with callbacks found" for an app full of
  them, and `--model X --no-boot` raised `TypeError` on a Hash lookup against
  an Array. (#122)
- **`get_mailers` reports the actions Rails calls actions.** It listed
  `instance_methods(false)`, which includes ActiveSupport's generated
  `_run_*_callbacks` and any public helper, so an abstract `ApplicationMailer`
  was reported as having deliverable actions. It now asks
  `action_methods`. (#126)
- **One answer to which database the app runs on.** Four surfaces each carried
  their own substitute for the internal `static_parse` marker and disagreed:
  the generated `CLAUDE.md`, `rails_get_schema`, `rails_onboard` and
  `rails ai:inspect` could name three different databases for one app, and
  `onboard`'s gem loop let the last match win where the serializer's let the
  first. They now share `RailsAiContext::SchemaAdapter`, which resolves from
  the app's own database configuration first, then the `structure.sql` dialect
  already parsed, then the Gemfile - order-independent. (#125)
- **Generated context files no longer print `Database: static_parse`.** That is
  the internal marker for "read from db/schema.rb, not the connection";
  `onboard` already substituted the live adapter and the serializers did
  not. (#125)
- **`get_job_pattern` says what it checked.** "This app may not use background
  jobs" was a claim about the whole app drawn from one directory, and apps
  keeping Sidekiq workers in `app/workers/` were told they have none. (#120)
- **`validate`'s empty-files message advises a syntax the CLI accepts.** It
  recommended `files:["..."]`, which the CLI reads as a literal filename. (#124)
- **`validate --files a.rb b.rb` validates every file.** Array parameters
  consumed only the first token, so the rest were dropped silently and the
  summary read "1/1 files passed" for a set containing a broken file. (#124)

### Added

- **The static tier reads `config.api_only`.** Without a booted app the view
  tools fell back to "no Stimulus controllers found" on an API-only app, where a
  booted run says "Not applicable". Both were true, but only one of them stops
  an agent adding a view layer to an app that has none by design.

## [5.20.1] - 2026-08-11

### Fixed

- **`config.custom_tools` no longer takes the MCP server down.** Naming a
  `BaseTool` subclass resolved its constant, which autoloaded the class and
  enrolled it in the same registry the built-in list is read from, so it was
  offered to the SDK twice and rejected as a duplicate name. The server exited
  1 with an empty stdout while the CLI kept working. Tools are now merged by
  name; two different classes claiming one name keep the built-in and warn.
- **`--flag value` no longer inverts boolean parameters.** A boolean flag
  consumed no value, so `--app-only false` set `app_only` to true and dropped
  the `false` without a warning. Affected every boolean on every tool, and
  `--param value` is the form the CLI docs teach.
- **The static tier stops answering questions it cannot answer.** `mailers`
  reported "no mailers found" for an app with mailers, `engines` reported no
  engines loaded, `i18n` reported one locale while listing two locale files,
  and the Action Cable channels, deprecators, on_load hooks, cache store and
  credentials sections vanished with no marker. Mailers, channels and locales
  are read from source through `static_call`; the rest report
  `[UNAVAILABLE]`. Locale files using YAML anchors are read correctly, and an
  `I18n.default_locale` set in an initializer is honoured.
- **`app_only:false` lists the routes it counts.** It announced the unfiltered
  total above a body containing only app routes, and never showed a framework
  route. App routes are now listed first, so they cannot paginate out of sight.
  `app_only:true` says how many routes it hid and how to see them.
- **One app, one route count.** Generated context files counted raw routes
  while the tools merged each resource's `PATCH`/`PUT` pair, so `CLAUDE.md` and
  `rails_get_routes` quoted different numbers for the same app. The totals are
  merged at the source, and the serializers read
  `config.excluded_route_prefixes` instead of a hardcoded copy.
- **`rails_get_gems` past the last page** no longer opens with "No notable gems
  found" above its own "No items at offset N" note.
- The MCP startup banner reads the list off the built server, so it cannot
  announce a different set of tools than the server answers with.

## [5.20.0] - 2026-08-11

### Security

- **Initializer config values are redacted where they are read, not where
  they are rendered.** The config-assignment listener served raw source
  slices, so a `config.secret_key = "..."` in `devise.rb` reached
  `rails_get_context` and the generated context files in plaintext. Values
  assigned to secret-named settings are now filtered at emission, which
  covers every current and future reader of that listener.
- **Redaction and shortening are one operation.** They were separate calls
  in the caller's hands, and getting the order wrong let a long credential
  be cut apart before the pattern that would have caught it ever ran. The
  module exposes `redact_and_shorten`, so the order is not a caller's to get
  wrong.
- **The secret vocabulary widens, and nesting no longer hides a value.**
  `pepper`, `salt`, `master_key`, `signing_key`, `encryption_key`,
  `deterministic_key` and `encryption.primary_key` now read as secret names,
  and a value under a secret-named setting is filtered however deeply it
  nests. `config.secret = { primary: [ "..." ] }` emitted the credential in
  full.

### Changed

- **The prism floor rises from 0.28 to 1.4.** The old range was a claim
  nothing tested. A CI leg now pins prism at exactly 1.4.0 on Ruby 3.2, where
  prism is a real gem rather than stdlib, with a trimmed gemfile so a dev
  dependency cannot resolve it upward and turn the floor into a test of
  whatever version won. A scheduled allowed-to-fail leg runs the suite
  against prism's main branch, so a removal there surfaces here rather than
  in your bundle. 0.28 was measured green in the one configuration that could
  be checked locally; the raise is a tightening to a version CI proves, not a
  fix for a known break.
- **Redaction markers converge on `[FILTERED]`.** One module now owns the
  patterns and the vocabulary. `[EMAIL]` stays as the one semantic marker.
  Marker presence and this vocabulary are contract going forward; see the
  output contract in `docs/SECURITY.md`.

  | Was | Now |
  |-----|-----|
  | `[REDACTED]` | `[FILTERED]` |
  | `[redacted]` | `[FILTERED]` |
  | `[ENV VAR REDACTED]` | `[FILTERED]` |
  | `[dotenv] Set [ENV VARS REDACTED]` | `[dotenv] Set [FILTERED]` |
  | `[EMAIL]` | `[EMAIL]` (unchanged) |

- **`rails_get_schema` says "failed:" where it used to say "not available:"**
  when the introspector raised. It was the only one of the sixteen tools
  carrying that preamble whose failed-case wording differed; it now shares
  the phrasing the other fifteen use. The not-available and unavailable
  answers are unchanged.
- **An invalid `detail` answers at the default level and says it did.**
  Eleven tools each answered `Unknown detail level: x` and nothing else;
  `detail` is normalized once now, before any tool runs, so junk and omission
  both land on the default. You still get told: the response carries a note
  naming the value that was discarded and the levels that exist, so a typo is
  visible without eleven copies of the check. Tools that spell their own
  levels (`rails_onboard`: quick/standard/full) are untouched.
- **Listener registration is derived from the listener.** Defining an `on_*`
  handler is now its registration, validated against the events the running
  prism dispatches, so a typo'd handler raises instead of never firing. The
  hand-typed event allowlist that shipped the 5.19.1 fabricated-routes bug is
  gone, along with the hydrator's private copy of it.
- **MCP view resources resolve through the current app root** rather than
  `Rails.root`, so `rails-ai-context://views/...` works in the static tier.
- **One error frame for the MCP edge.** The middleware and the engine
  controller each built their own JSON-RPC internal-error body; both now read
  it from one place, so a failure looks the same whichever transport served
  it. Transport construction moves behind one factory; memoization stays with
  each caller, which holds a different scope (per instance, per class, per
  process).
- **A setting's name decides whether it is redacted, not its value's type.**
  `config.secret_key = 12345` was filtered in one emitted field and left plain
  in the other, because one path saw an Integer and the other saw the source
  text. One decision drives both now.

### Added

- **Twenty-seven sections now answer with the app not booted.** Gems, i18n,
  views, view templates, tests, jobs, turbo, stimulus, assets, devops, seeds,
  middleware, engines, components, performance, credentials, env and the rest
  read files the static tier already had on disk; they refused only because
  nothing had said they could answer. Each introspector now declares its
  static tier (files-only, alternate-source, or runtime-only), an undeclared
  one fails the suite, and every files-only declaration is proven against a
  fixture app with nothing booted. Runtime-only sections - config, api,
  conventions, autoload, security, observability, database stats, connection
  pool, initializers - still refuse honestly.

### Fixed

- **Re-running install through a different entry keeps your AI-tool
  selection.** The Rails generator read it from the initializer, the
  standalone CLI read it from `.rails-ai-context.yml`, and the rake task
  kept a third copy of the logic. Switching between them silently dropped
  the previous choice and re-prompted from scratch. All three read and write
  the same record now, initializer first on read because that is the file you
  hand-edit. Recording the selection also reaches both files together, so an
  entry can no longer leave a stale initializer that outranks the YAML it
  just wrote. An initializer with a `configure` block but no selection line
  now gets one from any entry, not just the rake task.
- **The standalone HTTP server scopes its session record per client.** The
  Rack middleware and the engine controller got this; `rails-ai-context serve
  --transport http` serves many clients from one process too and was still
  pooling their `rails_session_context` history.
- **The generated guide advertised a CLI command that does not exist.** Its
  row for `rails_get_env_config` printed `ai:tool[environments]`, which the
  CLI cannot resolve; the CLI name is now derived from the tool name rather
  than typed beside it.
- **One MCP client's session record no longer shows up in another's.**
  `rails_session_context` kept one process-global list of calls, which is
  right over stdio but wrong for the two HTTP transports, where a single
  process serves every client. The record is now bucketed by
  `Mcp-Session-Id`. A caller's snapshot of the record also stopped changing
  under it: `session_queries` returned live entries that later calls kept
  mutating.
- **`.env.example` placeholders are shown, not filtered.** A
  `<your-secret-here>` came back as `[FILTERED]`, hiding the one thing an
  example file exists to show. A credential's shape and a placeholder's are
  told apart now.
- **The HTTP session record evicts the least recently used client, and is
  bounded.** It dropped the oldest-created session, which is usually the
  busiest one still in use, and it grew for as long as the process lived.
- **Tools no longer report themselves as failing on mcp 0.8.** The note
  naming a discarded `detail` value read `meta` off the response, which the
  0.8 SDK has no reader for, so building the note raised and the tool
  answered `Tool ... failed:`.

## [5.19.1] - 2026-08-10

### Fixed

- **Static-tier routes no longer inherit a closed `namespace` block.**
  `SourceIntrospector` registered its listeners for every Prism event except
  `:on_call_node_leave`, so the two listeners that pop a scope stack never
  received it. With `--no-boot`, every route declared after a
  `namespace :admin do ... end` block was reported under that namespace, so an
  app with `/comments` and `/health` served `/admin/comments` and
  `/admin/health` tagged `[VERIFIED]`. The same cause put a gem declared after
  a `group :development do ... end` block into that group in
  `rails_get_gems`' group listing. Booted mode was never affected.
- **`rails_get_i18n` coverage is measured against the default locale's keys.**
  It compared raw key counts, so a locale defining five keys against a
  one-key default reported `500.0%`. Coverage is now the share of the default
  locale's keys the other locale also defines, and each locale reports how
  many keys are missing and how many it adds beyond the default.
- **`rails_get_autoload` reports each path once.** Rails lists a path once per
  railtie that contributed it, so an app using `config.autoload_lib` showed
  `lib` twice under a count of two.
- **Counts of one read as singular.** Tools, generated context files, `doctor`,
  `facts`, the rake tasks and the standalone CLI wrote `1 keys`,
  `1 associations`, `1 pending migration(s)` and the like. A locale file with
  one key now reads `1 key`, a model with one association reads
  `1 association`, and `facts` reads `1 index, 1 FK`. Counts render through
  one shared helper, replacing the four spellings that had grown up across the
  render code: raw interpolation, a `== 1 ?` ternary, an `#{"s" unless n == 1}`
  suffix, and the `(s)` hedge. A handful of sites keep raw interpolation on
  purpose: ratios (`1/1 files passed`), diff stats, and byte or row counts
  whose branch only runs past a limit.
- **A locale file with a symbol root key counts toward coverage.** Both `en:`
  and `:en:` load as valid YAML, but only the string form had its root
  stripped, so a symbol-rooted locale compared its `es.`-prefixed paths
  against nothing and scored 0%.

## [5.19.0] - 2026-08-09

### Added - 6 new tools surfacing previously unserved introspection (45 tools total)

An audit found five introspectors whose data never reached the tool
surface (three only served context files; `:autoload` and
`:active_support` were unreachable entirely), plus one nervous-system
gap nothing introspected. All six are now first-class tools, registered
automatically in both MCP and CLI:

- **`rails_get_i18n`** - default/available locales, backend, locale files with
  key counts, per-locale coverage vs the default locale, and fallbacks
  (data: `:i18n` introspector, previously serializer-only).
- **`rails_get_mailers`** - every ActionMailer class with its delivery actions
  and delivery method (data: `:jobs` introspector's mailer extraction,
  previously serializer-only). Filter with `mailer:"UserMailer"`.
- **`rails_get_engines`** - engines mounted in `config/routes.rb` with
  known-engine descriptions, plus loaded engine classes with route/model
  counts (data: `:engines` introspector, previously resource-only).
- **`rails_get_autoload`** - Zeitwerk vs Classic mode, autoloaders with
  collapsed/ignored dirs, autoload/eager-load paths, and custom inflections
  (data: `:autoload` introspector, previously unreachable).
- **`rails_get_active_support`** - concerns registry, deprecators,
  MessageVerifier/MessageEncryptor usage, tagged logging, subscribed
  `on_load` hooks, and cache store (data: `:active_support` introspector,
  previously unreachable).
- **`rails_get_env_config`** - per-environment configuration from
  `config/environments/*.rb`: notable toggles (`force_ssl`, `eager_load`,
  caching, log level, queue adapter, mailer delivery) and every config key
  each environment sets. Backed by the new **EnvConfigIntrospector**
  (40 introspectors total, wired into `PRESETS[:full]`; file-based, so it
  also works in the static tier). Config keys and values are read with
  `ConfigAssignmentListener`, so a multi-line value, an assignment nested in
  a conditional, and the `Rails.application.config.x = y` form all read
  correctly. The key list pages with `offset`/`limit`.

### Fixed

- **Engine-mounted MCP returns JSON-RPC errors instead of Rails 500s.**
  `McpController#handle` had no rescue around `handle_request` - a
  transport-level exception escaped into a generic Rails HTML 500, breaking
  the client's JSON-RPC loop. It now answers 500 with a JSON-RPC `-32603`
  body, mirroring `RailsAiContext::Middleware`.
- **Standalone HTTP transport survives transport exceptions.** The Rack
  lambda behind `rails-ai-context serve --transport http` let a
  `handle_request` exception propagate to rackup (dropped connection). It
  now returns the same JSON-RPC `-32603` body.
- **MCP resources honor `max_tool_response_chars` without breaking the JSON
  contract.** Static resource, model, and VFS routes payloads were emitted
  unbounded (a huge schema or routes table rode a single JSON-RPC frame).
  They now fit the cap by dropping whole elements from the data rather than
  slicing the serialized string, so a capped payload still parses as the
  `application/json` it is labeled. What was dropped is reported under a
  `_truncated` key, which also counts any over-long string value that had to
  be cut. New `RailsAiContext::JsonBudget` owns the reduction.
- **A committed SSE stream is no longer overwritten by the error handler.**
  `McpController#handle`'s rescue set a status, headers, and a JSON body on
  responses that were already on the wire - closing a stream commits it, so
  every streaming failure reached the rescue committed. Assigning a body
  there swapped the stream out from under the thread draining it, turning a
  truncated SSE response into a garbled one. Committed failures now re-raise
  to `ActionController::Live`, which logs them with a backtrace and closes
  the connection; uncommitted failures still get the JSON-RPC `-32603` body.
- **`server.json` tool count** said 38 while the gem served 39; now tracks
  the real count (45). Broken `RAILS_NERVOUS_SYSTEM.md` link in
  `docs/INTROSPECTORS.md` replaced with a plain reference.

## [5.18.0] - 2026-08-09

### Added

- **Three new Prism listeners.** `ConfigAssignmentListener` reads
  `config.key = value` and `config.key.subkey = value` in initializers, matching
  the root anywhere in the chain so `Rails.application.config.assets.paths`
  resolves too. `ComponentStructureListener` reads ViewComponent and Phlex
  structure: `renders_one`/`renders_many`, slot methods, constant tables,
  `case @ivar` variant branching, and `CONST[@ivar]` indexing.
  `ClassDefinitionListener` reads class definitions with their superclass.
- **`docs/INTROSPECTORS.md` documents the listener catalogue**, how to add a
  listener, and when regex is the right tool instead of the AST.

### Changed

- **Auth, component, channel, controller, inflection and initializer reading
  moved from regex to the AST.** Devise and Doorkeeper settings, devise-jwt
  detection, ViewComponent and Phlex structure, Action Cable `identified_by` /
  `stream_from` / `stream_for` / `periodically`, `rate_limit` options, custom
  inflections, CORS origins, RSpec helper `include`s, `DatabaseCleaner.strategy`
  and model class detection are all read structurally now. Formatting that used
  to defeat the patterns (multi-line arguments, adjacent string literals,
  `%i[]` and `%w[]` forms) is read correctly.
- **A filter's `if:` condition reports the action it names.** A lambda has no
  literal value, so `if: -> { action_name == "create" }` used to surface as
  `[INFERRED]`; it now reads `action_name == "create"`. Same key, same type.
- **`rate_limit_parsed[:within]` no longer keeps a trailing comma.**
  `within: 1.minute, only: :create` returned `"1.minute,"` and now returns
  `"1.minute"`.
- **Initializer `setup_calls` sees more.** The old pattern only matched a line
  beginning with `config.`, so `Rails.application.config.x = y` and multi-line
  chains were missed.
- **Every remaining regex over Ruby source carries a note** saying why regex is
  right there: non-Ruby files, mixed-extension globs, vocabulary matching, or
  scope the listeners cannot see.

### Fixed

- **Dead namespace-tracking loop removed from `RakeTaskIntrospector`**, which
  walked every line of every `.rake` file and discarded the result.

## [5.17.0] - 2026-08-09

### Added

- **`config.query_allowed_columns`** exempts a column name from the built-in
  sensitive list used by `rails_query`. The rejection message told you to
  subtract from `query_redacted_columns`, which could never work: that list is
  unioned with a frozen suffix list, so an app with its own
  `oauth_applications.secret` had no way to query it.

### Fixed

- **Documented security behaviour now matches the code.** The ReDoS timeout on
  user-supplied regexes needs `Regexp.timeout`, which Ruby 3.1 does not have,
  so `SECURITY.md` no longer promises it unconditionally on a version the gem
  still supports. Layer 4 was documented as post-execution redaction; it has
  rejected the query outright since 5.8.1, which is what the doc now says.
- **`config.introspectors = %i[source]` no longer appears to be supported.**
  `SourceIntrospector` was listed in the introspector table but is
  infrastructure, not a registered introspector, so configuring it raised
  `ConfigurationError`.
- **Corrected documented defaults**, which had drifted: `sensitive_patterns` is
  27 patterns not 8, `excluded_middleware` 25 not 24, `excluded_filters` 5 not
  3, and the listener count is 21. `extra_app_paths` and
  `instrumentation_include_arguments` were undocumented.
- **Secondary database dumps report their own generated columns.** Parsing
  `db/queue_schema.rb` read generated columns from the primary `db/schema.rb`
  instead of the dump being parsed.
- **Polymorphic foreign keys no longer always report a missing index.** The
  compound check compared one joined string against two column names, so it
  could never match an existing index.
- **A column is no longer treated as indexed because a wider column name is.**
  Index matching compared substrings, so an index on `user_id` counted as
  covering `id`.

### Changed

- **schema.rb is read through one AST-backed reader.** `SchemaIntrospector`,
  `PerformanceIntrospector` and `ConventionIntrospector` each parsed the dump
  line by line with their own `create_table` regex; they now share
  `SchemaReader`, built on the existing `SchemaDslListener`, as do the static
  tier's table parse and the check-constraint, enum and generated-column
  reads that each walked the dump separately.
- **The static schema tier reports four things differently.** Where no live
  connection is available and `db/schema.rb` is parsed instead: a `t.references`
  or `t.belongs_to` column is reported by its foreign key name (`author_id`,
  not `author`), which is what the live tier has always reported; a column
  default written as a proc reports its source rather than being omitted; a
  default split across lines is picked up; and an expression index declared at
  the top level is flagged `expression: true`, as an in-table one already was.
- **`rails_validate`'s Rails-aware rules moved to `ValidateSemantics`.** The
  tool entry point kept syntax validation and orchestration; the 15 lint rules
  now live in their own class. Behaviour is unchanged.
- **`detail` has a type.** `DetailLevel` defines the three levels, their
  ordering and normalization. An unrecognised value now reads as `standard`
  rather than silently selecting whichever branch happened to be last.
- **Soft-delete detection prefers the schema.** A `deleted_at` column in the
  dump now drives the `soft_delete` convention, instead of matching the word
  anywhere in model source. Apps dumping `structure.sql` keep the old source
  match, and the `acts_as_paranoid` / `discard` macro check is unchanged.

## [5.16.2] - 2026-07-17

### Fixed

- **Standalone static tier works when installed via `gem install`.**
  `tool <name> --no-boot`, `tool <name> --help`, and `tool --list` outside
  an app all died with `cannot load such file -- active_support/...`. The
  RubyGems binstub eagerly activates the whole dependency tree, so the
  exe's framework-path strip left every rails-family spec still flagged as
  activated and `Gem.try_activate` refused to re-add the stripped paths.
  The exe now stashes the stripped specs and splices their load paths back
  at every app-less require site (Bundler-pinned paths still win after a
  boot). Verified through the real binstub in an empty directory, in an
  app whose Gemfile does not include the gem, and on the boot-failed
  static fallback.
- **Engine-mounted MCP survives mcp SDK 0.24.** The SDK's SSE writer now
  calls `stream.flush` after every event, and
  `ActionController::Live::Buffer` defines no `flush` - every SSE-mode
  `tools/call` through `mount RailsAiContext::Engine` 500'd on all
  supported Rails versions (the payload still arrived, then the request
  died). The controller now hands the transport a flush-capable stream.
  Verified with live curl sessions on booted Rails 7.1 and 8.1 apps.
- **Engine-mounted GET streams actually stay open.** The transport
  registers the server-push stream and returns; Live then closed the
  response as soon as the action returned, so the SSE channel died
  instantly, `notifications/tools/list_changed` could never be delivered,
  and (once held open) clients would have waited up to 30s for response
  headers. The action now commits headers immediately with an SSE comment
  and holds the thread until the transport or the client closes the
  stream. SETUP.md documents the one-thread-per-connected-client cost.
- **Helpers keep their namespaces.** `app/helpers/admin/dashboard_helper.rb`
  was reported as `DashboardHelper`, and looking it up by its real constant
  name `Admin::DashboardHelper` failed. Module names now derive from the
  path under `app/helpers` (`app/helpers/concerns` stays its own root,
  matching the railties autoload glob), and exact path matches win before
  basename fallbacks so a top-level helper is not shadowed by a namespaced
  one.
- **`rails_validate` checks qualified render targets in Ruby files.**
  `render partial: "posts/missing"` in a controller or service passed
  `level:"rails"` silently (the partial check only ran for ERB). Bare
  `render "posts/show"` keeps template semantics in Ruby files, so the
  controller template-render idiom is not false-flagged. Tool descriptions
  now state exactly which column references are checked
  (validates/permit/callbacks).
- **`rails_review_changes` describes untracked files.** New files rendered
  as empty headings (a fresh app right after `rails new` plus install
  showed 20 of them); they now read `_new file, N lines_`, and only the
  HEAD flow makes that claim (a committed-then-reverted file against an
  older ref reads `_no diff available_`).
- **Views resource resolves extension-less paths.** Reading
  `rails-ai-context://views/posts/index` now serves
  `posts/index.html.erb`; a same-named directory no longer defeats the
  lookup, and sensitive-file candidates are rejected so the
  not-found/not-allowed message split cannot act as an existence oracle
  for secrets placed under `app/views`.
- **Resource templates accept both URI schemes.** `rails://` and
  `rails-ai-context://` now both resolve for the controllers, views, and
  routes templates, and contents echo the URI the client requested.
- **`preset` output no longer scrambles under pipes** in either CLI:
  all framing (banner, separators, "Running:" labels) goes to stderr and
  stdout carries pure tool output.
- **Context files stop leaking internal tokens.** Architecture sections
  showed raw keys (`concerns_models`, `pwa`, `solid_queue`) next to
  humanized labels; every token the convention introspector emits now has
  a label. Stale doc counts corrected across README and docs (39 tools,
  25 doctor checks).

## [5.16.1] - 2026-07-12

### Fixed

- **Engine-mounted MCP works on Rails 7.0-7.2** (caught by the release e2e
  matrix minutes after 5.16.0 shipped; 8.x was unaffected). The MCP
  transport answers SSE-mode requests with a Rack 3 streaming body (a
  Proc); Rails 7.x's response buffer fed that Proc through Rack::ETag,
  which 500'd every `tools/call` through
  `mount RailsAiContext::Engine, at: "/mcp"`. `McpController` now includes
  `ActionController::Live` and pumps callable bodies through the live
  stream (enumerable bodies are joined to a plain string), verified with
  real curl MCP sessions against booted Rails 7.0, 7.1, 7.2, and 8.0 apps.

## [5.16.0] - 2026-07-12

### Fixed

- **HTTP engine mount works again.** `mount RailsAiContext::Engine, at: "/mcp"`
  500'd with `uninitialized constant McpController`: the engine is not
  namespace-isolated, so its route needed the fully-qualified
  `rails_ai_context/mcp#handle` controller path. Verified with a real curl
  MCP session (initialize + session-id + tools/call) against a booted app.
- **`config.custom_tools` is usable as documented.** Referencing an
  `app/mcp_tools/` class constant in the initializer aborted boot with
  `NameError` (app/ constants are not autoloadable while initializers run),
  and a class-name string crashed every CLI tool invocation with
  `undefined method 'tool_name' for an instance of String`. Entries may now
  be classes or class-name strings; strings resolve lazily after boot, and
  invalid entries are warn-skipped everywhere (server, CLI runner,
  TestHelper) instead of taking down unrelated tools. Docs and the
  initializer template now show the string form.
- **Mailers are no longer invisible in development.** `extract_mailers` read
  `ActionMailer::Base.descendants` without the eager-load fallback that
  channels already had, so every dev-mode run reported zero mailers
  (`ai:inspect`, context files, onboard).
- **TestHelper is self-sufficient.** `require "rails_ai_context/test_helper"`
  alone raised `uninitialized constant RailsAiContext::Tools` - the common
  case, since a `group: :development` install is never Bundler-required in
  the test environment. The helper now requires the gem core itself; docs
  explain custom-tool name lookup in the test environment.
- **`claude_max_lines` counts physical lines.** Dual MCP/CLI tool examples
  embed newlines inside single entries, so a default-capped CLAUDE.md could
  ship 161 real lines with no trim marker. The cap (and the trim) now apply
  to physical lines of the managed block.
- **turbo_map no longer flags correct wiring.** `broadcast_append_to post`
  against `turbo_stream_from @post` warned "no matching turbo_stream_from";
  stream matching now strips the ivar sigil before comparing.
- **frontend_stack's Turbo wiring line can actually render.** It read
  `turbo[:broadcasts]`/`[:frames]` - keys the introspector never emits
  (`model_broadcasts`/`turbo_frames`) - so the line was dead code for every
  app; callback-style `broadcast_*_to` calls are now also detected.
- **generate_test emits runnable tests for arg-taking scopes.** A scope like
  `scope :by_status, ->(s) { ... }` produced `Post.by_status` (ArgumentError
  at runtime); scope lambdas' required params are now captured through the
  AST layer and such scopes get an `assert_respond_to` test with a
  fill-in-the-args call site. Verified by running the generated file for real.
- **job_pattern keeps `wait:` in retry configuration.** One ordered regex
  dropped whichever of `wait:`/`attempts:` came first in `retry_on`; the two
  options are now scanned independently.
- **get_env skips comment lines.** `# ENV["WEB_CONCURRENCY"]` in the stock
  puma.rb comment was reported as a real environment variable.
- **diagnose omits an empty "Next Steps" section** instead of rendering a
  bare header when no file/method context was parsed.
- **analyze_feature lists jbuilder templates and record renders**
  (`render @post` / `render post`), matching what get_view reports.
- **service_pattern surfaces mailer dependencies** (`PostMailer.published_email`
  style calls) and recognizes `perform_now`.
- **README observability example reads `event.payload[:duration]`** - the
  bridge emits a zero-width event, so `event.duration` is always ~0ms.
- Singular/plural agreement in tool output ("1 result", "1 site",
  "1 broadcast", "1 line", "1 table", "1 controller", "1 migration file").
- edit_context's footer no longer suggests pasting the line-numbered block
  verbatim as an Edit old_string.
- **A syntax-broken model or controller file no longer kills the process in
  the runtime tier.** Eager loading aborts at the first bad file with a
  `SyntaxError` - a `ScriptError`, which sailed past every bare `rescue` and
  took down the MCP server mid-session and every model-touching rake task.
  Introspection now rescues `ScriptError` at the dispatch level, eager
  loading falls back to per-constant loading, and `discover_models`
  tolerates unloadable classes - one broken file costs exactly that file,
  matching the static tier's contract.
- **Standalone CLI no longer mixes framework versions.** The RubyGems
  binstub activates the newest installed railties before the app's
  Gemfile.lock pins its own, leaving newer framework paths in $LOAD_PATH:
  every generated fact reported the wrong Rails version (e.g. 8.1.3 for an
  8.0.5 app) with "already initialized constant" warnings polluting all
  output. The exe now strips Rails-family gem paths at startup; the app's
  bundle is the only framework source.
- **`--app-path` and `--environment` work after the tool name** (`tool
  schema --table notes --app-path /x`), matching the `--json`/`--no-boot`
  passthrough handling. Previously they were silently discarded and the
  command ran against the wrong directory.
- **structure.sql parsing: single-line CREATE TABLE statements** (the shape
  sqlite's `.schema` emits) no longer lose every column but the first;
  bodies are split on top-level commas before per-line parsing.
- **structure.sql parsing: foreign keys land on the right table.** The
  `ALTER TABLE ... FOREIGN KEY` regex could span statement boundaries and
  attribute a FK to whichever table had the first `ADD CONSTRAINT`.
- **structure.sql parsing: NOT NULL columns are no longer reported as
  nullable** (nullability was simply not extracted).
- **Runtime-only tools refuse in the static tier.** After a mid-boot
  failure, `runtime_info` and `query` ran against the half-initialized app
  and returned live, unmarked data contradicting the static-tier banner in
  the same response; both now answer `[UNAVAILABLE: static tier]` with the
  boot-failure reason. This also removes a raw NameError leak in
  runtime_info's Cache section and query's wrong `--skip-active-record`
  blame under `--no-boot`.
- **The static-tier banner carries the literal `[STATIC]` tag** that README
  and COMPATIBILITY.md promise.
- **doctor's "Secrets in .gitignore" check understands globs.** Rails 8.1
  generates `/config/*.key`; the substring check false-failed every default
  8.1 app and docked its readiness score.
- **model_details carries confidence tags**: `[VERIFIED]` on the runtime
  model header, per-scope `[VERIFIED]`/`[INFERRED]` from the AST layer
  (README promised tags this tool never rendered).
- **Route stats agree across generated context files.** CLAUDE.md counted
  all routes over app controllers while copilot-instructions counted all
  routes over all controllers ("35 across 1" vs "35 across 18"); every
  serializer now reports app routes across app controllers with the
  framework-inclusive total alongside.
- **get_routes counts engine mounts.** Verbless rack mounts (propshaft's
  `/assets`) vanished from both the app list and the excluded-framework
  count; the header now reports them explicitly.
- **Mongoid apps are detected from the Gemfile too** (previously only
  Gemfile.lock or config/mongoid.yml), so a fresh checkout without a
  lockfile gets honest Mongoid treatment instead of ActiveRecord answers.
- **`extra_app_paths` accepts entries ending in `/app`** (`custom/app`
  previously globbed `custom/app/app/models` and silently missed).
- **analyze_feature no longer invents model names** ("user, payment, order")
  on apps with zero models.
- **A missing schema is "unavailable", not "failed".** A greenfield app's
  `context` output framed the absent db/schema.rb as "introspection failed";
  absent data sources now use the `[UNAVAILABLE]` vocabulary.
- **conventions: `create!` flows are no longer attributed the save-and-branch
  skeleton**, zero-signal test files are no longer credited as pattern
  sources, and empty custom-directory descriptions drop the dangling dash.
- **get_config names the environment its values reflect** (cache store,
  queue adapter, and Action Cable differ per environment).
- **get_env skips ERB-only false positives from comments** and standalone
  `doctor` writes its report to stdout (`doctor > report.txt` works).
- docs: TROUBLESHOOTING covers RubyGems' "Resolving dependencies..." stdout
  pollution of the MCP stdio stream and its fixes; a new doctor check ("MCP
  stdio hygiene") detects the condition by re-running gem activation the way
  an MCP client's binstub launch does.
- **Static schema answers include the implicit id primary key**, typed per
  the adapter in config/database.yml (bigint everywhere, integer on SQLite);
  composite-primary-key tables (`primary_key: [...]`) are left to their
  explicitly dumped columns instead of gaining a phantom id.
- **Static schema answers name their source dialect and migration state**:
  structure.sql parses report "Dialect", "Schema version" (from the
  schema_migrations insert tail), and the exact pending migration files;
  schema.rb parses report version plus files newer than it. Secondary
  database dumps compare against their own db/<name>_migrate directories.
- Review-round regression fixes (found by adversarial review of this batch):
  the missing-schema `{unavailable:}` result no longer leaks blank
  "- Database:" lines into generated context files; the gitignore matcher
  honors git's basename rule (`*.key`, bare `master.key`); multi-line
  `retry_on` declarations keep their continuation-line options; a
  syntax-broken `custom_tools` string entry warn-skips instead of crashing
  the server and CLI; the Turbo broadcast scan ignores comments and method
  definitions; redirect and lambda routes are not counted as engine mounts.
- Second review-round fixes: the gitignore security check honors `!`
  negation patterns (a re-included secret now correctly fails the check);
  `SafeFile.read` scrubs invalid UTF-8 so one bad byte in one file can no
  longer raise out of any scan (previously it could erase every model's
  Turbo broadcasts, or crash `get_turbo_map` outright); legacy zero-padded
  migration versions (`001_` storing version "1") no longer read as
  forever-pending; the synthesized primary-key type is resolved per
  database from config/database.yml (a mixed postgres/sqlite multi-db app
  types each dump correctly); endless-method broadcasts
  (`def refresh = broadcast_replace_to(...)`) are detected while trailing
  `#comments` (with or without spaces) are not, in both the introspector
  and get_turbo_map's own scanners; `retry_on` options inside trailing
  comments are not reported as real retry config; the doctor stdio-hygiene
  probe launches from Bundler's original environment (a configured bundle
  path no longer produces a spurious warning); a custom tool whose class
  body raises during autoload is reported as broken rather than
  "class not found"; the schema_migrations INSERT regex and the
  section-usability predicate each have a single home.
- Third review-round fixes: source-line scans (Turbo broadcasts, retry_on
  options) strip comments with a string-aware walker (`SourceLine`) instead
  of a regex, so a `#` inside a string literal (`"#comments"`, `"##{id}"`)
  no longer truncates the line and drops real calls, while comment text
  still never reads as code - including comments after a continuation comma
  in multi-line `retry_on`; `def self.broadcast_*_to` definitions are not
  counted as broadcast calls; the doctor gitignore check now models git's
  negation semantics (dir-only `!*/` entries, no re-inclusion under an
  excluded parent, negations must match the file itself) - verified against
  `git check-ignore` on a 16-case battery; the database.yml block lookup
  no longer bleeds across whitespace-only lines into a sibling database's
  adapter; and a custom tool whose body references a missing constant that
  shares a name segment with the entry is no longer misreported as
  "class not found".
- Fourth review-round fixes: the gitignore check now evaluates paths the
  way git does (ancestor-directory recursion with last-match-wins instead
  of descend globbing), closing a false-SAFE case where `config/` followed
  by `!config/` read as still covering config/master.key - verified 25/25
  against `git check-ignore`, including `**/`, whitelist preludes, and
  re-included directories; it also honors case-insensitive filesystems the
  way core.ignorecase does. `SourceLine.strip_comment` gained %-literal
  support (`%w[cs#billing]` is content, `n % 2` is not a literal), an
  O(n) walk (a 400k-char multibyte line dropped from 27s to 51ms), and a
  no-`#` fast path. Broadcast def-blanking handles constant receivers
  (`def User.broadcast_updates_to`) and multiple defs per line; multi-line
  broadcast extraction reads comment-stripped context; `::`-prefixed
  custom_tools entries classify correctly; config/database.yml is read
  once, CRLF-normalized, per introspection run.
- Sixth-through-eighth review-round fixes (call-site scanning converged
  after three more single-finding rounds): classic one-line methods
  (`def x; broadcast_y_to(...); end`) contribute their body while
  visibility-prefixed definitions (`private def`, `private_class_method
  def`) contribute nothing; `;`/`=` inside string keyword defaults
  (`sep: "; "`, `label: "a=b"`) and inside `#{...}` interpolation (with
  nested quoted strings) no longer delimit a signature. A final review
  round at a realistic-Rails bar returned zero findings.
- Fifth review-round fixes: comment stripping is now a whole-fragment
  state machine (`SourceLine.strip_comments`) - literal state carries
  across newlines, so a comment mid-way through a multi-line broadcast
  call is removed while a string spanning lines keeps its tail; backtick
  command literals (with interpolation) are modeled; singleton broadcast
  definitions on any receiver (`def record.broadcast_status_to`,
  `def self::...`) are excluded from broadcast detection; database.yml
  without a final newline still resolves its last block's adapter; and
  the case-insensitivity probe works for app roots with caseless names
  (all-digit directories).

### Changed

- Standalone `doctor` writes its report to stdout (previously stderr), so
  `doctor > report.txt` captures it; update scripts that redirected `2>`.
- Custom tools resolved through the CLI are now validated as `MCP::Tool`
  subclasses, matching what the MCP server has always enforced; duck-typed
  tool classes that only ever worked via `rails-ai-context tool` are
  warn-skipped with the reason.

## [5.15.0] - 2026-07-11

### Added

- Static tier: `serve` and `tool` fall back to source-file analysis when the
  app cannot boot, instead of exiting. Routes (new `config/routes.rb` Prism
  walker), models, controllers, schema, and migrations answer statically;
  other sections report `[UNAVAILABLE]` with the reason; every response
  carries a tier banner.
- CLI flags: `--no-boot` (serve/tool), `--app-path` (all app-reading
  commands), and `--environment` (all commands).
- `[STATIC]` and `[UNAVAILABLE: <reason>]` confidence tags.
- structure.sql parsing is dialect-aware: MySQL (backticks, inline
  KEY/CONSTRAINT definitions, ENGINE trailers) and SQLite (quoted
  identifiers, IF NOT EXISTS) now parse; output gains a `dialect` key.
- Shape-aware discovery: models and controllers are found in packwerk
  `packs/`, in-repo `engines/`, and configured `extra_app_paths`.
- Multi-database schema dumps (`db/*_schema.rb`, `db/*_structure.sql`)
  reported under `secondary_databases`.
- Mongoid detection: honest `[UNAVAILABLE]` schema signal and basic static
  model extraction (fields, embeds, store_in) for Mongoid apps.
- API-only apps get explicit "not applicable" answers from view/frontend
  tools instead of empty listings.
- **Loud Rails 9 warning in the standalone CLI.** In-Gemfile installs already
  fail Bundler resolution against Rails 9 (`railties < 9.0`); the standalone
  CLI has no such check, so it used to boot silently against an untested
  Rails version. It now prints a stderr warning naming the installed Rails
  version and pointing at checking for a newer gem release.
- **`docs/COMPATIBILITY.md`** publishes the supported-version matrix, the CI
  version grid, the RUNTIME/STATIC tier contract with the confidence-tag
  vocabulary, and a shape-by-introspector matrix that cites the spec or QA
  run proving every cell.

### Changed

- Boot failure in `tool`/`serve` no longer exits 1; it degrades to the
  static tier with a stderr notice. `doctor` keeps requiring a bootable app.
- CI runs Rails 8.x on Ruby 3.2 again. The exclusion assumed Rails 8
  required Ruby 3.3+; both railties 8.0.5 and 8.1.3 declare
  `required_ruby_version >= 3.2.0`.

### Fixed

- `config.auto_mount = true` set in a user initializer now takes effect
  (the middleware initializer ran before user initializers loaded).
- `prism` and `concurrent-ruby` are now capped below their next majors
  (`< 2.0`, `< 3.0`) instead of an open-ended floor.
- A syntax error in one model file now costs exactly that model - the rest
  of the models section, and every other section, still answers normally
  (verified end-to-end in the static tier).

## [5.14.0] - 2026-07-11

### Added

- **New `rails_get_api` tool (CLI: `api`)** exposing the API-layer introspection that was previously invisible on demand: API-only mode, serialization strategy (Jbuilder templates, serializer classes), GraphQL, versioning, rate limiting, OpenAPI specs, CORS, and pagination. On API-only apps the API layer was the least-served layer while six view tools returned nothing; this closes that gap. Tool count is now 39.
- **`doctor --strict`** exits 1 when any check fails, giving CI a real gate. Default behavior is unchanged: doctor is a readiness report and exits 0.
- **`rails_generate_test` scaffolds tests that pass out of the box.** Generated controller tests use the app's real routes, fixtures, and strong params; destroy tests create a fresh record instead of deleting a fixture row other fixtures hold foreign keys on; create/update params mutate values for columns backed by a unique index (a fixture's own value would collide). Verified by running the generated tests for real on scaffold HTML and API-only JSON controllers.

### Added - Boot resilience

- **Friendly boot-failure diagnostics.** Every CLI command (`tool`, `doctor`, `serve`, `context`, etc.) now boots the host app through `BootManager`, which catches `StandardError` and `ScriptError` alike. When the app can't boot -- a missing ENV var, an unreachable database or Redis, a syntax error in an initializer -- the CLI prints a one-line cause plus common-cause hints and exits 1, instead of a raw Thor backtrace. Boot is bounded by a 60-second timeout so a hanging initializer fails loudly rather than wedging the process; the timeout is configurable via `RAILS_AI_CONTEXT_BOOT_TIMEOUT`. A timed-out boot gets a dedicated message naming the configured limit and how to raise it, instead of the stdlib's `Timeout::Error: execution expired`. Set `DEBUG=1` for the full backtrace. `doctor` on an app that fails to boot appends one line noting it needs a bootable app to run its checks.
- **stdout quarantine on every stdio launch path.** The stdio MCP transport carries JSON-RPC on stdout, so anything the host app prints while booting (initializer `puts`, deprecation warnings) used to corrupt the handshake and leave the client reporting a dead server. `OutputGuard` now redirects `$stdout` to `$stderr` for the duration of boot on every stdio launch path -- the `rails-ai-context serve` binary, the `rails ai:serve` rake task, and standalone mode. It also reopens file descriptor 1 onto `$stderr`'s target for that duration, so writes through the `STDOUT` constant (which bypass the `$stdout` global) and subprocess output inherited on fd 1 are caught too; only a descriptor duplicated before boot starts stays out of reach.
- **Unexpected tool errors return in-band MCP error results instead of protocol errors.** Every registered tool's `call` is now wrapped so an unhandled exception produces an `isError: true` tool response (error class, origin line, and a recovery hint) rather than escaping to the MCP SDK, which turned it into a JSON-RPC -32603 protocol error that most AI clients silently swallow. Exceptions that still escape at the SDK level get a stderr backtrace via a new `exception_reporter`.
- **Aggregate tools flag partial context.** `rails_get_context` and `rails_onboard` append a "Partial context" note listing which introspectors failed when any did, so an AI client can tell missing data from empty data. The note is appended after the truncation decision, so it survives response truncation instead of being cut off with the rest of the body.
- **Generated MCP configs launch the quarantined CLI command.** All 5 generated config formats (Claude Code, Cursor, VS Code, OpenCode, and Codex CLI) now point at `bundle exec rails-ai-context serve` instead of `bundle exec rails ai:serve`, so new installs get stdout quarantine from before `Bundler.require` runs. `rails ai:serve` still works and now quarantines its own boot output too.

### Fixed

- Introspector fault isolation no longer crashes when `Rails.logger` is nil (early-boot rake tasks, engine dummy apps). The failure-logging call that the rescue exists to protect now falls back to `$stderr` via `RailsAiContext.log_warn` instead of raising `NoMethodError` on a nil logger.
- `BaseTool.abstract!` now works when called on a subclass. It read `registry_mutex` and `descendants` off `self`, but those are ivars set on `BaseTool` itself -- a subclass has no ivar storage of its own to read them from, so the call raised `NoMethodError` on the nil mutex. It now reaches back to `BaseTool` explicitly.
- Custom tools that subclass `RailsAiContext::Tools::BaseTool` must accept a `server_context:` keyword (or `**kwargs`) in `self.call` -- the MCP dispatch now always passes it.
- **The install generator no longer crashes on non-interactive stdin.** Thor's `ask` returns `nil` on EOF (piping fewer answers than prompts, or `< /dev/null`), and the very next `.strip` call raised `NoMethodError`. Every prompt now goes through `ask_safe`, which treats EOF the same as an empty answer -- each prompt's existing default-handling logic takes it from there. A new `--defaults` flag skips every prompt outright for CI/scripted installs.
- **`rails-ai-context --version` and `-v` work**, not just the `version` subcommand -- Thor only recognized the bare subcommand by default.
- **Presets share one definition.** The rake task (`rails 'ai:preset[name]'`) and the CLI (`rails-ai-context preset name`) used to define their own, different tool lists under the same preset name. Both now read from `RailsAiContext::Presets::DEFINITIONS`, the single source of truth. The `migration` preset's old tool list called `migration_advisor` with an invalid `action` and `validate` with no files -- both require a caller-supplied target and only emitted errors on a healthy app; it now runs `get_schema`, `runtime_info`, and `performance_check` with zero arguments, matching what `architecture` and `debugging` already did correctly.
- **`rails_performance_check` no longer claims "Your app looks good!" when a category or model filter is hiding issues elsewhere.** A zero count under a filter now says so explicitly and points back at the unfiltered call, instead of implying the whole app is clean.
- **`rails_get_view`'s render map now detects the Rails 7+ bare local-variable render form** (`render article`, as the default scaffold generates), not just `render "partial"` and `render @article`. The scan excludes keyword-argument hashes (`render json:`, `render partial:`, ...) so it doesn't misread those as local-variable renders.
- **`rails_get_view` accepts a full repo-relative path** (e.g. `app/views/layouts/mailer.html.erb`) in addition to the documented app/views-relative form -- previously a genuinely-existing file read as "not found" solely because of which convention the caller used.
- **`rails_analyze_feature` no longer substring-matches unrelated identifiers.** `feature:"post"` used to pull in ActionMailbox's `postmark` ingress route because `"postmark".include?("post")` is true. Matching is now word-boundary aware (with basic singular/plural handling), so `post` still matches `posts`, `post_comments`, and `PostsController`, but not `postmark`.
- Empty-result "not found" responses no longer end with a dangling `Available:` line when there's nothing to list (`rails_get_concern`, and any other tool built on the shared `not_found_response` helper).
- `rails_get_partial_interface`'s "not found" suggestion list no longer lists the same partial twice when it exists under two extensions (e.g. `_article.html.erb` and `_article.json.jbuilder` both display as `articles/article`).
- A non-numeric `RAILS_AI_CONTEXT_BOOT_TIMEOUT` value now falls back to the default with a stderr warning instead of raising a raw `ArgumentError` that surfaced as a Thor backtrace on `doctor`, `inspect_app`, and `watch`.
- **`rails_get_conventions`'s create-action and read-only-page skeletons now reflect what's actually detected**, instead of a hardcoded `current_user`-based template labeled with real controller names regardless of whether any auth pattern existed. They're built from the union of flow parts actually matched, and only reference `current_user` when a permission or auth check was really found.
- **`rails_analyze_feature`'s test counts are accurate again.** `discover_tests` counted the bare words `it`/`test`/`should` anywhere in a file's text, including comments and prose. It now counts line-anchored `test`/`it`/`specify` declarations and `def test_*` methods, matching how `rails_get_test_info` already counted correctly.
- **CLI and rake tool failures exit non-zero.** `rails-ai-context tool NAME` and `rails 'ai:tool[NAME]'` used to exit 0 even when the tool itself reported failure (`isError: true`); both now exit 1 in that case, and `--json` output gains an `error` key so scripts can check it without parsing text. An unrecognized `rails-ai-context` subcommand also exits 1 instead of Thor's default 0. The "unknown tool" error message points at whichever `--list` invocation actually works for the caller (CLI vs rake) instead of always suggesting the CLI-only flag, and a blank tool-name query no longer produces an arbitrary "Did you mean" suggestion.
- Routine MCP protocol errors (unknown tool, invalid params) now log as a single quiet line instead of a 10-line backtrace; only genuinely unhandled exceptions still get the full backtrace.
- **Install generator output is honest about install mode and idempotency.** Generating context files for multiple selected AI-tool formats no longer reports the shared `AGENTS.md` trio as both written and unchanged in the same run. `.rails-ai-context.yml` writes report Created/Updated/unchanged consistently across the generator, standalone `init`, and the `ai:context` rake task. `.codex/config.toml` (which embeds a machine's Ruby PATH/GEM_HOME) is now flagged as local and added to `.gitignore` instead of told to commit it. Generated context files reference the `rails-ai-context` CLI binary instead of rake tasks on standalone installs, detected via a Gemfile.lock scan for the gem's own spec line.
- Eight tool-output and doctor accuracy fixes from live QA: `rails_get_gems` points the Solid Queue config hint at `config/queue.yml`/`config/recurring.yml` (checked at runtime) instead of `config/solid_queue.yml`, which Rails 8's generator never writes; `doctor`'s gitignore check distinguishes a missing `.gitignore` file from a missing entry; `rails_get_model_details` no longer renders a bare "Key instance methods" heading when every candidate method was filtered out as an association accessor; `rails_onboard`'s route total shares dedup logic and prefix config with `rails_get_routes` instead of disagreeing with it; CLI `tool --list` truncates descriptions with an ellipsis instead of mid-word; `tool --list` falls back to loading the gem standalone when there's no app to boot; and `doctor`'s introspector-health message computes the tool count it compares against dynamically instead of hardcoding it.
- **Tools stay truthful on API-only apps.** `rails_get_frontend_stack` reports "No frontend stack detected" instead of a lone "TypeScript: disabled" line implying a JS frontend exists. `rails_get_turbo_map` reports that Turbo isn't installed when `turbo-rails` isn't in `Gemfile.lock`, instead of an empty broadcast/subscription report. `rails_get_context`'s instance-variable cross-check recognizes ivars rendered via `render json: @foo`/`render xml: @foo` (which have no view template to cross-reference), and swaps "used in view" language for "used in response" on API-only apps; the generated CLAUDE.md/AGENTS.md workflow guide swaps its view-editing walkthrough for a JSON-endpoint walkthrough on the same apps. `app/models/concerns` and `app/controllers/concerns` are only reported as in-use patterns when they contain a real Ruby file, not just the `.keep` placeholder a fresh `rails new` leaves behind. `rails_get_conventions`'s create-action skeleton now emits `render json:` (and `render json: @record.errors`) instead of an HTML redirect when the app's create actions render JSON directly, not just via a scaffold's `respond_to` JSON branch.
- **MySQL/Trilogy adapter parity.** Rails 8's default MySQL adapter reports `adapter_name` as "Trilogy", not "Mysql2", so every `/mysql/`-only regex dispatch silently fell through to unsafe or degraded fallbacks -- `rails_query`'s read-only transaction and statement timeout, `rails_runtime_info`'s table sizes, and the database-stats introspector now all match `/mysql|trilogy/i`. `rails_query`'s `SHOW`/`DESCRIBE`/`EXPLAIN` are exempted from row-limit appending (invalid syntax after those statements) and from column-name-based redaction (MySQL's `DESCRIBE` returns a literal "Key" column that isn't secret data); `EXPLAIN` on MySQL forces `FORMAT=TRADITIONAL` so parsing doesn't depend on the server's default explain format.
- **Pending-migrations detection works again.** All three call sites (`rails_runtime_info`, `doctor`, the migration introspector) guarded on `respond_to?(:pending_migrations)`, which is never true on any currently supported Rails version, and fell back to an `ActiveRecord::Migrator.new` signature that raises on Rails 7.0+ -- it always reported zero pending migrations. A shared `MigrationStatus` helper now walks `migration_context.open.pending_migrations`, the same path Rails uses for its own "migrations are pending" error page; the file-based fallback also reads the schema version from `db/structure.sql`'s trailing `schema_migrations` insert, so `:sql`-format apps get correct results instead of always reporting zero.
- `migration_advisor`'s locking advice is now adapter-aware instead of always suggesting Postgres-only `algorithm: :concurrently` and two-step foreign key validation on every adapter.
- The generated tool-usage guide names `db/structure.sql` instead of `db/schema.rb` in its "don't read this file" guidance on apps configured with `schema_format = :sql`.
- Fixed the remaining "N indexes"/"N files" pluralization misses: `rails_get_schema`'s summary view now says "1 column, 1 index" and `rails_get_conventions`'s directory structure says "1 file", matching the singular/plural handling already applied to table, issue, and test counts.
- The CLI `preset` command's banner now uses a plain hyphen instead of an em dash, matching the rake task's output, and its per-tool "Running:" headers print to stdout (the same stream as the tool's own output) instead of stderr, so `2>&1` captures stay in order.
- The install generator no longer emits raw terminal escape sequences (cursor hide/show, line clears) when stdin or stdout isn't a real terminal (`rails generate rails_ai_context:install < /dev/null`, captured CI logs). Thor's line editor now falls back to its plain, escape-free reader outside a genuine interactive TTY session.
- **The generated initializer no longer crashes `bin/rails test` on path:/git: Gemfile installs scoped to `group :development`.** Bundler evaluates a path:/git: gemspec in-process during dependency resolution in every environment, so `require_relative "lib/rails_ai_context/version"` defines a VERSION-only stub `RailsAiContext` module even in environments where `Bundler.require` correctly skips the gem. The initializer's `if defined?(RailsAiContext)` guard was satisfied by that stub and called `.configure` on it anyway, raising `NoMethodError`. The guard now also checks `RailsAiContext.respond_to?(:configure)`; re-running the install generator upgrades an existing initializer's bare guard in place, and `doctor` warns when one is still on the old guard.
- **`DEBUGGER__::TrapInterceptor` no longer shows up as a model concern.** The `debug` gem, default in Rails 7.0+ Gemfiles, prepends this module onto `Kernel`, so it appeared in every model's ancestors. It's now excluded the same way other framework-internal modules are.
- **The `rails-ai-context://routes/{controller}` MCP resource returns real routes.** It filtered a flat `:routes` list that the route introspector never emits (routes are grouped under `:by_controller`), so every read returned an empty array. It now reads the real shape, merges the controller name back into each entry, and dedupes PUT/PATCH update pairs into one `PATCH|PUT` entry so the resource reports the same counts as the routes tool.
- MCP resource contents use the spec field name `mimeType` instead of snake_case `mime_type`.
- **Rails-internal routes are excluded correctly.** The route introspector guarded on `route.respond_to?(:internal?)`, but `ActionDispatch::Journey::Route` exposes the flag as a plain `internal` attribute, so the guard never matched and Rails' info/mailers/welcome routes leaked into route listings as "framework routes". The tool and the MCP resource now agree on route counts, and the routes header notes how many framework routes were excluded.
- **`.mcp.json` content is stable across entry points.** The standalone `init` wrote `rails-ai-context serve` while the in-Gemfile generator and `ai:context` rake task wrote `bundle exec rails-ai-context serve`, so alternating commands rewrote the file on every run. All writers now derive the command from the detected install mode.
- **`rails_validate` failures exit non-zero.** A failed validation ("0/1 files passed", real Prism diagnostics) is now an MCP error result, so the CLI exits 1 and CI can gate on it; passing validations still exit 0. `rails_query`'s genuine SQL execution errors (unknown column, syntax error) get the same treatment, while policy guardrail messages ("Blocked: contains UPDATE") remain informational at exit 0.
- `rails-ai-context preset bogus` exits 1 with the available-presets list instead of exiting 0.
- **`rails_get_conventions` renders the status symbol actually detected in the app's controllers** (`:unprocessable_content` on Rails 7.1+ scaffolds) instead of hardcoding `:unprocessable_entity` in a skeleton labeled "Detected in".
- `rails_get_frontend_stack` reads the introspector's real output keys, so the Framework and Testing lines (React/Vue/Jest and friends) render again; they had been silently dropped for every app.
- `rails_search_code` marks match lines with a `>` prefix and indents context lines, so matches are distinguishable in captured output; a legend line explains the markers.
- `rails_diagnose` classifies an undefined method on a model by checking the model's real associations and columns, reporting "no association or column named X" instead of the generic nil-reference guidance.
- `rails_review_changes` no longer leaks git's raw "fatal: not a git repository" stderr line above its own friendly message when run outside a repository.
- The config tool lists every file in `config/initializers/`, not just the gem's own initializer.
- CLI copy is install-mode aware everywhere: `tool --list`, per-tool help, unknown-tool errors, and the generated git pre-commit hook show only invocation forms that exist in the current install (standalone installs have no rake tasks). The `tree` command shows the binary name as its root and `inspect` under its public name.
- Assorted output honesty from the final QA sweep: onboard only recommends `bin/dev` when the app has one, names the real queue adapter instead of mentioning Sidekiq on non-Sidekiq apps, labels implicit `belongs_to` validations as such, and pluralizes counts correctly; the view tool omits its "Directories with views:" enumeration when there are none; the standalone `facts` command matches the rake task's singular/plural forms and prints `_none_` instead of a bare Associations header; `rails_get_partial_interface` no longer lists ERB block parameters (`|form|`, `|error|`) as partial locals.

## [5.13.0] - 2026-07-10

### Added

- **Ruby 3.1 and Rails 7.0 are now supported.** `required_ruby_version` drops to `>= 3.1.0` and the `railties` floor to `>= 7.0`, widening the test matrix to Ruby 3.1-4.0 x Rails 7.0-8.1. Rails 7.0 is exercised on Ruby 3.1, its only supported pairing (7.0 predates official Ruby 3.2+ support). Reaching parity required:
  - A vendored `Data.define` backport (`lib/rails_ai_context/polyfill/data.rb`) for the value objects `Doctor::Check`, `SchemaHint`, and `HydrationResult`. `Data` is a Ruby 3.2+ class; the shim is inert on 3.2+ (guarded on `Data.respond_to?(:define)`) and activates only on 3.1, preserving keyword construction, the `super`-forwarding custom initialize, frozen instances, and value equality.
  - `rails_search_code` no longer passes the Ruby 3.2+ `timeout:` keyword to `Regexp.new` on Ruby 3.1, where it raised `TypeError: no implicit conversion of Hash into String` and broke every search. The per-pattern ReDoS timeout is applied only when the runtime supports it (`Regexp.respond_to?(:timeout)`); 3.1 builds the pattern without it.
  - Every version-sensitive Rails call in the 40 introspectors was already `respond_to?`/`defined?`-guarded or rescue-wrapped, so no introspector changed to run on Rails 7.0.
  - The dev/test Gemfile pins `sqlite3 ~> 1.4` on Rails 7.0 (whose adapter predates the sqlite3 2.x line) and always loads `logger` (concurrent-ruby 1.3.5 dropped the implicit `require "logger"` that Rails < 7.1 relies on at boot).

## [5.12.1] - 2026-07-10

### Fixed

- `rails_query` no longer fails on MySQL with `Transaction characteristics can't be changed while a transaction is in progress`. `execute_mysql` issued `SET TRANSACTION READ ONLY` inside `conn.transaction`, but Rails materializes the lazy `BEGIN` before the first in-block statement, so MySQL (error 1568) rejected the SET on every call -- a 100% failure rate for plain queries and `explain: true`. The SET now runs before the transaction opens; without `GLOBAL`/`SESSION` scope it applies only to the next transaction, which the query transaction immediately consumes, so the read-only guard still holds and nothing leaks onto the pooled connection. PostgreSQL (where `SET TRANSACTION` applies to the current transaction) and SQLite are unaffected. (#89)
- The static `schema.rb` parser now recognizes the PostgreSQL `timestamptz` and `tsvector` column types. `t.timestamptz` and `t.tsvector` columns were dropped from the parsed schema because the DSL listener's column-type set omitted them, so schema-backed tools under-reported columns on Postgres apps using `timestamp with time zone` or full-text search vectors. (#88)

## [5.12.0] - 2026-06-29

### Fixed

Live-usage audit of the full MCP surface (all 38 tools over stdio + HTTP, the CLI tool runner, and the 9 resources / 5 resource templates) against a real Rails 8 app surfaced 15 correctness and edge-case defects, now fixed:

- **`rails_get_schema` (and every schema-backed tool) now reads the live database.** The schema introspector treated `ActiveRecord::Base.connected?` as "is a DB reachable", but that is `false` on a freshly booted server before any query runs, so it silently fell back to static `schema.rb` parsing -- which omits the implicit `id` primary key and reports schema.rb-approximate types. It now probes the connection (`SELECT 1`) and uses live column metadata, falling back to static parsing only when the database is genuinely unreachable. `rails_get_model_details`, `rails_get_context`, `rails_get_controllers` schema hints, and `rails_analyze_feature` all benefit.
- **`rails_get_view`** resolves a logical `controller/action` path (e.g. `posts/index`) to its template instead of reporting "View not found" for a file it then lists in the same hint.
- **`rails_diagnose`** classifies Ruby 3.4+ `undefined method 'x' for an instance of Y` errors (and other bare, class-prefix-less messages) by inferring the exception class from the message signature.
- **`rails_get_turbo_map`** now reports `.turbo_stream.erb` response templates and their stream actions. Apps using the common scaffold-style Turbo Stream pattern no longer show "No Turbo Streams or Frames detected".
- **`rails_get_partial_interface`** detects implicit object/collection render sites (`render @post`, `render post`, `render @posts`), not just explicit `render "posts/post"` calls.
- **`rails_get_controllers`** and **`rails_analyze_feature`** no longer list an inherited `before_action` twice (once as inherited, once from the reflection-derived full chain).
- **`rails_runtime_info`** "Table Sizes" lists real application tables instead of SQLite internal objects (`sqlite_schema`, `sqlite_autoindex_*`, `sqlite_sequence`) and index b-trees that were crowding out the app tables.
- **`rails_get_gems`** strips the platform suffix from versions (`sqlite3 2.9.5`, not `sqlite3 2.9.5-x86_64-linux-musl`) on multi-platform lockfiles.
- **`rails_get_test_info`** falls back to `Gemfile.lock` to report the test framework (minitest/rspec) when no `test/` or `spec/` directory exists yet, instead of "unknown".
- **`rails_get_frontend_stack`** no longer renders a literal `[]` for empty state-management data.
- **`rails_onboard`** reports the app route count instead of pairing the framework-inclusive total with the app-controller count ("14 app routes across 3 controllers", not "46 routes across 3 controllers").
- **MCP resources** return a proper `-32602 Resource not found: <uri>` for unknown URIs and blocked paths instead of a generic "Internal error" with the URI stripped (on `mcp >= 0.20`; older mcp keeps prior behavior). Path traversal and sensitive-file access remain blocked.
- **CLI `--json`** flag is honored in any position (`tool NAME args --json`), not only before the tool name.
- **CLI presets** (`architecture`, `debugging`, `migration`) now chain tools that produce useful output with zero arguments, instead of calling tools whose required arguments were never supplied.
- **Standalone/zero-config CLI on Ruby 3.4+** no longer crashes with `Gem::LoadError: already activated psych 5.4.0, but your Gemfile requires psych 5.3.1` (or the equivalent for `date`). The standalone executable pre-activates Ruby 3.4's newer default-gem versions before the app's `Bundler.setup` runs; it now clears those pre-activated specs first so Bundler activates the versions the app resolves. No-op under `bundle exec` (in-Gemfile mode is unaffected).

## [5.11.2] - 2026-06-16

### Fixed

- CLI tool runner now reads tool input schemas via `MCP::Tool::InputSchema#to_h` instead of the `#schema` accessor that `mcp` 0.20.0 removed. `rails-ai-context tool ...` and `rails 'ai:tool[NAME]'` no longer raise `undefined method 'schema'` when the bundle resolves `mcp` to 0.20.0+. `to_h` exposes the same `properties` and `required` the runner reads across the supported `mcp` range (`>= 0.8, < 2.0`), so no version pin is needed. (#85)

## [5.11.1] - 2026-05-24

### Fixed

- E2E MCP HTTP protocol spec sends `initialize` once per session instead of per-test, fixing compatibility with newer `mcp` gem versions that reject duplicate initialization.

## [5.11.0] - 2026-05-24

### Changed - Prism AST migration: all introspectors now use structural code extraction

Every introspector that scans `.rb` files has been migrated from regex-based pattern matching to Prism AST-based structural extraction. This is a zero-regression internal refactor -- all introspector outputs are verified identical via side-by-side comparison, 2257 unit tests, 119 E2E tests, and live validation against a production-scale Rails 8.1 app (39/39 introspectors, 41/41 tool invocations, 0 failures).

**What changed internally:**

- **`SourceIntrospector.walk(path, listener_map)`** -- new generic API that accepts any combination of listener classes or Proc factories, enabling ad-hoc AST extraction without modifying the core dispatcher. Supports both `Class` values (instantiated via `.new`) and `-> { Instance }` lambdas for configurable listeners.
- **11 new listener classes** for patterns beyond the original 7 model-level listeners:
  - `GenericMacroListener` -- configurable no-receiver call detector (handles most Rails DSL patterns including `self.method` calls)
  - `ChainedCallListener` -- method calls with receivers (`.variant()`, `.includes()`, `.create()`)
  - `VariantCallListener` -- ActiveStorage variant detection
  - `MailboxRoutingListener` -- ActionMailbox routing + lifecycle callbacks
  - `MiddlewareConfigListener` -- `config.middleware.use/insert_before/insert_after/unshift`
  - `EnvAccessListener` -- `ENV["KEY"]` / `ENV.fetch("KEY")` with block-default detection
  - `MountListener` -- `mount Engine, at: "/path"` (both keyword and hash-rocket syntax)
  - `RakeTaskDslListener` -- `namespace`/`desc`/`task` with deps and args (handles string + symbol deps)
  - `GemfileDslListener` -- `gem`/`group`/`source` with group-scope tracking
  - `SchemaDslListener` -- `create_table`/`t.type`/`t.index`/`add_foreign_key`/`create_enum`/`check_constraint`
  - `MigrationDslListener` -- `create_table`/`add_column`/`add_index`/`rename_column`/`add_reference` and 6 more actions
- **28 introspectors converted**: ActiveStorage, ActionText, ActionMailbox, Middleware, ActiveSupport, Auth, Security, Controller (all 9 regex blocks including strong params, filters, rescue_from, rate_limit, respond_to, turbo_stream), Convention, Turbo, MultiDatabase, Performance, Job, Model, Component, View, Api, AssetPipeline, DevOps, Env, Gem, RakeTask, Engine, Seeds, Test, Schema, Config.
- **181 regex patterns intentionally remain** in categories where Prism cannot help: non-Ruby files (JS/TS/ERB/Haml -- 78), keyword/content matching (22), config assignments (15), runtime SQL/YAML (25), and complex partial patterns (41).

**What didn't change:**

- All introspector output formats are identical. No consumer-facing API changes.
- All 39 MCP tools work exactly as before.
- Runtime reflection paths (ActiveRecord, Rails config, I18n, etc.) are untouched.
- Non-Ruby file scanning (YAML, JSON, ERB, JS, Procfile, Dockerfile, Gemfile.lock) is untouched.

**Why this matters:**

- Regex scanning matches patterns in comments, strings, and dead code. AST extraction only matches actual code structure -- fewer false positives.
- Multi-line declarations that broke regex (e.g., `devise` with 9 modules across 3 lines, `before_action` with complex `only:`/`except:` constraints) are now parsed correctly by Prism.
- The `AstCache` provides thread-safe LRU caching of parse results, so repeated walks of the same file are free.
- New listeners are composable -- introspectors mix and match listeners via `SourceIntrospector.walk(path, { key: Listener })` without coupling.

### Fixed

- Avoid false-positive route helper warnings when `rails_validate` sees locally defined Ruby methods ending in `_path` or `_url` (#83, thanks @curi).
- Preserve newline-separated staged file names in the generated pre-commit validation hook (#83).

### Tests

- 2257 unit examples (up from 2154), 0 failures
- 119 E2E examples, 0 failures
- 47 edge-case tests for controller, auth, and security AST conversions
- 10 listener edge-case tests (block-syntax ENV defaults, string rake deps, insert-with-index middleware, hash-rocket mounts, complex gem lines)
- Side-by-side regression comparison: all 39 introspector outputs verified identical between old regex and new AST code

## [5.10.0] - 2026-04-20

### Added - 8 new introspectors closing RAILS_NERVOUS_SYSTEM.md gaps

An audit against [`RAILS_NERVOUS_SYSTEM.md`](RAILS_NERVOUS_SYSTEM.md) identified 9 framework sections where introspection was missing or partial. This release ships the 8 introspectors needed to close them (the 9th - §11 Query interface - was already covered by `:conventions` via `load_async` / `.async_*` scanning). All are wired into `PRESETS[:full]`. The gem now exposes **39 introspectors** (up from 31).

- **`InitializerIntrospector` (`:initializers`, §2).** Enumerates `Rails.application.initializers` - every initializer's name, owner, declared `before:` / `after:` ordering edges, and the `source_location` of its block. Also summarizes each `config/initializers/*.rb` file (initializer count + the top `config.*` setters it touches) so AI can jump straight to user-owned boot code.
- **`AutoloadIntrospector` (`:autoload`, §3).** Zeitwerk presence, both `Rails.autoloaders.main` and `.once` with their collapsed dirs + ignored paths + root dirs, raw `autoload_paths` / `autoload_once_paths` / `eager_load_paths`, the resolved `eager_load` boolean, plus custom inflection rules extracted from `config/initializers/*.rb` (`inflect.acronym` / `.plural` / `.singular` / `.irregular` / `.uncountable` / `.human`). Paths are root-relative.
- **`ConnectionPoolIntrospector` (`:connection_pool`, §10).** Per-database adapter config: `pool`, `checkout_timeout`, `idle_timeout`, `reaping_frequency`, `prepared_statements`, `advisory_locks`, replica flag, role, connection-handler pool counts per role (`:writing` / `:reading`), and automatic shard selector detection (Rails 7.1+ `ActiveRecord::Middleware::ShardSelector`). Complements `:database_stats` (which only returns row counts).
- **`ActiveSupportIntrospector` (`:active_support`, §17).** Covers ActiveSupport runtime surface other introspectors leave untouched: Concerns in `app/**/concerns/` (with `ActiveSupport::Concern` / `included do` / `class_methods do` flags), `Rails.application.deprecators` registry keys, MessageEncryptor + MessageVerifier usage scan across `lib/` + `app/`, TaggedLogging configuration (`config.log_tags` + initializer-based `ActiveSupport::TaggedLogging.new`), active on-load hooks, and cache-store options.
- **`CredentialsIntrospector` (`:credentials`, §30).** Default `config/credentials.yml.enc` + every per-env `config/credentials/<env>.yml.enc`, master-key source resolution (`env:RAILS_MASTER_KEY` / `file:config/master.key` / `missing`), `config.require_master_key` flag, arbitrary encrypted configs (`config/<name>.yml.enc` pairs), and top-level credential **key names only** - decrypted hash is inspected for `.keys` and nothing more. A regression spec asserts no known credential value appears in the output.
- **`SecurityIntrospector` (`:security`, §32).** Framework-level security controls `auth_introspector` doesn't cover: `config.force_ssl`, SSL options (HSTS `expires` / `subdomains` / `preload`, `redirect`, `secure_cookies`), `config.hosts` + `host_authorization` options, `ContentSecurityPolicy` directives (including `report_only`), `PermissionsPolicy` directives, CSRF config (`protect_from_forgery` declaration, `per_form_csrf_tokens`, `forgery_protection_origin_check`), cookie session options (`:key`, `:secure`, `:httponly`, `:same_site`, `:domain`, `:path`, `:expire_after`), and Rails 7.2+ `allow_browser` calls per controller.
- **`ObservabilityIntrospector` (`:observability`, §34 + §38).** `ActiveSupport::LogSubscriber.log_subscribers` catalog (class + namespace), full `ActiveSupport::Notifications` subscriber registry walked via `@string_subscribers` / `@other_subscribers` / legacy `@subscribers` (handles Rails 7.0/7.1/8.x variants - grouped by pattern with subscriber count + sample class name), `ActionDispatch::ServerTiming` middleware detection + `config.server_timing` flag, Rails 8.1 `event_reporter` availability, log level + tags + `colorize_logging`, and a static catalog of 60+ canonical Rails event names across 10 subsystems (`action_controller`, `action_view`, `active_record`, `active_job`, `action_mailer`, `action_mailbox`, `action_cable`, `active_support`, `active_storage`, `railties`).
- **`EnvIntrospector` (`:env`, §36).** Curated catalog of 30+ Rails-related ENV vars (core, server, bundler, assets, boot, secrets, database, cache, deploy, platform, observability, testing) partitioned into `set` / `unset`. Safe vars (`RAILS_ENV`, `RAILS_MAX_THREADS`, `PORT`, etc.) return their value. Sensitive vars (`SECRET_KEY_BASE`, `RAILS_MASTER_KEY`, `DATABASE_URL`, `REDIS_URL`, `KAMAL_REGISTRY_PASSWORD`, etc.) return `redacted: true` only - the value never leaves the process. Also scans `config/`/`app/`/`lib/` for app-specific `ENV["X"]` / `ENV.fetch("X")` references beyond the catalog.

### Why these specifically

Each corresponds to a `RAILS_NERVOUS_SYSTEM.md` section the audit flagged as uncovered. Partial-coverage sections (§2 filenames, §3 Zeitwerk presence, §17 CurrentAttributes, §27 Solid Trifecta, §30 boolean, §32 CORS/CSP/force_ssl, §34 N+1 anti-patterns, §36 puma/procfile) are preserved - the new introspectors complement rather than replace existing ones.

### Preset wiring

All 8 are in `PRESETS[:full]`. None are in `PRESETS[:standard]` - they're framework-runtime data most valuable in `full` mode where full context outranks boot speed. `config.introspectors.size` for `:full` is now `39` (from `31`). The configuration spec was updated accordingly.

### Tests

Every new introspector ships with a unit spec under `spec/lib/rails_ai_context/introspectors/*_introspector_spec.rb`, plus an orchestrator-level assertion in `spec/lib/rails_ai_context/introspector_spec.rb` that all 8 keys land in the context hash, plus a real-Rails-app e2e spec at `spec/e2e/nervous_system_introspectors_spec.rb` (8 examples, run via `E2E=1`). Specs assert shape guarantees, error absence, category-specific invariants, and the `CredentialsIntrospector` / `EnvIntrospector` specs include explicit sentinel-value leak assertions (a secret is injected, then the output hash is searched for the sentinel string). The full non-e2e suite runs **2154 examples, 0 failures**.

### Fixed - post-review hardening

Three parallel code reviews (security/data-leak, Rails-version correctness, CLAUDE.md invariant compliance) surfaced the following issues, all addressed in this release:

- **`ObservabilityIntrospector#detect_event_reporter` crashed on Rails 8.1.** The original code called `reporter.tagged` without a block to read "registered tags". `ActiveSupport::EventReporter#tagged` delegates unconditionally to `TagStack#with_tags(&block)` which `yield`s - a blockless call raises `LocalJumpError`. The outer `rescue` caught it and returned `{ available: false }`, which silently misreported Rails 8.1 apps as lacking the event reporter and dropped the `subscriber_count` too. The `entry[:tags]` line was removed; `tagged` is stack-scoped context, not an introspectable keyspace. `subscriber_count` is still reported.
- **`ObservabilityIntrospector#extract_subscribers_from_notifier` had dead code.** A "legacy `@subscribers` (array)" fallback claimed to support Rails 7.0, but Rails 7.0 already used `@string_subscribers` + `@other_subscribers`. The flat `@subscribers` ivar hasn't existed since Rails ≤ 5.x, so the branch was unreachable across the entire 7.1 / 7.2 / 8.0 CI matrix. Removed. Also: the `subscriber_raw_pattern` helper now unwraps `ActiveSupport::Notifications::Fanout::Subscribers::Matcher` one level deep so Regexp-pattern subscribers surface as `"pattern.source"` instead of `"#<…::Matcher:0x…>"`.
- **`CredentialsIntrospector` leaked paths via `e.message`.** Both the top-level `rescue` and `inspect_default_credentials`'s rescue returned `{ error: e.message }` in the output hash. OS-level errors (`Errno::EACCES`, `Errno::ENOENT`) and OpenSSL decryption failures include absolute paths with the OS username in their message - credentials-adjacent data that shouldn't leave the process. Both rescues now return `{ error: "…failed", exception_class: e.class.name }`; `e.message` stays in the `ENV["DEBUG"]`-gated stderr log where it's fine. New regression specs inject a `Errno::EACCES` with a path containing `/Users/alice/secret/master.key` and assert neither `"/Users/alice"` nor `"alice/secret"` appears anywhere in the output.
- **`EnvIntrospector` classified `BUNDLE_PATH` and `BUNDLE_GEMFILE` as safe-to-return.** Both are absolute filesystem paths that usually contain the OS username (e.g. `/Users/alice/.bundle`). Flipped to `safe: false` so only presence is reported, matching the treatment of other path-containing vars (`DATABASE_URL`, `REDIS_URL`, etc.).
- **`ActiveSupportIntrospector` + `EnvIntrospector` had non-deterministic directory walks.** Both called `Dir.glob(...).first(2000)` to cap traversal on large monorepos, but `Dir.glob` ordering is filesystem-dependent, so the selected 2000-file slice could differ run-to-run. Both now call `Dir.glob(...).sort.first(2000)`, matching the `.sort` already used by the other new introspectors.
- **Spec-coverage gaps on ivar-derived paths.** The reviewers flagged that three silently-failing paths had no assertions: initializer `:source` capture (via `@block.source_location`), connection_pool `:pool_config` shape, and the `@other_subscribers` Regexp-pattern branch in the Fanout walk. All three now have targeted assertions - a silent drift if any of these ivars is renamed upstream will now fail CI.

## [5.9.1] - 2026-04-20

### Fixed - `GetConcern` missed plural concern names (#78)

Thanks to [@johan--](https://github.com/johan--) for the report and fix.

`rails_get_concern`'s includer search built its include-pattern regex via `String#classify`, which singularizes its input. Concerns with intentionally plural module names - `WorksheetImports`, `PaperTrailEvents`, `SoftDeletables`, etc. - got demodulized to `WorksheetImport` and the `include WorksheetImports` line in the model never matched. The tool reported no includers even when the concern was in use.

Switched to `String#camelize`, which normalizes case (so lowercase input like `plan_limitable` → `PlanLimitable` still works) **without** singularizing. This also restores consistency with the three other `.camelize` calls already used in `get_concern.rb` for the same "file basename / module name → class name" conversion. Covered by a new spec in `get_concern_spec.rb` that exercises the plural-name case end-to-end.

### Fixed - internal invariant compliance

- **`validate.rb` now routes all Prism parses through `AstCache`.** The Ruby syntax validator was calling `Prism.parse_file` directly and the ERB + semantic-visitor paths `Prism.parse` on string input, bypassing the cache entirely for the first and violating the "all Prism parses must flow through `RailsAiContext::AstCache`" invariant (`.results/3-identify-architecture.json:33`) for all three. Now uses `AstCache.parse(path)` for on-disk sources (picking up the existing size-cap + content-hash caching) and `AstCache.parse_string(source)` for synthetic strings. Note: `AstCache.parse` enforces a 5 MB `MAX_PARSE_SIZE` cap; Ruby files above that size fall through the existing `rescue` to the `ruby -c` subprocess validator, which returns errors but not Prism warnings - a graceful degradation that affects only pathologically large source files.
- **`Listeners::BaseListener` uses `Confidence::INFERRED` constant.** Replaced three hardcoded `"[INFERRED]"` literals in `extract_first_symbol`, `extract_key`, and `extract_value` with `RailsAiContext::Confidence::INFERRED`. Value is identical; constant reference prevents drift if the marker string is ever versioned.
- **Diagnostic `$stderr.puts` in `rescue` blocks now `ENV["DEBUG"]`-gated.** 12 previously-unconditional stderr writes across `tools/diagnose.rb` (5), `tools/review_changes.rb` (4), and `serializers/stack_overview_helper.rb` (3) were logging under normal operation whenever an optional context-enrichment step failed. These were never visible to most users but polluted stderr in MCP/CLI logs. Now silent unless `DEBUG=1`, matching the convention used everywhere else in the gem.

### Added

- **Prism-discipline regression spec** (`spec/lib/rails_ai_context/ast_cache_discipline_spec.rb`). Scans every `lib/**/*.rb` file (excluding `ast_cache.rb`) for direct `Prism.parse` / `Prism.parse_file` / `Prism.parse_string` calls and fails if any are found. Prevents re-introduction of the bypass that `validate.rb` had.

## [5.9.0] - 2026-04-16

### Fixed - Cursor chat agent didn't detect rules

Real user report during release QA: the Cursor IDE's chat agent didn't pick up rules written only as `.cursor/rules/*.mdc`, even when the rule declared `alwaysApply: true`. Cursor has **two** rule systems and the chat-agent composition path still consults the legacy `.cursorrules` file in many current builds.

`CursorRulesSerializer` now writes **both**: `.cursor/rules/*.mdc` (newer format with frontmatter / glob scoping / agent-requested triggers) AND a plain-text `.cursorrules` at the project root (legacy fallback, parsed verbatim by every Cursor build). Newer clients read the mdc files; older / chat-mode clients read `.cursorrules`. No behavior change for users who already relied on the mdc format.

The `.cursorrules` content goes through the **same** `CompactSerializerHelper#render_compact_rules` pipeline as `CLAUDE.md`, so both files convey identical project context - header, stack overview, key models, gems, architecture, commands, rules, and the MCP tool guide. Drift between the two files is no longer possible short of a manual divergence (regression spec enforces parity).

`.cursorrules` is **wrapped in `<!-- BEGIN/END rails-ai-context -->` markers** via the new `SectionMarkerWriter` module - same convention as `CLAUDE.md`, `AGENTS.md`, and `.github/copilot-instructions.md`. Pre-existing user content above or below the marker block survives every `rails ai:context` regeneration. Three regression specs cover the three branches: no-file → write markers; existing-without-markers → prepend gem block; existing-with-markers → replace only the gem block.

`FORMAT_PATHS[:cursor]` in the install generator now includes `.cursorrules` so re-install cleanup covers both files when a user removes Cursor from their selection. Regression specs added in `cursor_rules_serializer_spec.rb` and `in_gemfile_install_spec.rb` (e2e) verify both files are produced and the legacy file is plain text without frontmatter.

### Fixed - Round 3 follow-ups (post-quad-agent review)

- **`safe_glob_realpath` rescue widened.** Previously rescued only `Errno::ENOENT` and `Errno::EACCES`. Circular symlink chains (think `node_modules/@scope/*` cycles or developer-crafted loops) raise `Errno::ELOOP`; path components exceeding `NAME_MAX` raise `Errno::ENAMETOOLONG`. Both now rescued - return `nil` to skip the entry - preserving the CLAUDE.md invariant that every introspector wraps errors.

- **Install generator `CONFIG_SECTIONS` gained 3 sections.** Several user-facing config options existed in `Configuration::YAML_KEYS` but had no commented-out template line in the generated `config/initializers/rails_ai_context.rb`. Added "Database Query Tool" (`query_timeout`, `query_row_limit`, `query_redacted_columns`, `allow_query_in_production`), "Log Reading" (`log_lines`), and "Hydration" (`hydration_enabled`, `hydration_max_hints`) sections so in-Gemfile installs surface every supported knob.

### Added

- **`preset` command** - composite multi-tool workflows from CLI and rake. `rails ai:preset[architecture]` runs `analyze_feature` + `dependency_graph` + `performance_check` in one call. Also: `debugging` (logs + review + validate) and `migration` (schema + migration_advisor + validate). Available via both `rails-ai-context preset architecture` and `rails 'ai:preset[architecture]'`.

- **`facts` command** - concise schema facts summary. `rails ai:facts` / `rails-ai-context facts` prints tables with column/index/FK counts, model associations, key dependencies, and architecture patterns. Single command replaces 3+ MCP tool calls for quick context loading.

- **Validation pre-commit hook** - optional during `rails generate rails_ai_context:install`. Prompts to install a `.git/hooks/pre-commit` hook that runs `rails ai:tool[validate]` on staged `.rb` and `.erb` files. Catches hallucinated columns and schema drift before commit. Respects existing hooks and `--no-verify`.

### Added - E2E harness (`spec/e2e/`)

Real `rails new` → install → exercise → teardown against a fresh Rails application in a tmpdir. Covers the three install paths documented in CLAUDE.md #36, every CLI tool, the install generator, all 5 AI-client config files, and the MCP JSON-RPC protocol over both stdio and HTTP transports. Excluded from the default `rspec` run - opt-in via `E2E=1` or the new rake tasks.

- **`spec/e2e/in_gemfile_install_spec.rb`** - Path A (Gemfile entry + `rails generate rails_ai_context:install`). Verifies generator idempotency, per-AI-client config file validity, every built-in tool callable via both `bin/rails ai:tool[name]` and `bundle exec rails-ai-context tool name`, plus the `version`/`doctor`/`inspect` subcommands.

- **`spec/e2e/standalone_install_spec.rb`** - Path B (`gem install rails-ai-context` into an isolated GEM_HOME, no Gemfile entry, then `rails-ai-context init`). Verifies the Bundler-stripped `$LOAD_PATH` restoration logic described in CLAUDE.md #33 actually works on a real app.

- **`spec/e2e/zero_config_install_spec.rb`** - Path C (gem install, no init, no generator). Verifies the CLI works from pure defaults against any Rails app without any project-side setup.

- **`spec/e2e/mcp_stdio_protocol_spec.rb`** - spawns `rails-ai-context serve` as a subprocess and walks the full JSON-RPC 2.0 handshake: `initialize` → `notifications/initialized` → `tools/list` → `tools/call`. Verifies every registered built-in tool is advertised in `tools/list` with a rails_-prefixed name, description, and inputSchema.

- **`spec/e2e/mcp_http_protocol_spec.rb`** - spawns `rails-ai-context serve --transport http` on a random free port and sends `Net::HTTP` POST requests with JSON-RPC payloads. Verifies the HTTP transport returns the same tool registry and tool-call responses as stdio. Handles the Streamable HTTP requirements: `Accept: application/json, text/event-stream` header + `Mcp-Session-Id` round-trip from initialize.

- **`spec/e2e/empty_app_spec.rb`** - every built-in tool must handle a Rails app with no scaffolds, no models, no custom routes. Catches "tool crashes when introspecting an empty greenfield app" - the moment a developer is most likely to install rails-ai-context.

- **`spec/e2e/tool_edge_cases_spec.rb`** - malformed CLI inputs: unknown tool name, unknown parameter, missing required parameter, oversized string (10 KB), invalid enum value, fuzzy-match recovery, nonexistent target. Each case must produce structured user-facing errors, never an unhandled exception or signal.

- **`spec/e2e/concurrent_mcp_spec.rb`** - two parallel `rails-ai-context serve` subprocesses against the same Rails app. Verifies independent initialize responses, identical tool registries, and that simultaneous `tools/call` invocations don't cross-talk (response id matches request id per client).

- **`spec/e2e/postgres_install_spec.rb`** - Postgres adapter coverage for the `rails_query` tool's adapter-specific code paths: `SET TRANSACTION READ ONLY`, `BLOCKED_FUNCTIONS` regex against `pg_read_file`, `dblink`, `COPY ... PROGRAM`, and DDL rejection. Skipped locally unless `TEST_POSTGRES=1`; runs unconditionally in CI which spins up a Postgres 16 service container.

- **`spec/e2e/massive_app_spec.rb`** - 1500-model stress test. Programmatically generates a single migration with 1500 `create_table` statements and 1500 corresponding `ApplicationRecord` subclass files (rails-g-scaffold × 1500 would take 30+ min; direct file writes take seconds). Runs representative tools (`schema`, `model_details`, `routes`, `context`, `onboard`, `analyze_feature`, `get_turbo_map`, `get_env`) against the massive fixture and asserts: no signal, exit < 2, stdout non-empty, response size < 2 MB (tools must truncate - uncapped output overwhelms AI client context). Also verifies `rails_get_schema --table thing_0750s` finds a table in the middle of the range, proving schema introspection walks beyond the first page.

Rake tasks: `bundle exec rake e2e` (full), `rake e2e:in_gemfile`, `rake e2e:standalone`, `rake e2e:zero_config`, `rake e2e:mcp`.

CI: `.github/workflows/e2e.yml` runs on push to main + workflow_dispatch (separate from `ci.yml` so the 30-min job doesn't fail-stop the per-commit matrix). Matrix covers Ruby 3.3 + 3.4 across Rails 7.1, 7.2, 8.0, 8.1, and includes a Postgres 16 service container so the SQL-query and adapter-specific code paths are exercised on every push.

### Fixed - Security Hardening (Round 3)

Pre-release audit of **every** `Dir.glob` call site across the 38 tools. The 5-rule file-read pattern documented in CLAUDE.md was enforced on caller-supplied paths, but glob-sourced paths were reading file content without the same hardening. A symlink pre-planted inside `app/services/`, `app/jobs/`, `app/helpers/`, `app/models/`, `app/controllers/`, `app/views/`, or `app/` (pointing at `config/master.key`) would have leaked secret contents through tool output.

- **`BaseTool.safe_glob_realpath` + `BaseTool.safe_glob`** added as shared helpers. Every glob-sourced file read now passes through this filter: realpath + separator-aware containment + `sensitive_file?` recheck on the realpath. Broken symlinks, sibling-directory bypasses, and sensitive-pattern matches return `nil` and are skipped.

- **`get_service_pattern`, `get_job_pattern`, `get_helper_methods`** - glob+read on `app/services/`, `app/jobs/`, `app/helpers/` plus nested `find_callers` / `find_enqueuers` / `find_view_references` / `detect_framework_helpers`. All hardened.

- **`analyze_feature`** - 10 glob sites across `discover_services`, `discover_jobs`, `discover_views`, `discover_tests`, `discover_test_gaps`, `discover_channels`, `discover_mailers`, `discover_env_dependencies`. All hardened.

- **`get_conventions`** - glob+read on controllers (convention detection), services (listing), locales, controllers (UI-language detection), tests (pattern detection). All hardened.

- **`get_turbo_map`** - glob+read on models, controllers/services/jobs/channels, and two view scans. All hardened.

- **`get_env`** - glob+read on `app/config/lib` for ENV scans, `app/` for HTTP-client detection, and `app/config/lib` for prefix-matched ENV vars. All hardened. Removed redundant pre-realpath `sensitive_file?` now that `safe_glob` checks post-realpath.

- **`get_test_info`** - glob+read on `test/**/*_test.rb` for Devise detection, `test/fixtures` and `spec/fixtures` for fixture parsing. Hardened.

- **`generate_test`** - glob+read on `spec/**/*_spec.rb` or `test/**/*_test.rb` for pattern detection. Hardened.

- **`get_stimulus`** - glob+read on `app/views/**/*.{erb,html.erb}` for `data-controller` usage. Hardened.

- **`onboard`** - glob of `app/services/` for service name extraction (basename only). Hardened for consistency even though no content is read.

- **`search_code`** (ruby-fallback path) - the pre-realpath `sensitive_file?` check did not catch a symlink `app/models/innocent.rb → config/master.key` because the relative path looked safe. Now goes through `safe_glob` which rechecks on the realpath.

- **`job_introspector.rb:205`** - bare `rescue` (catching `Exception`, including `Interrupt`/`SystemExit`) replaced with project-standard `rescue => e` + DEBUG logging guard.

- **14 new regression specs** covering every newly-hardened tool with a symlink-to-master.key PoC + 5 edge cases for the `safe_glob_realpath` helper (sibling bypass, broken symlinks, sensitive realpath, separator awareness, in-tree passthrough).

### Fixed - Security Hardening (Round 2)

Eleven additional vulnerabilities and defense-in-depth gaps found by multi-round adversarial code review. All discovered post-v5.8.1 - **users on 5.8.x should upgrade**.

- **MySQL executable-comment bypass of `BLOCKED_FUNCTIONS`.** `strip_sql_comments` stripped `/*! ... */` (MySQL version-conditional comments) along with regular block comments. MySQL *executes* content inside `/*! ... */`, so `SELECT /*!50000 LOAD_FILE('/etc/passwd') */ AS x` passed all validation. **Fix:** unwraps executable comments (preserves inner content for checker visibility) before the block-comment strip. Belt-and-suspenders: also runs `BLOCKED_FUNCTIONS` against the raw SQL before any stripping.

- **`execute_explain` bypassed READ ONLY transaction and statement timeout.** The EXPLAIN path called `conn.select_all(explain_sql)` directly instead of routing through `execute_postgresql`/`execute_mysql`/`execute_sqlite`. PostgreSQL `EXPLAIN (FORMAT JSON, ANALYZE)` actually executes the query plan - an attacker could hold a DB connection indefinitely and bypass the read-only guard. **Fix:** routes through adapter-specific safety wrappers.

- **`read_logs` C1 sibling-directory bypass.** Bare `real.start_with?(File.realpath(root))` matched `/var/app/myapp_evil` against `/var/app/myapp`. **Fix:** separator-aware containment (`real == base || real.start_with?(base + File::SEPARATOR)`).

- **`read_logs` TOCTOU window.** Resolved the realpath for the containment check, then opened the original `path` for reading. Symlink swap between check and open leaked arbitrary files. **Fix:** returns and reads from the realpath.

- **`read_logs` missing post-realpath sensitive recheck.** A symlink `log/credentials.log -> ../config/master.key` resolves to a path still under Rails.root, passing containment. Without `sensitive_file?` on the realpath, `tail_file` read the secret. **Fix:** added post-realpath `sensitive_file?` recheck.

- **VFS `resolve_view` existence-oracle side channel.** `File.exist?` ran before `sensitive_file?`, so two distinct error messages ("View not found" vs "sensitive file") revealed whether `.env` / `master.key` existed inside `app/views/`. **Fix:** early `sensitive_file?` check before any filesystem stat.

- **`get_partial_interface` existence-oracle side channel.** `candidates.find { |c| File.exist?(c) }` stat'd candidates before any sensitive check on the caller-supplied `partial` string. Same oracle as the VFS fix. **Fix:** early `sensitive_file?` check in `call`.

- **`get_view` `list_layouts` missing all security rules.** Iterated `Dir.glob` results with no realpath containment, no sensitive recheck, and no size gate. A symlink `layouts/leak.key -> ../../config/master.key` leaked secrets in the `full` detail branch. **Fix:** full 5-rule file-reading pattern per file.

- **`get_view` `read_view_content` missing all security rules.** Called `SafeFile.read` after a bare `File.exist?` with no containment, no sensitive recheck, and no size cap. **Fix:** full 5-rule file-reading pattern with `max_file_size` gate.

- **`get_concern` `show_concern` path traversal.** `name.underscore` does not sanitize `../`, so `name: "../../config/initializers/devise"` read arbitrary `.rb` files under Rails.root. The proposed fix in the IDOR variant would have been a security downgrade. **Fix:** early traversal/null-byte/absolute-path rejection, early `sensitive_file?`, per-candidate realpath + separator containment, post-realpath sensitive recheck.

- **`get_concern` `list_concerns` symlink escape.** `Dir.glob` results passed to `SafeFile.read` with no realpath containment or sensitive recheck. **Fix:** per-file 5-rule pattern.

### Changed

- All documentation examples, tool descriptions, code comments, and test fixtures now use generic Rails terminology (`PostsController`, `publishable?`, `posts/index.html.erb`) instead of app-specific references. Affects README, GUIDE, CLI, RECIPES docs, tool_guide_helper serializer, 6 MCP tool description strings, CHANGELOG, demo scripts, and 3 spec files.

## [5.8.1] - 2026-04-15

### Fixed - Security Hardening

Four exploitable vulnerabilities across `rails_query`, the VFS URI dispatcher, and the instrumentation bridge, plus six defense-in-depth hardening issues. All discovered by security and deep code-review passes conducted during v5.8.1 pre-release verification. None were known at the v5.8.0 release - **users should upgrade immediately**.

- **SQL column-aliasing redaction bypass (exploitable).** Post-execution redaction in `rails_query` operated on `result.columns` (the DB-returned column names), which the caller controls via aliases and expressions. `SELECT password_digest AS x FROM users` returned raw bcrypt hashes. Same for `SELECT substring(password_digest, 1, 60) FROM users` (column named `substring`), `SELECT md5(session_data) FROM sessions`, `SELECT CASE WHEN id > 0 THEN password_digest END FROM users`, and subqueries that re-project the sensitive column. **Fix:** moved enforcement to pre-execution in `validate_sql`. Any query that textually references a column name in `config.query_redacted_columns` OR the hard-coded `SENSITIVE_COLUMN_SUFFIXES` list (password_digest, encrypted_password, password_hash, reset_password_token, api_key, refresh_token, otp_secret, session_data, secret_key, private_key, etc.) is now rejected. Users with a legitimately non-sensitive column matching one of these names can subtract from `config.query_redacted_columns` in an initializer. **8 bypass scenarios covered by new specs.**

- **Arbitrary filesystem read via database functions (exploitable).** `rails_query` did not block PostgreSQL's `pg_read_file`, `pg_read_binary_file`, `pg_ls_dir`, `pg_stat_file`, `lo_import`/`lo_export`, `dblink`, MySQL's `LOAD_FILE`, `SELECT ... INTO OUTFILE/DUMPFILE`, or SQLite's `load_extension`. These are SELECT-callable (so they pass the `BLOCKED_KEYWORDS` scanner and `SET TRANSACTION READ ONLY`) but give the caller a filesystem and shared-library-load primitive - completely bypassing the gem's `sensitive_patterns` allowlist by pivoting through the database process. PoC: `SELECT pg_read_file('/etc/passwd')`, `SELECT pg_read_file('config/master.key')`. **Fix:** added a `BLOCKED_FUNCTIONS` regex and `BLOCKED_OUTPUT` pattern that reject any query referencing these built-ins. **10 function-specific specs added.**

- **`sensitive_patterns` default list expanded.** The v5.8.0 default list covered `.env`, `.env.*`, `config/master.key`, `config/credentials*.yml.enc`, `*.pem`, `*.key` but missed common secret locations. v5.8.1 adds `config/database.yml`, `config/secrets.yml`, `config/cable.yml`, `config/storage.yml`, `config/mongoid.yml`, `config/redis.yml`, `*.p12`, `*.pfx`, `*.jks`, `*.keystore`, `**/id_rsa`, `**/id_ed25519`, `**/id_ecdsa`, `**/id_dsa`, `.ssh/*`, `.aws/credentials`, `.aws/config`, `.netrc`, `.pgpass`, `.my.cnf`.

- **`get_edit_context` now re-checks `sensitive_file?` after realpath resolution.** The initial check ran on the caller-supplied string; a symlink inside `app/models/` pointing at `config/master.key` previously passed the basename check and fell through to `File.read`. The post-realpath check blocks this.

- **`validate` now enforces `sensitive_file?`.** The validate tool had no sensitive-file check at all. Even though its output is limited to error messages (not raw content), it still leaked file existence/size and ran readers on secret files. Now denied with an `access denied (sensitive file)` error.

- **`BaseTool.sensitive_file?` has direct spec coverage for the first time.** The security boundary behind every file-accepting tool had zero direct tests in v5.8.0 - 36 new specs added covering the Rails secret locations, the v5.8.1 expanded pattern list, private keys and certificates, case-insensitivity, basename-only matching, and custom pattern configurations.

- **VFS `resolve_view` sibling-directory path traversal (exploitable).** The `rails-ai-context://views/{path}` URI resolver used bare `String#start_with?` on the realpath without a `File::SEPARATOR` suffix check. `/app/views_spec/secret.erb` matched `/app/views` as a prefix, so a symlink inside `app/views/` pointing at a sibling directory escaped containment and returned arbitrary file content. **Fix:** changed the containment check to `real == base || real.start_with?(base + File::SEPARATOR)`. Also added a `sensitive_file?` realpath check mirroring the v5.8.1 `get_edit_context` fix, so `.env`/`.key` symlinks inside `app/views/` are rejected. **2 new regression specs covering both PoCs.**

- **Instrumentation bridge leaks raw tool arguments to ActiveSupport::Notifications subscribers (exploitable).** `Instrumentation.callback` forwarded the MCP SDK's full data hash to `ActiveSupport::Notifications.instrument`. The SDK's `add_instrumentation_data(tool_name:, tool_arguments:)` includes raw tool inputs - so every Rails observability subscriber (Datadog, Scout, New Relic, custom loggers) received `rails_query`'s raw SQL, `rails_get_env`'s env var names, and `rails_read_logs`'s search patterns unredacted. The response-side redaction each of those tools carefully implements did nothing for the request side. **Fix:** introduced `Instrumentation::SAFE_KEYS` (`method`, `tool_name`, `duration`, `error`, `resource_uri`, `prompt_name`) - only those fields are forwarded. Users who need arguments in observability can set `config.instrumentation_include_arguments = true` in an initializer (taking on the redaction obligation). **3 new regression specs.**

- **Instrumentation subscriber failures could crash tool calls (exploitable).** The MCP SDK's `instrument_call` invokes our callback from an `ensure` block. Any exception raised inside the callback (e.g. a custom subscriber bug, a Datadog client losing connection) would propagate out of `ensure` and overwrite the tool's actual return value - effectively failing every tool call whenever any subscriber was broken. **Fix:** wrapped the `Notifications.instrument` call in a `rescue => e` block. Subscriber failures now log to stderr under `DEBUG=1` instead of corrupting tool responses. **1 new regression spec.**

- **`analyze_feature` caps per-directory file scans at 500 files.** `discover_services`, `discover_jobs`, and `discover_views` previously ran unbounded `Dir.glob` + `SafeFile.read` on every match, which on large monorepos could read thousands of files per call. Matches the existing cap used by `discover_tests`. Tool output notes when the cap was hit so the AI agent knows to narrow its feature keyword.

### Added - Configuration

- **`config.instrumentation_include_arguments`** (default `false`) - controls whether raw tool arguments are forwarded to `ActiveSupport::Notifications` subscribers. See the Security Hardening note above for the opt-in risk.

### Performance - Hot-Path Optimization

- **`cached_context` TTL short-circuit.** The hot path of every tool call ran `Fingerprinter.changed?` on every hit, which walks every `*.{rb,rake,js,ts,erb,haml,slim,yml}` file in `WATCHED_DIRS` plus (for path:-installed users) every file in the gem's own lib/ tree - doing an `mtime` stat per file. Measured at ~12ms per call in dev-mode path installs, ~0.5ms in production. Since LiveReload fires `reset_all_caches!` on actual file-change events, stale-cache risk during a short TTL window is already covered. **Fix:** skip the fingerprint check entirely when within the TTL window. When TTL expires, re-fingerprint; if unchanged, bump the timestamp and reuse the cached context (avoiding a 31-introspector re-run).

- **Fingerprinter gem-lib scan memoized.** For users who install the gem via `path:` (common for gem contributors, monorepos, the standalone dev workflow), the fingerprinter was walking 123 gem-lib files on every tool call. Memoized at class level with a `reset_gem_lib_fingerprint!` hook that `BaseTool.reset_cache!` and LiveReload invoke.

- **Measured result:** `cached_context` hot-path benchmark dropped from **11.77ms to 0.199ms** per call - a **~59x speedup** on dev-mode path installs. In-Gemfile / production users see a smaller but still meaningful improvement (0.77ms → 0.199ms).

### Fixed - schema.rb empty-file wrinkle

- `SchemaIntrospector#static_schema_parse` returned `{ error: "No db/schema.rb, db/structure.sql, or migrations found" }` when `db/schema.rb` existed but contained zero `create_table` calls (common on freshly-created Rails apps between `db:create` and the first migration). Now returns `{ total_tables: 0, tables: {}, note: "Schema file exists but is empty - no migrations have been run yet..." }`.

### Changed - CI release matrix synced to PR matrix

- `.github/workflows/release.yml` test matrix was still on the old Ruby `3.2/3.3/3.4` × Rails `7.1/7.2/8.0` grid even though `ci.yml` was expanded to cover Ruby 4.0 and Rails 8.1 in v5.8.0. Now synced - release-time testing matches PR-time testing across all 12 combos, including the #69 reporter's environment (Ruby 4.0.2 + Rails 8.1.3).

### Fixed - Pre-release review pass (rounds 2–3)

Five additional issues found during multi-round cold-eyes security and correctness review after the initial hardening pass.

- **`search_code` sibling-directory path traversal.** `rails_search_code`'s `path` parameter used `real_search.start_with?(real_root)` without a `File::SEPARATOR` suffix - the same bypass class as the original VFS C1 bug. A Rails root of `/app/myapp` would accept a search path whose realpath is `/app/myapp_evil`. **Fix:** changed to `real_search == real_root || real_search.start_with?(real_root + File::SEPARATOR)`. Spec added.

- **Instrumentation callback: `data[:method]` extraction outside `begin/rescue`.** Two lines before the `begin` block (`method = data[:method]` and `event_name = ...`) were not covered by the rescue. A non-Hash `data` argument from the MCP SDK would raise `NoMethodError` which would propagate into the SDK's `ensure` context and overwrite the tool's return value. **Fix:** moved `begin` to wrap the full lambda body after the early-exit guard.

- **`get_partial_interface` TOCTOU gap (residual from initial hardening).** `resolve_partial_path` performed the `File.realpath` security check internally but returned the original glob `found` path to the caller. The caller then called `File.size(found)` and `safe_read(found)` - creating a sub-millisecond race window where a symlink swap could read from a path that bypassed the check. **Fix:** `resolve_partial_path` now returns `real_found`. All file operations in the caller use the pre-checked realpath.

- **`validate` tool passed pre-realpath path to validators.** `validate_ruby`, `validate_erb`, `validate_javascript`, and `check_rails_semantics` all received `full_path` (pre-realpath) after the security check resolved `real`. **Fix:** all four now receive `Pathname.new(real)`.

- **`rails_query` `LOAD DATA INFILE` not explicitly blocked.** Added `LOAD\s+DATA` to `BLOCKED_FUNCTIONS`. Belt-and-suspenders: `ALLOWED_PREFIX` already blocks it at statement level, but the explicit entry makes intent self-documenting. Two specs added (`LOAD DATA INFILE` and `LOAD DATA LOCAL INFILE`).

### Test coverage

- **2004 examples, 0 failures** (was 1928 in v5.8.0, +76 new regression tests across the security + hardening + empty-schema + VFS + instrumentation + review-pass fixes).

## [5.8.0] - 2026-04-14

### Added - Modern Rails Coverage Pass

Five targeted gaps in modern Rails introspection, identified by an audit of the introspectors against current Rails 7/8 patterns. Net result: the gem now surfaces what AI agents need to know about Rails 8 built-in auth, Solid Errors, async query usage, strong_migrations safety, and Action Cable channel detail.

- **Rails 8 built-in auth depth.** `auth_introspector#detect_authentication` previously detected `bin/rails generate authentication` only as a boolean. Now returns a hash with the Authentication concern path, the Sessions/Passwords controller paths, and a per-controller list of `allow_unauthenticated_access` filters with their `only:`/`except:` scope. Each declaration in a file yields its own entry (a controller with both `only:` and `except:` is captured fully, not collapsed to the first match), and trailing line comments are stripped from the captured scope. AI agents can answer "which controllers are public?" in one tool call.
- **Solid Errors gem detection.** Added `solid_errors` (Rails 8 database-backed error tracking, by @fractaledmind) to `gem_introspector.rb`'s `NOTABLE_GEMS` map under the `:monitoring` category. Was the only Solid-* gem missing from the list (`solid_queue`, `solid_cache`, `solid_cable` were already covered). `solid_health` is NOT a real published gem - Rails 8 ships a built-in `/up` healthcheck endpoint with no gem needed.
- **Async query pattern detection.** `convention_introspector#detect_patterns` now adds `async_queries` to the patterns array when it finds `load_async` or any of the `async_count`/`async_sum`/`async_minimum`/`async_maximum`/`async_average`/`async_pluck`/`async_ids`/`async_exists`/`async_find_by`/`async_find`/`async_first`/`async_last`/`async_take` calls in `app/controllers`, `app/services`, `app/jobs`, or `app/models`. Comment-only references (e.g. `# TODO: bring back load_async`) are skipped to avoid false positives. AI agents can recognize the perf optimization is in use without re-scanning.
- **Strong Migrations integration.** `migration_advisor` now emits a `## Strong Migrations Warnings` section when the `strong_migrations` gem is in `Gemfile.lock`. Catalog covers the most common breaking-change patterns: `remove_column` (needs `safety_assured` + `ignored_columns` first), `rename_column` (unsafe under load, two-step pattern), `change_column` type change (table rewrite), `add_index` without `algorithm: :concurrently` (Postgres write lock), `add_foreign_key` without `validate: false` (lock validation), and `add_column` with `null: false` but no default (table rewrite). Each warning includes the safer pattern. Fires only when the gem is detected - zero noise for projects that don't use it.
- **Action Cable channel detail.** `job_introspector#extract_channels` was returning `{ name, stream_methods }` only. Enriched to also extract `identified_by` attributes, `stream_from`/`stream_for` targets, `periodically` timers with their full intervals (including lambdas like `every: -> { current_user.interval }`), RPC action methods (excluding subscribed/unsubscribed/stream_*), and the source file path. **`get_job_pattern` now renders an "Action Cable Channels" section with all of these fields**, so AI agents calling the tool actually see the data instead of just the channel name. Also added `eager_load_channels!` to `JobIntrospector` so the channel set is populated in development mode (where `config.eager_load = false` and `ActionCable::Channel::Base.descendants` is otherwise empty until a client subscribes).

### Changed - CI matrix expanded to cover Ruby 4.0 + Rails 8.1

- Added Ruby `4.0` and Rails `8.1` to the GitHub Actions test matrix. Net jobs: 12 (was 8). Excludes the unsupported combinations: Ruby 3.2 × Rails 8.x (Rails 8 needs 3.3+) and Ruby 4.0 × Rails 7.x (Rails 7 has no Ruby 4 support). Verified locally that the full spec suite passes on Ruby 4.0.2 + Rails 8.1.3 (the environment in #69) - 1925 examples, 0 failures, rubocop clean across all 282 source files.

### Fixed - Standalone Install Path Crashed Inside Bundler-Backed Rails Apps

- **`rails-ai-context` installed via `gem install` (standalone path) crashed on every tool call** when run inside a Rails app that has its own `Gemfile`. Root cause: `boot_rails!` in `exe/rails-ai-context` calls `require config/environment.rb` which runs `Bundler.setup`, which strips `Gem.loaded_specs` to only the app's Gemfile-resolved gems. The MCP SDK reads `Gem.loaded_specs["json-schema"].full_gem_path` at tool-call time (`mcp/tool/schema.rb:45`) - but `json-schema` is a transitive dep of `mcp`, not in the app's Gemfile, so the lookup nils and crashes with `NoMethodError: undefined method 'full_gem_path' for nil`.
- **Fix:** added `restore_standalone_gem_specs` to `exe/rails-ai-context` which re-registers `mcp`, `json-schema`, and a couple of their transitive deps in `Gem.loaded_specs` after `Bundler.setup` runs. No-op in in-Gemfile mode (the specs are already registered). This was a pre-existing bug that was discovered during v5.8.0 pre-release E2E verification - affected v5.4.0 onward.

### Fixed - MCP Tool Responses Rejected by Strict Clients (#69)

- **Removed default `output_schema` from all 38 tools.** Since v5.4.0, `BaseTool.inherited` automatically assigned a `DEFAULT_OUTPUT_SCHEMA` to every tool. The schema described the response wire envelope (`{content: [...]}`) rather than app-level structured data, and tools never returned matching `structured_content`. Per MCP spec, when a tool declares `outputSchema`, it MUST return `structuredContent` matching it. Strict MCP clients (e.g. Copilot CLI) reject responses that don't, with `MCP error -32600: Tool ... has an output schema but did not return structured content`. Lenient clients (Claude Code, Cursor) silently ignored the missing field, which is why the bug went unnoticed since v5.4.0.
- **Why this happened.** The MCP Ruby SDK does not enforce `output_schema` server-side (no `validate_result` call in `MCP::Server`), so the test suite passed end-to-end. Validation happens client-side, and only strict clients caught it. Reported by @pardeyke.
- **What changed.** Deleted `DEFAULT_OUTPUT_SCHEMA` constant and the `inherited` hook line that set it (`lib/rails_ai_context/tools/base_tool.rb`). Tools now ship with no `outputSchema` by default - matching what they actually return (text-only). Individual tools can still declare their own `output_schema` via the MCP::Tool DSL, provided they also return matching `structured_content`.
- **Regression spec added.** `spec/lib/rails_ai_context/tools_spec.rb` now asserts (a) no tool advertises a default `outputSchema`, and (b) any tool that *does* declare one must also have `structured_content:` in its source - preventing the v5.4.0 misuse from sneaking back in.
- **Future enhancement.** Per-tool structured output (returning parseable JSON alongside the Markdown text via `structured_content:`) is a future feature for tools where it adds value (`get_schema`, `get_routes`, etc.). Out of scope for this patch.

### Added - Framework Association Noise Filter

- **`excluded_association_names` config option** - filters framework-generated associations (ActiveStorage, ActionText, ActionMailbox, Noticed) from model introspection output. 7 association names excluded by default. Configurable via initializer (`config.excluded_association_names += %w[...]`) or YAML. Closes #57.

## [5.7.1] - 2026-04-09

### Changed - SLOP Cleanup

Internal code quality improvements - no API changes, no new features.

- **Extract `safe_read`, `max_file_size`, `sensitive_file?` to BaseTool** - removed 16 duplicate one-liner methods across 8 tool files (get_env, get_job_pattern, get_service_pattern, get_turbo_map, get_partial_interface, get_view, get_edit_context, get_model_details, search_code)
- **Extract `FullSerializerBehavior` module** - deduplicated identical `footer` and `architecture_summary` methods from FullClaudeSerializer and FullOpencodeSerializer
- **Derive `tools_name_list` from `TOOL_ROWS`** - replaced hardcoded 38-tool name array with derivation from single source of truth in ToolGuideHelper
- **Fix `notable_gems_list` bypass** - copilot_instructions_serializer and markdown_serializer now use the triple-fallback helper instead of raw hash access
- **Narrow bare `rescue` to `rescue StandardError`** - 4 sites in get_config and i18n_introspector no longer catch `SignalException`/`NoMemoryError`
- **Delete dead `SENSITIVE_PATTERNS = nil` constant** - vestigial from get_edit_context

## [5.7.0] - 2026-04-09

### Quickstart - Two commands. Problem gone.

```bash
gem "rails-ai-context", group: :development
rails generate rails_ai_context:install
```

### Fixed - Bug Fixes from Codebase Audit

6 bug fixes discovered via automated codebase audit (bug-finder, code-reviewer, doc-consistency-checker agents).

- **AnalyzeFeature service/mailer method extraction** (HIGH) - `\A` (start-of-string) anchor in `scan` regex replaced with `^` (start-of-line). Services and mailers now correctly list all methods instead of always returning empty arrays.

- **SearchCode exact_match + definition double-escaping** (HIGH) - Word boundaries (`\b`) were applied before `Regexp.escape`, producing unmatchable regex when combining `exact_match: true` with `match_type: "definition"` or `"class"`. Boundaries now applied per-match_type after escaping.

- **MigrationAdvisor empty string column bypass** (MEDIUM) - Empty string `""` column names bypassed the "column required" validation (Ruby truthiness). Now normalized via `.presence` so empty strings become `nil` and are caught.

- **GetConcern class method block tracking** - Regex no longer matches `def self.method` as a `class_methods do` block entry, preventing instance methods after `def self.` from being incorrectly skipped.

- **AstCache eviction comment accuracy** - Comment corrected from "evicts oldest entries" to "arbitrary selection" since `Concurrent::Map` has no ordering guarantee.

- **SECURITY.md supported versions** - Added missing 5.6.x row to supported versions table.

- **CONFIGURATION.md preset count** - Fixed stale `:standard` preset count from 13 to 17.

## [5.6.0] - 2026-04-09

### Added - Auto-Registration, TestHelper & Bug Fixes

Developer experience improvements inspired by action_mcp patterns, plus 5 security/correctness bug fixes.

- **Auto-registration via `inherited` hook** - Tools are now auto-discovered from `BaseTool` subclasses. No manual list to maintain - drop a file in `tools/` and it's registered. `Server.builtin_tools` is the new public API. Thread-safe via `@registry_mutex` with deadlock-free design (const_get runs outside mutex to avoid recursive locking from inherited). `Server::TOOLS` preserved as deprecated `const_missing` shim for backwards compatibility.

- **`abstract!` pattern** - `BaseTool.abstract!` excludes a class from the registry. `BaseTool` itself is abstract. Subclasses are concrete by default.

- **TestHelper module** (`lib/rails_ai_context/test_helper.rb`) - Reusable test helper for custom_tools users. Methods: `execute_tool` (by name, short name, or class), `execute_tool_with_error`, `assert_tool_findable`, `assert_tool_response_includes`, `assert_tool_response_excludes`, `extract_response_text`. Works with both RSpec and Minitest. Supports fuzzy name resolution (`schema` → `rails_get_schema`).

### Fixed

- **SQL comment stripping validation bypass** (HIGH) - `#` comment stripping now restricted to line-start only, preventing validation bypass via hash characters in string literals. PostgreSQL JSONB operators (`#>>`) preserved.

- **SHARED_CACHE read outside mutex** (MEDIUM) - `redact_results` now uses `cached_context` for thread-safe access to encrypted column data.

- **McpController double-checked locking** (MEDIUM) - Removed unsynchronized read outside mutex, fixing unsafe pattern on non-GVL Rubies (JRuby/TruffleRuby).

- **PG EXPLAIN parser bare rescue** (LOW) - Changed from `rescue` to `rescue JSON::ParserError`, preventing silent swallowing of bugs in `extract_pg_nodes`.

- **GetConcern `class_methods` block closing** (LOW) - Indent-based tracking to detect the closing `end`, so `def self.` methods after the block are no longer lost.

- **Query spec graceful degradation** - Replaced permanently-pending spec (sqlite3 2.x removed `set_progress_handler`) with a spec that verifies queries execute correctly without it.

## [5.5.0] - 2026-04-08

### Added - Universal MCP Auto-Discovery & Per-Tool Context Optimization (#51-#56)

Every AI tool now gets its own MCP config file - auto-detected on project open. No manual setup needed for any supported tool.

- **McpConfigGenerator** (`lib/rails_ai_context/mcp_config_generator.rb`) - Shared infrastructure for per-tool MCP config generation. Writes `.mcp.json` (Claude Code), `.cursor/mcp.json` (Cursor), `.vscode/mcp.json` (GitHub Copilot), `opencode.json` (OpenCode), `.codex/config.toml` (Codex CLI). Merge-safe - only manages the `rails-ai-context` entry, preserves other servers. Supports standalone mode and CLI skip.

- **Codex CLI support** (#51) - 5th supported AI tool. Reuses `AGENTS.md` (shared with OpenCode) and `OpencodeRulesSerializer` for directory-level split rules. Config via `.codex/config.toml` (TOML format) with `[mcp_servers.rails-ai-context.env]` subsection that snapshots Ruby environment variables at install time - required because Codex CLI `env_clear()`s the process before spawning MCP servers. Works with all Ruby version managers (rbenv, rvm, asdf, mise, chruby, system). Added to all 3 install paths (generator, CLI, rake), doctor checks, and search exclusions.

- **Cursor improvements** (#52) - `.cursor/mcp.json` auto-generated for MCP auto-discovery. MCP tools rule changed from `alwaysApply: true` to `alwaysApply: false` with descriptive text for agent-requested (Type 3) loading.

- **OpenCode improvements** (#53) - `opencode.json` auto-generated for MCP auto-discovery.

- **Claude Code improvements** (#54) - `paths:` YAML frontmatter added to `.claude/rules/` schema, models, and components rules for conditional loading. Context and mcp-tools rules remain unconditional.

- **Copilot improvements** (#55) - `.vscode/mcp.json` auto-generated for MCP auto-discovery. `name:` and `description:` YAML frontmatter added to all `.github/instructions/` files. Updated `excludeAgent` spec to validate `code-review`, `coding-agent`, and `workspace` per GitHub Copilot docs.

- **All 3 install paths updated** - Install generator, standalone CLI (`rails-ai-context init`), and rake task (`rails ai:setup`) all delegate to McpConfigGenerator. Codex added as option "5" in interactive tool selection.

- **Doctor expanded** - `check_mcp_json` now validates per-tool MCP configs based on configured `ai_tools` (JSON parse validation + TOML existence check).

- **Search exclusions** - `.codex/`, `.vscode/mcp.json`, `opencode.json` added to `search_code` tool exclusions.

## [5.4.0] - 2026-04-08

### Added - Phase 3: Dynamic VFS & Live Resource Architecture (Ground Truth Engine Blueprint #39)

Live Virtual File System replaces static resource handling. Every MCP resource is introspected fresh on every request - zero stale data.

- **VFS URI Dispatcher** (`lib/rails_ai_context/vfs.rb`) - Pattern-matched routing for `rails-ai-context://` URIs. Resolves models, controllers, controller actions, views, and routes. Each call introspects fresh. Path traversal protection for view reads.

- **4 new MCP Resource Templates:**
  - `rails-ai-context://controllers/{name}` - controller details with actions, filters, strong params
  - `rails-ai-context://controllers/{name}/{action}` - action source code and applicable filters
  - `rails-ai-context://views/{path}` - view template content (path traversal protected)
  - `rails-ai-context://routes/{controller}` - live route map filtered by controller name

- **MCP Controller** (`app/controllers/rails_ai_context/mcp_controller.rb`) - Native Rails controller for Streamable HTTP transport. Alternative to Rack middleware - integrates with Rails routing, authentication, and middleware stack. Mount via `mount RailsAiContext::Engine, at: "/mcp"`.

- **output_schema on all 38 tools** - Default `MCP::Tool::OutputSchema` set via `BaseTool.inherited` hook. Every tool now declares its output format in the MCP protocol. Individual tools can override with custom schemas.

- **Instrumentation** (`lib/rails_ai_context/instrumentation.rb`) - Bridges MCP gem instrumentation to `ActiveSupport::Notifications`. Events: `rails_ai_context.tools.call`, `rails_ai_context.resources.read`, etc. Subscribe with standard Rails notification patterns.

- **Server instructions** - MCP server now includes `instructions:` field describing the ground truth engine capabilities.

- **Enhanced LiveReload** - Full cache sweep on file changes via `reset_all_caches!` (includes AST, tool, and fingerprint caches).

- **82 new specs** covering VFS resolution (models, controllers, actions, views, routes), instrumentation callback, McpController (thread safety, delegation, subclass isolation), resource templates (5 total), output_schema on all 38 tools, and server configuration.

## [5.3.0] - 2026-04-07

### Added - Phase 2: Cross-Tool Semantic Hydration (Ground Truth Engine Blueprint #38)

Controller and view tools now automatically inject schema hints for referenced models, eliminating the need for follow-up tool calls.

- **SchemaHint** (`lib/rails_ai_context/schema_hint.rb`) - Immutable `Data.define` value object carrying model ground truth: table, columns, associations, validations, primary key, and `[VERIFIED]`/`[INFERRED]` confidence tag.

- **HydrationResult** - Wraps hints + warnings for downstream formatting.

- **SchemaHintBuilder** (`lib/rails_ai_context/hydrators/schema_hint_builder.rb`) - Resolves model names to `SchemaHint` objects from cached introspection context. Case-insensitive lookup, batch builder with configurable cap.

- **HydrationFormatter** (`lib/rails_ai_context/hydrators/hydration_formatter.rb`) - Renders `SchemaHint` objects as compact Markdown `## Schema Hints` sections with columns (capped at 10), associations, and validations.

- **ControllerHydrator** (`lib/rails_ai_context/hydrators/controller_hydrator.rb`) - Parses controller source via Prism AST to detect model references (constant receivers, `params.require` keys, ivar writes), then builds schema hints.

- **ViewHydrator** (`lib/rails_ai_context/hydrators/view_hydrator.rb`) - Maps instance variable names to models by convention (`@post` → `Post`, `@posts` → `Post`). Filters framework ivars (page, query, flash, etc.).

- **ModelReferenceListener** (`lib/rails_ai_context/introspectors/listeners/model_reference_listener.rb`) - Prism Dispatcher listener for controller-specific model detection. Not registered in `LISTENER_MAP` - used standalone by `ControllerHydrator`.

- **Tool integrations:**
  - `GetControllers` - schema hints injected into both action source and controller overview
  - `GetContext` - hydrates combined controller+view ivars in action context mode
  - `GetView` - hydrates instance variables from view templates in standard detail

- **Configuration:** `hydration_enabled` (default: true), `hydration_max_hints` (default: 5). Both YAML-configurable.

- **65 new specs** covering SchemaHint, HydrationResult, SchemaHintBuilder, HydrationFormatter, ModelReferenceListener, ControllerHydrator, ViewHydrator, tool-level hydration integration (GetControllers, GetView), and configuration (defaults, YAML loading, max_hints propagation).

## [5.2.0] - 2026-04-07

### Added - Phase 1: Prism AST Foundation (Ground Truth Engine Blueprint #36)

System-wide AST migration replacing all regex-based Ruby source parsing with Prism AST visitors. This is the foundation layer for the Ground Truth Engine transformation (#37).

- **AstCache** (`lib/rails_ai_context/ast_cache.rb`) - Thread-safe Prism parse cache backed by `Concurrent::Map`. Keyed by path + SHA256 content hash + mtime. Invalidates automatically on file change. Shared by all AST-based introspectors.

- **VERIFIED/INFERRED confidence contract** - `Confidence.for_node(node)` determines whether an AST node's arguments are all static literals (`[VERIFIED]`) or contain dynamic expressions (`[INFERRED]`). Called from listeners via `BaseListener#confidence_for(node)`. Every source-level introspection result now carries a confidence tag.

- **7 Prism Listener classes** (`lib/rails_ai_context/introspectors/listeners/`):
  - `AssociationsListener` - `belongs_to`, `has_many`, `has_one`, `has_and_belongs_to_many`
  - `ValidationsListener` - `validates`, `validates_*_of`, custom `validate :method`
  - `ScopesListener` - `scope :name, -> { ... }`
  - `EnumsListener` - Rails 7+ and legacy enum syntax with prefix/suffix options
  - `CallbacksListener` - all AR callback types including `after_commit` with `on:` resolution
  - `MacrosListener` - `encrypts`, `normalizes`, `delegate`, `has_secure_password`, `serialize`, `store`, `has_one_attached`, `has_many_attached`, `has_rich_text`, `generates_token_for`, `attribute` API
  - `MethodsListener` - `def`/`def self.` with visibility tracking, parameter extraction, `class << self` support

- **SourceIntrospector** (`lib/rails_ai_context/introspectors/source_introspector.rb`) - Single-pass Prism Dispatcher that walks the AST once and feeds events to all 7 listeners simultaneously. Available as `SourceIntrospector.call(path)` for file-based introspection or `SourceIntrospector.from_source(string)` for in-memory parsing.

- **73 new specs** covering AstCache, SourceIntrospector integration, and all 7 listener classes with edge cases (multi-line associations, legacy enums, visibility tracking, parameter extraction).

### Changed

- **ModelIntrospector** rewritten to use AST-based source parsing via `SourceIntrospector` instead of regex. Reflection-based extraction (associations via AR, validations via AR, enums via AR) preserved where it provides runtime accuracy. All `source.scan(...)`, `source.each_line`, and `line.match?(...)` patterns in model introspection eliminated.

- **Install generator** now wraps `config/initializers/rails_ai_context.rb` in `if defined?(RailsAiContext)` so apps with the gem in `group :development` only don't crash in test/production. Re-install upgrades existing unguarded initializers and preserves indentation. All README and GUIDE initializer examples updated to the guarded form (#35).

### Dependencies

- Added `prism >= 0.28` (stdlib in Ruby 3.3+, gem for 3.2)
- Added `concurrent-ruby >= 1.2` (thread-safe AST cache; already transitive via Rails)

### Why

Regex-based Ruby source parsing was the #3 critical finding in the architecture audit: it breaks on heredocs, multi-line DSL calls, `class << self` blocks, and metaprogrammed constructs. Prism AST provides 100% syntax-level accuracy. The single-pass Dispatcher pattern means parsing a 500-line model file runs all 7 listeners in one tree walk - no repeated I/O or re-parsing. The confidence tagging gives AI agents explicit signal about what data is ground truth vs. what requires runtime verification.

## [5.1.0] - 2026-04-06

### Fixed

Accuracy fixes across 8 introspectors, eliminating false positives and capturing previously-missed signals. No public API changes; all 38 MCP tools retain their contracts.

- **ApiIntrospector** - pagination detection (`detect_pagination`) was substring-matching Gemfile.lock content, producing false positives on gems that merely contain the strategy name: `happypagy`, `kaminari-i18n`, transitive `pagy` dependencies. Now uses anchored lockfile regex (`^    pagy \(`) that only matches direct top-level dependencies. Same fix applied to `kaminari`, `will_paginate`, and `graphql-pro` detection.
- **DevOpsIntrospector** - health-check detection (`detect_health_check`) used an unanchored word regex (`\b(?:health|up|ping|status)\b`) that matched comments, controller names, and any line containing those words. Tightened to match only quoted route strings (`"/up"`, `"/healthz"`, `"/liveness"`, etc.) or the `rails_health_check` symbol. Also newly detects `/readiness`, `/alive`, and `/healthz` routes.
- **PerformanceIntrospector** - schema parsing (`parse_indexed_columns`) tracked table context with a boolean-ish `current_table` variable but never cleared it on `end` lines, so `add_index` statements after a `create_table` block matched both the inner block branch AND the outer branch, producing duplicate index entries. This polluted `missing_fk_indexes` analysis. Fixed via explicit `inside_create_table` state flag with block boundary detection. Also added `m` (multiline) flag to specific-association preload regex so `.includes(...)` calls spanning multiple lines are matched.
- **I18nIntrospector** - `count_keys_for_locale` only read `config/locales/{locale}.yml`, missing nested locale files that are the Rails convention for gem-added translations: `config/locales/devise.en.yml`, `config/locales/en/users.yml`, `config/locales/admin/en.yml`. New `find_locale_paths` method globs all YAML under `config/locales/**/*` and selects files whose basename equals the locale, ends with `.{locale}`, or lives under a `{locale}/` subfolder. In typical Rails apps this captures 2-10x more translation keys than the previous single-file read, making `translation_coverage` percentages meaningful.
- **JobIntrospector** - when a job class declared `queue_as ->(job) { ... }`, `job.queue_name` returned a Proc that was then called with no arguments, crashing or returning stale values. Now returns `"dynamic"` when queue is a Proc, matching the job's actual runtime behavior (queue is resolved per-invocation).
- **ModelIntrospector** - source-parsed class methods in `extract_source_class_methods` emitted a spurious `"self"` entry because `def self.foo` matched both the `def self.(\w+)` branch AND the generic `def (\w+)` branch inside `class << self` tracking. Restructured as `if/elsif` so each `def` line matches exactly one pattern. Also anchored `class << self` detection with `\b` to avoid partial-word matches.
- **RouteIntrospector** - `call` method could raise if `Rails.application.routes` was not yet loaded or a sub-method failed mid-extraction. Added a top-level rescue that returns `{ error: msg }`, matching the error contract used by every other introspector.
- **SeedsIntrospector** - `has_ordering` regex (`load.*order|require.*order|seeds.*\d+`) matched unrelated code like `require 'order'` or `seeds 001` in comments. Tightened to match actual ordering patterns: `Dir[...*.rb].sort`, `load "seeds/NN_foo.rb"`, `require_relative "seeds/NN_foo"`.

### Performance

- **ConventionIntrospector** - `gem_present?` was reading `Gemfile.lock` from disk 15 times per introspection pass (once per notable gem check). Memoized into a single read: **-93% I/O** (15 reads → 1 read). ~60% faster on typical apps.
- **ComponentIntrospector** - `build_summary` called `extract_components` again after `call` already computed it, doubling the filesystem walk and component parsing work. Now passes the result through: **-50% work**. ~50% faster.
- **GemIntrospector** - `categorize_gems(specs)` internally called `detect_notable_gems(specs)` after `call` had already called it, duplicating gem-list iteration and category lookup. Now accepts the notable-gem result directly: **-50% work**.
- **ActiveStorageIntrospector** - `uses_direct_uploads?` globbed `**/*` across `app/views` + `app/javascript`, reading every binary, image, font, and asset in those trees. Scoped to 9 relevant extensions (`erb,haml,slim,js,ts,jsx,tsx,mjs,rb`), avoiding wasteful I/O on irrelevant files.
- **Total**: ~14% cumulative speedup across all 12 modified introspectors on a medium-sized Rails app (23.66ms → 20.33ms).

### Why

Introspector output feeds every MCP tool response, every context file, and every rule file this gem generates. Silent inaccuracies (false-positive pagination detection, missed locale files, phantom duplicate indexes) compound: AI assistants make decisions based on this data, and incorrect data produces incorrect code suggestions. These fixes tighten the accuracy floor without changing any public interface.

## [5.0.0] - 2026-04-05

### Removed (BREAKING)

This release removes the Design & Styling surface and the Accessibility rule surface. When AI assistants consumed pre-digested design/styling context (color palettes, Tailwind class strings, canonical HTML/ERB snippets), they produced poor UI/UX output by blindly copying class strings instead of understanding visual hierarchy. The accessibility surface was asymmetric (Claude-only static rule file, no live MCP tool) and provided generic best-practice rules that didn't earn their keep.

**Design system:**
- **Removed `rails_get_design_system` MCP tool** - tool count is now **38** (was 39). Tool class `RailsAiContext::Tools::GetDesignSystem` deleted.
- **Removed `:design_tokens` introspector** - class `RailsAiContext::Introspectors::DesignTokensIntrospector` deleted.
- **Removed `ui_patterns`, `canonical_examples`, `shared_partials` keys** from `ViewTemplateIntrospector` output. The introspector now returns only `templates` and `partials`.
- **Removed `DesignSystemHelper` serializer module** - module `RailsAiContext::Serializers::DesignSystemHelper` deleted. Consumers no longer receive UI Patterns sections in rule files or compact output.
- **Removed `"design"` option** from the `include:` parameter of `rails_get_context`. Valid options are now: `schema`, `models`, `routes`, `gems`, `conventions`.

**Accessibility:**
- **Removed `:accessibility` introspector** - class `RailsAiContext::Introspectors::AccessibilityIntrospector` deleted. `ctx[:accessibility]` no longer populated.
- **Removed `discover_accessibility` cross-cut** from `rails_analyze_feature`. The tool no longer emits a `## Accessibility` section with per-feature a11y findings.
- **Removed Accessibility line** from root-file Stack Overview (no more "Accessibility: Good/OK/Needs work" label).

**Preset counts:** `:full` is now **31** (was 33); `:standard` is now **17** (was 19). Both lost `:design_tokens` and `:accessibility`.

**Legacy rule files no longer generated:**
- `.claude/rules/rails-ui-patterns.md`
- `.cursor/rules/rails-ui-patterns.mdc`
- `.github/instructions/rails-ui-patterns.instructions.md`
- `.claude/rules/rails-accessibility.md`

### Migration notes

- **Legacy files are NOT auto-deleted.** On first run after upgrade (via `rake ai:context`, `rails-ai-context context`, install generator, or watcher), the gem detects stale `rails-ui-patterns.*` and `rails-accessibility.md` files and prompts interactively in TTY sessions, or warns (non-destructive) in non-TTY sessions. Answer `y` to remove, or delete the files manually.
- **If you depended on `rails_get_design_system`**, replace with `rails_get_component_catalog` (component-based) or read view files directly with `rails_read_file` / `rails_search_code`.
- **If you depended on `include: "design"`** in `rails_get_context`, remove that option.
- **If you depended on `ctx[:accessibility]`** (custom tools / serializers), that key is gone. Use standard a11y linters (axe-core, lighthouse) in your test suite instead.
- **The "Build or modify a view" workflow** in tool guides now starts with `rails_get_component_catalog` instead of `rails_get_design_system`.

### Why

AI assistants that consume pre-digested summaries produce worse output than AI that reads actual source files. For design systems, class-string copying defeats the mental model required for cohesive visual hierarchy. For accessibility, generic rules ("add alt text") are universal knowledge that AI already has - the static counts didn't add actionable context, and the asymmetric distribution (Claude-only rule file, no live tool) was incoherent with the gem's charter. The gem's charter is ground truth for Rails structure (schema, associations, routes, controllers) - design-system and accessibility summaries were adjacent to that charter and actively counterproductive or inert.

## [4.7.0] - 2026-04-05

### Added
- **Anti-Hallucination Protocol** - 6-rule verification section embedded in every generated context file (CLAUDE.md, AGENTS.md, .claude/rules/, .cursor/rules/, .github/instructions/, copilot-instructions.md). Targets specific AI failure modes: statistical priors overriding observed facts, pattern completion beating verification, inheritance blindness, empty-output-as-permission, stale-context-lies. Rules force AI to verify column/association/route/method/gem names before writing, mark assumptions with `[ASSUMPTION]` prefix, check inheritance chains, and re-query after writes. Enabled by default via new `config.anti_hallucination_rules` option (boolean, default: `true`). Set `false` to skip.

### Changed
- **Repositioning: ground truth, not token savings** - the gem's mission is now explicit about what it actually does: stop AI from guessing your Rails app. Token savings are a side-effect, not the product. Updated README headline, "What stops being wrong" section (replaces "Measured token savings"), gemspec summary/description, server.json MCP registry description, docs/GUIDE.md intro, and the tools guide embedded in every generated CLAUDE.md/AGENTS.md/.cursor/rules. The core pitch: AI queries your running app for real schema, real associations, real filters - and writes correct code on the first try instead of iterating through corrections.

## [4.6.0] - 2026-04-04

### Added
- **Integration test suite** - 3 purpose-built Rails 8 apps exercising every gem feature end-to-end:
  - `full_app` - full-featured app (38 gems, 14 models, 15 controllers, 26 views, 5 jobs, 3 mailers, multi-database, ViewComponent, Stimulus, STI, polymorphic, AASM, PaperTrail, FriendlyId, encrypted attributes, CurrentAttributes, Flipper feature flags, Sentry monitoring, Pundit auth, Ransack search, Dry-rb, acts_as_tenant, Docker, Kamal, GitHub Actions CI, RSpec + FactoryBot)
  - `api_app` - API-only app (Products/Orders/OrderItems, namespaced API v1 routes, CLI tool_mode)
  - `minimal_app` - bare minimum app (single model, graceful degradation testing)
- **Master test runner** (`test_apps/run_all_tests.sh`) - validates Doctor, context generation, all 33 introspectors, all 39 MCP tools, Rake tasks, MCP server startup, and app-specific pattern detection across all 3 apps (222 tests)
- All 3 test apps achieve **100/100 AI Readiness Score**

### Fixed
- **Standalone CLI `full_gem_path` crash** - `Gem.loaded_specs.delete_if { |_, spec| !spec.default_gem? }` in the exe file cleared gem specs needed by MCP SDK at runtime (`json-schema` gem's `full_gem_path` returned nil). Added `!ENV["BUNDLE_BIN_PATH"]` guard so cleanup only runs in true standalone mode, not under `bundle exec`. This bug affected ALL `rails-ai-context tool` commands in standalone mode.

### Changed
- Test count: 1621 RSpec examples + 222 integration tests across 3 apps

## [4.5.2] - 2026-04-04

### Added
- **Strong params permit list extraction** - Controller introspector now parses `params.require(:x).permit(...)` calls, returning structured hashes with `requires`, `permits`, `nested`, `arrays`, and `unrestricted` fields. Handles multi-line chains, hash rocket syntax, and `params.permit!` detection
- **N+1 risk levels** - PerformanceCheck now classifies N+1 risks as `[HIGH]` (no preloading), `[MEDIUM]` (partial preloading), or `[low]` (already preloaded). Detects loop patterns in controller actions, recognizes `.includes`/`.eager_load`/`.preload`, and reports per-action context
- **DependencyGraph polymorphic/through/cycles/STI** - `show_cycles` param detects circular dependencies via DFS. `show_sti` param groups STI hierarchies. Polymorphic associations resolve concrete types. Through associations render as two-hop edges. Mermaid: dashed arrows for polymorphic, double arrows for through, dotted for STI
- **Query EXPLAIN support** - New `explain` boolean param wraps SELECT in adapter-specific EXPLAIN (PostgreSQL JSON ANALYZE, MySQL EXPLAIN, SQLite EXPLAIN QUERY PLAN). Parses scan types, indexes, and warnings. Skips row limits for metadata output
- **GetConfig Rails API integration** - Assets detection now uses FrontendFrameworkIntrospector data instead of regex-parsing package.json. Action Cable uses Rails config API with YAML fallback. New Active Storage service and Action Mailer delivery method detection
- **Standardized pagination** - `BaseTool.paginate(items, offset:, limit:, default_limit:)` returns `{ items:, hint:, total:, offset:, limit: }`. Adopted across 7 tools: GetControllers, GetModelDetails, GetRoutes, SearchCode, GetGems, GetHelperMethods, GetComponentCatalog. New `offset`/`limit` params added to GetGems, GetHelperMethods, GetComponentCatalog, SearchCode
- `RailsAiContext::SafeFile` module - safe file reading with configurable size limits, encoding handling, and error suppression
- `RailsAiContext::MarkdownEscape` module - escapes markdown special characters in dynamic content interpolated into headings and prose
- **Provider API key redaction** - ReadLogs now redacts Stripe, SendGrid, Slack, GitHub, GitLab, and npm token patterns

### Fixed
- **Middleware crash protection** - MCP HTTP middleware now rescues exceptions and returns a proper JSON-RPC 2.0 error (`-32603 Internal error`) instead of crashing the Rails request pipeline
- **File read size limits** - Replaced 150+ unguarded `File.read` calls across all introspectors and tools with `SafeFile.read` to prevent OOM on oversized files
- **Cache race condition** - `BaseTool.cached_context` now returns a `deep_dup` of the shared cache, preventing concurrent MCP requests from mutating shared data structures
- **Silent failure warnings** - Introspector failures now propagate as `_warnings` to serializer output; AI clients see a `## Warnings` section listing which sections were unavailable and why
- **Markdown escaping** - Dynamic content in generated markdown is now escaped to prevent formatting corruption from special characters
- **GetConcern nil crash** - Added nil guard for `SafeFile.read` return value
- **GenerateTest type coercion** - Fixed `max + 1` crash when `maximum:` validation stored as string
- **Standalone Bundler conflict** - Resolved gem activation conflict in standalone mode
- **CLI error messages** - Clean error messages for all CLI error paths
- **Rake/init parity** - `rake ai:context` and `init` command now match generator output

### Refactored
- **SLOP audit: ~640 lines removed** - cut superfluous abstractions, dead code, and duplicated patterns
- **CompactSerializerHelper** - extracted shared logic from ClaudeSerializer and OpencodeSerializer, eliminating ~75% duplication
- **StackOverviewHelper consolidation** - moved `project_root`, `detect_service_files`, `detect_job_files`, `detect_before_actions`, `scope_names`, `notable_gems_list`, `arch_labels_hash`, `pattern_labels_hash`, `write_rule_files` into shared module, replacing 30+ duplicate copies across 6 serializers
- **Atomic file writes** - `write_rule_files` uses temp file + rename for crash-safe context file generation
- **ConventionDetector → ConventionIntrospector** - renamed for naming consistency with all 33 other introspectors
- **MarkdownEscape inlined** - single-use module inlined into MarkdownSerializer as private method
- **RulesSerializer deleted** - dead code never called by ContextFileSerializer
- **BaseTool cleanup** - removed dead `auto_compress`, `app_size`, `session_queried?` methods
- **IntrospectionError deleted** - exception class never raised anywhere
- **mobile_paths config removed** - config option never read by any introspector, tool, or serializer
- **server_version** - changed from attr_accessor to method delegating to `VERSION` constant
- **Configuration constants** - extracted `DEFAULT_EXCLUDED_FILTERS`, `DEFAULT_EXCLUDED_MIDDLEWARE`, `DEFAULT_EXCLUDED_CONCERNS` as frozen constants
- **Detail spec consolidation** - merged 5 detail spec files into their base spec counterparts
- **Orphaned spec cleanup** - removed `gem_introspector_spec.rb` duplicate (canonical spec already exists under introspectors/)

### Changed
- Test count: 1621 examples (consolidated from 1658 - no coverage lost, only duplicate/orphaned specs removed)

## [4.4.0] - 2026-04-03

### Added
- **33 introspector enhancements** - every introspector upgraded with new detection capabilities:
  - **SchemaIntrospector**: expression indexes, column comments in static parse, `change_column_default`/`change_column_null` in migration replay
  - **ModelIntrospector**: STI hierarchy detection (parent/children/type column), `attribute` API, enum `_prefix:`/`_suffix:`, `after_commit on:` parsing, inline `private def` exclusion
  - **RouteIntrospector**: route parameter extraction, root route detection, RESTful action flag
  - **JobIntrospector**: SolidQueue recurring job config, Sidekiq config (concurrency/queues), job callbacks (`before_perform`, `around_enqueue`, etc.)
  - **GemIntrospector**: path/git gems from Gemfile, gem group extraction (dev/test/prod)
  - **ConventionDetector**: multi-tenant (Apartment/ActsAsTenant), feature flags (Flipper/LaunchDarkly), error monitoring (Sentry/Bugsnag/Honeybadger), event-driven (Kafka/RabbitMQ/SNS), Zeitwerk detection, STI with type column verification
  - **ControllerIntrospector**: `rate_limit` parsed into structured data (to/within/only), inline `private def` exclusion
  - **StimulusIntrospector**: lifecycle hooks (connect/disconnect/initialize), outlet controller type mapping, action bindings from views (`data-action` parsing)
  - **ViewIntrospector**: `yield`/`content_for` extraction from layouts, conditional layout detection with only/except
  - **TurboIntrospector**: stream action semantics (append/update/remove counts), frame `src` URL extraction
  - **I18nIntrospector**: locale fallback chain detection, locale coverage % per locale
  - **ConfigIntrospector**: cache store options, error monitoring gem detection, job processor config (Sidekiq queues/concurrency)
  - **ActiveStorageIntrospector**: attachment validations (content_type/size), variant definitions
  - **ActionTextIntrospector**: Trix editor customization detection (toolbar/attachment/events)
  - **AuthIntrospector**: OmniAuth provider detection, Devise settings (timeout/lockout/password_length)
  - **ApiIntrospector**: GraphQL resolvers/subscriptions/dataloaders, API pagination strategy detection
  - **TestIntrospector**: shared examples/contexts detection, database cleaner strategy
  - **RakeTaskIntrospector**: task dependencies (`=> :prerequisite`), task arguments (`[:arg1, :arg2]`)
  - **AssetPipelineIntrospector**: Bun bundler, Foundation CSS, PostCSS standalone detection
  - **DevOpsIntrospector**: Fly.io/Render/Railway deployment detection, `docker-compose.yaml` support
  - **ActionMailboxIntrospector**: mailbox callback detection (before/after/around_processing)
  - **MigrationIntrospector**: `change_column_default`, `change_column_null`, `add_check_constraint` action detection
  - **SeedsIntrospector**: CSV loader detection, seed ordering detection
  - **MiddlewareIntrospector**: middleware added via initializers (`config.middleware.use/insert_before`)
  - **EngineIntrospector**: route count + model count inside discovered engines
  - **MultiDatabaseIntrospector**: shard names/keys/count from `connects_to`, improved YAML parsing for nested multi-db configs
  - **ComponentIntrospector**: `**kwargs` splat prop detection
  - **AccessibilityIntrospector**: heading hierarchy (h1-h6), skip link detection, `aria-live` regions, form input analysis (required/types)
  - **PerformanceIntrospector**: polymorphic association compound index detection (`[type, id]`)
  - **FrontendFrameworkIntrospector**: API client detection (Axios/Apollo/SWR/etc.), component library detection (MUI/Radix/shadcn/etc.)
  - **DatabaseStatsIntrospector**: MySQL + SQLite support (was PostgreSQL-only), PostgreSQL dead row counts
  - **ViewTemplateIntrospector**: slot reference detection
  - **DesignTokenIntrospector**: Tailwind arbitrary value extraction

### Fixed
- **Security: SQLite SQL injection** - `database_stats_introspector` used string interpolation for table names in COUNT queries; now uses `conn.quote_table_name`
- **Security: query column redaction bypass** - `SELECT password AS pwd` bypassed redaction; now also matches columns ending in `password`, `secret`, `token`, `key`, `digest`, `hash`
- **Security: log redaction gaps** - added AWS access key (`AKIA...`), JWT token (`eyJ...`), and SSH/TLS private key header patterns
- **Security: HTTP bind wildcard** - non-loopback warning now catches `0.0.0.0` and `::` (was only checking 3 specific addresses)
- **Thread safety: `app_size()` race condition** - `SHARED_CACHE[:context]` read without mutex; now wrapped in `SHARED_CACHE[:mutex].synchronize`
- **Crash: nil callback filter** - `model_introspector` `cb.filter.to_s` crashed on nil filters; added `cb.filter.nil?` guard
- **Crash: fingerprinter TOCTOU** - `File.mtime` after `File.exist?` could raise `Errno::ENOENT` if file deleted between calls; added rescue
- **Crash: tool_runner bounds** - `args[i+1]` access without bounds check; added `i + 1 < args.size` guard
- **Bug: server logs wrong tool list** - logged all 39 `TOOLS` instead of filtered `active_tools` after `skip_tools`; now shows correct count and names
- **Bug: STI false positive** - convention detector flagged `Admin < User` as STI even without `type` column; now verifies parent's table has `type` column via schema.rb
- **Bug: resources bare raise** - `raise "Unknown resource"` changed to `raise RailsAiContext::Error`
- **Config validation** - `http_port` (1-65535), `cache_ttl` (> 0), `max_tool_response_chars` (> 0), `query_row_limit` (1-1000) now validated on assignment

### Changed
- Test count: 1529 (unchanged - all new features tested via integration test against sample app)

## [4.3.3] - 2026-04-02

### Fixed
- **100 bare rescue statements across 46 files** - all replaced with `rescue => e` + conditional debug logging (`$stderr.puts ... if ENV["DEBUG"]`); errors are now visible instead of silently swallowed
- **database_stats introspector orphaned** - `DatabaseStatsIntrospector` was unreachable (not in any preset); added to `:full` preset (32 → 33 introspectors)
- **CHANGELOG date errors** - v4.0.0 corrected from 2026-03-26 to 2026-03-27, v4.2.0 from 2026-03-26 to 2026-03-30 (verified against git commit timestamps)
- **CHANGELOG missing v3.0.1 entry** - added (RubyGems republish, no code changes)
- **CHANGELOG date separator inconsistency** - normalized all version entries to use consistent date separators
- **Documentation preset counts** - CLAUDE.md, README, GUIDE all corrected: `:full` 32→33, `:standard` 14→19 (turbo, auth, accessibility, performance, i18n were added in v4.3.1 but docs not updated)
- **GUIDE.md standard preset table** - added 5 missing introspectors (turbo, auth, accessibility, performance, i18n) to match `configuration.rb`

### Changed
- Full preset: 32 → 33 introspectors (added :database_stats)

## [4.3.2] - 2026-04-02

### Fixed
- **review_changes undefined variable** - `changed_tests` (NameError at runtime) replaced with correct `test_files` variable in `detect_warnings`
- **N+1 introspector O(n*m*k) view scan** - `detect_n_plus_one` now pre-loads all view file contents once via `preload_view_contents` instead of re-globbing per model+association pair
- **atomic write collision** - temp filenames now include `SecureRandom.hex(4)` suffix to prevent concurrent process collisions on the same file
- **bare rescue; end across 7 serializers + 2 tools** - all 16 occurrences replaced with `rescue => e` + stderr logging so errors are visible instead of silently swallowed

### Changed
- Test count: 1176 → 1529 (+353 new tests)
- 26 new spec files covering previously untested tools, serializer helpers, introspectors, and infrastructure (server, engine, resources, watcher)

## [4.3.1] - 2026-04-02

### Fixed
- **performance_check false positives** - now parses `t.index` inside `create_table` blocks (was only parsing `add_index` outside blocks, missing inline indexes)
- **review_changes overflow** - capped at 20 files with 30 diff lines each; remaining files listed without diff to prevent 200K+ char responses
- **get_context ivar cross-check** - now follows `render :other_template` references (create rendering :new on failure no longer shows false positives)
- **generate_test setup block** - always generates `setup do` with factory/fixture/inline fallback; minitest tests no longer reference undefined instance variables
- **session_context auto-tracking** - `text_response()` now auto-records every tool call; `session_context(action:"status")` shows what was queried without manual `mark:` calls
- **search_code AI file exclusion** - excludes CLAUDE.md, AGENTS.md, .claude/, .cursor/, .cursorrules, .github/copilot-instructions.md, .ai-context.json from results
- **diagnose output truncation** - per-section size limits (3K chars each) + total output cap (20K) prevent overflow
- **diagnose NameError classification** - `NameError: uninitialized constant` now correctly classified as `:name_error`, not `:nil_reference`
- **diagnose specific inference** - identifies nil receivers, missing `authenticate_user!`, and `set_*` before_actions from code context
- **onboard purpose inference** - quick mode now infers app purpose from models, jobs, services, gems (e.g., "news aggregation app with RSS, YouTube, Reddit ingestion")
- **onboard adapter resolution** - resolves `static_parse` adapter name from config or gems instead of showing internal implementation detail
- **security_scan transparency** - "no warnings" response now lists which check categories were run (e.g., "SQL injection, XSS, mass assignment")
- **read_logs filename filter** - `available_log_files` now rejects filenames with non-standard characters
- **Phlex view support** - get_view detects Phlex views (.rb), extracts component renders and helper calls
- **Component introspector Phlex** - discovers Phlex components alongside ViewComponent
- **Schema introspector array columns** - detects PostgreSQL `array: true` columns from schema.rb
- **search_code regex injection** - `definition` and `class` match types now escape user input with `Regexp.escape` (previously raw interpolation could crash with metacharacters like `(`, `[`, `{`)
- **sensitive file bypass on macOS** - all 3 `sensitive_file?` implementations now use `FNM_CASEFOLD` flag; `.ENV`, `Master.Key`, `.PEM` variants no longer bypass the block on case-insensitive filesystems
- **doctor silent exception swallowing** - `rescue nil` replaced with `rescue StandardError` + stderr logging; broken health checks are now reported instead of silently skipped
- **context file race condition** - `write_plain` and `write_with_markers` now use atomic write (temp file + rename) to prevent partial writes from concurrent generators
- **performance_introspector O(n*m) scan** - `detect_model_all_in_controllers` now builds a single combined regex instead of scanning each controller once per model
- **HTTP transport non-loopback warning** - MCP server now logs a warning when `http_bind` is set to a non-loopback address (no authentication on the HTTP transport)

### Added
- **`rails_runtime_info`** - live runtime state: DB connection pool, table sizes (PG/MySQL/SQLite), pending migrations, cache stats (Redis hit rate + memory), Sidekiq queue depth, job adapter detection
- **`rails_session_context`** - session-aware context tracking with auto-recording; `action:"status"` shows what tools were called, `action:"summary"` for compressed recap, `action:"reset"` to clear
- **`auto_compress` helper** - BaseTool method that auto-downgrades detail when response approaches 85% of max chars
- **`not_found_response` dedup** - no longer suggests the exact same string the user typed
- **get_frontend_stack Hotwire** - reports Stimulus controllers, Turbo config, importmap pins for Hotwire/importmap apps (not just React/Vue)
- **get_component_catalog guidance** - returns actionable message for partial-based apps: "Use get_partial_interface or get_view"
- **get_context feature enrichment** - `feature:` mode now also searches controllers and services by name when analyze_feature misses them
- **Fingerprinter gem development** - includes gem lib/ directory mtime when using path gem (local dev cache invalidation)

### Changed
- Tool count: 37 → 39
- Test count: 1052 → 1170
- Standard preset now includes turbo, auth, accessibility, performance, i18n (was 14 introspectors, now 19)

## [4.3.0] - 2026-04-01

### Added
- **`rails_onboard`** - narrative app walkthrough (quick/standard/full)
- **`rails_generate_test`** - test scaffolding matching project patterns
- **`rails_diagnose`** - one-call error diagnosis with classification + context + git + logs
- **`rails_review_changes`** - PR/commit review with per-file context + warnings
- **Improved AI instructions** - workflow sequencing, detail guidance, anti-patterns, get_context as power tool

### Changed
- Tool count: 33 → 37
- Test count: 1016 → 1052

## [4.2.3] - 2026-04-01

### Fixed
- **Unicode output** - `rails_get_context` ivar cross-check now renders actual Unicode symbols (✓✗⚠) instead of literal `\u2713` escape sequences
- **Scope name rendering** - all 6 serializers (claude, cursor, copilot, opencode, claude_rules, copilot_instructions) now extract scope names from hash-style scope data instead of dumping raw `{:name=>"active", :body=>"..."}` into output
- **Scope exclusion** - `ModelIntrospector#extract_public_class_methods` now correctly extracts scope names from hash-style scope data so scopes are properly excluded from the class methods listing
- **Pending migrations check** - `Doctor#check_pending_migrations` now uses `MigrationContext#pending_migrations` on Rails 7.1+ instead of the deprecated `ActiveRecord::Migrator.new` API (silently returned nil on modern Rails)
- **SQLite query timeout** - `rails_query` now uses `set_progress_handler` for real statement timeout enforcement on SQLite instead of `busy_timeout` (which only controls lock-wait, not query execution time)
- **ripgrep caching** - `SearchCode.ripgrep_available?` now caches `false` results, avoiding repeated `which rg` system calls on every search when ripgrep is not installed
- **Controller action extraction** - `SearchCode#extract_controller_actions_from_matches` now correctly captures RESTful action names instead of always appending `nil` (was using `match?` which doesn't set `$1`, plus overly broad `[a-z_]+` regex)

### Changed
- Test count: 1003 → 1016

## [4.2.2] - 2026-04-01

### Fixed
- **Vite config detection** - framework plugin detection now checks `.mts`, `.mjs`, `.cts`, `.cjs` extensions in addition to `.ts` and `.js`
- **Component catalog ERB** - no-props no-slots components now generate inline `<%= render Foo.new %>` instead of misleading `do...end` block
- **Custom tools validation** - invalid entries in `config.custom_tools` are now filtered with a clear warning instead of crashing the MCP server with a cryptic `NoMethodError`

### Changed
- Test count: 998 → 1003

## [4.2.1] - 2026-03-31

### Fixed
- **Security: SQL comment stripping** - `rails_query` now strips MySQL-style `#` comments in addition to `--` and `/* */`
- **Security: Regex injection** - PerformanceIntrospector now uses `Regexp.escape` on all interpolated model/association names to prevent regex injection
- **Security: SearchDocs error memoization** - transient index load failures (JSON parse errors, missing file) are no longer cached permanently; subsequent calls retry instead of returning stale errors
- **Security: ReadLogs file parameter** - null byte sanitization + `File.basename` enforcement prevents path traversal via directory separators in file names
- **Security: ReadLogs redaction** - added `cookie`, `session_id`, and `_session` patterns to sensitive data redaction
- **Security: SearchDocs fetch size** - 2MB cap on fetched documentation content prevents memory exhaustion from oversized HTTP responses
- **Security: MigrationAdvisor input validation** - table and column names now validated as safe identifiers; special characters rejected with clear error messages
- **Cache: Fingerprinter watched paths** - added `app/components` to WATCHED_DIRS, `package.json` and `tsconfig.json` to WATCHED_FILES; component catalog and frontend stack tools now invalidate on relevant file changes
- **Schema: static parse skipped tables** - `parse_schema_rb` no longer leaves `current_table` pointing at a skipped table (`schema_migrations`, `ar_internal_metadata`), preventing potential nil access on subsequent column lines
- **Query: CSV newline escaping** - CSV format output now properly quotes cell values containing newlines and carriage returns
- **DependencyGraph: Mermaid node IDs** - model names starting with digits now get an `M` prefix to produce valid Mermaid syntax

### Changed
- Test count: 983 → 998

## [4.2.0] - 2026-03-30

### Added
- New `rails_search_docs` tool: bundled topic index with weighted keyword search, on-demand GitHub fetch for Rails documentation
- New `rails_query` tool: safe read-only SQL queries with defense-in-depth (regex pre-filter + SET TRANSACTION READ ONLY + configurable timeout + row limit + column redaction)
- New `rails_read_logs` tool: reverse file tail with level filtering (debug/info/warn/error/fatal) and sensitive data redaction
- New config options: `query_timeout` (default timeout for SQL queries), `query_row_limit` (max rows returned), `query_redacted_columns` (columns to mask in query results), `allow_query_in_production` (safety gate, default false), `log_lines` (default number of log lines to read)

### Changed
- Tool count: 30 → 33
- Test count: 893 → 983

## [4.1.0] - 2026-03-29

### Added
- New `rails_get_frontend_stack` tool: detects React/Vue/Svelte/Angular, Inertia/react-rails mounting, state management, TypeScript config, monorepo layout, package manager
- New `FrontendFrameworkIntrospector`: parses package.json (JSON.parse with BOM-safe reading), config/vite.json, config/shakapacker.yml, tsconfig.json
- Frontend framework detection covers patterns 3 (hybrid SPA), 4 (API+SPA), and 7 (Turbo Native)
- API introspector: OpenAPI/Swagger spec detection, CORS config parsing, API codegen tool detection (openapi-typescript, graphql-codegen, orval)
- Auth introspector: JWT strategy (devise-jwt, Doorkeeper config), HTTP token auth detection
- Turbo introspector: Turbo Native detection (turbo_native_app?, native navigation patterns, native conditionals in views)
- Gem introspector: 6 new notable gems (devise-jwt, rswag-api, rswag-ui, grape-swagger, apipie-rails, hotwire-native-rails)
- Optional config: `frontend_paths`, `mobile_paths` (auto-detected if nil, user override for edge cases)
- Install generator: re-install now updates `ai_tools` and `tool_mode` selections, adds missing config sections without removing existing settings
- Install generator: prompts to remove generated files when AI tools are deselected (per-tool chooser)
- `rails ai:context:cursor` (and other format tasks) now auto-adds the format to `config.ai_tools`
- CLI tool_runner: warns on invalid enum values instead of silent fallback

### Fixed
- `analyze_feature` crash on nil/empty input - now returns helpful prompt
- `analyze_feature` with nonexistent feature - returns clean "no match" instead of scaffolded empty sections
- `migration_advisor` crash on empty/invalid action - now validates with "Did you mean?" suggestions
- `migration_advisor` generates broken SQL with empty table/column - now validates required params
- `migration_advisor` doesn't normalize table names - "Post" now auto-resolves to "posts"
- `migration_advisor` no duplicate column/index detection - now warns on existing columns, indexes, and FKs
- `migration_advisor` no nonexistent column detection - now warns on remove/rename/change_type/add_index for missing columns
- `edit_context` "File not found" with no hint - now suggests full path with "Did you mean?"
- `performance_check` model filter fails for multi-word models - "UserProfile" now resolves to "user_profiles"
- `performance_check` unknown model silently ignored - now returns "not found" with suggestions
- `turbo_map` stream filter misses dynamic broadcasts - multi-line call handling + snippet fallback + fuzzy prefix matching
- `turbo_map` controller filter misses job broadcasts - now includes broadcasts matching filtered subscriptions' streams
- `security_scan` wrong check name examples - added CHECK_ALIASES mapping (CheckXSS → CheckCrossSiteScripting, sql → CheckSQL, etc.)
- `search_code` unknown match_type silently ignored - now returns error with valid values
- `validate` unknown level silently ignored - now returns error with valid values
- `get_view` no "Did you mean?" on wrong controller - now uses `find_closest_match`
- `get_context` plural model name ("Posts") produces mixed output - now normalizes via singularize/classify, fails fast when not found
- `component_catalog` specific component returns generic "no components" - now acknowledges the input
- `stimulus` doesn't strip `_controller` suffix - now auto-strips for lookup
- `controller_introspector_spec` rate_limit test crashes on Rails 7.1 - split into source-parsing test (no class loading)

### Changed
- Full preset: 31 → 32 introspectors (added :frontend_frameworks)
- Tool count: 29 → 30
- Test count: 817 → 893
- Install generator always writes `config.ai_tools` and `config.tool_mode` uncommented for re-install detection

## [4.0.0] - 2026-03-27

### Added

- 4 new MCP tools: `rails_get_component_catalog`, `rails_performance_check`, `rails_dependency_graph`, `rails_migration_advisor`
- 3 new introspectors: ComponentIntrospector (ViewComponent/Phlex), AccessibilityIntrospector (ARIA/a11y), PerformanceIntrospector (N+1/indexes)
- ViewComponent/Phlex component catalog: props, slots, previews, sidecar assets, usage examples
- Accessibility scanning: ARIA attributes, semantic HTML, screen reader text, alt text, landmark roles, accessibility score
- Performance analysis: N+1 query risks, missing counter_cache, missing FK indexes, Model.all anti-patterns, eager load candidates
- Dependency graph generation in Mermaid or text format
- Migration code generation with reversibility warnings and affected model detection
- Component and accessibility split rules for Claude, Cursor, Copilot, and OpenCode
- Stimulus cross-controller composition detection
- Stimulus import graph and complexity metrics
- Turbo 8 morph meta and permanent element detection
- Turbo Drive configuration scanning (data-turbo-*, preload)
- Form builder detection (form_with, simple_form, formtastic)
- Semantic HTML element counting
- DaisyUI theme and component detection
- Font loading strategy detection (@font-face, Google Fonts, system fonts)
- CSS @layer and PostCSS plugin detection
- Convention fingerprint with SolidQueue/SolidCache/SolidCable awareness
- Dynamic directory detection in app/
- Controller rate_limit and rescue_from extraction
- Model encryption, normalizes, and generates_token_for details
- Schema check constraints, enum types, and generated columns
- Factory trait extraction and test count by category
- Expanded NOTABLE_GEMS list (30+ new gems including dry-rb, Solid stack)
- Job retry_on/discard_on and perform argument extraction

### Changed

- Standard preset: 13 → 14 introspectors (added :components)
- Full preset: 28 → 31 introspectors (added :components, :accessibility, :performance)
- Tool count: 25 → 29
- Test count: 681 → 806 examples
- Combustion test app expanded with Stimulus controllers, ViewComponents, accessible views, factories

## [3.1.0] - 2026-03-26

### Fixed

- **Consistent input normalization across all tools** - AI agents and humans can now use any casing or format and tools resolve correctly:
  - `model=user_profile` (snake_case) now resolves to `UserProfile` via `.underscore` comparison in `get_model_details`.
  - `table=Post` (model name) now resolves to `posts` table via `.underscore.pluralize` normalization in `get_schema`.
  - `controller=PostsController` now works in `get_view` and `get_routes` - both strip `Controller`/`_controller` suffix consistently, matching `get_controllers` behavior.
  - `controller=posts_controller` no longer leaves a trailing underscore in route matching.
  - `stimulus=PostStatus` (PascalCase) now resolves to `post_status` via `.underscore` conversion in `get_stimulus`.
  - `partial=_status_badge` (underscore-prefixed, no directory) now searches recursively across all view directories in `get_partial_interface`.
  - `model=posts` (plural) now tries `.singularize` for test file lookup in `get_test_info`.
- **Smarter fuzzy matching** - `BaseTool.find_closest_match` now prefers shortest substring match (so `Post` suggests `posts`, not `post_comments`) and supports underscore/classify variant matching.
- **File path suggestions in validate** - `files=["post.rb"]` now suggests `app/models/post.rb` when the file isn't found at the given path.
- **Empty parameter validation** - `edit_context` now returns friendly messages for empty `file` or `near` parameters instead of hard errors.

## [3.0.1] - 2026-03-26

### Changed
- Patch for RubyGems publish - no code changes from v3.0.0.

## [3.0.0] - 2026-03-26

### Removed

- **Windsurf support dropped** - removed `WindsurfSerializer`, `WindsurfRulesSerializer`, `.windsurfrules` generation, and `.windsurf/rules/` split rules. v2.0.5 is the last version with Windsurf support. If you need Windsurf context files, pin `gem "rails-ai-context", "~> 2.0"` in your Gemfile.

### Added

- **CLI tool support** - all 25 MCP tools can now be run from the terminal: `rails 'ai:tool[schema]' table=users detail=full`. Also via Thor CLI: `rails-ai-context tool schema --table users`. `rails ai:tool` lists all tools. `--help` shows per-tool help auto-generated from input_schema. `--json` / `JSON=1` for JSON envelope. Tool name resolution: `schema` → `get_schema` → `rails_get_schema`.
- **`tool_mode` config** - `:mcp` (default, MCP primary + CLI fallback) or `:cli` (CLI only, no MCP server needed). Selected during install and first `rails ai:context` run.
- **ToolRunner** - `lib/rails_ai_context/cli/tool_runner.rb` handles CLI tool execution: arg parsing, type coercion from input_schema, required param validation, enum checking, fuzzy tool name suggestions on typos.
- **ToolGuideHelper** - shared serializer module renders tool reference sections with MCP or CLI syntax based on `tool_mode`, with MANDATORY enforcement + CLI escape hatch. 3-column tool table (MCP | CLI | description).
- **Copilot `excludeAgent`** - MCP tools instruction file uses `excludeAgent: "code-review"` (code review can't invoke MCP tools, saves 4K char budget).
- **`.mcp.json` auto-create** - `rails ai:context` automatically creates `.mcp.json` when `tool_mode` is `:mcp` and the file doesn't exist. Existing apps upgrading to v3.0.0 get it without re-running the install generator.
- **Full config initializer** - generated initializer documents every configuration option organized by section (AI Tools, Introspection, Models & Filtering, MCP Server, File Size Limits, Extensibility, Security, Search).
- **Cursor MDC compliance spec** - 26 tests validating MDC format: frontmatter fields, rule types, glob syntax, line limits.
- **Copilot compliance spec** - 25 tests validating instruction format: applyTo, excludeAgent, file naming, content quality.

### Changed

- Serializer count reduced from 6 to 5 (Claude, Cursor, Copilot, OpenCode, JSON).
- Install generator renumbered (4 AI tool options instead of 5) + MCP opt-in step.
- Cursor glob-based rules no longer combine `globs` + `description` (pure Type 2 auto-attach per Cursor best practices).
- MCP tool instructions use MANDATORY enforcement with CLI escape hatch - AI agents use tools when available, fall back to CLI or file reading when not.
- All CLI examples use zsh-safe quoting: `rails 'ai:tool[X]'` (brackets are glob patterns in zsh).
- README rewritten with real-world workflow examples, categorized tool table, MCP vs CLI showcase.

## [2.0.5] - 2026-03-25

### Changed

- **Task-based MCP tool instructions** - all 6 serializers (Claude, Cursor, Copilot, Windsurf, OpenCode) rewritten from tool-first to task-first: "What are you trying to do?" → exact tool call. 7 task categories: understand a feature, trace a method, add a field, fix a controller, build a view, write tests, find code. Every AI agent now understands which tool to use for any task.
- **Concern detail:"full" bug fix** - `\b` after `?`/`!` prevented 13 of 15 method bodies from being extracted. All methods now show source code.

## [2.0.4] - 2026-03-25

### Added

- **Orphaned table detection** - `get_schema` standard mode flags tables with no ActiveRecord model: "⚠ Orphaned tables: content_calendars, post_comments"
- **Concern method source code** - `get_concern(name:"X", detail:"full")` shows method bodies inline, same pattern as callbacks tool.
- **analyze_feature: inherited filters** - shows `authenticate_user! (from ApplicationController)` in controller section.
- **analyze_feature: code-ready route helpers** - `post_path(@record)`, `posts_path` inline with routes.
- **analyze_feature: service test gaps** - checks services for missing test files, not just models/controllers/jobs.
- **All 6 serializers updated** - Claude, Cursor, Copilot, Windsurf, OpenCode all document trace mode, concern source, orphaned tables, inherited filters.

## [2.0.3] - 2026-03-25

### Added

- **Trace mode 100%** - `match_type:"trace"` now shows 7 sections: definition with class/module context, source code, internal calls, sibling methods (same file), app callers with route chain hints, and test coverage (separated from app code). Zero follow-up calls needed.
- **README rewrite** - neuro marketing techniques: loss aversion hook, measured token savings table, trace output inline, architecture diagram. 456→261 lines.

## [2.0.2] - 2026-03-25

### Added

- **`match_type:"trace"` in search_code** - full method picture in one call: definition + source code + all callers grouped by type (Controller/Model/View/Job/Service/Test) + internal calls. One call replaces 3-4 separate searches.
- **`match_type:"call"`** - find call sites only, excluding definitions.
- **Smart result limiting** - <10 shows all, 10-100 shows half, >100 caps at 100. Pagination via `offset:` param.
- **`exclude_tests:true`** - skip test/spec/features directories in search results.
- **`group_by_file:true`** - group search results by file with match counts.
- **Inline cross-references** - schema shows model name + association count per table, routes show controller filters inline, views use pipe-separated metadata.
- **Test template generation** - `get_test_info(detail:"standard")` includes a copy-paste test template matching the app's patterns (Minitest/RSpec, Devise sign_in, fixtures).
- **Interactive AI tool selection** - install generator and `rails ai:context` prompt users to select which AI tools they use (Claude, Cursor, Copilot, Windsurf, OpenCode). Selection saved to `config.ai_tools`.
- **Brakeman in validate** - `rails_validate(level:"rails")` now runs Brakeman security checks inline alongside syntax and semantic checks.

### Fixed

- **Documentation audit** - fixed max_tool_response_chars reference (120K→200K), added missing search_code params to GUIDE, added config.ai_tools to config reference.

## [2.0.1] - 2026-03-25

### Fixed

- **MCP-first mandatory workflow in all serializers** - all 6 serializer outputs (Claude, Cursor, Copilot, Windsurf, OpenCode) now use "MANDATORY, Use Before Read" language with structured workflow, anti-patterns table, and "Do NOT Bypass" rules. AI agents are explicitly instructed to never read reference files directly.
- **27 type-safety bugs in serializers** - fixed `.keys` called on Array values (same pattern as #14) across `design_system_helper.rb`, `get_design_system.rb`, `markdown_serializer.rb`, and `stack_overview_helper.rb`.
- **Strong params JSONB check** - no longer skips the entire check when JSONB columns exist. Plain-word params allowed (could be JSON keys), `_id` params still validated.
- **Strong params test skip on Ruby < 3.3** - test now skips gracefully when Prism is unavailable, matching the tool's own degradation.
- **Issue #14** - `multi_db[:databases].keys` crash on Array fixed.
- **Search code NON_CODE_GLOBS** - excludes lock files, docs, CI configs, generated context from all searches.

## [2.0.0] - 2026-03-24

### Added

- **9 new MCP tools (16→25)** - `rails_get_concern` (concern methods + includers), `rails_get_callbacks` (execution order + source), `rails_get_helper_methods` (app + framework helpers + view refs), `rails_get_service_pattern` (interface, deps, side effects), `rails_get_job_pattern` (queue, retries, guards, broadcasts), `rails_get_env` (env vars, credentials keys, external services), `rails_get_partial_interface` (locals contract + usage), `rails_get_turbo_map` (stream/frame wiring + mismatch warnings), `rails_get_context` (composite cross-layer tool).
- **Phase 1 improvements** - scope definitions include lambda body, controller actions show instance variables + private methods called inline, Stimulus shows HTML data-attributes + reverse view lookup.
- **3 new validation rules** - instance variable consistency (view uses @foo but controller never sets it), Turbo Stream channel matching (broadcast without subscriber), respond_to template existence.
- **`rails_security_scan` tool** - Brakeman static security analysis via MCP. Detects SQL injection, XSS, mass assignment, and more. Optional dependency - returns install instructions if Brakeman isn't present. Supports file filtering, confidence levels (high/medium/weak), specific check selection, and three detail levels (summary/standard/full).
- **`config.skip_tools`** - users can now exclude specific built-in tools: `config.skip_tools = %w[rails_security_scan]`. Defaults to empty (all 39 tools active).
- **Schema index hints** - `get_schema` standard detail now shows `[indexed]`/`[unique]` on columns, saving a round-trip to full detail.
- **Enum backing types** - `get_model_details` now shows integer vs string backing: `status: pending(0), active(1) [integer]`.
- **Search context lines default 2** - `search_code` now returns 2 lines of context by default (was 0). Eliminates follow-up calls for context.
- **`match_type` parameter for search** - `search_code` supports `match_type:"definition"` (only `def` lines) and `match_type:"class"` (only `class`/`module` lines).
- **Controller respond_to formats** - `get_controllers` surfaces `respond_to` formats (html, json) already collected by introspector.
- **Config database/auth/assets detection** - `get_config` now shows database adapter, auth framework (Devise/Rodauth/etc), and assets stack (Tailwind/esbuild/etc).
- **Frontend stack detection** - `get_conventions` detects frontend dependencies from package.json (Tailwind, React, TypeScript, Turbo, etc).
- **Validate fix suggestions** - semantic warnings now include actionable fix hints (migration commands, `dependent:` options, index commands).
- **Prism fallback indicator** - `validate` reports when Prism is unavailable so agents know semantic checks may be skipped.
- **Factory attributes/traits** - `get_test_info` full detail parses factory files to show attributes and traits, not just names.
- **Partial render locals** - `get_view` standard detail shows what locals each partial receives based on render call scanning.
- **Edit context header** - `get_edit_context` shows enclosing class/method name in response header.
- **Gem config location hints** - `get_gems` shows config file paths for 17 common gems (Devise, Sidekiq, Pundit, etc).
- **Stimulus lifecycle detection** - `get_stimulus` detects connect/disconnect/initialize lifecycle methods.
- **Route params inline** - `get_routes` standard detail shows required params: `[id]`, `[user_id, id]`.
- **Feature test coverage gaps** - `analyze_feature` reports which models/controllers/jobs lack test files.
- **Model macros surfaced** - `get_model_details` now shows `has_secure_password`, `encrypts`, `normalizes`, `generates_token_for`, `serialize`, `store`, `broadcasts`, attachments - all previously collected but hidden.
- **Model delegations and constants** - `get_model_details` shows `delegate :x, to: :y` and constants like `STATUSES = %w[pending completed]`.
- **Association FK column hints** - `get_model_details` shows `(fk: user_id)` on belongs_to associations.
- **Schema model references** - `get_schema` full detail shows which ActiveRecord models reference each table.
- **Schema column comments** - `get_schema` full detail shows database column comments when present.
- **Action Cable adapter detection** - `get_config` detects Action Cable adapter from cable.yml.
- **Gem version display** - `get_gems` shows version numbers from Gemfile.lock.
- **Package manager detection** - `get_conventions` detects npm/yarn/pnpm/bun from lock files.
- **Exact match search** - `search_code` supports `exact_match:true` for whole-word matching with `\b` boundaries.
- **Scaled defaults for big apps** - increased `max_tool_response_chars` (120K→200K), `max_search_results` (100→200), `max_validate_files` (20→50), `cache_ttl` (30→60s), `max_file_size` (2MB→5MB), `max_test_file_size` (500KB→1MB), `max_view_total_size` (5MB→10MB), `max_view_file_size` (500KB→1MB). Schema standard pagination 15→25, full 5→10. Methods shown per model 15→25. Routes standard 100→150.
- **AI-optimal tool ordering** - schema standard sorts tables by column count (complex first), model listing sorts by association count (central models first). Stops AI from missing important tables/models buried alphabetically.
- **Cross-reference navigation hints** - schema single-table suggests `rails_get_model_details`, model detail suggests `rails_get_controllers` + `rails_get_schema` + `rails_analyze_feature`, controller detail suggests `rails_get_routes` + `rails_get_view`. Reduces AI round-trips.
- **Schema adapter in summary** - `get_schema` summary shows database adapter (postgresql/mysql/sqlite3) so AI knows query syntax immediately.
- **App size detection** - `BaseTool.app_size` returns `:small`/`:medium`/`:large` based on model/table count for auto-tuning.
- **Doctor checks for Prism and Brakeman** - `rails ai:doctor` now reports availability of Prism parser and Brakeman security scanner.

### Fixed

- **JS fallback validator false-positives** - escaped backslashes before string-closing quotes (`"path\\"`) no longer cause false bracket mismatch errors. Replaced `prev_char` check with proper `escaped` toggle flag.

## [1.3.1] - 2026-03-23

### Fixed

- **Documentation audit** - updated tool count from 14 to 15 across README, GUIDE, CONTRIBUTING, server.json. Added `rails_get_design_system` documentation section to GUIDE.md. Updated SECURITY.md supported versions. Fixed spec count in CLAUDE.md. Added `rails_get_design_system` to README tool table. Updated `rails_analyze_feature` description to reflect full-stack discovery (services, jobs, views, Stimulus, tests, related models, env deps).
- **analyze_feature crash on complex models** - added type guards (`is_a?(Hash)`, `is_a?(Array)`) to all data access points preventing `no implicit conversion of Symbol into Integer` errors on models with many associations or complex data.

## [1.3.0] - 2026-03-23

### Added

- **Full-stack `analyze_feature` tool** - now discovers services (AF1), jobs with queue/retry config (AF2), views with partial/Stimulus refs (AF3), Stimulus controllers with targets/values/actions (AF4), test files with counts (AF5), related models via associations (AF6), concern tracing (AF12), callback chains (AF13), channels (AF10), mailers (AF11), and environment variable dependencies (AF9). One call returns the complete feature picture.
- **Modal pattern extraction** (DS1) - detects overlay (`fixed inset-0 bg-black/50`) and modal card patterns
- **List item pattern extraction** (DS5) - detects repeating card/item patterns from views
- **Shared partials with descriptions** (DS7) - scans `app/views/shared/` and infers purpose (flash, navbar, status badge, loading, modal, etc.)
- **"When to use what" decision guide** (DS8) - explicit rules: primary button for CTAs, danger for destructive, when to use shared partials
- **Bootstrap component extraction** (DS13-DS15) - detects `btn-primary`, `card`, `modal`, `form-control`, `badge`, `alert`, `nav` patterns from Bootstrap apps
- **Tailwind `@apply` directive parsing** (DS16) - extracts named component classes from CSS `@apply` rules
- **DaisyUI/Flowbite/Headless UI detection** (DS17) - reports Tailwind plugin libraries from package.json
- **Animation/transition inventory** (DS19) - extracts `transition-*`, `duration-*`, `animate-*`, `ease-*` patterns
- **Smarter JSONB strong params check** (V1) - only skips params matching JSON column names, validates the rest
- **Route-action fix suggestions** (V2) - suggests "add `def action; end`" when route exists but action is missing

### Fixed

- **`self` filtered from class methods** (B2/MD1) - no longer appears in model class method lists
- **Rules serializer methods cap raised to 20** (RS1) - uses introspector's pre-filtered methods directly instead of redundant re-filtering
- **oklch token noise filtered** (DS21) - complex color values (oklch, calc, var) hidden from summary, only shown in `detail:"full"`

## [1.2.1] - 2026-03-23

### Fixed

- **New models now discovered via filesystem fallback** - when `ActiveRecord::Base.descendants` misses a newly created model, the introspector scans `app/models/*.rb` and constantizes them. Fixes model invisibility until MCP restart.
- **Devise meta-methods no longer fill class/instance method caps** - filtered 40+ Devise-generated methods (authentication_keys=, email_regexp=, password_required?, etc.). Source-defined methods now prioritized over reflection-discovered ones.
- **Controller `unless:`/`if:` conditions now extracted** - filters like `before_action :authenticate_user!, unless: :devise_controller?` now show the condition. Previously silently dropped.
- **Empty string defaults shown as `""`** - schema tool now renders `""` instead of a blank cell for empty string defaults. AI can distinguish "no default" from "empty string default".
- **Implicit belongs_to validations labeled** - `presence on user` from `belongs_to :user` now shows `_(implicit from belongs_to)_` and filters phantom `(message: required)` options.
- **Array columns shown as `type[]`** in generated rules - `string` columns with `array: true` now render as `string[]` in schema rules.
- **External ID columns no longer hidden** - columns like `stripe_checkout_id` and `stripe_payment_id` are now shown in schema rules. Only conventional Rails FK columns (matching a table name) are filtered.
- **Column defaults shown in generated rules** - columns with non-nil defaults now show `(=value)` inline.
- **`analyze_feature` matches models by table name and underscore form** - `feature:"share"` now finds `PostShare` (via `post_shares` table and `post_share` underscore form), not just exact model name substring.

## [1.2.0] - 2026-03-23

### Added

- **Design system extraction** - ViewTemplateIntrospector now extracts canonical page examples (real HTML/ERB snippets from actual views), full color palette with semantic roles (primary/danger/success/warning), typography scale (sizes, weights, heading styles), layout patterns (containers, grids, spacing scale), responsive breakpoint usage, interactive state patterns (hover/focus/active/disabled), dark mode detection, and icon system identification.
- **New MCP tool: `rails_get_design_system`** - dedicated tool (15th) returns the app's design system: color palette, component patterns with real HTML examples, typography, layout conventions, responsive breakpoints. Supports `detail` parameter (summary/standard/full). Total MCP tools: 15.
- **DesignSystemHelper serializer module** - replaces flat component listings with actionable design guidance across all output formats (Claude, Cursor, Windsurf, Copilot, OpenCode). Shows components with semantic roles, canonical page examples in split rules, and explicit design rules.
- **DesignTokenIntrospector semantic categorization** - tokens now grouped into colors/typography/spacing/sizing/borders/shadows. Enhanced Tailwind v3 parsing for fontSize, spacing, borderRadius, and screens.

### Changed

- **"UI Patterns" section renamed to "Design System"** - richer content with color palette, typography, components, spacing conventions, interactive states, and design rules.
- **Design tokens consumed for the first time** - `context[:design_tokens]` data was previously extracted but never rendered. Now merged into design system output in all serializers and the new MCP tool.

## [1.1.1] - 2026-03-23

### Added

- **Full-preset stack overview in all serializers** - compact mode now surfaces summary lines for auth, Hotwire/Turbo, API, I18n, ActiveStorage, ActionText, assets, engines, and multi-database in generated context files (CLAUDE.md, AGENTS.md, .windsurfrules, and all split rules). Previously this data was only available via MCP tools.
- **`rails_analyze_feature` in all tool reference sections** - the 14th tool (added in v1.0.0) was missing from serializer output. Now listed in all generated files across Claude, Cursor, Windsurf, Copilot, and OpenCode formats.

### Fixed

- **Tool count corrected from 13 to 14** across all serializers to reflect `rails_analyze_feature` added in v1.0.0.

## [1.1.0] - 2026-03-23

### Changed

- **Default preset changed to `:full`** - all 28 introspectors now run by default, giving AI assistants richer context out of the box. Introspectors that don't find relevant data return empty hashes with zero overhead. Use `config.preset = :standard` for the previous 13-core default.

## [1.0.0] - 2026-03-23

### Added

- **New composite tool: `rails_analyze_feature`** - one call returns schema + models + controllers + routes for a feature area (e.g., `rails_analyze_feature(feature:"authentication")`). Total MCP tools: 14.
- **Custom tool registration API** - `config.custom_tools << MyCompany::PolicyCheckTool` lets teams extend the MCP server with their own tools.
- **Structured error responses with fuzzy suggestions** - `not_found_response` helper in BaseTool with "Did you mean?" fuzzy matching (substring + prefix) and `recovery_action` hints. Applied to schema, models, controllers, and stimulus lookups. AI agents self-correct on first retry.
- **Cache keys on paginated responses** - every paginated response includes `cache_key` from fingerprint so agents detect stale data between page fetches. Applied to schema, models, controllers, and stimulus pagination.

### Changed

- **LLM-optimized tool descriptions (all 14 tools)** - every description now follows "what it does / Use when: / key params" format so AI agents pick the right tool on first try.

## [0.15.10] - 2026-03-23

### Changed

- **Gemspec description rewritten** - repositioned from feature list to value proposition: mental model, semantic validation, cross-file error detection.

## [0.15.9] - 2026-03-23

### Added

- **Deep diagnostic checks in `rails ai:doctor`** - upgraded from 13 shallow file-existence checks to 20 deep checks: pending migrations, context file freshness, .mcp.json validation, introspector health (dry-runs each one), preset coverage (detects features not in preset), .env/.master.key gitignore check, auto_mount production warning, schema/view size vs limits.

## [0.15.8] - 2026-03-23

### Added

- **Semantic validation (`level:"rails"`)** - `rails_validate` now supports `level:"rails"` for deep semantic checks beyond syntax: partial existence, route helper validity, column references vs schema, strong params vs schema columns, callback method existence, route-action consistency, `has_many` dependent options, missing FK indexes, and Stimulus controller file existence.

## [0.15.7] - 2026-03-22

### Improved

- **Hybrid filter extraction** - controller filters now use reflection for complete names (handles inheritance + skips), with source parsing from the inheritance chain for only/except constraints.
- **Callback source fallback** - when reflection returns nothing (e.g. CI), falls back to parsing callback declarations from model source files.
- **ERB validation accuracy** - in-process compilation with `<%=` → `<%` pre-processing and yield wrapper eliminates false positives from block-form helpers.
- **Schema static parser** - now extracts `null: false`, `default:`, `array: true` from schema.rb columns, and parses `add_foreign_key` declarations.
- **Array column display** - schema tool shows PostgreSQL array types as `string[]`, `integer[]`, etc.
- **Concern test lookup** - `rails_get_test_info(model:"PlanLimitable")` searches concern test paths.
- **Controller flexible matching** - underscore-based normalization handles CamelCase, snake_case, and slash notation consistently.

## [0.15.6] - 2026-03-22

### Added

- **7 new configurable options** - `excluded_controllers`, `excluded_route_prefixes`, `excluded_concerns`, `excluded_filters`, `excluded_middleware`, `search_extensions`, `concern_paths` for stack-specific customization.
- **Configurable file size limits** - `max_file_size`, `max_test_file_size`, `max_schema_file_size`, `max_view_total_size`, `max_view_file_size`, `max_search_results`, `max_validate_files` all exposed via `Configuration`.
- **Class methods in model detail** - `rails_get_model_details` now shows class methods section.
- **Custom validate methods** - `validate :method_name` calls extracted from source and shown in model detail.

### Fixed

- **Schema defaults always visible** - Null and Default columns always shown (NOT NULL marked bold). Previous token-saving logic accidentally hid critical migration data.
- **Optional associations** - `belongs_to` with `optional: true` now shows `[optional]` flag.
- **Concern methods inline** - shows public methods from concern source files (e.g. `Publishable - publishable?, publish!`).
- **MCP tool error messages** - all tools now show available values on error/not-found for AI self-correction.

## [0.15.5] - 2026-03-22

### Fixed

- **ERB validation** - now catches missing `<% end %>` by compiling ERB to Ruby then syntax-checking the result (was only checking ERB tag syntax).
- **Controller namespace format** - accepts both `Bonus::CrisesController` and `bonus/crises` (cross-tool consistency).
- **Layouts discoverable** - `controller:"layouts"` now works in view tool.
- **Validate error detail** - Ruby shows up to 5 error lines, JS shows 3 (was truncated to 1).
- **Invalid/empty regex** - early validation with clear error messages instead of silent fail.
- **Route count accuracy** - shows filtered count when `app_only:true`, not unfiltered total.
- **Namespace test lookup** - supports `bonus/crises` format and flat test directories.
- **Empty inputs** - `near:""` in edit_context and `pattern:""` in search return helpful errors.

## [0.15.4] - 2026-03-22

### Fixed

- **View subfolder paths** - listings now show full relative paths (`admin/comments/index.html.erb`) instead of just basenames.
- **Controller flexible matching** - `"posts"`, `"PostsController"`, `"postscontroller"` all resolve (matches other tools' forgiving lookup).
- **View path traversal** - explicit `..` and absolute path rejection before any filesystem operation.
- **Schema case-insensitive** - table lookup now case-insensitive (matches models/routes/etc.).
- **limit:0 silent empty** - uses default instead of returning empty results.
- **offset past end** - shows "Use `offset:0` to start over" instead of empty response.
- **Search ordering** - deterministic results via `--sort=path` on ripgrep.
- **Generated context prepended** - `<!-- BEGIN rails-ai-context -->` section now placed at top of existing files (AI reads top-to-bottom, may truncate at token limits).

### Added

- **Pagination on models, controllers, stimulus** - `limit`/`offset` params (default 50) with "end of results" hints. Prevents token bombs on large apps.

## [0.15.3] - 2026-03-22

### Fixed

- **Schema `add_index` column parsing** - option keys (e.g. `unique`, `name`) were being picked up as column names (PR #12).
- **Windsurf test command** - extracted `TestCommandDetection` shared module; Windsurf now shows specific test command instead of generic "Run tests after changes".

### Changed

- **Documentation** - updated all docs (README, CLAUDE.md, GUIDE.md, SECURITY.md, CHANGELOG, server.json, install generator) to match v0.15.x codebase. Fixed spec counts, file counts, preset counts, config options, and supported versions.

## [0.15.2] - 2026-03-22

### Fixed

- **Test command detection** - Serializers now use detected test framework (minitest → `rails test`, rspec → `bundle exec rspec`) instead of hardcoding `bundle exec rspec`. Default is `rails test` (the Rails default). Contributed by @curi (PR #13).

## [0.15.1] - 2026-03-22

### Fixed

- **Copilot serializer** - Show all model associations (not capped at 3), use human-readable architecture/pattern labels.
- **OpenCode rules serializer** - Filter framework controllers (Devise) from AGENTS.md output, show all associations, match `before_action` with `!`/`?` suffixes.

## [0.15.0] - 2026-03-22

### Security

- **Sensitive file blocking** - `search_code` and `get_edit_context` now block access to `.env*`, `*.key`, `*.pem`, `config/master.key`, `config/credentials.yml.enc`. Configurable via `config.sensitive_patterns`.
- **Credentials key names redacted** - Replaced `credentials_keys` (exposed names like `stripe_secret_key`) with `credentials_configured` boolean. No more information disclosure via JSON output or MCP resources.
- **View content size cap** - `collect_all_view_content` capped at 5MB total / 500KB per file to prevent memory exhaustion.
- **Schema file size limits** - 10MB limit on `schema.rb`/`structure.sql` parsing. Cached `schema.rb` reads to avoid re-reading per table.

### Added

- **Token optimization (~1,500-2,700 tokens/session saved)**:
  - Filter framework filters (`verify_authenticity_token`, etc.) from controller output
  - Filter framework/gem concerns (`Devise::*`, `Turbo::*`, `*::Generated*`) from models
  - Combine duplicate PUT/PATCH routes into single `PATCH|PUT` entry
  - Only show Nullable/Default columns when they have meaningful values
  - Drop gem version numbers from default output
  - Single HTML naming hint for Stimulus (not per-controller)
  - Only show non-default middleware and initializers in config
  - Group sibling controllers/routes with identical structure
  - Compress repeated Tailwind classes in view full output
  - Strip inline SVGs from view content
  - Separate active vs lifecycle-only Stimulus controllers

### Fixed

- **Controller staleness** - Source-file parsing for actions/filters instead of Ruby reflection. Filesystem discovery for new controllers not yet loaded as classes.
- **Schema `t.index` format** - Parse indexes inside `create_table` blocks (not just `add_index` outside).
- **Stimulus nested values** - Brace-depth counting for single-line `{ active: { type: String, default: "overview" } }`.
- **Stimulus phantom `type:Number`** - Exclude `type`/`default` as value names (JS keywords, not Stimulus values).
- **Search context_lines** - Use `--field-context-separator=:` for ripgrep `-C` output compatibility.
- **Schema defaults** - Supplement live DB nil defaults with values from `schema.rb`.
- **Config missing data** - Added `queue_adapter` and `mailer` settings to config introspector and tool.
- **View garbled fields** - Only extract from `@variable.field` patterns (not arbitrary method chains).
- **View shared partials** - `controller:"shared"` now finds partials in `app/views/shared/`.
- **View full detail** - Lists available controllers when no controller specified.
- **Edit context hint** - "Also found" only shown for matches outside the context window.
- **Model file structure** - Compressed to single-line format.
- **Strong params body** - Action detail now shows the actual `permit(...)` call.
- **AR-generated methods** - Filter `build_*`, `*_ids=`, etc. from model instance methods.

## [0.14.0] - 2026-03-20

### Fixed

- **Schema 0 indexes** - Fixed composite index parsing in schema.rb (regex didn't match array syntax) and structure.sql (`.first` only took first column). Both single and composite indexes now extracted correctly.
- **Stale routes after editing routes.rb** - Route introspector now calls `routes_reloader.execute_if_updated` to force Rails to reload routes before extraction.
- **Config "not available"** - Added `:config` to `:standard` preset. Was `:full` only, so default users never saw config data.
- **Stimulus values lost name** - Fixed parsing for both simple (`name: Type`) and complex (`name: { type: Type, default: val }`) formats. Now shows `max: Number (default: 3)`.
- **Model concerns noise** - Filtered out internal Rails modules (ActiveRecord::, ActiveModel::, Kernel, JSON::, etc.) from concerns list.

### Added

- **Route helpers in standard detail** - `rails_get_routes(detail: "standard")` now includes route helper names alongside paths.
- **`app_only` filter for routes** - `rails_get_routes(app_only: true)` (default) hides internal Rails routes (Active Storage, Action Mailbox, Conductor).
- **Search context lines** - `rails_search_code(context_lines: 2)` adds surrounding lines to matches (passes `-C` to ripgrep).
- **Stimulus dash/underscore normalization** - Both `weekly-chart` and `weekly_chart` work for controller lookup. Output shows HTML `data-controller` attribute.
- **Model public method signatures** - `rails_get_model_details(model: "Post")` shows method names with params from source, stopping at private boundary.

## [0.13.1] - 2026-03-20

### Changed

- **View summary** - now shows partials used by each view.
- **Model details** - shows method signatures (name + parameters) instead of just method names.
- Removed unused demo files; fixed GUIDE.md preset tables.

## [0.13.0] - 2026-03-20

### Added

- **`rails_validate` MCP tool** - batch syntax validation for Ruby, ERB, and JavaScript files. Replaces separate `ruby -c`, ERB check, and `node -c` calls. Returns pass/fail for each file with error details. Uses `Open3.capture2e` (no shell execution). Falls back to brace-matching when Node.js is unavailable.
- **Model constants extraction** - introspects `STATUSES = %w[...]` style constants and includes them in model context.
- **Global before_actions in controller rules** - OpenCode AGENTS.md now shows ApplicationController before_actions.
- **Service objects and jobs listed** - OpenCode controller AGENTS.md now lists service objects and background jobs.
- **Validate spec** - 8 tests covering happy path, syntax errors, path traversal, MAX_FILES, unsupported types.

### Security

- **Validate tool uses Open3 array form** - no shell execution for `ruby -c`, ERB compilation, or `node -c`. Fixed critical shell quoting bug in ERB validation that caused it to always fail.
- **File size limit** on JavaScript fallback validation (2MB).
- **`which node` check uses array form** - `system("which", "node")` instead of shell string.

### Fixed

- ERB validation was broken due to shell quoting bug (backticks + nested quotes). Replaced with `Open3.capture2e("ruby", "-e", script, ARGV[0])`.
- Rubocop offenses in validate.rb (18 spacing issues auto-corrected).

## [0.12.0] - 2026-03-20

### Added

- **Design Token Introspector** - auto-detects CSS framework and extracts tokens from Tailwind v3/v4, Bootstrap/Sass, plain CSS custom properties, Webpacker-era stylesheets, and ViewComponent sidecar CSS. Tested across 8 CSS setups. Added to standard preset.
- **`rails_get_edit_context` MCP tool** - purpose-built for surgical edits. Returns code around a match point with line numbers. Replaces the Read + Edit workflow with a single call.
- **Line numbers in action source** - `rails_get_controllers(action: "index")` now returns start/end line numbers for targeted editing.
- **Model file structure** - `rails_get_model_details(model: "Post")` now returns line ranges for each section (associations, validations, scopes, etc.).

### Changed

- **MCP instructions updated** - "Use MCP for reference files (schema, routes, tests). Read directly if you'll edit." Prevents unnecessary double-reads.
- **UI pattern extractor rewritten** - semantic labels (primary/secondary/danger), deduplication, 12+ component types, color scheme + radius + form layout extraction, framework-agnostic.
- **Schema rules include column types** - `status:string, intake:jsonb` instead of just names. Also shows foreign keys, indexes, and enum values.
- **View standard detail enhanced** - shows partial fields, helper methods, and shared partials.

### Security

- **File.realpath symlink protection** on all file-reading tools (get_view, get_edit_context, get_test_info, search_code).
- **File size limits** - 2MB on controllers/models/views, 500KB on test files.
- **Ripgrep flag injection prevention** - `--` separator before user pattern.
- **Nil guards** on all component rendering across 10 serializers.
- **Non-greedy regex** - ReDoS prevention in card/input/label pattern matching.
- **UTF-8 encoding safety** - all File.read calls handle binary/non-UTF-8 files gracefully.

### Fixed

- Off-by-one in model structure section line ranges.
- Stimulus sort crash on nil controller name.
- Secondary button picking up disabled states (`cursor-not-allowed`).
- Progress bars misclassified as badges.
- Input detection picking up alert divs instead of actual inputs.

## [0.11.0] - 2026-03-20

### Added

- **UI pattern extraction** - scans all views for repeated CSS class patterns. Detects buttons, cards, inputs, labels, badges, links, headings, flashes, alerts. Added to ALL serializers (root files + split rules for Claude, Cursor, Windsurf, Copilot, OpenCode).
- **View partial structure** - `rails_get_view(detail: "standard")` shows model fields and helper methods used by each partial.
- **Schema column names** - `.claude/rules/rails-schema.md` shows key column names with types, foreign keys, indexes, and enum values. Keeps polymorphic `_type`, STI `type`, and soft-delete `deleted_at` columns.

## [0.10.2] - 2026-03-20

### Security

- **ReDoS protection** - added regex timeout and converted greedy quantifiers to non-greedy across all pattern matching.
- **File size limits** - added size caps on parsed files to prevent memory exhaustion from oversized inputs.

## [0.10.1] - 2026-03-19

### Changed

- Patch release for RubyGems republish (no code changes).

## [0.10.0] - 2026-03-19

### Added

- **`rails_get_view` MCP tool** - get view template contents, partials, Stimulus references. Filter by controller or specific path. Supports summary/standard/full detail levels. Eliminates reading 490+ lines of view files per task. ([#7](https://github.com/crisnahine/rails-ai-context/issues/7))
- **`rails_get_stimulus` MCP tool** - get Stimulus controller details (targets, values, actions, outlets, classes). Filter by controller name. Wraps existing StimulusIntrospector. ([#8](https://github.com/crisnahine/rails-ai-context/issues/8))
- **`rails_get_controllers` `action` parameter** - returns actual action source code + applicable filters instead of the entire controller file. Saves ~1,400 tokens per call. ([#9](https://github.com/crisnahine/rails-ai-context/issues/9))
- **`rails_get_test_info` enhanced** - now supports `detail` levels (summary/standard/full), `model` and `controller` params to find existing tests, fixture/factory names, test helper setup. ([#10](https://github.com/crisnahine/rails-ai-context/issues/10))
- **ViewTemplateIntrospector** - new introspector that reads view file contents and extracts partial references and Stimulus data attributes.
- **Stimulus and view_templates in standard preset** - both introspectors now in `:standard` preset (11 introspectors, was 10).

## [0.9.0] - 2026-03-19

### Added

- **`config.generate_root_files` option** - when set to `false`, skips generating root-level context files (CLAUDE.md, AGENTS.md, .windsurfrules, copilot-instructions.md, .ai-context.json) while still generating all split rules (.claude/rules/, .cursor/rules/, .windsurf/rules/, .github/instructions/). Defaults to `true`.
- **Section markers on root files** - generated content in CLAUDE.md, AGENTS.md, .windsurfrules, and copilot-instructions.md is now wrapped in `<!-- BEGIN rails-ai-context -->` / `<!-- END rails-ai-context -->` markers. User content outside the markers is preserved on re-generation. Existing files without markers get the marked section appended.
- **App overview split rules** - new `rails-context.md` in `.claude/rules/` and `rails-context.instructions.md` in `.github/instructions/` provide a compact app overview (stack, models, routes, gems, architecture) so context is available even when root files are disabled.

### Changed

- **Removed `.cursorrules` root file** - Cursor officially deprecated `.cursorrules` in favor of `.cursor/rules/`. The `:cursor` format now generates only `.cursor/rules/*.mdc` split rules. The `rails-project.mdc` split rule (with `alwaysApply: true`) already provides the project overview.
- **License changed from AGPL-3.0 to MIT** - removes the copyleft blocker for SaaS and commercial projects.

## [0.8.5] - 2026-03-19

### Fixed

- **Thread-safe shared tool cache** - `BaseTool.cached_context` now uses a Mutex-protected shared cache across all 9 tool subclasses. Previously, each subclass cached independently (up to 9 redundant introspections after invalidation) and had no synchronization for multi-threaded servers like Puma. ([#2](https://github.com/crisnahine/rails-ai-context/issues/2))
- **SearchCode ripgrep total result cap** - `rg --max-count N` limits matches per file, not total. A search with `max_results: 5` against a large codebase could return hundreds of results. Now capped with `.first(max_results)` after parsing, matching the Ruby fallback behavior. ([#3](https://github.com/crisnahine/rails-ai-context/issues/3))
- **JobIntrospector Proc queue fallback** - when a Proc-based `queue_name` raises during introspection, the queue now falls back to `"default"` instead of producing garbage like `"#<Proc:0x00007f...>"`. ([#4](https://github.com/crisnahine/rails-ai-context/issues/4))
- **CLI `version` command crash** - `rails-ai-context version` crashed with `LoadError` due to wrong `require_relative` path (`../rails_ai_context/version` instead of `../lib/rails_ai_context/version`). ([#5](https://github.com/crisnahine/rails-ai-context/issues/5))

### Documentation

- **Standalone CLI documented** - the `rails-ai-context` executable (serve, context, inspect, watch, doctor, version) is now documented in README, GUIDE, and CLAUDE.md.

## [0.8.4] - 2026-03-19

### Added

- **`structure.sql` support** - the schema introspector now parses `db/structure.sql` when no `db/schema.rb` exists and no database connection is available. Extracts tables, columns (with SQL type normalization), indexes, and foreign keys from PostgreSQL dump format. Prefers `schema.rb` when both exist.
- **Fingerprinter watches `db/structure.sql`** - file changes to `structure.sql` now trigger cache invalidation and live reload.

## [0.8.3] - 2026-03-19

### Changed

- **License published to RubyGems** - v0.8.2 changed the license from MIT to AGPL-3.0 but the gem was not republished. This release ensures the AGPL-3.0 license is reflected on RubyGems.

## [0.8.2] - 2026-03-19

### Changed

- **License** - changed from MIT to AGPL-3.0 to protect against unauthorized clones and ensure derivative works remain open source.
- **CI: auto-publish to MCP Registry** - the release workflow now automatically publishes to the MCP Registry via `mcp-publisher` with GitHub OIDC auth. No manual `mcp-publisher login` + `publish` needed.

## [0.8.1] - 2026-03-19

### Added

- **OpenCode support** - generates `AGENTS.md` (native OpenCode context file) plus per-directory `app/models/AGENTS.md` and `app/controllers/AGENTS.md` that OpenCode auto-loads when reading files in those directories. Falls back to `CLAUDE.md` when no `AGENTS.md` exists. New command: `rails ai:context:opencode`.

### Fixed

- **Live reload LoadError in HTTP mode** - when `live_reload = true` and the `listen` gem was missing, the `start_http` method's rescue block (for rackup fallback) swallowed the live reload error, producing a confusing rack error instead of the correct "listen gem required" message. The rescue is now scoped to the rackup require only.
- **Dangling @live_reload reference** - `@live_reload` was assigned before `start` was called. If `start` raised LoadError, the instance variable pointed to a non-functional object. Now only assigned after successful start.

## [0.8.0] - 2026-03-19

### Added

- **MCP Live Reload** - when running `rails ai:serve`, file changes automatically invalidate tool caches and send MCP notifications (`notifications/resources/list_changed`) to connected AI clients. The AI's context stays fresh without manual re-querying. Requires the `listen` gem (enabled by default when available). Configurable via `config.live_reload` (`:auto`, `true`, `false`) and `config.live_reload_debounce` (default: 1.5s).
- **Live reload doctor check** - `rails ai:doctor` now warns when the `listen` gem is not installed.

## [0.7.1] - 2026-03-19

### Added

- **Full MCP tool reference in all context files** - every generated file (CLAUDE.md, .cursorrules, .windsurfrules, copilot-instructions.md) now includes complete tool documentation with parameters, detail levels, pagination examples, and usage workflow. Dedicated `rails-mcp-tools` split rule files added for Claude, Cursor, Windsurf, and Copilot.
- **MCP Registry listing** - published to the [official MCP Registry](https://registry.modelcontextprotocol.io) as `io.github.crisnahine/rails-ai-context` via mcpb package type.

### Fixed

- **Schema version parsing** - versions with underscores (e.g. `2024_01_15_123456`) were truncated to the first digit group. Now captures the full version string.
- **Documentation** - updated README (detail levels, pagination, generated file tree, config options), SECURITY.md (supported versions), CONTRIBUTING.md (project structure), gemspec (post-install message), demo_script.sh (all 17 generated files).

## [0.7.0] - 2026-03-19

### Added

- **Detail levels on MCP tools** - `detail:"summary"`, `detail:"standard"` (default), `detail:"full"` on `rails_get_schema`, `rails_get_routes`, `rails_get_model_details`, `rails_get_controllers`. AI calls summary first, then drills down. Based on Anthropic's recommended MCP pattern.
- **Pagination** - `limit` and `offset` parameters on schema and routes tools for apps with hundreds of tables/routes.
- **Response size safety net** - Configurable hard cap (`max_tool_response_chars`, default 120K) on tool responses. Truncated responses include hints to use filters.
- **Compact CLAUDE.md** - New `:compact` context mode (default) generates ≤150 lines per Claude Code's official recommendation. Contains stack overview, key models, and MCP tool usage guide.
- **Full mode preserved** - `config.context_mode = :full` retains the existing full-dump behavior. Also available via `rails ai:context:full` or `CONTEXT_MODE=full`.
- **`.claude/rules/` generation** - Generates quick-reference files in `.claude/rules/` for schema and models. Auto-loaded by Claude Code alongside CLAUDE.md.
- **Cursor MDC rules** - Generates `.cursor/rules/*.mdc` files with YAML frontmatter (globs, alwaysApply). Project overview is always-on; model/controller rules auto-attach when working in matching directories. Legacy `.cursorrules` kept for backward compatibility.
- **Windsurf 6K compliance** - `.windsurfrules` is now hard-capped at 5,800 characters (within Windsurf's 6,000 char limit). Generates `.windsurf/rules/*.md` for the new rules format.
- **Copilot path-specific instructions** - Generates `.github/instructions/*.instructions.md` with `applyTo` frontmatter for model and controller contexts. Main `copilot-instructions.md` respects compact mode (≤500 lines).
- **`rails ai:context:full` task** - Dedicated rake task for full context dump.
- **Configurable limits** - `claude_max_lines` (default: 150), `max_tool_response_chars` (default: 120K).

### Changed

- Default `context_mode` is now `:compact` (was implicitly `:full`). Existing behavior available via `config.context_mode = :full`.
- Tools default to `detail:"standard"` which returns bounded results, not unlimited.
- All tools return pagination hints when results are truncated.
- `.windsurfrules` now uses dedicated `WindsurfSerializer` instead of sharing `RulesSerializer` with Cursor.

## [0.6.0] - 2026-03-18

### Added

- **Migrations introspector** - Discovers migration files, pending migrations, recent history, schema version, and migration statistics. Works without DB connection.
- **Seeds introspector** - Analyzes db/seeds.rb structure, discovers seed files in db/seeds/, detects which models are seeded, and identifies patterns (Faker, environment conditionals, find_or_create_by).
- **Middleware introspector** - Discovers custom Rack middleware in app/middleware/, detects patterns (auth, rate limiting, tenant isolation, logging), and categorizes the full middleware stack.
- **Engine introspector** - Discovers mounted Rails engines from routes.rb with paths and descriptions for 23+ known engines (Sidekiq::Web, Flipper::UI, PgHero, ActiveAdmin, etc.).
- **Multi-database introspector** - Discovers multiple databases, replicas, sharding config, and model-specific `connects_to` declarations. Works with database.yml parsing fallback.
- **2 new MCP resources** - `rails://migrations`, `rails://engines`
- **Migrations added to :standard preset** - AI tools now see migration context by default
- **Doctor check** - New `check_migrations` diagnostic
- **Fingerprinter** - Now watches `db/migrate/`, `app/middleware/`, and `config/database.yml`

### Changed

- Default `:standard` preset expanded from 8 to 9 introspectors (added `:migrations`)
- Default `:full` preset expanded from 21 to 26 introspectors
- Doctor checks expanded from 11 to 12
- Static MCP resources expanded from 7 to 9

## [0.5.2] - 2026-03-18

### Fixed

- **MCP tool nil crash** - All 9 MCP tools now handle missing introspector data gracefully instead of crashing with `NoMethodError` when the introspector is not in the active preset (e.g. `rails_get_config` with `:standard` preset)
- **Zeitwerk dependency** - Changed from open-ended `>= 2.6` to pessimistic `~> 2.6` per RubyGems best practices
- **Documentation** - Updated CONTRIBUTING.md, CHANGELOG.md, and CLAUDE.md to reflect Zeitwerk autoloading, introspector presets, and `.mcp.json` auto-discovery changes

## [0.5.1] - 2026-03-18

### Fixed

- Documentation updates and animated demo GIF added to README.
- Zeitwerk autoloading fixes for edge cases.

## [0.5.0] - 2026-03-18

### Added

- **Introspector presets** - `:standard` (8 core introspectors, fast) and `:full` (all 21, thorough) via `config.preset = :standard`
- **`.mcp.json` auto-discovery** - Install generator creates `.mcp.json` so Claude Code and Cursor auto-detect the MCP server with zero manual config
- **Zeitwerk autoloading** - Replaced 47 `require_relative` calls with Zeitwerk for faster boot and conventional file loading
- **Automated release workflow** - GitHub Actions publishes to RubyGems via trusted publishing when a version tag is pushed
- **Version consistency check** - Release workflow verifies git tag matches `version.rb` before publishing
- **Auto GitHub Release** - Release notes extracted from CHANGELOG.md automatically
- **Dependabot** - Weekly automated dependency and GitHub Actions updates
- **README demo GIF** - Animated terminal recording showing install, doctor, and context generation
- **SECURITY.md** - Security policy with supported versions and reporting process
- **CODE_OF_CONDUCT.md** - Contributor Covenant v2.1
- **GitHub repo topics** - Added discoverability keywords (rails, mcp, ai, etc.)

### Changed

- Default introspectors reduced from 21 to 8 (`:standard` preset) for faster boot; use `config.preset = :full` for all 21
- New files auto-loaded by Zeitwerk - no manual `require_relative` needed when adding introspectors or tools

## [0.4.0] - 2026-03-18

### Added

- **14 new introspectors** - Controllers, Views, Turbo/Hotwire, I18n, Config, Active Storage, Action Text, Auth, API, Tests, Rake Tasks, Asset Pipeline, DevOps, Action Mailbox
- **3 new MCP tools** - `rails_get_controllers`, `rails_get_config`, `rails_get_test_info`
- **3 new MCP resources** - `rails://controllers`, `rails://config`, `rails://tests`
- **Model introspector enhancements** - Extracts `has_secure_password`, `encrypts`, `normalizes`, `delegate`, `serialize`, `store`, `generates_token_for`, `has_one_attached`, `has_many_attached`, `has_rich_text`, `broadcasts_to` via source parsing
- **Stimulus introspector enhancements** - Extracts `outlets` and `classes` from controllers
- **Gem introspector enhancements** - 30+ new notable gems: monitoring (Sentry, Datadog, New Relic, Skylight), admin (ActiveAdmin, Administrate, Avo), pagination (Pagy, Kaminari), search (Ransack, pg_search, Searchkick), forms (SimpleForm), utilities (Faraday, Flipper, Bullet, Rack::Attack), and more
- **Convention detector enhancements** - Detects concerns, validators, policies, serializers, notifiers, Phlex, PWA, encrypted attributes, normalizations
- **Markdown serializer sections** - All 14 new introspector sections rendered in generated context files
- **Doctor enhancements** - 4 new checks: controllers, views, i18n, tests (11 total)
- **Fingerprinter expansion** - Watches `app/controllers`, `app/views`, `app/jobs`, `app/mailers`, `app/channels`, `app/javascript/controllers`, `config/initializers`, `lib/tasks`; glob now covers `.rb`, `.rake`, `.js`, `.ts`, `.erb`, `.haml`, `.slim`, `.yml`

### Fixed

- **YAML parsing** - `YAML.load_file` calls now pass `permitted_classes: [Symbol], aliases: true` for Psych 4 (Ruby 3.1+) compatibility
- **Rake task parser** - Fixed `@last_desc` instance variable leaking between files; fixed namespace tracking with indent-based stack
- **Vite detection** - Changed `File.exist?("vite.config")` to `Dir.glob("vite.config.*")` to match `.js`/`.ts`/`.mjs` extensions
- **Health check regex** - Added word boundaries to avoid false positives on substrings (e.g. "groups" matching "up")
- **Multi-attribute macros** - `normalizes :email, :name` now captures all attributes, not just the first
- **Stimulus action regex** - Requires `method(args) {` pattern to avoid matching control flow keywords
- **Controller respond_to** - Simplified format extraction to avoid nested `end` keyword issues
- **GetRoutes nil guard** - Added `|| {}` fallback for `by_controller` to prevent crash on partial introspection data
- **GetSchema nil guard** - Added `|| {}` fallback for `schema[:tables]` to prevent crash on partial schema data
- **View layout discovery** - Added `File.file?` filter to exclude directories from layout listing
- **Fingerprinter glob** - Changed from `**/*.rb` to multi-extension glob to detect changes in `.rake`, `.js`, `.ts`, `.erb` files

### Changed

- Default introspectors expanded from 7 to 21
- MCP tools expanded from 6 to 9
- Static MCP resources expanded from 4 to 7
- Doctor checks expanded from 7 to 11
- Test suite expanded from 149 to 247 examples with exact value assertions

## [0.3.0] - 2026-03-18

### Added

- **Cache invalidation** - TTL + file fingerprinting for MCP tool cache (replaces permanent `||=` cache)
- **MCP Resources** - Static resources (`rails://schema`, `rails://routes`, `rails://conventions`, `rails://gems`) and resource template (`rails://models/{name}`)
- **Per-assistant serializers** - Claude gets behavioral rules, Cursor/Windsurf get compact rules, Copilot gets task-oriented GFM
- **Stimulus introspector** - Extracts Stimulus controller targets, values, and actions from JS/TS files
- **Database stats introspector** - Opt-in PostgreSQL approximate row counts via `pg_stat_user_tables`
- **Auto-mount HTTP middleware** - Rack middleware for MCP endpoint when `config.auto_mount = true`
- **Diff-aware regeneration** - Context file generation skips unchanged files
- **`rails ai:doctor`** - Diagnostic command with AI readiness score (0-100)
- **`rails ai:watch`** - File watcher that auto-regenerates context files on change (requires `listen` gem)

### Fixed

- **Shell injection in SearchCode** - Replaced backtick execution with `Open3.capture2` array form; added file_type validation, max_results cap, and path traversal protection
- **Scope extraction** - Fixed broken `model.methods.grep(/^_scope_/)` by parsing source files for `scope :name` declarations
- **Route introspector** - Fixed `route.internal?` compatibility with Rails 8.1

### Changed

- `generate_context` now returns `{ written: [], skipped: [] }` instead of flat array
- Default introspectors now include `:stimulus`

## [0.2.0] - 2026-03-18

### Added

- Named rake tasks (`ai:context:claude`, `ai:context:cursor`, etc.) that work without quoting in zsh
- AI assistant summary table printed after `ai:context` and `ai:inspect`
- `ENV["FORMAT"]` fallback for `ai:context_for` task
- Format validation in `ContextFileSerializer` - unknown formats now raise `ArgumentError` with valid options

### Fixed

- `rails ai:context_for[claude]` failing in zsh due to bracket glob interpretation
- Double introspection in `ai:context` and `ai:context_for` tasks (removed unused `RailsAiContext.introspect` calls)

## [0.1.0] - 2026-03-18

### Added

- Initial release
- Schema introspection (live DB + static schema.rb fallback)
- Model introspection (associations, validations, scopes, enums, callbacks, concerns)
- Route introspection (HTTP verbs, paths, controller actions, API namespaces)
- Job introspection (ActiveJob, mailers, Action Cable channels)
- Gem analysis (40+ notable gems mapped to categories with explanations)
- Convention detection (architecture style, design patterns, directory structure)
- 6 MCP tools: `rails_get_schema`, `rails_get_routes`, `rails_get_model_details`, `rails_get_gems`, `rails_search_code`, `rails_get_conventions`
- Context file generation: CLAUDE.md, .cursorrules, .windsurfrules, .github/copilot-instructions.md, JSON
- Rails Engine with Railtie auto-setup
- Install generator (`rails generate rails_ai_context:install`)
- Rake tasks: `ai:context`, `ai:serve`, `ai:serve_http`, `ai:inspect`
- CLI executable: `rails-ai-context serve|context|inspect`
- Stdio + Streamable HTTP transport support via official mcp SDK
- CI matrix: Ruby 3.2/3.3/3.4 × Rails 7.1/7.2/8.0
