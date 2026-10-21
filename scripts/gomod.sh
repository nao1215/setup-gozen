#!/usr/bin/env bash
#
# gomod.sh - locate a go.mod safely inside the workspace and read the
# github.com/nao1215/gozen version it pins.
#
# Sourced by install.sh and by the tests. Only relies on tools that ship with
# every runner (bash 3.2+, awk, sed, tr, readlink). Functions call `die` on bad
# input, so callers that want to survive a failure run them in a subshell.

# shellcheck disable=SC2034  # GO_MOD_FILE, TAG and NUM_VERSION are read by the caller.
GOZEN_MODULE="github.com/nao1215/gozen"

if ! declare -F die >/dev/null 2>&1; then
  die() { printf '%s\n' "ERROR: $*" >&2; exit 1; }
fi

GOZEN_HINT="Set the 'version:' input (for example v0.2.0 or latest), or use 'go run github.com/nao1215/gozen/cmd/gozen' instead."

# ---------------------------------------------------------------------------
# validate_rel_path RAW
#
# Accepts a path relative to the workspace and sets REL_PATH (with "/" as the
# separator). Rejects everything that could point outside the workspace by
# its spelling: absolute paths, drive letters, UNC paths, and any ".." segment.
# Backslashes are treated as separators so Windows spellings cannot sneak a
# ".." past a check that only looks for "/".
# ---------------------------------------------------------------------------
validate_rel_path() {
  local raw="$1" p seg
  local -a segs

  case "$raw" in
    *[[:cntrl:]]*) die "go-mod-path must not contain control characters" ;;
  esac

  # Trim surrounding spaces.
  p="${raw#"${raw%%[! ]*}"}"
  p="${p%"${p##*[! ]}"}"
  [ -n "$p" ] || p="."

  p="$(printf '%s' "$p" | sed 's|\\|/|g')"

  case "$p" in
    /*) die "go-mod-path must be relative to the workspace, got an absolute path: ${raw}" ;;
  esac
  if [[ "$p" =~ ^[A-Za-z]: ]]; then
    die "go-mod-path must be relative to the workspace, got a drive path: ${raw}"
  fi

  IFS='/' read -r -a segs <<<"$p"
  for seg in "${segs[@]}"; do
    if [ "$seg" = ".." ]; then
      die "go-mod-path must not contain '..': ${raw}"
    fi
  done

  REL_PATH="$p"
}

# physical_path FILE
#
# Prints FILE with every symbolic link resolved (the portable equivalent of
# realpath: macOS before 13 has none). The file itself must exist.
physical_path() {
  local p="$1" n=0 target dir
  while [ -L "$p" ]; do
    n=$((n + 1))
    [ "$n" -le 40 ] || return 1
    target="$(readlink "$p")" || return 1
    case "$target" in
      /*) p="$target" ;;
      *) p="$(dirname "$p")/$target" ;;
    esac
  done
  dir="$(cd "$(dirname "$p")" && pwd -P)" || return 1
  printf '%s/%s' "${dir%/}" "$(basename "$p")"
}

# ---------------------------------------------------------------------------
# resolve_go_mod_file RAW
#
# Interprets RAW (a file or a directory, relative to $GITHUB_WORKSPACE) and
# sets GO_MOD_FILE to the real path of the go.mod it names. The real path
# (symlinks resolved) must lie inside the real workspace.
# ---------------------------------------------------------------------------
resolve_go_mod_file() {
  local raw="$1" ws ws_real candidate real

  ws="${GITHUB_WORKSPACE:-}"
  [ -n "$ws" ] || die "GITHUB_WORKSPACE is not set"
  [ -d "$ws" ] || die "GITHUB_WORKSPACE is not a directory: ${ws}"
  ws_real="$(cd "$ws" && pwd -P)" || die "cannot resolve GITHUB_WORKSPACE"

  validate_rel_path "$raw"

  candidate="${ws_real}/${REL_PATH}"
  [ -e "$candidate" ] || die "go-mod-path does not exist in the workspace: ${raw}"
  if [ -d "$candidate" ]; then
    candidate="${candidate%/}/go.mod"
    [ -e "$candidate" ] || die "no go.mod in directory: ${raw}"
  fi
  [ "$(basename "$candidate")" = "go.mod" ] \
    || die "go-mod-path must name a directory or a file called go.mod: ${raw}"

  real="$(physical_path "$candidate")" || die "cannot resolve go-mod-path: ${raw}"
  case "$real" in
    "${ws_real}"/*) ;;
    *) die "go-mod-path resolves outside the workspace (symbolic link?): ${raw}" ;;
  esac
  [ -f "$real" ] || die "go-mod-path is not a regular file: ${raw}"

  GO_MOD_FILE="$real"
}

# ---------------------------------------------------------------------------
# gomod_gozen_lines FILE
#
# Prints the lines of go.mod that mention the gozen module:
#   require <version>
#   replace <old-version|-> <new-path> <new-version|->
# Handles single-line and block forms, // comments (including // indirect),
# quoted paths and CRLF.
# ---------------------------------------------------------------------------
gomod_gozen_lines() {
  awk -v mod="$GOZEN_MODULE" '
    function unq(s) { gsub(/^["`]|["`]$/, "", s); return s }
    {
      gsub(/\r/, "")
      sub(/\/\/.*$/, "")
      n = split($0, f, /[ \t]+/)
      k = 0
      for (i = 1; i <= n; i++) if (f[i] != "") t[++k] = f[i]
      if (k == 0) next

      if (block == "") {
        if (k >= 2 && t[2] == "(") { block = t[1]; next }
        verb = t[1]
        m = 0
        for (i = 2; i <= k; i++) a[++m] = t[i]
      } else {
        if (t[1] == ")") { block = ""; next }
        verb = block
        m = 0
        for (i = 1; i <= k; i++) a[++m] = t[i]
      }

      if (verb == "require" && m >= 2 && unq(a[1]) == mod) {
        print "require " unq(a[2])
      } else if (verb == "replace") {
        arrow = 0
        for (i = 1; i <= m; i++) if (a[i] == "=>") { arrow = i; break }
        if (arrow >= 2 && m > arrow && unq(a[1]) == mod) {
          ov = (arrow == 3) ? unq(a[2]) : "-"
          nv = (m >= arrow + 2) ? unq(a[arrow + 2]) : "-"
          print "replace " ov " " unq(a[arrow + 1]) " " nv
        }
      }
    }
  ' "$1"
}

# is_local_path P: true when a replace target is a directory, not a module.
is_local_path() {
  case "$1" in
    .|..|./*|../*|/*|.\\*|..\\*|\\*) return 0 ;;
  esac
  [[ "$1" =~ ^[A-Za-z]: ]]
}

# is_pseudo_version V: true for v0.0.0-20260101000000-abcdef123456 and its
# variants (v1.2.4-0.2026...-hash, v1.2.4-pre.0.2026...-hash).
is_pseudo_version() {
  [[ "$1" =~ ^v[0-9]+\.[0-9]+\.[0-9]+-([0-9A-Za-z.-]*\.)?[0-9]{14}-[0-9a-f]{12}$ ]]
}

# validate_release_version V
# Dies unless V (with leading v) names a release the action can download.
validate_release_version() {
  local v="$1"
  if is_pseudo_version "$v"; then
    die "go.mod pins gozen to a pseudo-version (${v}), which has no release binary. ${GOZEN_HINT}"
  fi
  [[ "$v" =~ ^v[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.-]+)?$ ]] \
    || die "not a valid gozen release version: ${v}"
}

# ---------------------------------------------------------------------------
# gozen_version_from_gomod FILE
# Sets TAG (with leading v) from the gozen entry of the go.mod FILE.
# ---------------------------------------------------------------------------
gozen_version_from_gomod() {
  local file="$1" kind a b c
  local req="" rep_exact="" rep_any=""

  while read -r kind a b c; do
    case "$kind" in
      require) [ -n "$req" ] || req="$a" ;;
      replace)
        # a=old version, b=new path, c=new version. Remember the first of each
        # kind; a versioned replace only applies to that exact version.
        if [ "$a" = "-" ]; then
          [ -n "$rep_any" ] || rep_any="$b $c"
        else
          [ -n "$rep_exact" ] || rep_exact="$a $b $c"
        fi
        ;;
    esac
  done < <(gomod_gozen_lines "$file")

  [ -n "$req" ] || die "${GOZEN_MODULE} is not required by ${file}. ${GOZEN_HINT}"

  local new_path="" new_ver=""
  if [ -n "$rep_exact" ]; then
    read -r a b c <<<"$rep_exact"
    if [ "$a" = "$req" ]; then new_path="$b"; new_ver="$c"; fi
  fi
  if [ -z "$new_path" ] && [ -n "$rep_any" ]; then
    read -r new_path new_ver <<<"$rep_any"
  fi

  if [ -n "$new_path" ]; then
    if is_local_path "$new_path" || [ "$new_ver" = "-" ]; then
      die "go.mod replaces gozen with a local path (${new_path}), so no release version is defined. ${GOZEN_HINT}"
    fi
    if [ "$new_path" != "$GOZEN_MODULE" ]; then
      die "go.mod replaces gozen with another module (${new_path}), which this action cannot download. ${GOZEN_HINT}"
    fi
    req="$new_ver"
  fi

  validate_release_version "$req"
  TAG="$req"
  NUM_VERSION="${req#v}"
}
