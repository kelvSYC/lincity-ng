# Private GitHub Actions CI Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add two GitHub Actions workflows to the fork: a weekly job that
keeps `master`/`macos-build-fix` in sync with upstream and fetches new
release tags, and an on-demand macOS build that packages the relocatable
`.app` bundle (from the companion macos-app-bundle plan) as a short-lived
artifact.

**Architecture:** Two independent, single-file workflows under
`.github/workflows/`. `sync-upstream.yml` does a scheduled fetch/rebase/push
against the real `upstream` remote and opens a tracking issue on conflict.
`macos-build.yml` is a thin `workflow_dispatch`-triggered wrapper around the
`cmake`/`cpack` invocation already exercised locally by the app-bundle plan
— it has no dependency on `sync-upstream.yml`'s internals.

**Tech Stack:** GitHub Actions YAML, `macos-14` runner (Apple Silicon),
`ubuntu-latest` runner for the sync job, Homebrew (macOS runner's
pre-installed package manager), `gh` CLI (pre-installed on GitHub-hosted
runners) for issue creation, `actionlint` (local validation only — not
installed on runners, not part of the workflow itself).

**Spec:** `docs/superpowers/specs/2026-09-15-github-actions-ci-design.md`

## Global Constraints

- Workflows live on the `macos-build-fix` branch (not `master`) — `master`
  stays an unmodified mirror of upstream. (This plan's own commits land on
  the current working branch, which is based on `macos-build-fix`; no task
  below needs to switch branches.)
- No workflow publishes a GitHub Release or any public distribution
  channel. Artifact retention: 7 days.
- `macos-build.yml` triggers only via `workflow_dispatch` (manual). A
  `push: tags:` trigger is included as a commented-out block, not enabled.
- Runner: `macos-14` (Apple Silicon) only — no Intel/matrix build.
- **No task in this plan pushes to the real `origin`/`fork` remote on
  GitHub, opens a real issue, or triggers an actual Actions run.** All
  verification is local: YAML authoring, `actionlint` static validation,
  and manual trace-through of the logic. Pushing the branch and triggering
  a real workflow run for end-to-end validation is a deliberate, separate,
  user-confirmed step after this plan's review is complete — it's a
  visible side effect on a public repo, not something any task or agent in
  this plan does unilaterally.
