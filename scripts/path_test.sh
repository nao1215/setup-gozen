#!/usr/bin/env bash
#
# path_test.sh - check that go-mod-path cannot leave GITHUB_WORKSPACE:
# traversal, absolute paths, Windows separators and drive letters, and
# symbolic links that point outside (checked on the resolved real path).
#
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source-path=SCRIPTDIR
# shellcheck source=gomod.sh
source "${here}/gomod.sh"

failures=0
root="$(mktemp -d)"
trap 'rm -rf "$root"' EXIT

pass() { printf 'ok:   %s\n' "$*"; }
fail() { printf 'FAIL: %s\n' "$*"; failures=$((failures + 1)); }

# Layout: $root/ws is the workspace; $root/outside holds a go.mod and a secret
# the workspace must never reach.
ws="$root/ws"
outside="$root/outside"
mkdir -p "$ws/games/rpg" "$ws/plain" "$ws/empty" "$outside/etc"
printf 'module a\nrequire github.com/nao1215/gozen v0.2.0\n' >"$ws/go.mod"
printf 'module b\nrequire github.com/nao1215/gozen v0.2.0\n' >"$ws/games/rpg/go.mod"
printf 'not a module\n' >"$ws/plain/readme.txt"
printf 'module evil\nrequire github.com/nao1215/gozen v0.0.1\n' >"$outside/go.mod"
printf 'module evil\n' >"$outside/etc/go.mod"
printf 'root:x:0:0\n' >"$outside/etc/passwd"

symlinks=true
if ln -s "$outside" "$ws/probe" 2>/dev/null && [ -L "$ws/probe" ] && [ -d "$ws/probe" ]; then
  rm -f "$ws/probe"
else
  symlinks=false
  printf 'note: symbolic links are not available here, skipping the symlink cases\n'
fi
if $symlinks; then
  ln -s "$outside" "$ws/link-dir"                          # directory link to outside
  ln -s "$outside/go.mod" "$ws/games/go.mod"               # go.mod file link to outside
  ln -s "$outside/etc" "$ws/games/rpg/hop"                 # nested directory link
  ln -s ../outside "$ws/rel-link"                          # relative link to outside
  ln -s "$ws/games/rpg" "$ws/inside-link"                  # link that stays inside: allowed
  ln -s "$ws/games/rpg/go.mod" "$ws/plain/go.mod"          # file link that stays inside: allowed
  ln -s loop-b "$ws/loop-a"; ln -s loop-a "$ws/loop-b"     # link loop
fi

errfile="$root/err"

# accept RAW WANT_REAL_FILE
accept() {
  local raw="$1" want="$2" got
  if got="$( (GITHUB_WORKSPACE="$ws" resolve_go_mod_file "$raw"; printf '%s' "$GO_MOD_FILE") 2>"$errfile")" \
    && [ "$got" = "$want" ]; then
    pass "accepted '$raw'"
  else
    fail "'$raw' -> '$got' (want $want) $(cat "$errfile")"
  fi
}

# reject RAW [MESSAGE_FRAGMENT]
reject() {
  local raw="$1" frag="${2:-}"
  if (GITHUB_WORKSPACE="$ws" resolve_go_mod_file "$raw") >/dev/null 2>"$errfile"; then
    fail "'$raw' was accepted"
  elif [ -n "$frag" ] && ! grep -qF -- "$frag" "$errfile"; then
    fail "'$raw' rejected for another reason: $(cat "$errfile")"
  else
    pass "rejected '$raw'"
  fi
}

ws_real="$(cd "$ws" && pwd -P)"

