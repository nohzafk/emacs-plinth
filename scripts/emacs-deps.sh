#!/usr/bin/env bash
# Shared archive verification for local and CI builds. This file is sourced.

EMACS_DEPS_SCRIPT_DIR="$(CDPATH= cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"

_emacs_deps_error() {
  printf 'Emacs dependency: %s\n' "$*" >&2
  return 1
}

_emacs_deps_sha256() {
  local result
  result="$(shasum -a 256 < "$1")" || return 1
  printf '%s\n' "${result%% *}"
}

emacs_deps_digest() {
  _emacs_deps_sha256 "${EBUILD_DEPS_LOCK:-$EMACS_DEPS_SCRIPT_DIR/deps.lock}"
}

# Print the selected entry only after checking the whole lock for duplicates.
_emacs_deps_entry() (
  shopt -u nocasematch
  local stage="$1" lock="${EBUILD_DEPS_LOCK:-$EMACS_DEPS_SCRIPT_DIR/deps.lock}"
  local tab=$'\t' line fields sha url path basename srcdir entry=''
  local sha_pattern='^[0123456789abcdef]{64}$'
  local url_pattern='^https://[^/?#[:space:]]+/[^[:space:]]+$'
  [[ -r "$lock" && -f "$lock" ]] || { _emacs_deps_error "cannot read $lock"; return 1; }
  while IFS= read -r line || [[ -n "$line" ]]; do
    line="${line%$'\r'}"
    case "$line" in ''|\#*) continue ;; esac
    [[ "${line%%"$tab"*}" == "$stage" ]] || continue
    [[ -z "$entry" ]] || { _emacs_deps_error "ambiguous stage '$stage' in $lock"; return 1; }

    fields="${line#*"$tab"}"
    sha="${fields%%"$tab"*}"
    fields="${fields#*"$tab"}"
    url="${fields%%"$tab"*}"
    srcdir="${fields#*"$tab"}"
    path="${url%%[?#]*}"
    basename="${path##*/}"
    if [[ "$line" != *"$tab"*"$tab"*"$tab"* || "$srcdir" == *"$tab"* ||
          ! "$sha" =~ $sha_pattern || ! "$url" =~ $url_pattern ||
          "$path" != https://*/* || -z "$basename" || "$basename" == . || "$basename" == .. ||
          -z "$srcdir" || "$srcdir" == */* || "$srcdir" == . || "$srcdir" == .. ]]; then
      _emacs_deps_error "malformed entry for stage '$stage' in $lock"
      return 1
    fi
    entry="$sha$tab$url$tab$basename$tab$srcdir"
  done < "$lock" || return 1
  [[ -n "$entry" ]] || { _emacs_deps_error "missing stage '$stage' in $lock"; return 1; }
  printf '%s\n' "$entry"
)

emacs_dep_srcdir() {
  local entry
  [[ $# == 1 && -n "$1" ]] || { _emacs_deps_error 'usage: emacs_dep_srcdir STAGE'; return 1; }
  entry="$(_emacs_deps_entry "$1")" || return 1
  printf '%s\n' "${entry##*$'\t'}"
}

_emacs_deps_verify() {
  local filename="$1" expected="$2" actual
  [[ -f "$filename" && ! -L "$filename" ]] || {
    _emacs_deps_error "not a regular archive: $filename"; return 1;
  }
  actual="$(_emacs_deps_sha256 "$filename")" || return 1
  [[ "$actual" == "$expected" ]] || {
    _emacs_deps_error "SHA-256 mismatch for $filename: expected $expected, got $actual"; return 1;
  }
}

emacs_dep_fetch() (
  local entry sha url basename srcdir cache archive tmp
  [[ $# == 2 && -n "$1" && -n "$2" ]] || {
    _emacs_deps_error 'usage: emacs_dep_fetch STAGE CACHE_DIR'; return 1;
  }
  entry="$(_emacs_deps_entry "$1")" || return 1
  IFS=$'\t' read -r sha url basename srcdir <<< "$entry"

  mkdir -p -- "$2" || return 1
  cache="$(CDPATH= cd -- "$2" && pwd -P)" || return 1
  archive="${cache%/}/$basename"
  if [[ -e "$archive" || -L "$archive" ]]; then
    _emacs_deps_verify "$archive" "$sha" || return 1
  else
    tmp="$(mktemp "${cache%/}/.emacs-dep.XXXXXX")" || return 1
    trap 'rm -f -- "$tmp"' EXIT
    trap 'exit 1' HUP INT TERM
    printf 'Fetching %s\n' "$url" >&2
    curl --disable --fail --retry 5 --retry-delay 5 --location --silent --show-error \
      --proto '=https' --proto-redir '=https' --globoff --output "$tmp" -- "$url" >&2 || return 1
    _emacs_deps_verify "$tmp" "$sha" || return 1
    mv -f -- "$tmp" "$archive" || return 1
  fi
  printf '%s\n' "$archive"
)
