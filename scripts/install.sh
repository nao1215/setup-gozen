#!/usr/bin/env bash
#
# install.sh - download and install a prebuilt gozen release binary.
#
# Runs as a composite-action step on GitHub-hosted runners (Linux, macOS,
# Windows). On Windows it executes under Git Bash, so it relies only on tools
# that ship with every runner (bash, curl, tar, awk, and unzip or PowerShell).
#
# Release artifacts are produced by gozen's GoReleaser config, e.g.:
#   gozen_0.2.0_linux_amd64.tar.gz
#   gozen_0.2.0_darwin_arm64.tar.gz
#   gozen_0.2.0_windows_amd64.zip
#   checksums.txt
set -euo pipefail

readonly OWNER="nao1215"
readonly REPO="gozen"
readonly BINARY="gozen"

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
log() { printf '%s\n' "==> $*"; }
die() { printf '%s\n' "ERROR: $*" >&2; exit 1; }

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source-path=SCRIPTDIR
# shellcheck source=gomod.sh
source "${here}/gomod.sh"

# Emit a GitHub Actions step output when running in Actions; harmless locally.
set_output() {
  local name="$1" value="$2"
  if [ -n "${GITHUB_OUTPUT:-}" ]; then
    printf '%s=%s\n' "$name" "$value" >>"$GITHUB_OUTPUT"
  fi
}

# Convert a path to the runner's native form before writing it to $GITHUB_PATH.
# On Windows the script runs under Git Bash, so a POSIX path like /c/foo would
# not resolve for a following PowerShell step; cygpath rewrites it to C:\foo.
to_native_path() {
  local p="$1"
  if [ "${OS:-}" = "windows" ] && command -v cygpath >/dev/null 2>&1; then
    cygpath -w "$p"
  else
    printf '%s' "$p"
  fi
}

# curl wrapper for the GitHub REST API. The token goes to api.github.com only:
# release downloads are public and redirect to other hosts, so they are made
# without credentials. The token is passed as a header argument and is never
# printed. Branching avoids expanding a possibly-empty array under `set -u` on
# macOS bash 3.2.
gh_curl() {
  if [ -n "${INPUT_GITHUB_TOKEN:-}" ]; then
    curl --fail --silent --show-error --location --retry 3 --retry-delay 2 \
      -H "X-GitHub-Api-Version: 2022-11-28" \
      -H "Authorization: Bearer ${INPUT_GITHUB_TOKEN}" "$@"
  else
    curl --fail --silent --show-error --location --retry 3 --retry-delay 2 \
      -H "X-GitHub-Api-Version: 2022-11-28" "$@"
  fi
}

# Plain download of a public release asset (no credentials).
download() {
  curl --fail --silent --show-error --location --retry 3 --retry-delay 2 "$@"
}

extract_tag_name() {
  local body="$1" after
  case "$body" in
    *'"tag_name"'*)
      after="${body#*\"tag_name\"}"
      after="${after#*:}"
      after="${after#*\"}"
      printf '%s' "${after%%\"*}"
      ;;
    *)
      printf ''
      ;;
  esac
}

# ---------------------------------------------------------------------------
# Resolve OS / architecture into GoReleaser's naming.
# ---------------------------------------------------------------------------
detect_platform() {
  case "${RUNNER_OS:-}" in
    Linux)   OS="linux"   ; EXT="tar.gz" ; BIN_SUFFIX=""     ;;
    macOS)   OS="darwin"  ; EXT="tar.gz" ; BIN_SUFFIX=""     ;;
    Windows) OS="windows" ; EXT="zip"    ; BIN_SUFFIX=".exe" ;;
    *) die "unsupported runner OS: '${RUNNER_OS:-}' (expected Linux, macOS, or Windows)" ;;
  esac

  # CACHE_ARCH follows the naming of actions/tool-cache (x64, arm64).
  case "${RUNNER_ARCH:-}" in
    X64|x86_64|amd64) ARCH="amd64" ; CACHE_ARCH="x64"   ;;
    ARM64|aarch64)    ARCH="arm64" ; CACHE_ARCH="arm64" ;;
    *) die "unsupported runner architecture: '${RUNNER_ARCH:-}' (expected X64 or ARM64)" ;;
  esac
}

