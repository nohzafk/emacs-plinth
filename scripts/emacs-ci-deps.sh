#!/usr/bin/env bash
# Sourced by each CI dependency step.
source "$GITHUB_WORKSPACE/scripts/emacs-deps.sh"

emacs_ci_prepare_dep() {
  local stage="$1" archive srcdir
  archive="$(emacs_dep_fetch "$stage" "$RUNNER_TEMP/emacs-deps")" || return 1
  srcdir="$(emacs_dep_srcdir "$stage")" || return 1
  # macOS tar detects gzip and xz compression when extracting.
  tar -xf "$archive" || return 1
  cd -- "./$srcdir"
}
