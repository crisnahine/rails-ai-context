# QA round eleven: primary-source notes

Every claim below was read out of gem source installed on this machine, or verified by running it
on Ruby 3.4.9. Gem roots are abbreviated as `$G = /Users/crisn/.rvm/gems/ruby-3.4.9/gems`.
Versions checked: sidekiq 8.1.7, sidekiq-throttled 2.1.0, active_interaction 5.5.0, brakeman 8.0.6
and 7.1.0, Rails 7.1.6 / 7.2.3.2 / 8.0.5.1 / 8.1.3.1.

## 1. Sidekiq 8.x: options inheritance, `Job` vs `Worker` vs `IterableJob`

`sidekiq_options` merges onto whatever `get_sidekiq_options` returns, and writes the result to the
receiver's own singleton (`$G/sidekiq-8.1.7/lib/sidekiq/job.rb:71-78`, storage defined at
`:92-125`). Both the reader and the writer are singleton methods, so a subclass reads the parent's
hash until it sets its own.

- Verified: parent `sidekiq_options queue: "parent_q", retry: 5`, child `sidekiq_options queue:
  "child_q"` gives child `{"retry" => 5, "queue" => "child_q"}`, parent unchanged, and a subclass
  that declares nothing gets `{"retry" => 5, "queue" => "parent_q"}`.
- The inheritance is live, not a snapshot. `get_sidekiq_options` only writes when the inherited
  value is `nil` (`job.rb:88-90`), so a later `sidekiq_options` on the parent is still seen by a
  subclass that already read its options.
- Keys are stringified two levels deep (`job.rb:73-75`). An introspector reading
  `get_sidekiq_options` gets `"queue"`, never `:queue`.

Including `Sidekiq::Job` in a parent does make every subclass enqueueable. `Job.included` extends
the base with `ClassMethods` (`job.rb:165-170`), and `perform_async` and friends are singleton
methods, which subclasses inherit. Verified: `class C3 < P3; end` with `C3.perform_async(1)`
enqueues onto the parent's queue with `"class" => "C3"`, the subclass name.

`Job.included` also raises `ArgumentError` when the base is an `ActiveJob::Base` descendant
(`job.rb:166`).

Today's three names:

- `Sidekiq::Job` is the module (`job.rb:44`).
- `Sidekiq::Worker` is a plain constant alias for it, since 6.3.0
  (`$G/sidekiq-8.1.7/lib/sidekiq/worker_compatibility_alias.rb:12`). `Sidekiq::Worker.equal?(Sidekiq::Job)`
  is `true`, so `ancestors` can never tell them apart.
- `Sidekiq::IterableJob` is separate: including it includes both `Sidekiq::Job` and
  `Sidekiq::Job::Iterable` (`$G/sidekiq-8.1.7/lib/sidekiq/iterable_job.rb:33-38`). The job defines
  `build_enumerator(*args, cursor:)` and `each_iteration(item, *args)` instead of `perform`, and is
  still enqueued with `perform_async`. Ancestors of such a class:
  `[It, Sidekiq::Job::Iterable, Sidekiq::Job::Iterable::Enumerators, Sidekiq::Job::Options,
  Sidekiq::Job, Sidekiq::IterableJob]`.

## 2. sidekiq-throttled 2.1.0: the macro

The macro comes from `Sidekiq::Throttled::Job`, a separate include from `Sidekiq::Job`
(`$G/sidekiq-throttled-2.1.0/lib/sidekiq/throttled/job.rb:33-36`).

```ruby
def sidekiq_throttle(**)          # job.rb:91-93  -> Registry.add(self, **)
def sidekiq_throttle_as(name)     # job.rb:137-139 -> Registry.add_alias(self, name)
```

`sidekiq_throttle` forwards straight to `Strategy#initialize`, which is the real signature
(`.../throttled/strategy.rb:43`):

```ruby
Strategy.new(name, concurrency: nil, threshold: nil, key_suffix: nil, observer: nil, requeue: nil)
```

Nested keys, from the strategy constructors:

- `concurrency:` -> `limit:` (required), `avg_job_duration:`, `lost_job_threshold:`, `ttl:`
  (deprecated alias for `lost_job_threshold`), `key_suffix:`, `max_delay:`
  (`.../throttled/strategy/concurrency.rb:39-44`, documented at README.adoc:348-357).