# Allowed spellings.
accept "" "$ws_real/go.mod"
accept "." "$ws_real/go.mod"
accept "./" "$ws_real/go.mod"
accept "go.mod" "$ws_real/go.mod"
accept "./go.mod" "$ws_real/go.mod"
accept "games/rpg" "$ws_real/games/rpg/go.mod"
accept "games/rpg/" "$ws_real/games/rpg/go.mod"
accept "games/rpg/go.mod" "$ws_real/games/rpg/go.mod"
accept "./games//rpg" "$ws_real/games/rpg/go.mod"
accept "  games/rpg  " "$ws_real/games/rpg/go.mod"
accept 'games\rpg' "$ws_real/games/rpg/go.mod"           # a Windows separator inside the workspace
if $symlinks; then
  accept "inside-link" "$ws_real/games/rpg/go.mod"
  accept "plain" "$ws_real/games/rpg/go.mod"
fi

# Traversal by spelling.
reject ".." "'..'"
reject "../" "'..'"
reject "../outside" "'..'"
reject "../../etc" "'..'"
reject "../../etc/passwd" "'..'"
reject "games/../../outside" "'..'"
reject "games/rpg/../../../outside" "'..'"
reject "./../outside/go.mod" "'..'"
reject "games/.." "'..'"
reject "%2e%2e/outside" "does not exist"                 # no URL decoding: just a name that is not there
reject '..\..\etc' "'..'"                                # Windows separators
reject '..\outside\go.mod' "'..'"
reject 'games\..\..\outside' "'..'"
reject '.\..\outside' "'..'"
reject '../..\etc' "'..'"                                # mixed separators

# Absolute and drive-qualified paths.
reject "/etc" "absolute"
reject "/etc/passwd" "absolute"
reject "$outside" "absolute"
reject "$outside/go.mod" "absolute"
reject "$ws" "absolute"                                  # even the workspace itself, spelled absolutely
reject "$ws/go.mod" "absolute"
reject "//server/share" "absolute"
reject '\\server\share' "absolute"                       # UNC
reject '\etc' "absolute"
reject 'C:\Windows\System32' "drive"
reject 'C:/Windows' "drive"
reject 'c:go.mod' "drive"
reject 'D:\a\ws\go.mod' "drive"

# Control characters.
reject $'go.mod\n../outside' "control"
reject $'games\t/rpg' "control"

# Things that are not a go.mod.
reject "nope" "does not exist"
reject "empty" "no go.mod"
reject "plain/readme.txt" "go.mod"
reject "games/rpg/other.mod" "does not exist"

# Symbolic links that lead outside, judged by their resolved real path.
if $symlinks; then
  reject "link-dir" "outside the workspace"
  reject "link-dir/go.mod" "outside the workspace"
  reject "link-dir/etc" "outside the workspace"
  reject "games" "outside the workspace"                 # games/go.mod is a link to outside
  reject "games/go.mod" "outside the workspace"
  reject "games/rpg/hop" "outside the workspace"
  reject "rel-link" "outside the workspace"
  reject "rel-link/go.mod" "outside the workspace"
  reject "loop-a" ""
  reject "loop-a/go.mod" ""
fi

# GITHUB_WORKSPACE itself must be usable.
if (unset GITHUB_WORKSPACE; resolve_go_mod_file ".") >/dev/null 2>"$errfile"; then fail "accepted without GITHUB_WORKSPACE"; else pass "rejected without GITHUB_WORKSPACE"; fi
if (GITHUB_WORKSPACE="$root/missing" resolve_go_mod_file ".") >/dev/null 2>"$errfile"; then fail "accepted a missing GITHUB_WORKSPACE"; else pass "rejected a missing GITHUB_WORKSPACE"; fi

# A workspace that is itself reached through a symlink is fine: both sides are resolved.
if $symlinks; then
  ln -s "$ws" "$root/ws-link"
  if got="$( (GITHUB_WORKSPACE="$root/ws-link" resolve_go_mod_file "games/rpg"; printf '%s' "$GO_MOD_FILE") 2>"$errfile")" \
    && [ "$got" = "$ws_real/games/rpg/go.mod" ]; then
    pass "workspace reached through a symlink"
  else
    fail "workspace reached through a symlink: $got $(cat "$errfile")"
  fi
fi

if [ "$failures" -ne 0 ]; then
  printf '%d test(s) failed\n' "$failures" >&2
  exit 1
fi
printf 'all path-safety tests passed\n'
