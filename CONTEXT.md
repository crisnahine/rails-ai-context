# Context

Terms this project uses in a narrower sense than everyday English. One entry per term that has caused a naming collision or an ambiguous read.

## Environment

Overloaded. Always qualify it; never use "environment" bare in a tool name, an introspector name, or a config key.

**Process environment** - the environment variables a running app sees, plus the places they are declared (`ENV[]` call sites, `.env.example`, Dockerfile, credentials keys). Served by `rails_get_env`, read by `EnvIntrospector`.

**Environment config** - what `config/environments/*.rb` declares per environment: the assigned `config.*` keys and the values of the notable toggles. Served by `rails_get_env_config`, read by `EnvConfigIntrospector`.

**Environment** (unqualified, as data) - a single named Rails environment: development, production, staging. This is the only sense in which the bare word is allowed, and only as a value, never as a name. The `:environments` payload key means "the list of these", which is why it kept its name when the introspector was renamed.

## AI tool

The assistant a user points at their app: claude, cursor, copilot, opencode, codex. What the gem generates for one is its **context files** (`CLAUDE.md`, `.cursor/rules/*.mdc`, and so on).

Avoid "format" for either sense - claude is not a file format, and the word collides with real formatting elsewhere in the code. The public config key `ai_tools` already uses the canonical term.

`Install::AiTool` is the one table of what each means: name, context files, MCP config shape, legacy leftovers. `Install::SelectionRecord` owns which ones the user picked - written to YAML always and to the initializer line inside a Rails app, read initializer-first because that is the file a user hand-edits.

## Path

Two senses, one per module, and neither is bare "path" in a name.

**Where code lives** - `PathResolver` answers which directories a kind of app code can occupy for a given root: conventional layout, packwerk packs, in-repo engines, configured extras.

**How a path is written down** - `PortablePath` rewrites one so it means the same thing on another machine, because what it touches ends up in `.ai-context.json` and the app commits that file. App paths go app-relative, gem paths keep the gem and version and drop the install prefix. Where a reader would otherwise resolve the result against the app root, `relativize_marked` prefixes a gem path with `gem:`. "Relativize" always means this.

## Safe path

A caller-supplied path resolved once, through `SafePath`, before anything reads it. Its refusal order is the contract, not an implementation detail: traversal, sensitive name, realpath, containment, sensitive realpath, file, size. A caller that reorders those checks, or repeats one of them itself, gets a different answer on a symlink or a dotfile than every other tool does, which is the divergence the module exists to end. `safe_glob` is the globbed-path form: the same guard applied to each path a pattern yields.

Not the same as a path that merely looks harmless, and not a caller's own containment check - "the tool guards this parameter" means it hands the parameter to `SafePath` and renders whatever refusal comes back.

## Carried path

A path the payload already holds because the gem's own walk found it - a controller's or a model's `file:`. It is re-read with `SafeFile.read(File.join(root, relative))`, which applies the size cap and nothing else. The reason is the walk: `SourceScan` deliberately keeps the spelling the app uses rather than the realpath, so a pack or an in-repo engine symlinked out of the root is spelled inside it, and `SafePath`'s realpath containment would refuse the very file the payload just named - the source comes back nil and a section silently empties.

Not an exception to the **safe path** rule, the other side of it: a caller-supplied path is untrusted and goes through `SafePath`; a carried path was produced by this gem and only needs the cap.

## Source scan

The one walk over a kind of app source, across every directory `PathResolver` resolves for it: conventional layout, packs, in-repo engines. `SourceScan.paths` stats only, `each` reads the source on top of it, and `classes` names each file by its declared constant. An introspector that globs `app/<kind>` itself is the mistake this entry exists to name: it misses every pack and engine, and it names files by their path rather than by what they declare.

Distinct from the **eager load** of the booted tier (`EagerLoad`), which makes constants exist rather than reading files, and from a **targeted walk** - one named file handed to `SourceIntrospector` with the listeners that file needs.

