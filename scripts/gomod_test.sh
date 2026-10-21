#!/usr/bin/env bash
#
# gomod_test.sh - check how the gozen version is read from go.mod: require
# forms, comments, replace directives, pseudo-versions and missing entries.
#
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source-path=SCRIPTDIR
# shellcheck source=gomod.sh
source "${here}/gomod.sh"

failures=0
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

pass() { printf 'ok:   %s\n' "$*"; }
fail() { printf 'FAIL: %s\n' "$*"; failures=$((failures + 1)); }

# check NAME WANT_TAG GO_MOD_TEXT
check() {
  local name="$1" want="$2" text="$3" got
  printf '%s' "$text" >"$tmp/go.mod"
  if got="$( (gozen_version_from_gomod "$tmp/go.mod" >/dev/null; printf '%s' "$TAG") 2>"$tmp/err")" && [ "$got" = "$want" ]; then
    pass "$name -> $got"
  else
    fail "$name -> '$got' (want $want) $(cat "$tmp/err")"
  fi
}

# check_error NAME WANT_MESSAGE_FRAGMENT GO_MOD_TEXT
check_error() {
  local name="$1" frag="$2" text="$3"
  printf '%s' "$text" >"$tmp/go.mod"
  if (gozen_version_from_gomod "$tmp/go.mod") >/dev/null 2>"$tmp/err"; then
    fail "$name was accepted"
  elif grep -qF -- "$frag" "$tmp/err"; then
    pass "$name -> error mentions '$frag'"
  else
    fail "$name -> unexpected error: $(cat "$tmp/err")"
  fi
}

check "single-line require" v0.2.0 $'module m\n\ngo 1.26\n\nrequire github.com/nao1215/gozen v0.2.0\n'
check "require block" v0.2.0 $'module m\nrequire (\n\tgithub.com/a/b v1.0.0\n\tgithub.com/nao1215/gozen v0.2.0\n)\n'
check "indirect comment" v0.2.0 $'module m\nrequire (\n\tgithub.com/nao1215/gozen v0.2.0 // indirect\n)\n'
check "indirect single line" v0.1.0 $'module m\nrequire github.com/nao1215/gozen v0.1.0 // indirect\n'
check "two require blocks" v0.2.0 $'module m\nrequire (\n\tgithub.com/a/b v1.0.0\n)\nrequire (\n\tgithub.com/nao1215/gozen v0.2.0 // indirect\n)\n'
check "CRLF line endings" v0.2.0 $'module m\r\nrequire (\r\n\tgithub.com/nao1215/gozen v0.2.0\r\n)\r\n'
check "quoted path" v0.2.0 $'module m\nrequire "github.com/nao1215/gozen" v0.2.0\n'
check "prerelease" v0.3.0-rc.1 $'module m\nrequire github.com/nao1215/gozen v0.3.0-rc.1\n'
check "commented-out require is ignored" v0.2.0 $'module m\n// require github.com/nao1215/gozen v0.1.0\nrequire github.com/nao1215/gozen v0.2.0\n'
check "a sibling module is not gozen" v0.2.0 $'module m\nrequire (\n\tgithub.com/nao1215/gozen-extra v9.9.9\n\tgithub.com/nao1215/gozen v0.2.0\n)\n'
check "exclude block mentioning gozen is ignored" v0.2.0 $'module m\nrequire github.com/nao1215/gozen v0.2.0\nexclude (\n\tgithub.com/nao1215/gozen v0.1.5\n)\n'

# replace to another version of gozen: the replacement's version wins.
check "replace to another version" v0.1.0 $'module m\nrequire github.com/nao1215/gozen v0.2.0\nreplace github.com/nao1215/gozen => github.com/nao1215/gozen v0.1.0\n'
check "replace block, versioned left side" v0.1.0 $'module m\nrequire github.com/nao1215/gozen v0.2.0\nreplace (\n\tgithub.com/nao1215/gozen v0.2.0 => github.com/nao1215/gozen v0.1.0\n)\n'
check "replace for a different version does not apply" v0.2.0 $'module m\nrequire github.com/nao1215/gozen v0.2.0\nreplace github.com/nao1215/gozen v0.1.0 => ../gozen\n'
check "replace of another module does not apply" v0.2.0 $'module m\nrequire github.com/nao1215/gozen v0.2.0\nreplace github.com/other/mod => ../other\n'

# Errors.
check_error "local replace (relative)" "local path" $'module m\nrequire github.com/nao1215/gozen v0.2.0\nreplace github.com/nao1215/gozen => ../gozen\n'
check_error "local replace (dot-slash)" "local path" $'module m\nrequire github.com/nao1215/gozen v0.2.0\nreplace github.com/nao1215/gozen => ./third_party/gozen\n'
check_error "local replace (absolute)" "local path" $'module m\nrequire github.com/nao1215/gozen v0.2.0\nreplace github.com/nao1215/gozen => /home/me/gozen\n'
check_error "local replace (windows drive)" "local path" $'module m\nrequire github.com/nao1215/gozen v0.2.0\nreplace github.com/nao1215/gozen => C:\\src\\gozen\n'
check_error "local replace in a block" "local path" $'module m\nrequire github.com/nao1215/gozen v0.2.0\nreplace (\n\tgithub.com/nao1215/gozen => ../gozen\n)\n'
check_error "replace by a fork" "another module" $'module m\nrequire github.com/nao1215/gozen v0.2.0\nreplace github.com/nao1215/gozen => github.com/me/gozen v0.2.0\n'
check_error "pseudo-version" "pseudo-version" $'module m\nrequire github.com/nao1215/gozen v0.0.0-20261021093000-0123456789ab\n'
check_error "pseudo-version after a tag" "pseudo-version" $'module m\nrequire github.com/nao1215/gozen v0.2.1-0.20261021093000-0123456789ab\n'
check_error "pseudo-version via replace" "pseudo-version" $'module m\nrequire github.com/nao1215/gozen v0.2.0\nreplace github.com/nao1215/gozen => github.com/nao1215/gozen v0.0.0-20261021093000-0123456789ab\n'
check_error "gozen missing" "is not required" $'module m\nrequire github.com/a/b v1.0.0\n'
check_error "empty go.mod" "is not required" ''
check_error "only a replace, no require" "is not required" $'module m\nreplace github.com/nao1215/gozen => github.com/nao1215/gozen v0.1.0\n'
check_error "the hint is shown" "version:" $'module m\n'

# The shipped fixtures.
fx="${here}/../test/fixtures"
for pair in "game:v0.2.0" "monorepo/games/rpg:v0.2.0"; do
  dir="${pair%%:*}"; want="${pair##*:}"
  TAG=""; gozen_version_from_gomod "${fx}/${dir}/go.mod"
  if [ "$TAG" = "$want" ]; then pass "fixture ${dir} -> $TAG"; else fail "fixture ${dir} -> $TAG"; fi
done
for dir in local-replace pseudo; do
  if (gozen_version_from_gomod "${fx}/${dir}/go.mod") >/dev/null 2>"$tmp/err"; then
    fail "fixture ${dir} was accepted"
  else
    pass "fixture ${dir} rejected"
  fi
done

if [ "$failures" -ne 0 ]; then
  printf '%d test(s) failed\n' "$failures" >&2
  exit 1
fi
printf 'all go.mod tests passed\n'