- `threshold:` -> `limit:` and `period:` (both required), `key_suffix:`
  (`.../throttled/strategy/threshold.rb:41-45`).
- `requeue:` -> `{to:, with:}`, where `with:` is `:enqueue` (default) or `:schedule`
  (`strategy.rb:17`, `strategy.rb:56`, README.adoc:82-105).
- `key_suffix:` may sit at the top level or inside a single strategy hash; `limit`, `period` and
  `key_suffix` all accept a callable, which is what `dynamic?` tests
  (`strategy/threshold.rb:50-57`, `strategy/base.rb:8-21`).
- `concurrency:` and `threshold:` each accept an array of option hashes, not only one
  (`.../throttled/strategy_collection.rb:21-25`).

Other spellings:

- `sidekiq_throttle_as :name` exists and points at a strategy registered under a symbol via
  `Sidekiq::Throttled::Registry.add` (`job.rb:137-139`, `registry.rb:32-39`).
- `Sidekiq::Throttled::Worker` is an alias constant for `Sidekiq::Throttled::Job`
  (`.../throttled/worker.rb:11`), so `include Sidekiq::Throttled::Worker` is the same thing.
- There is no `sidekiq_options throttle:` spelling. Grepping the whole gem for `sidekiq_options`
  returns only README examples setting `queue:` and the module doc comment. The gem never reads a
  throttle key out of the options hash; everything goes through `Registry`.
- The gem 2.1.0 declares support for Sidekiq 8.0.x and 8.1.x only (README.adoc:401-411).

## 3. ActiveInteraction 5.5.0

(a) Nested filters declared in a `hash :x do ... end` block do **not** appear in the class's
`.filters`. The block is `instance_eval`ed on the `HashFilter` instance
(`$G/active_interaction-5.5.0/lib/active_interaction/filter.rb:68-74`) and its `method_missing`
stores children in that filter's own `@filters` hash
(`.../filters/hash_filter.rb:79-87`). Reach them through `klass.filters[:x].filters`, a public
`attr_reader` (`filter.rb:20`). Verified: `Parent.filters.keys == [:a, :order]` while
`Parent.filters[:order].filters.keys == [:item, :quantity]`.

(b) A subclass does include the parent's filters, by copy at subclass-definition time.
`inherited` does `klass.instance_variable_set(:@_interaction_filters, filters.dup)`
(`.../base.rb:136-140`). Two consequences, both verified:

- `Child.filters.keys == [:a, :order, :b]`, and adding `:b` to the child leaves the parent alone.
- A filter added to the parent *after* the subclass was defined does not reach the subclass:
  `Late.filters.keys == [:x, :y]` but `LateChild.filters.keys == [:x]`.

`import_filters(OtherInteraction, only:/except:)` copies filters across unrelated classes
(`base.rb:124-133`).

(c) The class-level entry points are `run` and `run!` only
(`.../concerns/runnable.rb:111-122`), documented on `Base` at `base.rb:39-58`. `.run` returns the
interaction instance (read the value off `#result`); `.run!` returns `#execute`'s value or raises.
There is no `call` anywhere: grepping the whole `lib` for `def call` / `alias ... :call` returns
nothing, and `Klass.respond_to?(:call)` and `instance.respond_to?(:call)` are both `false`.

## 4. ActiveSupport::Inflector and `inflect.acronym "AI"`

`acronym(word)` stores `@acronyms[word.downcase] = word` and rebuilds two regexes
(`$G/activesupport-8.1.3.1/lib/active_support/inflector/inflections.rb:159-161`, `:267-271`).

`camelize` consults `inflections.acronyms` for the leading segment and for every `_`- or
`/`-delimited word (`.../inflector/methods.rb:70-86`). `underscore` applies
`acronyms_underscore_regex` before the general split (`methods.rb:99-107`).

Measured, with and without `acronym "AI"`:

| input | no acronyms | with `acronym "AI"` |
|---|---|---|
| `"ai_context".camelize` | `"AiContext"` | `"AIContext"` |
| `"AIContext".underscore` | `"ai_context"` | `"ai_context"` |
| `"api/v1/orders_controller".camelize` | `"Api::V1::OrdersController"` | `"API::V1::OrdersController"` (with `acronym "API"`) |

