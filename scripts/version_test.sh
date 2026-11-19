#!/usr/bin/env bash
#
# version_test.sh - check how the `version` input becomes a release tag:
# explicit versions, `latest` (API mocked), and rejection of anything that
# is not a plain release version.
#
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source-path=SCRIPTDIR
# shellcheck source=install.sh
source "${here}/install.sh"

failures=0
errfile="$(mktemp)"
trap 'rm -f "$errfile"' EXIT

pass() { printf 'ok:   %s\n' "$*"; }
fail() { printf 'FAIL: %s\n' "$*"; failures=$((failures + 1)); }

check_tag_name() {
  local body="$1" want="$2" got
  got="$(extract_tag_name "$body")"
  if [ "$got" != "$want" ]; then fail "extract_tag_name(...) -> $got (want $want)"; else pass "extract_tag_name(...) -> $got"; fi
}

check() {
  local input="$1" want_tag="$2" want_num="$3"
  INPUT_VERSION="$input"
  TAG="" NUM_VERSION=""
  resolve_version >/dev/null
  if [ "$TAG" != "$want_tag" ] || [ "$NUM_VERSION" != "$want_num" ]; then
    fail "$input -> TAG=$TAG NUM=$NUM_VERSION (want TAG=$want_tag NUM=$want_num)"
  else
    pass "$input -> TAG=$TAG NUM=$NUM_VERSION"
  fi
}

check_rejected() {
  local input="$1"
  INPUT_VERSION="$input"
  if (resolve_version) >/dev/null 2>"$errfile"; then
    fail "'$input' was accepted"
  else
    pass "'$input' rejected"
  fi
}

check_latest() {
  INPUT_VERSION="latest"
  TAG="" NUM_VERSION=""
  gh_curl() {
    printf '%s\n' '{"url":"https://api.github.com/repos/nao1215/gozen/releases/1","tag_name":"v0.2.1","name":"v0.2.1"}'
  }
  resolve_version >/dev/null
  if [ "$TAG" != "v0.2.1" ] || [ "$NUM_VERSION" != "0.2.1" ]; then
    fail "latest -> TAG=$TAG NUM=$NUM_VERSION (want v0.2.1)"
  else
    pass "latest -> TAG=$TAG NUM=$NUM_VERSION"
  fi
  unset -f gh_curl
}

# check_latest_fallback NAME WANT LATEST_BODY LIST_BODY
# releases/latest answers LATEST_BODY and GET /releases answers LIST_BODY; the
# resolved tag must be WANT, or the step must fail when WANT is empty.
check_latest_fallback() {
  local name="$1" want="$2" latest_body="$3" list_body="$4"
  INPUT_VERSION="latest"
  TAG="" NUM_VERSION=""
  LATEST_BODY="$latest_body" LIST_BODY="$list_body"
  gh_curl() {
    case "$*" in
      */releases/latest*) printf '%s\n' "$LATEST_BODY" ;;
      */releases\?per_page=*) printf '%s\n' "$LIST_BODY" ;;
      *) printf 'unexpected request: %s\n' "$*" >&2; return 1 ;;
    esac
  }
  if [ -z "$want" ]; then
    if (resolve_version) >/dev/null 2>"$errfile"; then
      fail "$name: resolved although no CLI release exists"
    else
      pass "$name: fails ($(tail -n1 "$errfile"))"
    fi
  else
    local got
    got="$( (resolve_version >/dev/null && printf '%s' "$TAG") 2>"$errfile")" || true
    if [ "$got" != "$want" ]; then
      fail "$name -> TAG=$got (want $want) $(tail -n1 "$errfile")"
    else
      pass "$name -> TAG=$got"
    fi
  fi
  unset -f gh_curl
}

check_tag_name '{"tag_name":"v0.2.0"}' "v0.2.0"
# A release lists every asset, so the API response outgrows a pipe buffer. The
# tag must come out without a pipe whose reader can stop early.
check_tag_name "$(printf '{\n  "tag_name": "v0.22.0",\n  "assets": ["%s"]\n}\n' "$(head -c 300000 /dev/zero | tr '\0' 'x')")" "v0.22.0"
check_tag_name '{"name":"demo","tag_name":"v2.0.0","draft":false}' "v2.0.0"

