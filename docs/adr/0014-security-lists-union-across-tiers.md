# The lists that keep things back are a union on every tier

Status: accepted

`sensitive_patterns`, `excluded_paths` and `skip_tools` keep a file or a tool out of a tool's reach. The booted tier loaded `.rails-ai-context.yml` after `config/application.rb` and before the initializers, and for these keys the file's value replaced what was there: a pattern application.rb appended was dropped, and the file was served. The static tier reads the same Ruby without running it and adds its literals on top of the file's, so it refused that file. One setting had two answers, and the weaker one was the server's.

## Decision

- For these three keys the file's entries and every value the code writes are kept together, whichever runs first. A block before the load keeps what it added beyond the defaults (all of it, when it assigned the key); an assignment after the load keeps the file's entries beside the new value.
- Every other key keeps the boot's order: a block before the load claims the key, and an initializer after it writes the last value.
- `UnbootedSettings` reads an app's settings without a boot in the same order, so the static tier, the tool list, the install and the plugin's hook give the answer the booted server gives, or a stricter one.

## Consequences

Code can no longer drop an entry the file lists by assigning the key: `config.skip_tools = []` in an initializer leaves the file's `skip_tools` in place. To serve a tool or a file the file holds back, edit the file. An in-place removal (`delete`) still runs on a booted app; the static tier does not follow one, the stricter reading.

## Alternatives not taken

- **The file replaces the key, as before**: the booted server keeps serving what the static tier and the docs say is held back.
- **Warn when a list differs from its default at load**: says something is wrong and still serves the file.
