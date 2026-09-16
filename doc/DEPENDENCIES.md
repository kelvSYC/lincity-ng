# Dependencies

Following is the list of dependencies for building and/or running LinCity-NG.

### Runtime Dependencies

* SDL3 3.2.0 or later

  http://www.libsdl.org

* SDL3_mixer 3.2.0 or later (with Ogg Vorbis support)

  https://github.com/libsdl-org/SDL_mixer

* SDL3_image 3.2.0 or later (with PNG support)

  https://github.com/libsdl-org/SDL_image

* SDL3_ttf 3.2.0 or later

  https://github.com/libsdl-org/SDL_ttf

* zlib 1.0 or later

  https://zlib.net/

* libxml2 2.6.11 or later (recommended 2.13.0 or later)

  http://xmlsoft.org/

* libxml++ 5.0

  https://libxmlplusplus.github.io/libxmlplusplus/

* fmt 9.0.0 or later

  https://fmt.dev/latest/index.html

* libintl (optional)

  https://www.gnu.org/software/gettext/

  Required for native language support.

  Some libc implementations provide libintl built-in. If this is the case,
  libintl need not be separately installed.

### Build Dependencies

* C++ compiler supporting C++17 (such as gcc)

  https://gcc.gnu.org/

* CMake 3.21 or later

  https://cmake.org/

* xsltproc

  https://gitlab.gnome.org/GNOME/libxslt

  xsltproc is provided by LibXslt

* pkg-config

  https://www.freedesktop.org/wiki/Software/pkg-config

  Used to locate libxml++.

* Header files for all [runtime dependencies](#runtime-dependencies)

  If you use packages from your distribution, header files are sometimes
  provided in separate `*-dev` packages.

* Include What You Use (optional)

  https://include-what-you-use.org/

  Recommended for identifying and fixing potential `#include` issues.

* gettext (optional)

  https://www.gnu.org/software/gettext/

  Required for native language support.


## macOS

Most dependencies above are available via [Homebrew](https://brew.sh):

```
brew install cmake pkg-config sdl3 sdl3_image sdl3_mixer sdl3_ttf \
  libxml2 libxml++@5 fmt gettext
```

zlib and xsltproc do not need to be installed separately; both already ship
with macOS.

Note the `@5`: Homebrew's plain `libxml++` formula is the incompatible 2.x
series. `brew install libxml++` alone will not satisfy this project's
`libxml++-5.0` requirement.

The macOS SDK also ships its own old copy of libxml2 (2.9.13), which CMake may
find in preference to the newer Homebrew one. This still satisfies the minimum
required version, so the build will succeed either way; to prefer the Homebrew
copy instead, pass `-DCMAKE_PREFIX_PATH=$(brew --prefix libxml2)` at configure
time.


## Other Optional Tools

* git

  https://git-scm.com/

  git is only necessary for cloning the LinCity-NG git repository as described
  in the readme. If sources are obtained via other means, e.g. downloading a
  source package from the LinCity-NG GitHub releases, then git is not needed.

* Python, Bash, Ammonite

  Some helper scripts are written in Python, Bash, and Scala (Ammonite), but
  none of these scripts are necessary for building the project.

* Docker

  A Dockerfile is provided in contrib/build/ that will package LinCity-NG for
  Ubuntu. Naturally, Docker is required for this.
