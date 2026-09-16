# macOS App Bundle Packaging Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make `cpack` on macOS produce a relocatable `lincity-ng.app` bundle
(dylibs bundled and rewritten to be self-contained) instead of a raw
executable that only runs on the machine it was built on.

**Architecture:** Extend `CMakeLists.txt`'s existing Windows DLL-bundling
pattern (`RUNTIME_DEPENDENCY_SET`) with a parallel `APPLE` path that also
runs CMake's built-in `fixup_bundle` (from the `BundleUtilities` module) to
rewrite dylib load-commands to be bundle-relative. Data files move into
`Contents/Resources` so the existing `LINCITYNG_RELOCATABLE` runtime lookup
(`Config.cpp:99-118`, based on `SDL_GetBasePath()`) can find them — this
plan investigates that lookup's actual in-bundle behavior empirically before
locking in the install-directory layout, since SDL3's docs don't say
whether `SDL_GetBasePath()` returns `Contents/MacOS/` or `Contents/Resources/`
when running from inside a `.app`.

**Tech Stack:** CMake 3.21+, CMake's `BundleUtilities`/`GNUInstallDirs`
modules, SDL3, Homebrew (local dev dependency install only).

**Spec:** `docs/superpowers/specs/2026-09-15-macos-app-bundle-design.md`

## Global Constraints

- No new external tools/dependencies beyond CMake itself (no `dylibbundler`)
  — spec's approach decision.