# ---------------------------------------------------------------------------
# Resolve the release tag from the `version` and `go-mod-path` inputs.
#   go.mod   (default) the version of github.com/nao1215/gozen in the go.mod
#   latest   the newest release
#   v0.2.0   an explicit release (the leading v is optional)
# Sets TAG (with leading v) and NUM_VERSION (without leading v).
# ---------------------------------------------------------------------------
resolve_version() {
  local requested="${INPUT_VERSION:-go.mod}"
  requested="$(printf '%s' "$requested" | tr -d '[:space:]')"

  if [ -z "$requested" ] || [ "$requested" = "go.mod" ]; then
    resolve_go_mod_file "${INPUT_GO_MOD_PATH:-.}"
    log "Reading the gozen version from ${GO_MOD_FILE}"
    gozen_version_from_gomod "$GO_MOD_FILE"
    return 0
  fi

  if [ "$requested" = "latest" ]; then
    log "Resolving latest gozen release..."
    local body tag
    body="$(gh_curl "https://api.github.com/repos/${OWNER}/${REPO}/releases/latest")" \
      || die "failed to query the latest release from the GitHub API"
    # Extract tag_name without depending on jq.
    tag="$(extract_tag_name "$body")"
    [ -n "$tag" ] || die "could not determine the latest release tag"
    requested="$tag"
  fi

  # Normalize: TAG keeps the leading v, NUM_VERSION drops it. The value ends
  # up in a download URL and a cache path, so it must be a plain version.
  case "$requested" in
    v*) ;;
    *) requested="v${requested}" ;;
  esac
  validate_release_version "$requested"
  TAG="$requested"
  NUM_VERSION="${requested#v}"
}

# ---------------------------------------------------------------------------
# Verify the archive against checksums.txt (SHA-256).
# ---------------------------------------------------------------------------
sha256_of() {
  local file="$1"
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$file" | awk '{print $1}'
  elif command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$file" | awk '{print $1}'
  elif command -v certutil >/dev/null 2>&1; then
    # Windows fallback: certutil prints the hash on the second line.
    certutil -hashfile "$file" SHA256 | sed -n '2p' | tr -d '[:space:]'
  else
    return 1
  fi
}

verify_checksum() {
  local archive="$1" checksums="$2" name="$3"
  local expected actual
  expected="$(grep -E "[[:space:]]\*?${name//./\\.}\$" "$checksums" | awk '{print $1}' | head -n1)"
  [ -n "$expected" ] || die "checksum for ${name} not found in checksums.txt"

  actual="$(sha256_of "$archive")" \
    || die "no SHA-256 tool (sha256sum/shasum/certutil) available to verify ${name}"

  # Normalize to lowercase for comparison.
  expected="$(printf '%s' "$expected" | tr '[:upper:]' '[:lower:]')"
  actual="$(printf '%s' "$actual" | tr '[:upper:]' '[:lower:]')"

  if [ "$expected" != "$actual" ]; then
    die "checksum mismatch for ${name}: expected ${expected}, got ${actual}"
  fi
  log "Checksum OK (${name})"
}

# ---------------------------------------------------------------------------
# Verify build provenance with the gh CLI (opt-in).
# ---------------------------------------------------------------------------
verify_attestation() {
  local archive="$1"
  command -v gh >/dev/null 2>&1 \
    || die "verify-attestation is enabled but the gh CLI is not available on this runner"
  if [ -z "${GH_TOKEN:-}" ] && [ -z "${GITHUB_TOKEN:-}" ]; then
    die "verify-attestation is enabled but neither GH_TOKEN nor GITHUB_TOKEN is set"
  fi
  log "Verifying build provenance with gh attestation verify..."
  gh attestation verify "$archive" --repo "${OWNER}/${REPO}" \
    || die "build provenance verification failed for $(basename "$archive")"
  log "Attestation OK"
}

# ---------------------------------------------------------------------------
# Extract the archive into a directory.
# ---------------------------------------------------------------------------
extract_archive() {
  local archive="$1" dest="$2"
  mkdir -p "$dest"
  case "$archive" in
    *.tar.gz|*.tgz)
      tar -xzf "$archive" -C "$dest"
      ;;
    *.zip)
      if command -v unzip >/dev/null 2>&1; then
        unzip -oq "$archive" -d "$dest"
      elif command -v pwsh >/dev/null 2>&1 || command -v powershell >/dev/null 2>&1; then
        local ps
        ps="$(command -v pwsh || command -v powershell)"
        "$ps" -NoProfile -NonInteractive -Command \
          "Expand-Archive -Path '${archive}' -DestinationPath '${dest}' -Force"
      else
        die "cannot extract ${archive}: neither unzip nor PowerShell is available"
      fi
      ;;
    *)
      die "unsupported archive format: ${archive}"
      ;;
  esac
}