## Declared constant

What a source file calls its own class, as opposed to the **path name** - the constant its path camelizes to. The two differ wherever the app registers an inflection, because Zeitwerk resolves a path through the app's own inflector and the static tier has never loaded it: `app/controllers/activitypub/` is `ActivityPub` in Mastodon, and `Oauth` is a constant nothing defines. `DeclaredConstant` reads the class the source declares, and since an inflection only ever changes case, the declaration that names a file is the one equal to the path name ignoring case. Anything else - a second class in the file, a nested error class, a tree Prism recovered from a syntax error - is not this file's class, and there the path name stays the answer: it is the only thing carrying the namespace when the source does not.

Distinct from the **Static tier** sense of "declared": that one is about declaring a tier's capability up front rather than detecting it at runtime. This one is about a constant's spelling.

The other half of the same problem is the reverse trip. Once a name is the declared one, no consumer can rebuild the path from it - and a pack or an in-repo engine breaks that derivation too, inflection or not. So controllers and models carry `file:` from whichever tier found them, and consumers read it through `Payload` (`controller_file`, `controller_route_key`, `controller_for_route_key`, `model_file`). The rule: a tool that needs a path for a name reads it, never underscores it.

## Table name

The table a model reads. Rails builds it as `table_name_prefix` + the demodulized class name pluralized + `table_name_suffix`, unless the class assigns one itself or is an STI child, which reads its parent's. The static tier answers the same order from source: an explicit `self.table_name =`, else the table of the model it inherits from, else the prefix and suffix the enclosing modules declare around the file's own basename pluralized. Never the underscored constant - that turns `Admin::ActionLog` into `admin/action_logs` and `OAuthClientConfig` into `o_auth_client_configs`, neither of which is a table.

`TableName` reads those three declarations out of a source and holds the two derivations; walking the namespace and the superclass chain belongs to the caller, because only it has the other files. A reader that starts from a model name instead of a file asks `TableName.for_model_name`, which takes the table the model tier already recorded before falling back to the convention. A prefix declared outside the model directories is still invisible, so the answer stays [STATIC].

## Static tier

The mode where the app did not boot, or `--no-boot` was passed. What an introspector answers here is what it declared, never what a runtime check happened to detect. Every introspector in `INTROSPECTOR_MAP` extends `StaticTier` and names one of three kinds:

**files-only** - `call` runs unchanged against the static app handle (`StaticApp`), because it only ever read files. Most of the map.

**alternate-source** - `static_call` answers from a different source than `call` does: `db/schema.rb` instead of the connection, `config/routes.rb` instead of the route set.

**runtime-only** - needs `app.config`, `app.routes` or a live database, and refuses honestly.

An undeclared introspector fails the suite, and every files-only declaration is proven against `spec/fixtures/static_app` with nothing booted. Declaring files-only while defining `static_call` (or the reverse) is also a spec failure.

The tier also caps what the records inside an answer may claim: no record can claim more than the tier carrying it, so an association or a scope the AST resolved with certainty reads `[STATIC]` inside a static entry rather than the `[VERIFIED]` the walk would give it on its own. One that the parser could not resolve keeps its lower `[INFERRED]`. A booted entry carries no tier mark, so its records keep theirs.

## Concern

Three senses inside the gem, and the payload one is wider than either everyday Rails reading.

**Concern (as payload)** - a module in a class's ancestor chain, minus framework noise. Not only `ActiveSupport::Concern`, and not only files under a concerns directory: anything reached by `include` or `prepend` counts, which is why `extend` and a singleton-class `include` do not. This is what `:concerns` holds in model and controller data and what a "Concerns" section renders. The booted tier reads `ancestors`, so it also sees what the superclass and other concerns pulled in; the static tier's list is the class's own file alone. The macros are a separate question: `ConcernMacros` walks the concern files on both tiers and merges what they declare into the same payload keys, tagged `from_concern:`, so a model whose associations all live in concerns does not answer "0 assoc". `ConcernMembership` decides membership for both tiers; renderers trust the payload rather than re-filtering.

