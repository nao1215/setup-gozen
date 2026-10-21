#!/usr/bin/env bash
#
# checksum_test.sh - check that archives are verified against checksums.txt and
# that a mismatch, a missing entry or a tampered archive stops the install.
#
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source-path=SCRIPTDIR
# shellcheck source=install.sh
source "${here}/install.sh"

failures=0
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

pass() { printf 'ok:   %s\n' "$*"; }
fail() { printf 'FAIL: %s\n' "$*"; failures=$((failures + 1)); }

name="gozen_0.2.0_linux_amd64.tar.gz"
printf 'archive bytes\n' >"$tmp/$name"
good="$(sha256_of "$tmp/$name")"
bad="0000000000000000000000000000000000000000000000000000000000000000"
unused="gozen_0.2.0_linux_amd64.tar.gz.sbom.json"

# The real checksums.txt lists many files; the entry must be matched by exact name.
printf '%s  %s\n%s  %s\n%s  %s\n' "$bad" "$unused" "$good" "$name" "$bad" "gozen_0.2.0_darwin_arm64.tar.gz" >"$tmp/checksums.txt"
if (verify_checksum "$tmp/$name" "$tmp/checksums.txt" "$name") >/dev/null; then pass "matching checksum accepted"; else fail "matching checksum rejected"; fi

printf '%s  %s\n' "$(printf '%s' "$good" | tr '[:lower:]' '[:upper:]')" "$name" >"$tmp/checksums.txt"
if (verify_checksum "$tmp/$name" "$tmp/checksums.txt" "$name") >/dev/null; then pass "uppercase hex accepted"; else fail "uppercase hex rejected"; fi

printf '%s  %s\n' "$bad" "$name" >"$tmp/checksums.txt"
if (verify_checksum "$tmp/$name" "$tmp/checksums.txt" "$name") >/dev/null 2>"$tmp/err"; then
  fail "mismatching checksum accepted"
elif grep -q "checksum mismatch" "$tmp/err"; then
  pass "mismatching checksum stops the install"
else
  fail "mismatch: unexpected error $(cat "$tmp/err")"
fi

printf '%s  %s\n' "$good" "gozen_0.2.0_darwin_arm64.tar.gz" >"$tmp/checksums.txt"
if (verify_checksum "$tmp/$name" "$tmp/checksums.txt" "$name") >/dev/null 2>"$tmp/err"; then
  fail "missing entry accepted"
elif grep -q "not found in checksums.txt" "$tmp/err"; then
  pass "missing entry stops the install"
else
  fail "missing entry: unexpected error $(cat "$tmp/err")"
fi

# A prefix of the file name must not satisfy the lookup.
printf '%s  %s\n' "$good" "x${name}" >"$tmp/checksums.txt"
if (verify_checksum "$tmp/$name" "$tmp/checksums.txt" "$name") >/dev/null 2>"$tmp/err"; then
  fail "suffix-only match accepted"
else
  pass "suffix-only match rejected"
fi

# A tampered archive no longer matches.
printf '%s  %s\n' "$good" "$name" >"$tmp/checksums.txt"
printf 'tampered\n' >>"$tmp/$name"
if (verify_checksum "$tmp/$name" "$tmp/checksums.txt" "$name") >/dev/null 2>"$tmp/err"; then
  fail "tampered archive accepted"
else
  pass "tampered archive rejected"
fi

if [ "$failures" -ne 0 ]; then
  printf '%d test(s) failed\n' "$failures" >&2
  exit 1
fi
printf 'all checksum tests passed\n'
