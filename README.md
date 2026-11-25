[![MacOS Build for GNU Emacs](https://github.com/nohzafk/emacs-plinth/actions/workflows/build.yml/badge.svg)](https://github.com/nohzafk/emacs-plinth/actions/workflows/build.yml)

# emacs-plinth

GNU Emacs 31.1 as a self-contained `Emacs.app` for Apple silicon, macOS 15.0 or later.
Every library Emacs uses is compiled from source and linked statically
into the app; only macOS's own frameworks are loaded from the system. The
app needs no Homebrew or Nix, and upgrading or removing them cannot break
it. On top of stock Emacs it carries the emacs-plus UI patches and local
patches that let a dynamic module show its own GPU-drawn views inside
buffers and child frames.

## Features

- **Static, self-contained bundle**: every dependency (GnuTLS, tree-sitter,
  libxml2, WebP, GMP, ncurses, zlib and their support libraries) is compiled
  from source and linked statically into `Emacs.app`; CI uninstalls Homebrew
  before it builds, so nothing from it can leak in.
- **Native xwidgets**: a `native` xwidget type whose `NSView` a dynamic
  module supplies, placed, clipped, and hidden like a WebKit view; views
  that move with copied pixel rows during scrolling; and chrome-less child
  frames that grow without a black band.
- **emacs-plus UI patches**: macOS system dark/light appearance detection
  and change hook, rounded undecorated frames that preserve geometry when
  toggled, and the full NS colour list at startup.
- **macOS bug fixes**: fixes for the `pixel-scroll-precision-mode`
  header-line scroll crash (bug#81585) and `delete-frame` stealing key-window
  focus.
- **Immutable, verifiable releases**: each release pins the exact Emacs
  commit SHA, SHA-256-locked dependency archives, and SHA-256-locked patch
  list (`patch -F0`), records four provenance markers in
  `Emacs.app/Contents/Resources/` before ad-hoc code signing, publishes a
  `.sha256` digest beside the archive, and refuses to reuse an existing
  release tag.
- **Terminal mode out of the box**: static `ncurses` is compiled with
  `/usr/share/terminfo` in its search path so `emacs -nw` and
  `emacsclient -t` work on machines without `/usr/local/share/terminfo`.

It bundles no font: use any installed font. bendmacs installs
[RysMono](https://github.com/nohzafk/rysmono).

Each patch is described under [The patch set](#the-patch-set); why the
local ones are shaped as they are is in
[docs/local-patches.md](docs/local-patches.md).

This repository is the application only: the source pin, the patches, the
build, and the release. It is one of four repositories around the
[bendcord](https://github.com/nohzafk/bendcord) agent: the config that runs
on this Emacs is [bendmacs](https://github.com/nohzafk/bendmacs), which
loads the [bendcord.el](https://github.com/nohzafk/bendcord.el) client of
the bendcord daemon. A change belongs here when it needs a different
`Emacs.app`; the native widgets and views that use the patches live in
bendmacs and bendcord.el.

## Install

Requires Apple silicon, macOS 15.0 or later.

Download the release asset and its digest, verify the archive, and unpack it:

```bash
curl -fLO https://github.com/nohzafk/emacs-plinth/releases/download/emacs-31.1-bendmacs.6/Emacs-31.1-bendmacs.6.tar.xz
curl -fLO https://github.com/nohzafk/emacs-plinth/releases/download/emacs-31.1-bendmacs.6/Emacs-31.1-bendmacs.6.tar.xz.sha256
shasum -a 256 -c Emacs-31.1-bendmacs.6.tar.xz.sha256
tar -xJf Emacs-31.1-bendmacs.6.tar.xz
```

The bundle carries four provenance markers in
`Emacs.app/Contents/Resources/` (see [Provenance markers](#provenance-markers))
and is signed ad hoc after they are written, so
`codesign --verify --deep --strict Emacs.app` checks that nothing in it
changed since. A browser download marks the files as quarantined; remove
only that attribute:

```bash
xattr -dr com.apple.quarantine Emacs.app
```

Not `xattr -cr`: codesign keeps the signatures of the bundle's non-Mach-O
files (the portable dump, a shell script) in extended attributes, and
clearing every attribute breaks the seal. For the same reason, copy the
bundle with Finder or `ditto` rather than a tool that drops extended
attributes:

```bash
ditto Emacs.app /Applications/Emacs.app
```

### What a release contains

A release is one build of the pinned source with one patch set, configure
arguments, and set of dependency versions. Its tag names the Emacs version
and this repository's build number, and never moves:

| | |
|---|---|
| Tag | `emacs-31.1-bendmacs.6` |
| Title | Emacs 31.1, bendmacs build 6 |
| Asset | `Emacs-31.1-bendmacs.6.tar.xz`, a tarball holding `Emacs.app` |
| Digest | `Emacs-31.1-bendmacs.6.tar.xz.sha256`, beside the asset |

New releases use `emacs-<version>-plinth.<N>` tags,
`Emacs <version>, plinth build <N>` titles, and
`Emacs-<version>-plinth.<N>.tar.xz` assets. Build numbers continue from 7;
published builds 1–6 keep their `bendmacs.<N>` names, and CI refuses to
reuse a build number under either prefix.

The build number is `EMACS_BUILD_NUMBER` in
[`scripts/emacs-source.lock`](scripts/emacs-source.lock).
Bump it by hand whenever the patch set, the configure arguments, or a
dependency changes; a commit that changes only documentation or tests
does not need a new release. The build job refuses to start when the tag
for its number already exists on GitHub, so a changed build cannot replace
a published one under the same name, and a pin of a tag and its digest
keeps meaning one set of bytes.

The release notes list the source revision, the patch-set digest, the
patches in the order they were applied, and the dependency lock SHA-256,
so what a build contains can be read without downloading it.

## The patch set

The patches are vendored under `patches/` and applied in the order
[`patches/ui-patches.lock`](patches/ui-patches.lock) lists them.
[`scripts/emacs-patches.sh`](scripts/emacs-patches.sh) checks
each one against the SHA-256 in the lock, checks that every patch applies
before it writes anything, and applies them with `patch -F0`, so a patch
that no longer fits fails instead of being applied with fuzz. The local
build and CI run the same code. The upstream patches come from emacs-plus
at commit `6489a284d333119a05c9b0c2175bedf68250d160`.

- **system-appearance** - Adds the `ns-system-appearance-change-functions` hook and
  dark/light (`dark aqua`) appearance detection. Rebased to this revision: the
  pinned source inserted "Sleep event notification" methods where the upstream
  patch expected its insertion points, so the two affected hunks are re-anchored
  (the added code is unchanged).
- **round-undecorated-frame** - Enables rounded corners on undecorated frames
  (the Emacs 31 variant that also preserves window geometry when toggling).
- **fix-ns-x-colors** - Refreshes `x-colors` at NS window-system init so the full
  color list (~800) is available, not the headless-dump subset (~62).
- **no-frame-refocus-cocoa** (local) - Stops `delete-frame` from forcing the
  Cocoa key window onto another Emacs frame. Rebased to this revision: only the
  forced `ns_make_frame_key_window` fallback block is removed; the most-recently
  used frame selection and `do_switch_frame` are kept.
- **fix-ns-scroll-crash** - Fixes bug#81585: a bus error in `memmove`
  (`copyRect:to:`) when the header line is toggled off while
  `pixel-scroll-precision-mode` leaves a partially visible line, plus the
  header-line overpaint that remains without the `ns_scroll_run` part.
- **native-xwidget** (local) - Adds a `native` xwidget type on macOS (NS only):
  `make-xwidget` takes, as ARGUMENTS, a user pointer to an `NSView` that a
  dynamic module created, and redisplay places, clips, and hides that view as it
  does a WebKit one. A hidden native view's container gets the `hidden`
  property, so the view receives `viewDidHide`/`viewDidUnhide`; a WebKit view is
  still moved off-screen. The per-window container now clips to its bounds for
  both types: AppKit stopped clipping subviews by default for programs linked
  against macOS 14 or later, so a widget cut by a window edge drew past it. The
  `xwidget-webkit-*` functions signal an error for a native widget. GTK and
  PGTK builds are unchanged.
- **ns-xwidget-scroll** (local) - Moves xwidget views when `ns_scroll_run`
  scrolls a window by copying rows, as `x_scroll_run` does on X. Without it a
  view stays where it was drawn while its glyph moves, one line's height off
  per line scrolled, under one-line, wheel, pixel-precision, and page
  scrolling, until a full `redraw-frame`. It selects a view by the widget's
  whole rectangle, so a widget clipped to nothing or in a row partly outside
  the text area moves with its row too. NS only; touches only `src/nsterm.m`.
- **ns-child-frame-resize** (local) - Growing a chrome-less child frame
  (`undecorated` or `undecorated-round`) through one `setFrame:` shows the new
  area black for a display frame or more; AppKit presents the commits of the
  resize frame clipped to the old size. The patch grows the window first
  while the view holds its old frame and draws nothing, then applies the final
  frame 20 ms later and draws. Child-frame windows become non-opaque with a
  clear background for it; top-level and decorated frames are unchanged. NS
  only; touches `src/nsterm.m`, `src/nsterm.h`, and `src/nsfns.m`. Titled
  windows do not show the band, so it cannot be reproduced with a normal
  frame; what a layer-backed view in such a frame must do itself is in
  [docs/local-patches.md](docs/local-patches.md).

The obsolete emacs-28 **fix-window-role** patch is not applied: this
revision already returns `NSAccessibilityWindowRole`, so the patch would fail
forward and would reverse an upstream fix.

## Build configuration

[`scripts/emacs-configure.sh`](scripts/emacs-configure.sh) configures Emacs
with `CFLAGS='-O2 -g0 -flto=thin'`, `PKG_CONFIG='pkgconf -static'`, and
options that enable:

- GnuTLS (`--with-gnutls`)
- Tree-sitter (`--with-tree-sitter`)
- libxml2 (`--with-xml2`)
- WebP (`--with-webp`)
- zlib (`--with-zlib`)
- Native Image API (`--with-native-image-api`)
- Dynamic modules support (`--with-modules`)
- Cocoa window system and xwidgets (`--with-ns`, `--with-xwidgets`)
- `kqueue` file notifications, threads, toolkit scroll bars, compressed
  install, and the small Japanese dictionary (`--with-file-notification=kqueue`,
  `--with-threads`, `--with-toolkit-scroll-bars`, `--with-compress-install`,
  `--with-small-ja-dic`)

Other optional features and GC mark tracing are disabled (`--without-all`,
`--disable-gc-mark-trace`).

The GNU MP Bignum Library (`gmp`) is built in the static dependency prefix
and detected automatically by `configure` (the obsolete `--with-gmp` flag is
not passed). Configure detects `XWIDGETS`, `MODULES`, `TREE_SITTER`, `WEBP`,
native image APIs, `GNUTLS`, `LIBXML2`, `GMP`, and `ZLIB`, and reports no
native Lisp compiler.

Native Elisp compilation is explicitly disabled with
`--without-native-compilation`. No GCC/libgccjit dependency is added.
The Cocoa `--with-xwidgets` path uses the macOS SDK and system WebKit;
it does not require GTK, WebKitGTK, libsoup, or a bundled browser engine.
The build keeps `--with-xwidgets` because the `native-xwidget` patch builds
on the xwidget glyph layout and view containers that stock Emacs compiles
only under `HAVE_XWIDGETS`. bendmacs no longer creates a WebKit view at run
time: every widget is a `native` xwidget, and Mermaid is compiled in-process
(bendmacs's `docs/design/140-ondine-mermaid.md`). The tests here do not run
the built Emacs, so they do not cover xwidgets at run time.

No package manager is used during the build: every dependency is fetched
from its upstream and compiled from source, and Emacs links them
statically (except the system frameworks), which makes link-time
optimization possible.

### Terminal mode

ncurses is built with `--with-terminfo-dirs=/usr/share/terminfo:/usr/local/share/terminfo`
so that `emacs -nw` and `emacsclient -t` can find macOS's system terminfo
database at `/usr/share/terminfo`. Without this, the compiled-in search path
only includes `/usr/local/share/terminfo` (the install prefix), which does not
exist on end-user machines and causes "Cannot open terminfo database file"
errors in terminal mode.

## Source lock

[`scripts/emacs-source.lock`](scripts/emacs-source.lock) is the single source of truth for local and CI builds:

- Repository: `https://github.com/emacs-mirror/emacs.git`
- Commit: `a360712c9d272d950d8d8255ef74570f7e90b7d9`
- Release: `emacs-31.1` (the upstream annotated tag points at this commit)
- Label: `31-snapshot-a360712c9d272d950d8d8255ef74570f7e90b7d9`
- Build number: `EMACS_BUILD_NUMBER` in [`scripts/emacs-source.lock`](scripts/emacs-source.lock)

The shared helper fetches only this full commit SHA into a detached Git checkout.
It does not follow `master`, an Emacs 31 branch, or the release tag itself: the
SHA is pinned so a moved or deleted upstream tag cannot change what is built.
Each checkout has its own `.git`, so Emacs build metadata comes from Emacs, not
this repository. The commit is the Emacs 31.1 release commit, though it
is fetched from Git rather than from the GNU release tarball.

The Emacs checkout must have its own `.git`, the locked revision, and the expected origin. The build allows tracked changes from the pinned patches.

### Dependency lock

[`scripts/deps.lock`](scripts/deps.lock) pins the 19 dependency archives used by local and CI builds. Each row gives the stage, SHA-256, HTTPS URL, and extracted directory. Before extracting an archive, the build checks its bytes against the lock, including archives found in the download cache. To update a dependency, verify the new upstream archive and update its row.

### Provenance markers

Every built bundle carries four provenance markers under `Emacs.app/Contents/Resources/`, written before ad-hoc code signing:

| Marker | What it records |
| --- | --- |
| `ebuild-source.txt` | Source repository, full commit revision, and the label build directories are keyed by |
| `ebuild-patches.txt` | `patchset=` (SHA-256 over the ordered patch digests and paths) and `provenance=` (the emacs-plus commit); matches the release notes |
| `ebuild-configure.txt` | Requested `CFLAGS`, `PKG_CONFIG`, `--prefix=` (local builds only), and configure options |
| `ebuild-deps.txt` | SHA-256 of the complete `scripts/deps.lock` file; matches the release notes |

`ebuild-deps.txt` identifies the locked source archives, not installed library binaries. These markers do not identify the compiler, SDK, inherited environment, or `configure`'s detected results. CI names the release archive by version and build number; the bundle inside is always `Emacs.app`.

## Local build

[`scripts/build.sh`](scripts/build.sh) installs into a private prefix rather than `/usr/local`. By default, the prefix, work directory, and app all live under `build/deps-<lock-SHA256>/`. Changing the lock selects fresh directories and leaves previous builds intact.

```bash
./scripts/build.sh                            # build all dependencies and Emacs
./scripts/build.sh emacs                      # Emacs stage only; build dependencies first
STAGES="m4 autoconf" ./scripts/build.sh       # selected stages only
OUT="$PWD/build/try/Emacs.app" ./scripts/build.sh emacs
PREFIX=/tmp/foo ./scripts/build.sh
```

The default app path is `build/deps-<lock-SHA256>/emacs-31-snapshot-<Emacs-revision>/Emacs.app`. `JOBS` sets the make parallelism and defaults to `sysctl -n hw.ncpu`. Each dependency writes a sentinel in `$PREFIX`, so rerunning with the same lock skips installed dependencies; delete a sentinel (or use a fresh `PREFIX`) to rebuild it. The build reuses an existing app only if all four [provenance markers](#provenance-markers) match and its signature verifies. Smoke-test a built bundle with `'<OUT>/Contents/MacOS/Emacs' --version`.

If you override `PREFIX` or `WORK`, use a fresh directory or one already marked for this lock (`ebuild-deps.txt`). For `OUT`, use a new path or a matching app. Relative overrides for `PREFIX`, `WORK`, and `OUT` are resolved against the working directory you invoke `scripts/build.sh` from. The build refuses mismatched caches rather than deleting them. Local builds carry no release number; only CI publishes.

## Tests

The tests are offline: they need no Emacs source, no download, and no build
stage. They cover the source pin and release scheme (`test_source_pin.py`),
dependency archive locking (`test_emacs_deps.py`), local build cache checks
(`test_local_deps_cache.py`), patch locking and strict `-F0` application
(`test_ui_patches.py`), configure policy (`test_configure_policy.py`), and
bundle signing (`test_bundle_sign.py`).

```bash
env -u BASH_ENV python3 -m unittest discover -s tests -p 'test_*.py'
```

`BASH_ENV` is unset because every bash the tests start would source it,
and a shell environment can put a real `git` or `curl` ahead of the tests'
mocks. `test_source_pin.py` also checks the release scheme: the names derived
from the build number, the refusal of an existing tag or legacy build number,
and the release notes.

`tests/test_ui_patches.py` can also apply the whole patch set at `-F0` to
the real files of the pinned revision. Point `EBUILD_UI_TARGETS` at a
directory holding that revision's `src/` and `lisp/term/` (never vendored
here), for instance taken from a source checkout's own `HEAD`:

```bash
mkdir -p /tmp/ui-targets
lock_sha=$(shasum -a 256 scripts/deps.lock | cut -d ' ' -f 1)
git -C "build/deps-$lock_sha/work/emacs-31-snapshot-<full-SHA>" archive HEAD src lisp/term | tar -x -C /tmp/ui-targets
EBUILD_UI_TARGETS=/tmp/ui-targets env -u BASH_ENV python3 tests/test_ui_patches.py
```

CI runs all of this on every push and pull request: the `tests` job runs
the offline tests, fetches the pinned commit, and applies the patch set to
it. The `build` job runs only when dispatched by hand, and only after the
`tests` job passes on the same commit.

## Lineage

This repository was forked from
[RadioNoiseE/ebuild](https://github.com/RadioNoiseE/ebuild) and renamed
bendmacs-emacs, because the name collided with Gentoo's ebuild and said
nothing of what the repository now is, then bendmacs.app, after the
artifact it builds. It became emacs-plinth because macOS treated the checkout
as an application bundle due to the `.app` suffix, and the build does not
depend on bendmacs, so it has a name of its own. The bundle's marker files
(`ebuild-*.txt`) and the scripts' `EBUILD_*` variables keep the old name:
the markers are inside bundles already published, and the variables are
identifiers only.

## License

GNU GPL version 3 or later, see [LICENSE](LICENSE): the patches are
derivative works of GNU Emacs, and so is the `Emacs.app` each release
publishes. The complete corresponding source of a release is the pinned
commit named in [`scripts/emacs-source.lock`](scripts/emacs-source.lock),
the patch set under `patches/`, and the dependency archives pinned in
[`scripts/deps.lock`](scripts/deps.lock), all recorded in the bundle's
[provenance markers](#provenance-markers).