**Concerns directory** - `app/*/concerns` as a place, glob-derived the way Rails autoloads it, never a hardcoded list. `ConcernPaths` is the one answer to "where does this app keep its concerns" for every surface that lists or counts them.

**Mixin** - the static detection feeding the payload: any `include`, `prepend` or `extend` with a constant argument, as `MixinsListener` reports it. Named mixin because it captures more than concerns; its `ancestor` flag marks the subset that becomes one.

## Action

The callable interface of a class as this gem reports it: the class's own public instance methods - a class nested in the same file is a separate owner, not part of the interface - minus framework-shaped `_` names, read source-first, with reflection minus the app-owned base as the honest fallback. `ActionResolver` is the one answer; controller and mailer are configurations of it, and a channel's "stream methods" are a narrower selection of the same reading.

## Filter chain

Which filters a controller runs, and which of them a given action runs. `ActionFilters` is the one answer, and every controller surface reads its filter line from there, so no two answers can disagree about what a class inherits or skips. `for_controller` answers about the class; `for` answers about one of its actions. Both return `own`, `inherited` and `skipped`.

**A skip is not the absence of a filter.** `skipped` holds unconditional skips only, and those are the ones a surface strikes through. Everything else keeps its place in the chain and carries the reason on the record, because a filter a class skips on some requests is still a filter that runs on the others: `if:`/`unless:` become `skipped_if`/`skipped_unless`, and `only:`/`except:` become `skipped_on`/`skipped_except` in the whole-controller answer.

**Ask about one action and the answer is absolute again.** On that action the filter either runs or is struck through, so a constraint that does not cover the action leaves no tail at all. That cuts both ways, and the second direction is the one that is easy to get wrong: a skip whose constraint leaves this action alone is the only evidence the chain runs that filter here at all, when the class that declared it is not in the payload. Such a record is marked as evidence, never as a skip, and a real condition on the same name always outranks it.

**Order is the run order, and a class's own body wins.** The chain keeps the order reflection or the source gives it, so a `prepend_before_action` does not fall behind everything the class inherits. A filter the body declares survives an ancestor's skip of the same name, because Rails re-adds it. Attribution names the ancestor whose body declared the filter, not the nearest one that merely carries it inherited.

**What it cannot see is stated rather than guessed.** A filter that only `ApplicationController` declares is missing from a static chain when nothing else in the payload mentions it; `docs/COMPATIBILITY.md` says so.

## Payload

The introspection context hash, in the sense consumers read it. `Payload` is the reading side: a section guard and pinned list readers whose key pairs a spec checks against the producing introspector's own output, so a renamed key fails a test instead of silently emptying a section everywhere. Facts rendered from it live once (`SectionFacts`); membership judgments are applied at the introspector seam, and readers trust the payload rather than re-filtering it.

## Standalone

Two senses on different axes. Qualify it; the bare word does not say which.

**Standalone install** - how the gem got installed: `gem install rails-ai-context`, driven through its own binary, never in the host app's Gemfile, so the `rails ai:*` rake tasks do not exist. `InstallMode.standalone?` is the decider, and the `standalone:` flag on `McpConfigGenerator` means this - it picks whether the written MCP command is the bare binary or a bundled invocation. `docs/STANDALONE.md` documents this sense only.

**Standalone server** - how MCP is served: the entry point that is its own process, `rails ai:serve_http` starting `Server` with `transport: :http`, serving MCP and nothing else. The middleware and the engine controller answer the same requests from inside the app's web server; the standalone server does not need one running. It says nothing about the install - an in-Gemfile app starts it from a rake task. ADR-0003 and `McpEdge` use this sense.
