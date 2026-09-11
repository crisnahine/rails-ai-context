# Releasing

The tag publishes, not the merge. `.github/workflows/release.yml` runs on a
pushed `v*` tag and does three things in order: the unit matrix, a gate that
demands an already-green E2E run for that exact commit, then the publish to
RubyGems, the GitHub release and the MCP registry.

Work this list top to bottom. Every item is checkable before the tag exists,
which matters because a tag that fails the version check has already been
pushed.

## Before the release commit

1. **The Changed section picks the number.** Read `## [Unreleased]` before
   renaming it. Anything under `Changed` that a consumer can observe - a
   renamed key in an MCP resource or a generated file, a flag that now refuses,
   an exit code that moved, a default that flipped - rules out a patch bump.
   Added entries rule one out too. A release whose whole section is `Fixed` is
   the patch case. Nothing downstream checks this, so it is decided here or not
   at all.
2. **The changelog section is the release notes.** Rename `## [Unreleased]` to
   `## [X.Y.Z] - YYYY-MM-DD`. The publish job extracts the notes with an awk
   range anchored on `^## \[X.Y.Z\]`, so a heading that does not match that
   shape exactly ships a release whose body is a link to the file.
3. **The version lives in two files and they must agree with the tag.**
   `lib/rails_ai_context/version.rb` is the one the workflow checks: the
   publish job compares the tag minus its `v` against `RailsAiContext::VERSION`
   and fails when they differ. `server.json` carries the same number for the
   MCP registry. The workflow rewrites `server.json` in its own checkout and
   commits the bump back to `main` on its own, so a stale value there costs an
   extra bot commit rather than a failed release. Bump both in the release
   commit anyway.
4. **Prose that names the last version goes stale where no check can see it.**
   `docs/COMPATIBILITY.md` names the release its proof sources come from. Grep
   the tree for the previous version before committing.

## Before the tag

5. **CI is green on the exact commit that will be tagged.** Check the run, do
   not infer it from a local pass. The release matrix is stricter than a local
   run in two ways: it runs seeds 1, 27377 and 90210 rather than a random one,
   and it runs `--order defined` as a fourth ordering no seed reproduces.
6. **A successful E2E run exists for that same SHA.** The E2E workflow does not
   run on tags, and the release's `e2e-gate` job asks the API for a completed
   successful `e2e.yml` run whose `head_sha` is this commit. Start it by hand
   from Actions and let it finish before tagging.

## Tagging

7. Tag the merge commit and push the tag. Nothing publishes until the tag is on
   the remote.

## After

8. **Confirm the release object exists and is not a draft**, and that its notes
   are this version's changelog section rather than the fallback sentence.
9. **Confirm the gem is on RubyGems and the version is in the MCP registry.**
   Both jobs skip themselves when the version is already published, so a skip
   in the log is not the same as a failure.
10. **Close what the release closed.** On GitHub a comma list after one `Closes`
   keyword closes only the first issue. Write the keyword once per issue.