# ---------------------------------------------------------------------------
# Download, verify and extract into the tool cache. Sets CACHE_DIR.
# The cache layout mirrors actions/tool-cache:
#   $RUNNER_TOOL_CACHE/gozen/<version>/<arch>[.complete]
# ---------------------------------------------------------------------------
fetch_into_cache() {
  local bin_name="$1"
  local archive_name="${BINARY}_${NUM_VERSION}_${OS}_${ARCH}.${EXT}"
  local base_url="https://github.com/${OWNER}/${REPO}/releases/download/${TAG}"

  # NOT `local`: the EXIT trap fires after the function returns, when a local
  # would already be out of scope; under `set -u` that fails the trap.
  workdir="$(mktemp -d)"
  trap 'rm -rf "${workdir:-}"' EXIT

  local archive_path="${workdir}/${archive_name}"
  local checksums_path="${workdir}/checksums.txt"
  # checksums.txt downloads while the archive does, to save a round trip.
  local checksums_pid=""
  if [ "${INPUT_VERIFY_CHECKSUM:-true}" = "true" ]; then
    download -o "$checksums_path" "${base_url}/checksums.txt" &
    checksums_pid=$!
  fi
  log "Downloading ${base_url}/${archive_name}"
  download -o "$archive_path" "${base_url}/${archive_name}" \
    || die "failed to download ${archive_name}. Does release ${TAG} exist with this OS/arch?"

  if [ -n "$checksums_pid" ]; then
    wait "$checksums_pid" \
      || die "verify-checksum is enabled but checksums.txt could not be downloaded for ${TAG}"
    verify_checksum "$archive_path" "$checksums_path" "$archive_name"
  else
    log "Checksum verification disabled by input (verify-checksum: false)"
  fi

  if [ "${INPUT_VERIFY_ATTESTATION:-false}" = "true" ]; then
    verify_attestation "$archive_path"
  fi

  local extract_dir="${workdir}/extracted"
  extract_archive "$archive_path" "$extract_dir"

  local src_bin
  src_bin="$(find "$extract_dir" -maxdepth 1 -type f -name "$bin_name" | head -n1)"
  [ -n "$src_bin" ] || die "binary '${bin_name}' not found inside ${archive_name}"

  rm -rf "$CACHE_DIR" "${CACHE_DIR}.complete"
  mkdir -p "$CACHE_DIR"
  cp "$src_bin" "${CACHE_DIR}/${bin_name}"
  chmod +x "${CACHE_DIR}/${bin_name}" || true
  : >"${CACHE_DIR}.complete"
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
main() {
  detect_platform
  resolve_version

  local bin_name="${BINARY}${BIN_SUFFIX}"
  local cache_root="${RUNNER_TOOL_CACHE:-${HOME}/.gozen/tool-cache}"
  CACHE_DIR="${cache_root}/${BINARY}/${NUM_VERSION}/${CACHE_ARCH}"

  log "Installing ${BINARY} ${TAG} (${OS}/${ARCH})"

  local cache_hit="false"
  if [ -f "${CACHE_DIR}.complete" ] && [ -x "${CACHE_DIR}/${bin_name}" ]; then
    cache_hit="true"
    log "Found ${BINARY} ${TAG} in the tool cache"
  else
    fetch_into_cache "$bin_name"
  fi

  # By default the binary is used where the tool cache keeps it. install-dir
  # copies it elsewhere instead.
  local install_dir="${INPUT_INSTALL_DIR:-}"
  local dest_bin="${CACHE_DIR}/${bin_name}"
  if [ -n "$install_dir" ]; then
    mkdir -p "$install_dir"
    dest_bin="${install_dir}/${bin_name}"
    cp "${CACHE_DIR}/${bin_name}" "$dest_bin"
    chmod +x "$dest_bin" || true
  else
    install_dir="$CACHE_DIR"
  fi

  # Add to PATH for subsequent steps, in the runner's native path format so it
  # resolves in both bash and PowerShell steps.
  if [ "${INPUT_ADD_TO_PATH:-true}" = "true" ] && [ -n "${GITHUB_PATH:-}" ]; then
    printf '%s\n' "$(to_native_path "$install_dir")" >>"$GITHUB_PATH"
  fi

  log "Installed ${bin_name} -> ${dest_bin}"

  set_output "version" "$TAG"
  set_output "gozen-path" "$(to_native_path "$dest_bin")"
  set_output "install-dir" "$(to_native_path "$install_dir")"
  set_output "cache-hit" "$cache_hit"
}

# Only run when executed directly, so tests can source the functions above.
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  main "$@"
fi