check "v0.2.0" "v0.2.0" "0.2.0"
check "0.2.0"  "v0.2.0" "0.2.0"
check " v0.2.0 " "v0.2.0" "0.2.0"
check "v0.3.0-rc.1" "v0.3.0-rc.1" "0.3.0-rc.1"
check_latest

# The gozen repository also publishes game packages and a catalog as
# releases. When one of them is marked latest, `latest` must still resolve the
# newest CLI release instead of a tag with no gozen binary.
pkg_latest='{"tag_name":"phone-counter-v1.0.1","prerelease":false}'
list_pretty="$(printf '[\n  {\n    "tag_name": "phone-counter-v1.0.1",\n    "name": "Counter 1.0.1",\n    "draft": false,\n    "prerelease": false\n  },\n  {\n    "tag_name": "v0.27.0-rc.1",\n    "draft": false,\n    "prerelease": true\n  },\n  {\n    "tag_name": "game-catalog",\n    "prerelease": false\n  },\n  {\n    "tag_name": "v0.26.0",\n    "assets": [{"name": "gozen_0.26.0_linux_amd64.tar.gz", "state": "uploaded"}],\n    "prerelease": false\n  },\n  {\n    "tag_name": "v0.25.0",\n    "prerelease": false\n  }\n]\n')"
list_compact='[{"tag_name":"game-catalog","prerelease":false},{"tag_name":"v0.26.0","prerelease":false},{"tag_name":"v0.25.0","prerelease":false}]'
check_latest_fallback "package release marked latest" v0.26.0 "$pkg_latest" "$list_pretty"
check_latest_fallback "compact release list" v0.26.0 "$pkg_latest" "$list_compact"
check_latest_fallback "latest without tag_name" v0.26.0 '{"message":"Not Found"}' "$list_compact"
check_latest_fallback "CLI release marked latest needs no listing" v0.26.0 '{"tag_name":"v0.26.0"}' 'not json'
check_latest_fallback "no CLI release at all" "" "$pkg_latest" '[{"tag_name":"game-catalog","prerelease":false}]'
check_latest_fallback "only a pre-release CLI" "" "$pkg_latest" '[{"tag_name":"v0.27.0-rc.1","prerelease":true}]'

# The version lands in a URL and a cache path: anything else must be refused.
check_rejected "v0.2"
check_rejected "V0.2.0"      # tags are lower-case v
check_rejected "vv0.2.0"     # doubled prefix
check_rejected "v"           # prefix without a version
check_rejected "0.2.0.0"     # extra component
check_rejected "Latest"      # only the exact word latest means the newest release
check_rejected "GO.MOD"      # only the exact word go.mod reads go.mod
check_rejected "main"
check_rejected "v0.2.0/../../x"
check_rejected 'v0.2.0;id'
# shellcheck disable=SC2016
check_rejected 'v0.2.0$(id)'
check_rejected "../v0.2.0"
check_rejected "v0.0.0-20261021093000-0123456789ab"

# Default (empty or "go.mod") reads go.mod from the workspace.
ws="$(mktemp -d)"
cp "${here}/../test/fixtures/game/go.mod" "$ws/go.mod"
for v in "" "go.mod"; do
  GITHUB_WORKSPACE="$ws" INPUT_GO_MOD_PATH="." check "$v" "v0.2.0" "0.2.0" || true
done
if GITHUB_WORKSPACE="$ws" INPUT_VERSION="go.mod" INPUT_GO_MOD_PATH="../x" \
  bash -c 'source "$1"; resolve_version' _ "${here}/install.sh" >/dev/null 2>"$errfile"; then
  fail "go.mod mode accepted ../x"
fi
if grep -q "'..'" "$errfile"; then pass "go.mod mode rejects ../x"; else fail "go.mod mode did not reject ../x"; fi
rm -rf "$ws"

if [ "$failures" -ne 0 ]; then
  printf '%d test(s) failed\n' "$failures" >&2
  exit 1
fi
printf 'all version tests passed\n'
