#!/usr/bin/env bash
# Local replica of .github/workflows/build.yml.
#
# Targets the locked GNU Emacs 31 snapshot with the existing patches/deps
# as CI, but installs everything into a local prefix so it doesn't touch
# /usr/local or your Homebrew install.
#
#   ./scripts/build.sh                # build everything
#   ./scripts/build.sh emacs          # rebuild only Emacs (deps already done)
#   STAGES="m4 autoconf" ./scripts/build.sh
#   PREFIX=/tmp/foo ./scripts/build.sh
#
# Resume after a failure: rerun. Each dep has a sentinel file in $PREFIX;
# already-installed deps are skipped. Delete the sentinel (or $PREFIX) to
# force a rebuild.
set -euo pipefail
unset CDPATH

REPO_ROOT="$(cd -P -- "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
source "$REPO_ROOT/scripts/emacs-source.sh"
source "$REPO_ROOT/scripts/emacs-patches.sh"
source "$REPO_ROOT/scripts/emacs-configure.sh"
source "$REPO_ROOT/scripts/emacs-sign.sh"
source "$REPO_ROOT/scripts/emacs-deps.sh"
DEPS_DIGEST="$(emacs_deps_digest)"
DEPS_ROOT="$REPO_ROOT/build/deps-$DEPS_DIGEST"
PREFIX="${PREFIX:-$DEPS_ROOT/prefix}"
WORK="${WORK:-$DEPS_ROOT/work}"
OUT="${OUT:-$DEPS_ROOT/$EMACS_SOURCE_DIR/Emacs.app}"
JOBS="${JOBS:-$(sysctl -n hw.ncpu)}"