The asymmetry is the whole problem for path -> constant derivation: `underscore` already collapses
`AIContext` to `ai_context` whether or not the acronym is registered, so the file path on disk
looks the same either way. Only `camelize` differs. A deriver that camelizes
`app/models/ai_context.rb` without the app's `config/initializers/inflections.rb` loaded produces
`AiContext`, which does not exist; the real constant is `AIContext`.

Second trap, straight from the AS docs (`inflections.rb:135-143`): the acronym has to match as a
delimited unit. With only `acronym "API"` registered, `"APIsController".underscore` is
`"ap_is_controller"` (the underscore regex requires `(?=\b|[^a-z])` after the acronym,
`inflections.rb:271`). Registering `acronym "APIs"` as well makes it round-trip:
`"APIsController".underscore == "apis_controller"` and back.

Practical rule: never trust a camelize-derived constant name. Resolve the constant, or compare
against `Object.const_get`, rather than assuming `path.camelize` names a real class.

## 5. Brakeman 8.x from Ruby

Public entry point: `Brakeman.run(options)`, returning a `Brakeman::Tracker`
(`$G/brakeman-8.0.6/lib/brakeman.rb:81-108`; the option list is the comment block at `:38-80`).
The useful options for a programmatic scan are `:app_path` (required, may be passed as a bare
String instead of the hash), `:quiet`, `:report_progress`, `:print_report`, `:min_confidence`,
`:run_checks` / `:skip_checks`, `:output_formats`, `:parallel_checks`, `:parser_timeout`,
`:use_prism`. Results come off the tracker as `tracker.warnings`. The `Warnings_Found_Exit_Code`
constants at `brakeman.rb:7-30` are only honoured by the `Commandline` module, not by `run`.

Metadata, which decides whether the gem is usable at all:

| version | required_ruby_version | runtime deps |
|---|---|---|
| 8.0.6 | `>= 3.2.0` | `racc` |
| 7.1.0 | `>= 3.1.0` | `racc` |

So on Ruby 3.1 (which this gem still supports) only brakeman 7.x can be installed.

### Loading it from a Bundler-restricted process

All three routes were tried in a process whose Gemfile has no brakeman.

1. `require "brakeman"` fails with `LoadError`: Bundler's load path does not contain it.
2. `Gem::Specification.find_by_name("brakeman")` raises
   `Gem::MissingSpecError: Could not find 'brakeman' (>= 0) among 67 total gem(s)`. Bundler
   replaces `Gem::Specification`'s spec set with the bundle's, so the gem is invisible even though
   it is installed. `Gem::Specification.reset` does not help; Bundler reinstalls its stubs on the
   reset hook.
3. Loading the gemspec off disk and calling `activate` gets one step further and then dies the same
   way on the dependency: `Gem::MissingSpecError: Could not find 'racc' (>= 0) among 67 total
   gem(s)`, raised from `Gem::Specification#activate_dependencies`. **This is the caveat: `activate`
   resolves the gem's whole dependency tree through the Bundler-restricted set, so any dep the app
   bundle lacks (or pins differently) fails the activation.**

What does work in-process is skipping RubyGems entirely and pushing the require paths:

```ruby
spec = Gem::Specification.load(
  Gem::Specification.dirs.flat_map { |d| Dir["#{d}/brakeman-*.gemspec"] }.sort.last
)
$LOAD_PATH.unshift(*spec.full_require_paths)
require "brakeman"
tracker = Brakeman.run(app_path: path, quiet: true, report_progress: false, print_report: false)
```

Verified end to end: this returns a `Brakeman::Tracker` and finds a `Dangerous Eval` warning in a
throwaway controller. Two conditions on it:

- **`racc` must be in the host bundle.** Ruby 3.3 demoted `racc` from a default gem to a bundled
  one, so `require "racc/parser"` from brakeman's vendored `ruby_parser` is blocked by Bundler and
  the scan aborts with `cannot load such file -- racc/parser` / `Please install the appropriate
  dependency: ruby_parser.` Adding `gem "racc"` to the Gemfile fixes it.