- Bundle must launch with no Homebrew paths reachable (`DYLD_LIBRARY_PATH`
  unset, dependencies not on the linker's default search path) — proves
  self-containment.
- No code signing / notarization — out of scope per spec.
- CPack packaging generator stays `TXZ` — no generator changes.
- All new/changed CMake logic must be gated behind `if(APPLE)` (or nested
  under it) so Linux/Windows builds are unaffected.

---

### Task 1: App icon (`.icns`) generation

**Files:**
- Modify: `data/CMakeLists.txt` (icon handling currently at lines 28-31 for
  `WIN32`)

**Interfaces:**
- Produces: `${CMAKE_CURRENT_BINARY_DIR}/${APPSTREAM_ID}.icns` at configure
  time, installed to `${CMAKE_INSTALL_APPDATADIR}/${APPSTREAM_ID}.icns` —
  later tasks (Task 2's `Info.plist`, Task 4's install-dir remap) reference
  it by that install-destination filename as the bundle's
  `CFBundleIconFile`.

- [ ] **Step 1: Generate the `.icns` at configure time**

  In `data/CMakeLists.txt`, immediately after the existing `if(WIN32)` icon
  block (after line 31), add:

  ```cmake
  # app icon for macOS
  if(APPLE)
    set(MACOS_ICNS_FILE "${CMAKE_CURRENT_BINARY_DIR}/${APPSTREAM_ID}.icns")
    set(MACOS_ICONSET_DIR "${CMAKE_CURRENT_BINARY_DIR}/${APPSTREAM_ID}.iconset")
    file(MAKE_DIRECTORY "${MACOS_ICONSET_DIR}")
    foreach(iconSize IN ITEMS 16 32 128 256 512)
      math(EXPR iconSize2x "${iconSize} * 2")
      execute_process(
        COMMAND sips -z ${iconSize} ${iconSize} "${CMAKE_CURRENT_SOURCE_DIR}/${APPSTREAM_ID}_2x.png"
          --out "${MACOS_ICONSET_DIR}/icon_${iconSize}x${iconSize}.png"
        RESULT_VARIABLE sipsResult
        OUTPUT_QUIET
      )
      if(NOT sipsResult EQUAL 0)
        message(FATAL_ERROR "Failed to generate ${iconSize}x${iconSize} icon via sips")
      endif()
      execute_process(
        COMMAND sips -z ${iconSize2x} ${iconSize2x} "${CMAKE_CURRENT_SOURCE_DIR}/${APPSTREAM_ID}_2x.png"
          --out "${MACOS_ICONSET_DIR}/icon_${iconSize}x${iconSize}@2x.png"
        RESULT_VARIABLE sipsResult
        OUTPUT_QUIET
      )
      if(NOT sipsResult EQUAL 0)
        message(FATAL_ERROR "Failed to generate ${iconSize}x${iconSize}@2x icon via sips")
      endif()
    endforeach()
    execute_process(
      COMMAND iconutil -c icns "${MACOS_ICONSET_DIR}" -o "${MACOS_ICNS_FILE}"
      RESULT_VARIABLE iconutilResult
    )
    if(NOT iconutilResult EQUAL 0)
      message(FATAL_ERROR "Failed to generate .icns via iconutil")
    endif()
    install(FILES "${MACOS_ICNS_FILE}"
      DESTINATION "${CMAKE_INSTALL_APPDATADIR}"
    )
  endif()
  ```

  This uses the existing `${APPSTREAM_ID}_2x.png` (already in the repo,
  referenced at `data/CMakeLists.txt:37`) as the highest-res source, and
  `sips`/`iconutil` (both ship with macOS — no new dependency).

  The `install(FILES ...)` call installs the generated `.icns` to
  `${CMAKE_INSTALL_APPDATADIR}` under its own name (`${APPSTREAM_ID}.icns`)
  — the same variable the data files a few lines above this block already
  install into. Before Task 4 lands, that variable is still the default
  Linux-style path (harmless for this task's own verification, which only
  checks the generated build-tree file); once Task 4 overrides
  `CMAKE_INSTALL_APPDATADIR` to `Contents/Resources` for `APPLE`, this same
  `install()` call starts placing the icon exactly where Task 2's
  `Info.plist` (`CFBundleIconFile` = `${APPSTREAM_ID}.icns`) expects to
  find it — no changes needed here when Task 4 lands.

- [ ] **Step 2: Verify the icon builds standalone**

  Run: `cmake -B build-icon-test -DCMAKE_BUILD_TYPE=Release && cmake --build build-icon-test --target lincity-ng 2>&1 | tail -20`

  Then check the file exists:
  `ls -la build-icon-test/data/io.github.lincity_ng.lincity-ng.icns`

  Expected: file exists and is non-empty (a few hundred KB). If `sips`/
  `iconutil` aren't found, the `FATAL_ERROR` message will name which one.

- [ ] **Step 3: Commit**

  ```bash
  git add data/CMakeLists.txt
  git commit -m "Generate .icns app icon for macOS builds

  Uses sips/iconutil (both ship with macOS) to build an .icns from the
  existing hi-res PNG, following the same per-platform icon pattern
  already used for the Windows .ico. Installed to CMAKE_INSTALL_APPDATADIR
  so it lands in the bundle's Contents/Resources once that variable is
  remapped for APPLE."
  ```

---

### Task 2: Bundle metadata — `MACOSX_BUNDLE` + `Info.plist`

**Files:**
- Create: `mk/cmake/Info.plist.in`
- Modify: `CMakeLists.txt:112-114` (existing `if(APPLE)` compile-definitions
  block — add bundle setup nearby) and `CMakeLists.txt:189-192` (the
  `install(TARGETS lincity-ng ...)` call)

**Interfaces:**
- Consumes: `${MACOS_ICNS_FILE}` variable name from Task 1 is local to
  `data/CMakeLists.txt`'s scope and not visible in the top-level
  `CMakeLists.txt`; this task instead references the icon by its known
  install destination filename (`${APPSTREAM_ID}.icns`) rather than the
  build-time variable.
- Produces: `LINCITYNG_MACOS_BUNDLE_NAME` CMake variable
  (`"${PROJECT_NAME}.app"`, i.e. `lincity-ng.app`) — Task 4 reads this to
  compute bundle-relative install paths. **This must be `${PROJECT_NAME}`,
  not `${PROJECT_NAME_PRETTY}`**: verified empirically (see ledger) that
  CMake names the on-disk `.app` bundle after the target's `OUTPUT_NAME`
  (which defaults to the target/project name, `lincity-ng`) — setting
  `MACOSX_BUNDLE_BUNDLE_NAME` does not rename the bundle folder, it only
  affects the default `CFBundleName` if the plist doesn't set one (which
  ours does, explicitly, in Step 1 below). Using the pretty name here would
  make this variable describe a bundle that doesn't exist on disk.

