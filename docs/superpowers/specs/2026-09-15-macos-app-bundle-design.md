# macOS App Bundle Packaging — Design

## Purpose

Today, building `lincity-ng` on macOS produces a raw executable plus a
`.tar.xz` that references Homebrew's absolute dylib paths — it only runs on
the machine (or identical Homebrew layout) it was built on. This design adds
a proper relocatable `.app` bundle, so the build output can be copied to
another Mac (or handed to the GitHub Actions macOS workflow) and just work.

This is a standalone, CMake-only change with no CI dependency — it can be
built and tested locally, and is scoped tightly enough to submit upstream as
its own PR later if desired (see "Upstream submission" below).

## Approach

Use CMake's built-in `BundleUtilities` module (`fixup_bundle`) rather than an
external tool like `dylibbundler`. It requires no extra dependency beyond
CMake itself, works identically in CI and locally, and is the standard idiom
for this exact problem. It mirrors the pattern the project already uses for
Windows: `CMakeLists.txt:189-211` installs a `RUNTIME_DEPENDENCY_SET` and,
inside `if(WIN32)`, bundles DLLs next to the executable. A parallel
`if(APPLE)` block does the analogous thing for dylibs, plus rewrites their
load-command paths to be bundle-relative (which `RUNTIME_DEPENDENCY_SET`
alone does not do — `fixup_bundle` is what handles that rewrite).

## Components

- **`CMakeLists.txt`**: set `MACOSX_BUNDLE` on the `lincity-ng` target when
  `APPLE`, with `MACOSX_BUNDLE_INFO_PLIST` pointing at a new
  `mk/cmake/Info.plist.in` template. `CFBundleIdentifier` = `${APPSTREAM_ID}`,
  `CFBundleShortVersionString`/`CFBundleVersion` = `${FULL_PROJECT_VERSION}`.
- **New `if(APPLE)` block** (parallel to the existing `if(WIN32)` block):
  installs the `dll_dependencies` runtime-dependency set into
  `Contents/Frameworks/`, then an `install(CODE [[ include(BundleUtilities);
  fixup_bundle(...) ]])` step.
- **App icon**: an `.icns` is required (only `.png`/`.ico` exist today, per
  `CPACK_PACKAGE_ICON`/`CPACK_NSIS_MUI_ICON`). Generate it at configure time
  from the existing PNG via `iconutil`/`sips` (one `execute_process` call)
  rather than checking in a new binary asset — avoids maintaining a second
  copy of the icon in a different format. Confirm this works cleanly during
  implementation; fall back to a checked-in `.icns` if the generation proves
  fragile.

## Data flow

- Data/locale files already install via `add_subdirectory(data
  ${CMAKE_INSTALL_APPDATADIR})` (`CMakeLists.txt:182`). Inside a bundle they
  must land under `Contents/Resources/` so the existing
  `LINCITYNG_RELOCATABLE` logic (`Config.cpp:99-118`, using
  `SDL_GetBasePath()`) resolves the app data dir correctly at runtime. This
  requires setting `CMAKE_INSTALL_BINDIR` / `CMAKE_INSTALL_APPDATADIR` to
  `Contents/MacOS` / `Contents/Resources` when `APPLE AND MACOSX_BUNDLE`, and
  building with `-DLINCITYNG_RELOCATABLE=ON`.
- **Risk to validate during implementation**: SDL3's `SDL_GetBasePath()`
  behavior inside a `.app` bundle needs to be confirmed empirically (its
  docs are ambiguous on the exact path returned when running from inside a
  bundle vs. a bare executable). This is the main technical uncertainty in
  this subsystem.
- Packaging stays CPack `TXZ` (already the non-Windows default,
  `CMakeLists.txt:221`) — a `.app` is just a directory, so tar preserves it
  fine. No CPack generator changes needed.

## Error handling

The build already `REQUIRED`s all dependencies via `find_package`.
`fixup_bundle` fails loudly (fatal CMake error) if a dylib can't be
resolved — no silent partial bundles.

## Testing

Build locally with `-DLINCITYNG_RELOCATABLE=ON`, run `cpack`, then copy the
resulting `.app` to a directory/user account without Homebrew on the dylib
search path and confirm it launches. This proves the bundle is actually
self-contained rather than "worked because Homebrew was still reachable."

## Upstream submission considerations

This fork's PR policy (per PR #388) requires forking + an AI-disclosure note
in the PR description, and prior review feedback flagged removing
unsupported causal framing from descriptions. If this bundle work is later
split off and submitted upstream, follow that same policy: disclose AI
assistance, and describe what changed without over-claiming why upstream
should want it. The disclosure requirement applies to commit messages as
well as the PR description — if commits from this branch are cherry-picked
or rebased into an upstream-bound PR, carry the disclosure into each commit
message, not just the PR summary.

## Out of scope

- Code signing / notarization — unsigned bundles are fine for private use
  (Gatekeeper can be bypassed manually); not needed for this design.
- Intel (`x86_64`) support — deferred; see the companion CI design doc.
- A `.dmg` installer (CPack `DragNDrop`/`Bundle` generators) — the plain
  `.tar.xz` of the `.app` is sufficient for private use.