# Build cache setup.
# Pin relative overrides to the caller before any stage changes directory.
base="$(pwd -P)"
[[ "$PREFIX" == /* ]] || PREFIX="$base/$PREFIX"
[[ "$WORK" == /* ]] || WORK="$base/$WORK"
[[ "$OUT" == /* ]] || OUT="$base/$OUT"

deps_marker_matches() {
  local marker="$1"
  [[ -f "$marker" && ! -L "$marker" ]] &&
    cmp -s -- "$marker" <(printf '%s\n' "$DEPS_DIGEST")
}

check_deps_cache() (
  local dir="$1" entries
  if [[ ! -e "$dir" && ! -L "$dir" ]]; then return 0; fi
  if [[ -d "$dir" && -r "$dir" && -x "$dir" ]]; then
    if deps_marker_matches "$dir/ebuild-deps.txt"; then return 0; fi
    unset GLOBIGNORE
    set +f
    shopt -s nullglob dotglob
    entries=("$dir"/*)
    if [[ ${#entries[@]} == 0 ]]; then return 0; fi
  fi
  printf 'Emacs dependency/cache mismatch: %s has no matching dependency marker; use a fresh %s path (nothing was deleted).\n' "$dir" "$2" >&2
  return 1
)

check_deps_cache "$PREFIX" PREFIX
check_deps_cache "$WORK" WORK
mkdir -p -- "$PREFIX" "$WORK"
WORK="$(cd -P -- "$WORK" && pwd -P)"
for dir in "$PREFIX" "$WORK"; do
  marker="$dir/ebuild-deps.txt"
  if ! deps_marker_matches "$marker"; then
    (set -C; printf '%s\n' "$DEPS_DIGEST" > "$marker")
  fi
done
export PATH="$PREFIX/bin:$PATH"
export PKG_CONFIG_PATH="$PREFIX/lib/pkgconfig:${PKG_CONFIG_PATH:-}"
export LDFLAGS="-L$PREFIX/lib ${LDFLAGS:-}"
export CPPFLAGS="-I$PREFIX/include ${CPPFLAGS:-}"

log()  { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
skip() { printf '\033[0;33m--\033[0m  %s (already built)\n' "$*"; }

extract() {
  local archive="$1" expect_dir="$2"
  if [[ -d "$WORK/$expect_dir" ]]; then return; fi
  case "$archive" in
    *.tar.xz)        ( cd "$WORK" && tar -Jxf "$archive" ) ;;
    *.tar.gz|*.tgz)  ( cd "$WORK" && tar -zxf "$archive" ) ;;
    *) echo "unknown archive: $archive" >&2; exit 1 ;;
  esac
}

# Build a configure-style autotools dependency.
#   build_dep <stage> <name> <sentinel> [-- configure args...]
build_dep() {
  local stage="$1" name="$2" sentinel="$3" srcdir archive; shift 3
  if [[ "${1:-}" == "--" ]]; then shift; fi
  if [[ -e "$PREFIX/$sentinel" ]]; then skip "$name"; return; fi
  log "$name"
  srcdir="$(emacs_dep_srcdir "$stage")"
  archive="$(emacs_dep_fetch "$stage" "$WORK")"
  extract "$archive" "$srcdir"
  ( cd "$WORK/$srcdir" && ./configure --prefix="$PREFIX" "$@" && make -j"$JOBS" && make install )
}

# Selective stage runner: STAGES="m4 autoconf" ./build.sh runs only those.
# CLI args also act as a stage filter: ./build.sh emacs
ALL_STAGES=(
  m4 autoconf automake libtool pkgconf texinfo libiconv libunistring
  gettext ncurses zlib libwebp libxml2 gmp nettle libidn2 gnutls treesitter
  gzip emacs
)

if [[ $# -gt 0 ]]; then
  STAGES="$*"
fi
WANT="${STAGES:-${ALL_STAGES[*]}}"
should_run() {
  local s="$1"
  [[ " $WANT " == *" $s "* ]]
}

stage_m4()           { build_dep m4 "GNU M4"            bin/m4; }
stage_autoconf()     { build_dep autoconf "GNU Autoconf"      bin/autoconf; }
stage_automake()     { build_dep automake "GNU Automake"      bin/automake; }
stage_libtool()      { build_dep libtool "GNU Libtool"       bin/libtool -- --disable-shared; }
stage_texinfo()      { build_dep texinfo "GNU Texinfo"       bin/makeinfo; }
stage_libiconv()     { build_dep libiconv "GNU Libiconv"      lib/libiconv.a -- --disable-shared; }
stage_libunistring() { build_dep libunistring "GNU Libunistring"  lib/libunistring.a -- --disable-shared; }
stage_gettext()      { build_dep gettext "GNU Gettext"       bin/msgfmt -- --disable-shared; }
stage_libxml2()      { build_dep libxml2 "Libxml2"           lib/libxml2.a -- --disable-shared; }
stage_libwebp()      { build_dep libwebp "Libwebp"           lib/libwebp.a -- --disable-shared; }
stage_gmp()          { build_dep gmp "GNU GMP"           lib/libgmp.a -- --disable-shared; }
stage_nettle()       { build_dep nettle "Nettle"            lib/libnettle.a -- --disable-shared; }
stage_libidn2()      { build_dep libidn2 "Libidn2"           lib/libidn2.a -- --disable-shared; }
stage_gnutls()       { build_dep gnutls "GnuTLS"            lib/libgnutls.a -- --disable-shared --with-included-libtasn1 --without-p11-kit; }
stage_gzip()         { build_dep gzip "GNU Gzip"          bin/gzip; }

# Pkgconf: needs autogen.sh, plus pkg-config symlink.
stage_pkgconf() {
  local srcdir archive
  if [[ -e "$PREFIX/bin/pkgconf" ]]; then skip "Pkgconf"; return; fi
  log "Pkgconf"
  srcdir="$(emacs_dep_srcdir pkgconf)"
  archive="$(emacs_dep_fetch pkgconf "$WORK")"
  extract "$archive" "$srcdir"
  ( cd "$WORK/$srcdir"
    ./autogen.sh
    ./configure --prefix="$PREFIX" --disable-shared
    make -j"$JOBS"
    make install )
  ln -sf "$PREFIX/bin/pkgconf" "$PREFIX/bin/pkg-config"
}

# Ncurses: --with-terminfo-dirs so emacs -nw finds /usr/share/terminfo,
# plus a curses.h compatibility symlink.
stage_ncurses() {
  local srcdir archive
  if [[ -e "$PREFIX/lib/libncursesw.a" ]]; then skip "Ncurses"; return; fi
  log "Ncurses"
  srcdir="$(emacs_dep_srcdir ncurses)"
  archive="$(emacs_dep_fetch ncurses "$WORK")"
  extract "$archive" "$srcdir"
  ( cd "$WORK/$srcdir"
    ./configure --prefix="$PREFIX" --disable-shared \
                --with-terminfo-dirs=/usr/share/terminfo:/usr/local/share/terminfo
    make -j"$JOBS"
    make install )
  ln -sf "$PREFIX/include/ncursesw/curses.h" "$PREFIX/include/ncurses.h"
}

# Zlib: uses its own configure script (no autotools), takes --static, --prefix.
stage_zlib() {
  local srcdir archive
  if [[ -e "$PREFIX/lib/libz.a" ]]; then skip "Zlib"; return; fi
  log "Zlib"
  srcdir="$(emacs_dep_srcdir zlib)"
  archive="$(emacs_dep_fetch zlib "$WORK")"
  extract "$archive" "$srcdir"
  ( cd "$WORK/$srcdir"
    ./configure --static --prefix="$PREFIX"
    make -j"$JOBS"
    make install )
}

# tree-sitter: no autoconf; Makefile honors PREFIX. Delete dylibs to force
# static linkage in Emacs.
stage_treesitter() {
  local srcdir archive
  if [[ -e "$PREFIX/lib/libtree-sitter.a" ]]; then skip "tree-sitter"; return; fi
  log "tree-sitter"
  srcdir="$(emacs_dep_srcdir treesitter)"
  archive="$(emacs_dep_fetch treesitter "$WORK")"
  extract "$archive" "$srcdir"
  ( cd "$WORK/$srcdir"
    make -j"$JOBS" PREFIX="$PREFIX"
    make install PREFIX="$PREFIX" )
  find "$PREFIX/lib" -name 'libtree-sitter*.dylib' -delete
}

# Emacs: fetch the locked Git commit; keep its own .git for true provenance.
# Patch suitability/build readiness for this snapshot is not yet validated.
stage_emacs() {
  local src="$WORK/$EMACS_SOURCE_DIR" deps_marker="$OUT/Contents/Resources/ebuild-deps.txt"
  emacs_check_output "$OUT"
  emacs_check_patches "$OUT"
  emacs_check_configuration "$OUT" "$PREFIX"
  if [[ -e "$OUT" || -L "$OUT" ]] && ! deps_marker_matches "$deps_marker"; then
    printf 'Emacs dependency/cache mismatch: %s has no matching dependency marker; use a fresh OUT path (nothing was deleted).\n' "$OUT" >&2
    return 1
  fi
  if [[ -e "$src" || -L "$src" ]]; then emacs_validate_source "$src"; fi
  if [[ -e "$OUT/Contents/MacOS/Emacs" ]]; then
    emacs_verify_bundle "$OUT"
    skip "Emacs $EMACS_SOURCE_LABEL"
    return
  fi
  log "Emacs $EMACS_SOURCE_LABEL"
  emacs_prepare_source "$src"

  # Patch dir: fixed, vendored set in patches/, selected and applied from
  # patches/ui-patches.lock.  The exact same code path (SHA-256 verification,
  # strict -F0, ordered) runs here and in CI: no network download and no
  # $WORK wildcard cache is involved.
  emacs_apply_patches "$src"

  cd "$src"
  # Same configure.ac tweak as CI: force libncursesw on darwin.  The match
  # includes the closing quote so a rerun on an already-tweaked checkout
  # finds nothing to change, instead of writing -lncursesww.
  sed -i '' '/darwin/ s/-lncurses"/-lncursesw"/' configure.ac

  if [[ ! -f configure ]]; then ./autogen.sh; fi
  emacs_configure "$PREFIX"
  make -j"$JOBS"
  make install
  rm -rf "$OUT"
  ditto nextstep/Emacs.app "$OUT"
  emacs_mark_output "$OUT"
  emacs_mark_patches "$OUT"
  emacs_mark_configuration "$OUT" "$PREFIX"
  printf '%s\n' "$DEPS_DIGEST" > "$deps_marker"
  emacs_sign_bundle "$OUT"
  log "Built: $OUT"
}

for s in "${ALL_STAGES[@]}"; do
  if should_run "$s"; then "stage_$s"; fi
done

log "Done. Emacs.app at: $OUT"
log "Test:  '$OUT/Contents/MacOS/Emacs' --version"