- [ ] **Step 1: Write the `Info.plist` template**

  Create `mk/cmake/Info.plist.in`:

  ```xml
  <?xml version="1.0" encoding="UTF-8"?>
  <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
  <plist version="1.0">
  <dict>
    <key>CFBundleName</key>
    <string>@PROJECT_NAME_PRETTY@</string>
    <key>CFBundleDisplayName</key>
    <string>@PROJECT_NAME_PRETTY@</string>
    <key>CFBundleIdentifier</key>
    <string>@APPSTREAM_ID@</string>
    <key>CFBundleVersion</key>
    <string>@FULL_PROJECT_VERSION@</string>
    <key>CFBundleShortVersionString</key>
    <string>@PROJECT_VERSION@</string>
    <key>CFBundleExecutable</key>
    <string>@PROJECT_NAME@</string>
    <key>CFBundleIconFile</key>
    <string>@APPSTREAM_ID@.icns</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>NSHighResolutionCapable</key>
    <true/>
  </dict>
  </plist>
  ```

- [ ] **Step 2: Wire up `MACOSX_BUNDLE` and the plist**

  In `CMakeLists.txt`, right after the `if(APPLE) add_compile_definitions("APPLE") endif()` block (line 112-114), add:

  ```cmake
  if(APPLE)
    set(CMAKE_MACOSX_BUNDLE ON)
    set(LINCITYNG_MACOS_BUNDLE_NAME "${PROJECT_NAME}.app")
  endif()
  ```

  `CMAKE_MACOSX_BUNDLE` set before `add_subdirectory(src)` (line 181) makes
  every executable target created after this point (including
  `lincity-ng`, defined in `src/lincity-ng/CMakeLists.txt:1`) a bundle by
  default — no per-target flag needed.

  The `configure_file()` call for the plist must NOT go here: at this point
  in the file `FULL_PROJECT_VERSION` hasn't been computed yet (that happens
  ~60 lines later, in the "compute LinCity-NG version" section), and
  `configure_file()` substitutes `@VAR@` placeholders using variable values
  *at the point it's called* — calling it early silently produces an empty
  `CFBundleVersion`. Instead, add the `configure_file()` call right after
  `message(STATUS "LinCity-NG version: ${FULL_PROJECT_VERSION}")`:

  ```cmake
  if(APPLE)
    configure_file(mk/cmake/Info.plist.in
      "${CMAKE_CURRENT_BINARY_DIR}/Info.plist" @ONLY)
  endif()
  ```

  Then, in the `install(TARGETS lincity-ng ...)` call at
  `CMakeLists.txt:189-192`, set the plist as a target property just before
  it (so it applies before the target is installed), and add a `BUNDLE
  DESTINATION` clause — `install(TARGETS)` errors at configure time on a
  `MACOSX_BUNDLE` target without one (`RUNTIME DESTINATION` alone is not
  enough once the target is a bundle):

  ```cmake
  if(APPLE)
    set_target_properties(lincity-ng PROPERTIES
      MACOSX_BUNDLE_INFO_PLIST "${CMAKE_CURRENT_BINARY_DIR}/Info.plist"
    )
  endif()
  set_target_properties(lincity-ng PROPERTIES RUNTIME_OUTPUT_DIRECTORY ${CMAKE_BINARY_BINDIR})
  install(TARGETS lincity-ng
      RUNTIME_DEPENDENCY_SET dll_dependencies
      RUNTIME DESTINATION ${CMAKE_INSTALL_BINDIR}
      BUNDLE DESTINATION ${CMAKE_INSTALL_BINDIR}
  )
  ```

  (`BUNDLE DESTINATION` only takes effect for `MACOSX_BUNDLE` targets, so
  this is a no-op on Linux/Windows — `RUNTIME DESTINATION` still governs
  those.)

- [ ] **Step 3: Verify the bundle is created**

  ```bash
  cmake -B build-bundle-test -DCMAKE_BUILD_TYPE=Release
  cmake --build build-bundle-test
  cmake --install build-bundle-test --prefix build-bundle-test/install
  find build-bundle-test/install -name "*.app" -maxdepth 3
  ```

  Expected: `build-bundle-test/install/bin/lincity-ng.app` exists (bundle
  installs under the default `CMAKE_INSTALL_BINDIR`, `bin`, same as the
  non-bundle executable would have), and `lincity-ng.app/Contents/Info.plist`
  / `lincity-ng.app/Contents/MacOS/lincity-ng` both exist (`ls
  build-bundle-test/install/bin/lincity-ng.app/Contents/MacOS/`). Also check
  `cat build-bundle-test/install/bin/lincity-ng.app/Contents/Info.plist` —
  `CFBundleVersion` must be non-empty (confirms the `configure_file()`
  placement is correct).

