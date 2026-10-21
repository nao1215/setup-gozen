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

# The version lands in a URL and a cache path: anything else must be refused.
check_rejected "v0.2"
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
GITHUB_WORKSPACE="$ws" INPUT_VERSION="go.mod" INPUT_GO_MOD_PATH="../x" \
  bash -c 'source "$1"; resolve_version' _ "${here}/install.sh" >/dev/null 2>"$errfile" \
  && fail "go.mod mode accepted ../x" || true
if grep -q "'..'" "$errfile"; then pass "go.mod mode rejects ../x"; else fail "go.mod mode did not reject ../x"; fi
rm -rf "$ws"

if [ "$failures" -ne 0 ]; then
  printf '%d test(s) failed\n' "$failures" >&2
  exit 1
fi
printf 'all version tests passed\n'