- Homebrew package list for the build job must match
  `doc/DEPENDENCIES.md`'s macOS section verbatim (`cmake pkg-config sdl3
  sdl3_image sdl3_mixer sdl3_ttf libxml2 libxml++@5 fmt gettext`), plus the
  `-DCMAKE_PREFIX_PATH=$(brew --prefix libxml2)` configure flag that same
  doc recommends to prefer Homebrew's libxml2 over the older macOS-SDK copy.
- Route any workflow input (`inputs.ref`, etc.) through an `env:` block
  before use in a `run:` shell script rather than interpolating
  `${{ inputs.x }}` directly inline in shell — standard GitHub Actions
  script-injection hygiene, and what `actionlint`'s shellcheck integration
  expects.

---

### Task 1: `macos-build.yml` — on-demand macOS build workflow

**Files:**
- Create: `.github/workflows/macos-build.yml`

**Interfaces:**
- Consumes: the `.app`-bundle-producing CMake configuration from the
  macos-app-bundle plan (`cmake -B build -DCMAKE_BUILD_TYPE=Release` +
  `cpack`, producing `build/lincity-ng-*-Darwin.tar.xz`;
  `LINCITYNG_RELOCATABLE` no longer needs to be passed explicitly — it's
  now forced `ON` for `APPLE` unconditionally in `CMakeLists.txt`).
- Produces: nothing consumed by another task — this workflow is a leaf.

- [ ] **Step 1: Write the workflow file**

  Create `.github/workflows/macos-build.yml`:

  ```yaml
  name: macOS build

  on:
    workflow_dispatch:
      inputs:
        ref:
          description: >-
            Git ref (tag or branch) to build. Leave empty to build the
            latest lincity-ng-* tag.
          required: false
          default: ''
    # push:
    #   tags:
    #     - 'lincity-ng-*'
    # Disabled for now — builds are triggered manually per the fork's CI
    # design (docs/superpowers/specs/2026-09-15-github-actions-ci-design.md).
    # Uncomment to auto-build on every new release tag instead.

  permissions:
    contents: read

  jobs:
    build:
      runs-on: macos-14
      steps:
        - name: Checkout
          uses: actions/checkout@v4
          with:
            fetch-depth: 0

        - name: Resolve build ref
          id: resolve
          env:
            INPUT_REF: ${{ inputs.ref }}
          run: |
            if [ -n "$INPUT_REF" ]; then
              target="$INPUT_REF"
            else
              target="$(git tag --list 'lincity-ng-*' --sort=-v:refname | head -1)"
              if [ -z "$target" ]; then
                echo "::error::No ref given and no lincity-ng-* tags found in this checkout."
                exit 1
              fi
            fi
            echo "ref=$target" >> "$GITHUB_OUTPUT"

        - name: Checkout resolved ref
          env:
            RESOLVED_REF: ${{ steps.resolve.outputs.ref }}
          run: git checkout "$RESOLVED_REF"

        - name: Install dependencies
          run: |
            brew install cmake pkg-config sdl3 sdl3_image sdl3_mixer sdl3_ttf \
              libxml2 libxml++@5 fmt gettext

        - name: Configure
          run: |
            cmake -B build -DCMAKE_BUILD_TYPE=Release \
              -DCMAKE_PREFIX_PATH="$(brew --prefix libxml2)"

        - name: Build
          run: cmake --build build

        - name: Package
          run: |
            cd build
            cpack

        - name: Upload artifact
          uses: actions/upload-artifact@v4
          with:
            name: lincity-ng-macos-${{ steps.resolve.outputs.ref }}
            path: build/lincity-ng-*-Darwin.tar.xz
            retention-days: 7
            if-no-files-found: error
  ```

  Notes on choices already made (don't re-derive these):
  - `fetch-depth: 0` on checkout is required so `git tag --list` sees all
    tags and `git describe` (used internally by the CMake build for
    `FULL_PROJECT_VERSION`) can find the nearest tag.
  - The two-step checkout (checkout default ref first, then `git checkout`
    the resolved ref) is simpler than trying to compute "latest tag" before
    any checkout exists — `actions/checkout`'s own `ref:` input can't
    express "default to latest tag if empty" natively.
  - `if-no-files-found: error` on the upload step turns a silently-empty
    artifact (e.g. if `cpack`'s output filename pattern ever changes) into
    a loud job failure instead of a confusing empty download.

- [ ] **Step 2: Validate with `actionlint`**

  Run: `actionlint .github/workflows/macos-build.yml`

  Expected: no output (clean). If `actionlint` isn't installed, install it
  first: `brew install actionlint`. Fix any reported issues (shellcheck
  findings inside `run:` blocks, schema errors, unpinned action versions)
  before proceeding — do not skip this step or silence warnings.

- [ ] **Step 3: Manual trace-through (no real trigger)**

  Read through the YAML once as if you were GitHub Actions evaluating it:
  confirm `steps.resolve.outputs.ref` is defined before the artifact-name
  step references it (it is — `resolve` runs before `upload-artifact`),
  confirm the `env:` blocks correctly shadow `inputs.ref`/`steps.resolve.
  outputs.ref` rather than leaving a raw `${{ }}` inside any `run:` shell
  string, and confirm the commented-out `push: tags:` block is valid YAML
  as a comment (i.e., it wouldn't break parsing if accidentally
  uncommented with a typo — check indentation matches the `on:` block's
  structure).

  This step produces no artifact and needs no report beyond confirming (in
  your task report) that you did it and found no issues, or listing what
  you fixed.

- [ ] **Step 4: Commit**

  ```bash
  git add .github/workflows/macos-build.yml
  git commit -m "Add on-demand macOS build GitHub Actions workflow

  Manual (workflow_dispatch) workflow that builds a given tag/ref's
  relocatable .app bundle and uploads it as a short-retention artifact.
  No Release is published; this repo is public but the build is for
  private use, so exposure is minimized rather than made structurally
  private (not possible for a public repo's Actions artifacts)."
  ```

---

### Task 2: `sync-upstream.yml` — weekly upstream sync workflow

**Files:**
- Create: `.github/workflows/sync-upstream.yml`

**Interfaces:**
- Produces: nothing consumed by another task — this workflow is a leaf,
  independent of Task 1's workflow (per the spec's explicit requirement
  that the two be deletable independently).

- [ ] **Step 1: Write the workflow file**

  Create `.github/workflows/sync-upstream.yml`:

  ```yaml
  name: Sync upstream

  on:
    schedule:
      # Every Monday at 06:00 UTC. Adjust if a different cadence/day is
      # wanted later — this is not a load-bearing choice, just "weekly".
      - cron: '0 6 * * 1'
    workflow_dispatch: {}

  permissions:
    contents: write
    issues: write

  jobs:
    sync:
      runs-on: ubuntu-latest
      steps:
        - name: Checkout
          uses: actions/checkout@v4
          with:
            fetch-depth: 0
            token: ${{ secrets.GITHUB_TOKEN }}

        - name: Add upstream remote and fetch
          run: |
            git remote add upstream https://github.com/lincity-ng/lincity-ng.git
            git fetch upstream --tags

        - name: Fast-forward master onto upstream/master
          id: sync_master
          continue-on-error: true
          run: |
            git checkout master
            if git merge-base --is-ancestor master upstream/master; then
              git merge --ff-only upstream/master
              git push origin master
              echo "Fast-forwarded master to upstream/master."
            else
              echo "::error::master has diverged from upstream/master (not a fast-forward). Manual intervention required — this step is expected to always succeed since master should only ever mirror upstream."
              exit 1
            fi

        - name: Rebase macos-build-fix onto master
          id: sync_macos
          if: always()
          continue-on-error: true
          run: |
            git fetch origin master
            git checkout macos-build-fix
            if git rebase origin/master; then
              git push --force-with-lease origin macos-build-fix
              echo "conflict=false" >> "$GITHUB_OUTPUT"
              echo "Rebased macos-build-fix onto master."
            else
              git rebase --abort
              echo "conflict=true" >> "$GITHUB_OUTPUT"
              echo "::warning::macos-build-fix could not be rebased onto master cleanly; opening a tracking issue."
            fi

        - name: Open tracking issue on rebase conflict
          if: always() && steps.sync_macos.outputs.conflict == 'true'
          env:
            GH_TOKEN: ${{ secrets.GITHUB_TOKEN }}
            RUN_URL: ${{ github.server_url }}/${{ github.repository }}/actions/runs/${{ github.run_id }}
          run: |
            cat > /tmp/issue-body.md <<'BODY_EOF'
            The weekly upstream sync workflow could not cleanly rebase `macos-build-fix` onto the updated `master`.

            Run `git fetch upstream && git checkout macos-build-fix && git rebase master` locally to see and resolve the conflicting commits, then force-push.

            Workflow run: $RUN_URL
            BODY_EOF
            # Substitute $RUN_URL manually since the heredoc above is quoted
            # (deliberately, so the literal backticks above aren't run as
            # shell command substitution).
            sed -i "s#\$RUN_URL#$RUN_URL#" /tmp/issue-body.md
            gh issue create \
              --title "sync-upstream: macos-build-fix rebase conflict ($(date -u +%Y-%m-%d))" \
              --body-file /tmp/issue-body.md

        - name: Push any newly fetched tags
          if: always()
          run: git push origin --tags
  ```

  Notes on choices already made:
  - `continue-on-error: true` on both sync steps, plus `if: always()` on
    the steps that follow, is what makes the two branch-syncs and the
    tag-push independent of each other, per the spec's "each branch's
    rebase is independent" requirement — a failure in one does not skip
    the others.
  - The tracking issue is opened only on an actual rebase *conflict*
    (`sync_macos` step failed for that specific reason), not on every
    `sync_macos` failure indiscriminately — this matches the spec's intent
    ("open a tracking issue listing the conflicting commits" specifically
    for conflicts). Since the step exits non-zero on *any* internal
    failure and there's no simple way to distinguish "rebase conflict" from
    "some other git error" from inside a `continue-on-error` step other
    than the explicit `conflict` output variable this workflow sets itself,
    this is the accurate signal to use here.
  - `master`'s divergence case deliberately does **not** open an issue
    (per the spec: "fail the job loudly", not "open a tracking issue" —
    that's specific to the `macos-build-fix` conflict case). The job
    failing (visible in the Actions tab / any configured failure
    notification) is the loud signal for that case.

- [ ] **Step 2: Validate with `actionlint`**

  Run: `actionlint .github/workflows/sync-upstream.yml`

  Expected: no output (clean). Fix any reported issues before proceeding.

- [ ] **Step 3: Manual trace-through (no real trigger)**

  Trace both failure paths by reading the YAML:
  1. **`master` diverged**: `sync_master` step exits 1 (via `::error::` +
     `exit 1`), `continue-on-error: true` keeps the job running,
     `sync_macos` still runs (`if: always()`) and rebases onto whatever
     `master` currently is (stale, since the fast-forward didn't happen —
     this is the accepted, documented behavior, not a bug: the spec allows
     `macos-build-fix`'s rebase to proceed independently even when
     `master`'s update failed). Tag push still runs.
  2. **`macos-build-fix` conflicts**: `sync_macos` sets
     `conflict=true` and fails; `continue-on-error: true` keeps the job
     running; the "Open tracking issue" step's `if:` condition correctly
     reads `steps.sync_macos.outputs.conflict` (confirm the step ID
     matches and the output variable name is spelled identically in both
     places). Tag push still runs.

  Confirm in your report that both paths were traced and the `if:`/
  `continue-on-error:` combinations produce the behavior described above
  — this is the part most likely to have a subtle GitHub Actions
  semantics bug (e.g. `continue-on-error` still counts as job failure for
  branch-protection purposes even though later steps run — note this if
  you find it relevant, but it doesn't block this task since there's no
  branch protection on this personal fork to interact with).

- [ ] **Step 4: Commit**

  ```bash
  git add .github/workflows/sync-upstream.yml
  git commit -m "Add weekly upstream sync GitHub Actions workflow

  Fetches upstream (including tags), fast-forwards master, and rebases
  macos-build-fix onto the updated master. Each branch's sync is
  independent (a conflict on one doesn't block the other), and a rebase
  conflict on macos-build-fix opens a tracking issue rather than
  force-pushing over it. Tag sync always runs last regardless of earlier
  outcomes."
  ```

## Follow-up (out of scope for this plan)

- Actually pushing this branch's commits to the fork and triggering a real
  `workflow_dispatch` run of each workflow (or waiting for the real
  weekly schedule) to confirm end-to-end behavior on GitHub's
  infrastructure — `actionlint` and manual trace-through catch syntax and
  logic errors, but not everything (e.g. real Homebrew package
  availability/version drift on the `macos-14` image, actual `gh issue
  create` permissions). This needs explicit user confirmation before any
  push happens, since it's a visible action on a public repository.
- If this branch is later merged into `macos-build-fix`, these workflow
  files travel with it as part of the normal merge — no special handling
  needed beyond what the macos-app-bundle plan's own merge already
  requires.