- **Brakeman vendors and unshifts its own copies of the app's gems.**
  `$G/brakeman-8.0.6/bundle/load.rb` prepends `csv`, `erubi`, `haml 6.4.0`, `highline`, `parallel`,
  `reline`, `rexml`, `ruby2ruby`, `ruby_parser`, `sexp_processor`, `slim 5.2.2`, `temple`,
  `terminal-table`, `tilt`, `unicode-display_width`, `unicode-emoji` onto `$LOAD_PATH`, ahead of
  whatever the app bundle resolved. It is triggered lazily by `load_brakeman_dependency`
  (`brakeman.rb:576-600`) whenever brakeman needs a template parser. In a Rails app that uses haml
  or slim, this can shadow the app's versions for the rest of the process.
- That same method calls `exit!(-1)` when a dependency is missing (`brakeman.rb:596-597`), so an
  in-process failure can kill the host process without an exception to rescue.

The route with none of these hazards is shelling out with the bundle stripped from the environment.
Verified: `Bundler.with_unbundled_env { \`brakeman --version\` }` prints `brakeman 8.0.6` from a
process whose own bundle has no brakeman. Note that `with_unbundled_env` only cleans `ENV` for
child processes; it does nothing for an in-process `require`.

## 6. `match ... via: :all` vs `mount`, and spotting a Rack endpoint

`mount` is implemented as `match` with three options forced and a name derived from the app class
(`$G/actionpack-8.1.3.1/lib/action_dispatch/routing/mapper.rb:605-648`; the 7.1 form is the same
shape at `$G/actionpack-7.1.6/.../mapper.rb:645-664`):

```ruby
match(path, to: app, as:, via: :all, anchor: false, format: false, ...)
```

Defaults: `anchor: false` and `format: false` are the mount defaults (`mapper.rb:605`), and the
name comes from `app_name` — `railtie_name` for a Rails engine, otherwise
`ActiveSupport::Inflector.underscore(app.name).tr("/", "_")` (`mapper.rb:689-696`). For an engine,
`define_generate_prefix` is called as well (`mapper.rb:646`).

Measured on both 7.1.6 and 8.1.3.1, for a plain `MyRackApp`:

| declaration | `route.path.spec` | `route.name` | `route.verb` | `route.defaults` | `route.app.class` | `app.dispatcher?` | `app.app` |
|---|---|---|---|---|---|---|---|
| `get "/widgets", to: "widgets#index"` | `/widgets(.:format)` | `"widgets"` | `"GET"` | `{controller: "widgets", action: "index"}` | `RouteSet::Dispatcher` | `true` | the Dispatcher |
| `match "/rackapp", to: MyRackApp, via: :all` | `/rackapp(.:format)` | `"rackapp"` | `""` | `{}` | `Mapper::Constraints` | `false` | `MyRackApp` |
| `mount MyRackApp => "/mounted"` | `/mounted` | `"my_rack_app"` | `""` | `{}` | `Mapper::Constraints` | `false` | `MyRackApp` |

So the only differences between the two Rack forms are the path (no `(.:format)` segment and no
anchor under `mount`) and the auto-derived route name. The endpoint object is identical.

Walking `Rails.application.routes.routes`, the discriminator is `route.app.dispatcher?`:

- `RouteSet::Dispatcher#dispatcher?` is hard-coded `true` (`route_set.rb:44`).
- `Mapper::Constraints#dispatcher?` is `@strategy == SERVE` (`mapper.rb:50`), which is `false` for
  a Rack endpoint, since `mount`/`match to: <rack app>` builds it with the `CALL` strategy.
- The base `Routing::Endpoint` defines `dispatcher?` as `false`, `app` as `self` and `rack_app` as
  `app` (`$G/actionpack-8.1.3.1/lib/action_dispatch/routing/endpoint.rb:7-17`).

`dispatcher?` takes zero arguments in every version 7.1 through 8.1 (checked in all four), so a
plain `route.app.dispatcher?` is safe. For the Rack case, the actual application object is
`route.app.app` (equivalently `route.app.rack_app`). `route.app.engine?` (`endpoint.rb:14-16`)
separates a mounted Rails engine from a bare Rack app; it references `Rails::Engine`, so it raises
`NameError` outside a Rails process.

Secondary signal, when the endpoint object is not available: a controller route always carries
`controller` and `action` in `route.defaults`, and a Rack endpoint's defaults are empty.

## 7. Namespaced controllers and view directories

