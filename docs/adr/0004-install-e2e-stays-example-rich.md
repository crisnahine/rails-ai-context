# The install e2e specs keep their examples; the fast specs took the load instead

Status: accepted

The install program (#116, #117) planned to shrink e2e install coverage to "one smoke per entry", on the stated grounds that install changes were paying a 30-minute loop. Measured before acting, that premise does not hold, so the trim was not made.

## What it costs now

The whole e2e suite is about 4 minutes for 159 examples, and builds 11 throwaway Rails apps. The three install specs account for 3 of those apps and 31 examples in roughly 73 seconds.

Within one install spec, the app is the cost and the examples are nearly free:

| Run | Time |
|-----|------|
| `standalone_install_spec.rb`, all 7 examples | 9.6s |
| the same file, 1 example | 6.5s |

So `rails new` plus `bundle install` is ~6.2s and each further example is ~0.5s. Cutting all three files to one example each would drop ~28 examples and save ~14 seconds of a 4-minute suite. The apps - the actual cost - would all still be built, because the three install paths (in-Gemfile, standalone, zero-config) are what the separate apps exist to distinguish.

## What it would cost to trim

Three of the surviving install examples have no unit-level equivalent, because they exercise the generator's prompting rather than its output: stdin hitting EOF mid-prompt, `--defaults` skipping every prompt, and a re-run being idempotent. Those are the paths that broke before, and they cannot be reproduced without running the real generator against a real app.

## The part of the goal that was real

The intent behind the bullet - that install changes stop paying a slow loop - is served by moving the questions that used to need an app into fast specs. `Install::SelectionRecord` and `Install::AiTool` are unit-tested with no Rails boot, and the entry round-trip that used to justify three e2e runs is now `spec/lib/rails_ai_context/install/entry_parity_spec.rb`, which runs in milliseconds.

Revisit this if the app-build count grows or if a fixture app can be built once and shared across install paths. Deleting examples is not the lever.
