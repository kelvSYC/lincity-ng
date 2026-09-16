## Unreleased

###### Internal
- macOS builds now produce a relocatable, self-contained `lincity-ng.app`
  bundle via `cpack`/`cmake --install`, instead of a bare executable and
  loose data directory. Third-party dylib dependencies are bundled into
  `Contents/Frameworks` and the bundle is ad-hoc code-signed (not
  notarized/Developer-ID signed, so it's intended for local/unnotarized
  use only).

###### Documentation / Translation
- Updated the macOS Packaging section of `doc/BUILD_OPTIONS.md` to
  describe the new `.app` bundle build instead of listing it as future
  work.