- [ ] **Step 4: Commit**

  ```bash
  git add mk/cmake/Info.plist.in CMakeLists.txt
  git commit -m "Build lincity-ng as a macOS .app bundle

  Sets CMAKE_MACOSX_BUNDLE before the executable target is created and
  supplies a generated Info.plist, so 'cmake --install' now produces a
  lincity-ng.app instead of a bare executable on APPLE."
  ```

---

### Task 3: `SDL_GetBasePath()` in-bundle behavior — already measured

This was a spike, resolved during plan-writing rather than left as a guess
for the implementer: `Config.cpp:99-118`'s relocatable app-data-dir logic
assumes `SDL_GetBasePath()` returns the directory containing the running
executable (true on Linux/Windows). Inside a real `.app` bundle it does
not — it returns the bundle's `Contents/Resources/` directory instead
(matching SDL2's long-documented macOS behavior).

**Finding, verified empirically** (not from docs) using the same SDL3
version this project builds against (Homebrew `sdl3`, `pkg-config --cflags
--libs sdl3` on this machine): a minimal C program calling
`SDL_GetBasePath()`, compiled and run from inside a hand-built
`Test.app/Contents/MacOS/Test`, printed:

```
SDL_GetBasePath() = /tmp/sdl_basepath_spike/Test.app/Contents/Resources/
```

i.e. **`SDL_GetBasePath()` returns `Contents/Resources/`**, not
`Contents/MacOS/`, when run from inside a bundle.

**Consequence for Task 4:** since `basePath` already *is*
`Contents/Resources/`, and Task 4 makes `CMAKE_INSTALL_APPDATADIR` point at
that same directory, `appDataDir` can be set to `basePath` directly — no
`invBin`-style ascend-then-descend math is needed or correct for the bundle
case (that math is for the Linux/Windows layout where the binary and app
data live in sibling directories under a shared prefix).

**If SDL is upgraded and this ever needs reconfirming**, the reproduction
steps are: build a trivial SDL3 program, place it at
`SomeName.app/Contents/MacOS/SomeName` with a minimal `Info.plist`
(`CFBundleExecutable`/`CFBundleIdentifier`/`CFBundlePackageType` are
enough), run it, and read the printed path.

No files change in this task — it's a recorded finding Task 4 implements
against, not code.

---

### Task 4: Install-directory layout + dylib bundling

**Files:**
- Modify: `CMakeLists.txt:171-177` (install-directory variable computation)
- Modify: `CMakeLists.txt:189-211` (the `install(...)` block, adding an
  `APPLE` branch parallel to the existing `WIN32` one)

**Interfaces:**
- Consumes: `LINCITYNG_MACOS_BUNDLE_NAME` from Task 2; the
  `dll_dependencies` runtime-dependency-set name already established at
  `CMakeLists.txt:190`; Task 3's finding that `SDL_GetBasePath()` returns
  `Contents/Resources/` inside a bundle.

- [ ] **Step 1: Remap install directories for the bundle**

  In `CMakeLists.txt`, override `CMAKE_INSTALL_BINDIR` and
  `CMAKE_INSTALL_APPDATADIR` for `APPLE` right after both are given their
  normal defaults (after line 174, before the `CMAKE_BINARY_*` derivations
  at lines 175-177 — those must see the overridden values):

  ```cmake
  include(GNUInstallDirs)
  set(CMAKE_INSTALL_APPDATADIR ${CMAKE_INSTALL_DATADIR}/${CMAKE_PROJECT_NAME})
  set(CMAKE_INSTALL_FULL_APPDATADIR ${CMAKE_INSTALL_FULL_DATADIR}/${CMAKE_PROJECT_NAME})
  if(APPLE)
    # SDL_GetBasePath() resolves to Contents/Resources/ inside a bundle
    # (verified empirically, see Task 3) rather than the binary's own
    # directory, so app data must be installed directly there rather than
    # at the usual DATADIR/PROJECT_NAME offset used on Linux/Windows.
    #
    # CMAKE_INSTALL_BINDIR is "." (not a nested Contents/MacOS path):
    # verified empirically that install(TARGETS ... BUNDLE DESTINATION x)
    # installs the *entire* bundle folder to x/<name>.app — CMake places
    # Contents/MacOS/<exe> inside automatically. Setting this to a nested
    # path would install the whole bundle nested at
    # <prefix>/lincity-ng.app/Contents/MacOS/lincity-ng.app/... instead of
    # <prefix>/lincity-ng.app/. "." keeps the bundle directly at the
    # prefix root, matching where CMAKE_INSTALL_APPDATADIR below expects
    # it (both resolve relative to the same prefix, so they refer to the
    # same lincity-ng.app).
    set(CMAKE_INSTALL_BINDIR ".")
    set(CMAKE_INSTALL_APPDATADIR "${LINCITYNG_MACOS_BUNDLE_NAME}/Contents/Resources")
  endif()
  set(CMAKE_BINARY_BINDIR ${CMAKE_BINARY_DIR}/${CMAKE_INSTALL_BINDIR})
  set(CMAKE_BINARY_DATADIR ${CMAKE_BINARY_DIR}/${CMAKE_INSTALL_DATADIR})
  set(CMAKE_BINARY_APPDATADIR ${CMAKE_BINARY_DIR}/${CMAKE_INSTALL_APPDATADIR})
  ```

  `CMAKE_INSTALL_DATADIR` itself (used elsewhere for the Linux desktop
  file/metainfo/man page install destinations in `data/CMakeLists.txt`) is
  deliberately left unchanged — those files aren't meaningful inside a
  `.app` and installing them to a `share/` directory alongside the bundle
  at the top of the install prefix is harmless (the same thing already
  happens today on Windows, which doesn't remap `CMAKE_INSTALL_DATADIR`
  either).

  Then, because `basePath` (`SDL_GetBasePath()`'s return value) is now
  exactly equal to the installed `CMAKE_INSTALL_APPDATADIR`, `Config.cpp`'s
  relocation math needs an `APPLE`-specific branch that uses `basePath`
  directly instead of the `invBin` ascend-then-descend logic meant for the
  Linux/Windows layout. In `src/lincity-ng/Config.cpp`, replace lines
  102-118:

  ```cpp
  #ifdef LINCITYNG_RELOCATABLE
  const std::filesystem::path basePath(SDL_GetBasePath());
  #ifdef APPLE
    // Inside a .app bundle, SDL_GetBasePath() already returns
    // Contents/Resources/, which is exactly where CMAKE_INSTALL_APPDATADIR
    // points (see the APPLE branch in CMakeLists.txt) — use it directly.
    if(!basePath.empty()) {
      appDataDir.default_ = basePath;
    }
    else {
      fmt::println(stderr,
        "error: failed to compute the relocation prefix: {}\n"
        "  Falling back to the install prefix.",
        SDL_GetError()
      );
    }
  #else
    const std::filesystem::path invBin =
      std::filesystem::path().lexically_relative(INSTALL_BINDIR);
    const std::filesystem::path relocPrefix =
      (basePath / invBin).lexically_normal();
    if(!relocPrefix.empty()) {
      appDataDir.default_ = relocPrefix / INSTALL_APPDATADIR;
    }
    else {
      fmt::println(stderr,
        "error: failed to compute the relocation prefix: {}\n"
        "  Falling back to the install prefix.",
        SDL_GetError()
      );
    }
  #endif
  #endif
  ```

  (`APPLE` here is the project's own compile definition set at
  `CMakeLists.txt:112-114`, the same macro already used elsewhere in this
  file — not the compiler-builtin `__APPLE__`.)

- [ ] **Step 2: Bundle dylibs via `fixup_bundle`**

  In `CMakeLists.txt`, after the existing `if(WIN32) ... endif()` block
  (ends at line 211), add:

  ```cmake
  if(APPLE)
    install(RUNTIME_DEPENDENCY_SET dll_dependencies
      DESTINATION "${LINCITYNG_MACOS_BUNDLE_NAME}/Contents/Frameworks"
      PRE_EXCLUDE_REGEXES "^/usr/lib/.*" "^/System/Library/.*"
      POST_EXCLUDE_REGEXES ".*"
      POST_INCLUDE_REGEXES ".*"
    )
    install(CODE [[
      include(BundleUtilities)
      fixup_bundle(
        "${CMAKE_INSTALL_PREFIX}/${LINCITYNG_MACOS_BUNDLE_NAME}"
        ""
        ""
      )
    ]])
  endif()
  ```

  `PRE_EXCLUDE_REGEXES`/`POST_EXCLUDE_REGEXES` skip system libraries (never
  bundle `/usr/lib` or `/System/Library` — they're guaranteed present on
  any Mac); `fixup_bundle` then does the actual load-command rewriting for
  everything that was copied in.

- [ ] **Step 3: Verify data files land correctly**

  ```bash
  rm -rf build-bundle-test
  cmake -B build-bundle-test -DCMAKE_BUILD_TYPE=Release -DLINCITYNG_RELOCATABLE=ON
  cmake --build build-bundle-test
  cmake --install build-bundle-test --prefix build-bundle-test/install
  ls build-bundle-test/install/lincity-ng.app/Contents/Resources | head -20
  ls build-bundle-test/install/lincity-ng.app/Contents/Frameworks
  ```

  Expected: `Contents/Resources` contains the game's data files (fonts,
  images, etc. — same tree that currently lands in
  `share/lincity-ng` on Linux); `Contents/Frameworks` contains copied
  `.dylib` files for SDL3/libxml2/fmt/etc.

- [ ] **Step 4: Commit**

  ```bash
  git add CMakeLists.txt src/lincity-ng/Config.cpp
  git commit -m "Bundle dylibs and relocate app data into the .app on macOS

  Adds an APPLE install branch mirroring the existing Windows DLL-bundling
  one: copies runtime dependencies into Contents/Frameworks and runs
  fixup_bundle to rewrite their load-commands to be bundle-relative. App
  data now installs into Contents/Resources, and Config.cpp gains an APPLE
  branch using SDL_GetBasePath() directly instead of the bin-relative
  math used on Linux/Windows, since SDL returns Contents/Resources/
  directly inside a bundle (verified empirically) rather than the
  executable's own directory."
  ```

---

### Task 5: End-to-end portability verification

**Files:** none (verification only)

- [ ] **Step 1: Full release build and package**

  ```bash
  rm -rf build-release
  cmake -B build-release -DCMAKE_BUILD_TYPE=Release -DLINCITYNG_RELOCATABLE=ON
  cmake --build build-release
  cd build-release && cpack && cd ..
  ```

  Expected: a `lincity-ng-<version>-Darwin.tar.xz` (or similarly named per
  `CPACK_GENERATOR TXZ`) is produced without errors.

- [ ] **Step 2: Extract to an isolated location and strip Homebrew from the environment**

  ```bash
  mkdir -p /tmp/lincity-bundle-test
  tar -xf build-release/lincity-ng-*-Darwin.tar.xz -C /tmp/lincity-bundle-test
  find /tmp/lincity-bundle-test -name "*.app" -maxdepth 2
  env -i /tmp/lincity-bundle-test/*/lincity-ng.app/Contents/MacOS/lincity-ng --version
  ```

  `env -i` runs with an empty environment (no `PATH`, no `DYLD_*`
  variables Homebrew might have set), so any dependency the bundle still
  pulls from `/opt/homebrew` rather than its own `Contents/Frameworks`
  will fail to load here (`dyld: Library not loaded` or similar), proving
  the bundle isn't secretly relying on Homebrew being present.

  Expected: prints the version string and exits 0 — no dyld load errors.

- [ ] **Step 3: Confirm app data is found (not just that it launches)**

  ```bash
  env -i /tmp/lincity-bundle-test/*/lincity-ng.app/Contents/MacOS/lincity-ng --help 2>&1 | grep -i "app.data\|error"
  ```

  Expected: no "failed to compute" or "app data directory not found"
  style errors in the output (compare against the warning text at
  `Config.cpp:111-117` — its absence confirms the relocation math from
  Task 4 worked).

- [ ] **Step 4: Clean up test artifacts**

  ```bash
  rm -rf build-icon-test build-bundle-test build-spike build-release /tmp/lincity-bundle-test
  ```

  These are local verification scratch builds, not part of the repo — no
  commit for this task.

## Follow-up (out of scope for this plan)

- Wiring this into the GitHub Actions macOS build workflow — separate plan,
  see `docs/superpowers/specs/2026-09-15-github-actions-ci-design.md`.
- If this work is later split off for an upstream PR, both the PR
  description and every individual commit message need the AI-disclosure
  note per this fork's PR #388 policy (see the app-bundle design doc's
  "Upstream submission considerations" section) — the commit messages
  above do not include it since they're written for this private fork.