`controller_path` is `name.delete_suffix("Controller").underscore`, memoized, and `nil` for an
anonymous class (`$G/actionpack-8.1.3.1/lib/abstract_controller/base.rb:118-120`; instance
delegator at `:158-160`).

The template directory is `app/views/<controller_path>/`. Verified:
`Api::V1::Admin::OrdersController.controller_path == "api/v1/admin/orders"`, so
`app/views/api/v1/admin/orders/index.html.erb`.

Lookup is not limited to that one directory. `_prefixes` is `local_prefixes + superclass._prefixes`
until an abstract superclass is reached, and `local_prefixes` is `[controller_path]`
(`$G/actionview-8.1.3.1/lib/action_view/view_paths.rb:23-29`, `:75-77`). Measured:
`Api::V1::Admin::OrdersController._prefixes == ["api/v1/admin/orders", "application"]`, so
`app/views/application/` is the fallback directory. The instance-level `_prefixes` just delegates
to the class (`view_paths.rb:81-83`) and feeds the `LookupContext` (`:88-91`).

Because `controller_path` is memoized on first call, inflections registered after a controller's
`controller_path` has been read do not change it.

## 8. Schema version and pending migrations, Rails 7.1 to 8.1

The receiver moved in 7.2. This is a hard break, not a deprecation:

| Rails | `MigrationContext` hangs off |
|---|---|
| 7.1 | the adapter: `ActiveRecord::Base.connection.migration_context` (`$G/activerecord-7.1.6/lib/active_record/connection_adapters/abstract_adapter.rb:253-255`) |
| 7.2, 8.0, 8.1 | the pool: `ActiveRecord::Base.connection_pool.migration_context` (`$G/activerecord-8.1.3.1/lib/active_record/connection_adapters/abstract/connection_pool.rb:326-328`; same in 7.2.3.2 at `:296` and 8.0.5.1 at `:295`) |

Verified against a sqlite3 in-memory database on all four versions:

- On 7.1, `connection_pool.migration_context` raises `NoMethodError`.
- On 7.2 / 8.0 / 8.1, `connection.migration_context` raises `NoMethodError`.
- Everything below `migration_context` is identical across the four.

Once you have the context, the API is stable:

```ruby
ctx = ActiveRecord::Base.connection_pool.migration_context   # 7.2+
ctx = ActiveRecord::Base.connection.migration_context        # 7.1

ctx.current_version              # => 0 before migrating, 20240202000000 after
ctx.pending_migration_versions   # => [20240101000000, 20240202000000], then []
ctx.needs_migration?             # => true, then false
ctx.open.pending_migrations      # => [Migration, ...], .map(&:version) matches the above
```

- `current_version` is `get_all_versions.max || 0`, and `get_all_versions` returns `[]` when the
  `schema_migrations` table does not exist, so an unmigrated database answers `0` rather than
  raising (`$G/activerecord-8.1.3.1/lib/active_record/migration.rb:1291-1302`; 7.1 at `:1295-1306`,
  7.2 at `:1285-1296`, 8.0 at `:1281-1292`).
- `current_version` rescues `ActiveRecord::NoDatabaseError` and returns `nil` in that case
  (`migration.rb:1301-1302`).
- `pending_migration_versions` is `migrations.collect(&:version) - get_all_versions`
  (`migration.rb:1308-1310`). It reads the migration files, so it needs `migrations_paths` to be
  correct; the pool takes it from `db_config.migrations_paths || Migrator.migrations_paths`
  (`connection_pool.rb:330-332`).
- The raw fallback works on every version and needs no `MigrationContext`:
  `ActiveRecord::Base.connection.select_values("SELECT version FROM schema_migrations")` returns
  `["20240101000000", "20240202000000"]` as strings.
- `ActiveRecord::SchemaMigration` is no longer a model class from 7.1 on; it is instantiated
  against a pool or adapter (`SchemaMigration.new(pool)`, `migration.rb:1225`). On 7.2+ reach it as
  `connection_pool.schema_migration` (`connection_pool.rb:334-335`); on 7.1 as
  `connection.schema_migration` (`abstract_adapter.rb:257-259`).
- Also relevant on 7.2+: `ActiveRecord::Base.connection` is the deprecated accessor and
  `lease_connection` / `with_connection` are the replacements (`Base.respond_to?(:lease_connection)`
  is `false` on 7.1 and `true` on 7.2, 8.0 and 8.1).
