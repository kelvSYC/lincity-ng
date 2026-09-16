# Private GitHub Actions CI — Design

## Purpose

`kelvSYC/lincity-ng` is a public fork carrying a macOS/Clang build fix
(`macos-build-fix` branch) on top of upstream `lincity-ng/lincity-ng`. There
is currently no CI. This adds two independent workflows:

1. A weekly job that keeps the fork's branches in sync with upstream
   (including release tags), rebasing where it can and flagging where it
   can't.
2. An on-demand macOS build that produces the relocatable `.app` bundle
   (see the companion app-bundle design doc) for a given tag/ref.

**Important constraint**: this repo is public. GitHub Actions artifacts on a
public repo are downloadable by anyone with read access to the repo — i.e.
the public — regardless of any "private" intent. There is no artifact-level
privacy control available here. This design does not attempt to work around
that; it minimizes exposure instead (short artifact retention, no public
Release, manual-only build trigger) rather than promising true privacy.

## Where the workflows live

`master` and `macos-build-fix` diverge (the latter carries the macOS fix on
top of the former). Since the CI config must be rebased along with
`macos-build-fix`'s other commits, both workflow files live on
`macos-build-fix`, not `master`. `master` stays an unmodified mirror of
upstream.

## Workflow 1 — `sync-upstream.yml`

**Trigger**: `schedule` (weekly cron) and `workflow_dispatch` (manual runs).

**Steps**:
1. Add `upstream` remote (`lincity-ng/lincity-ng`), `git fetch upstream
   --tags`.
2. Fast-forward/rebase `master` onto `upstream/master`. Since `master` is
   meant to be a clean mirror with no local changes, this should always be a
   plain fast-forward; push directly. A non-fast-forward here is unexpected
   and should fail the job loudly rather than force-pushing over it.
3. Rebase `macos-build-fix` onto the updated `master`. If clean, force-push
   (with `--force-with-lease`) the result. If the rebase conflicts, stop and
   open a tracking issue listing the conflicting commits — not a PR, since
   there's no reviewable "other side," just a rebase you need to resolve
   locally.
4. Push any newly-fetched tags to `origin` (the fork) regardless of whether
   steps 2-3 succeeded, so new release tags are available even when the
   branches need manual attention.

**Error handling**: each branch's rebase is independent — a conflict on
`macos-build-fix` doesn't block `master` from updating, and vice versa. Tag
sync (step 4) always runs last regardless of earlier failures.

## Workflow 2 — `macos-build.yml`

**Trigger**: `workflow_dispatch` with a required `ref` input (default:
latest tag). A `push: tags:` trigger block is included but commented out /
disabled, ready to enable later if upstream release cadence makes
auto-building on tag push worthwhile — not turned on now, per explicit
decision to build only on demand for release tags.

**Runner**: `macos-14` (Apple Silicon only). Intel (`macos-13`) support is
deferred; revisit if it's ever needed.

**Steps**:
1. Checkout `ref`.
2. `brew install` the macOS dependencies listed in
   `doc/DEPENDENCIES.md`'s macOS section.
3. `cmake -B build -DCMAKE_BUILD_TYPE=Release -DLINCITYNG_RELOCATABLE=ON`.
4. `cmake --build build`.
5. `cpack` (produces the `.app` bundle from the companion design, packaged
   as `.tar.xz`).
6. `actions/upload-artifact` with `retention-days: 7`. No GitHub Release is
   created — this keeps the exposure window short and avoids a permanent
   public download link, per the "public repo, private-use build" tradeoff
   above.

**Independence from Workflow 1**: this workflow only consumes tags/refs that
already exist in the repo — it has no dependency on `sync-upstream.yml`'s
internals. It can be deleted on its own the day upstream ships their own
macOS CI, without touching the sync workflow.

## Open items / assumptions carried from the app-bundle design

- Depends on the app-bundle design doc's CMake changes being implemented
  first (`-DLINCITYNG_RELOCATABLE=ON` + the bundle-producing `if(APPLE)`
  block) — this workflow is a thin wrapper around that, not new packaging
  logic of its own.
- If that implementation reveals the `.icns` generation or
  `SDL_GetBasePath()` bundle behavior needs adjustment, this workflow's
  `cmake`/`cpack` invocation may need matching flags — expected to be a
  small follow-up, not a redesign.

## Out of scope

- Auto-triggering the macOS build on tag push (provisioned for, not
  enabled).
- Publishing a GitHub Release or any other public distribution channel.
- Windows/Linux CI (this fork's focus is the macOS build fix specifically).
