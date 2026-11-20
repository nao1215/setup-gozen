# setup-gozen

[![Test](https://github.com/nao1215/setup-gozen/actions/workflows/test.yml/badge.svg)](https://github.com/nao1215/setup-gozen/actions/workflows/test.yml)
[![Gitleaks](https://github.com/nao1215/setup-gozen/actions/workflows/gitleaks.yml/badge.svg)](https://github.com/nao1215/setup-gozen/actions/workflows/gitleaks.yml)
[![Trivy](https://github.com/nao1215/setup-gozen/actions/workflows/trivy.yml/badge.svg)](https://github.com/nao1215/setup-gozen/actions/workflows/trivy.yml)
[![License](https://img.shields.io/github/license/nao1215/setup-gozen)](./LICENSE)
[![OpenSSF Scorecard](https://api.scorecard.dev/projects/github.com/nao1215/setup-gozen/badge)](https://scorecard.dev/viewer/?uri=github.com/nao1215/setup-gozen)

GitHub Action to install the [gozen](https://github.com/nao1215/gozen) CLI.

It downloads a prebuilt, checksum-verified release binary, so the workflow
needs no Go setup and no compile step. Works on Linux, macOS, and Windows
(amd64 / arm64).

## Quick start

```yaml
steps:
  - uses: actions/checkout@v7
  - uses: nao1215/setup-gozen@v0
  - run: gozen check game
```

By default the action installs the version of `github.com/nao1215/gozen` that
the root `go.mod` requires, so the CLI matches the library your game is built
with. `go run github.com/nao1215/gozen/cmd/gozen` gives the same match, but it
compiles the CLI and Ebitengine on every fresh runner; this action takes a few
seconds.

## Usage

Version from `go.mod` (default):

```yaml
- uses: nao1215/setup-gozen@v0
```

Latest release:

```yaml
- uses: nao1215/setup-gozen@v0
  with:
    version: latest
```

`latest` is the newest gozen CLI release (`vX.Y.Z`). Game package and catalog
releases from the gozen repository are skipped, even when GitHub marks one as
latest.

An explicit version:

```yaml
- uses: nao1215/setup-gozen@v0
  with:
    version: v0.2.0
```

A `go.mod` in a subdirectory, given as a directory or the file itself, relative
to the workspace:

```yaml
- uses: nao1215/setup-gozen@v0
  with:
    go-mod-path: games/rpg
```

## Pin the action to a commit SHA

Tags can be moved. To keep the action fixed, pin a full commit SHA and keep the
tag in a comment:

```yaml
- uses: nao1215/setup-gozen@1c378fc446f62ecb29a7bcd40aea6dff8565d698 # v0.1.1
```

Dependabot and Renovate can keep a SHA-pinned action up to date.

## Inputs

| Name                 | Default               | Description                                                                 |
| -------------------- | --------------------- | --------------------------------------------------------------------------- |
| `version`            | `go.mod`              | `go.mod` (the version your go.mod requires), `latest`, or `v0.2.0` / `0.2.0`. |
| `go-mod-path`        | `.`                   | With `version: go.mod`: a go.mod file or a directory holding one, relative to the workspace. |
| `github-token`       | `${{ github.token }}` | Token for GitHub API requests (resolving `latest`), to avoid rate limits.   |
| `install-dir`        | (tool cache)          | Copy the binary into this directory instead of using the tool cache path.   |
| `verify-checksum`    | `true`                | Verify the archive against the release `checksums.txt` (SHA-256).           |
| `verify-attestation` | `false`               | Verify build provenance with `gh attestation verify` (opt-in).              |
| `add-to-path`        | `true`                | Add the install directory to `PATH`. Set `false` for outputs only.          |

## Outputs

| Name          | Description                                              |
| ------------- | -------------------------------------------------------- |
| `version`     | Installed version (for example `v0.2.0`).                |
| `gozen-path`  | Absolute path to the `gozen` binary.                     |
| `install-dir` | Directory containing the binary (added to `PATH`).       |
| `cache-hit`   | `true` when the binary came from the runner tool cache.  |

The binary goes into the runner tool cache
(`$RUNNER_TOOL_CACHE/gozen/<version>/<arch>`), so a later step or job on the
same runner that asks for the same version skips the download.

## How go.mod is read

With `version: go.mod` the action finds the `github.com/nao1215/gozen` entry:

- Direct and `// indirect` requirements, single-line or inside a `require ( ... )` block.
- A `replace` that points gozen at another release of the same module: the version after `=>` is used.
- A `replace` that points at a local path: the action fails, because no release version is defined.
  Set `version:` explicitly, or use `go run github.com/nao1215/gozen/cmd/gozen`.
- A pseudo-version (`v0.0.0-20260101000000-0123456789ab`): the action fails for the same reason, since
  release binaries exist only for tagged versions.
- A go.mod without gozen: the action fails.

## Security

- `go-mod-path` is resolved against `GITHUB_WORKSPACE`. Absolute paths, drive
  letters (`C:\...`), UNC paths and any `..` segment are refused, with
  backslashes counted as separators (`..\..\etc` is refused too). The real path,
  with symbolic links followed, must stay inside the real workspace and must be
  a directory containing `go.mod` or a file named `go.mod`.
- The explicit `version` input must be a plain release version, because it ends
  up in a download URL and a cache path.
- The archive is checked against the same release's `checksums.txt`; a mismatch
  or a missing entry stops the install.
- `verify-attestation: true` also runs `gh attestation verify` against the gozen
  repository (the `gh` CLI is present on GitHub-hosted runners). Releases also
  publish a cosign-signed `checksums.txt` and SLSA provenance
  (`multiple.intoto.jsonl`) for checking by hand.
- `github-token` is sent only to `api.github.com`, never to release download
  hosts, and is never printed.

## Maintainer release flow

1. Run the `PrepareRelease` workflow from the Actions tab with `vX.Y.Z` (or `X.Y.Z`).
1. Open the draft GitHub release it creates, tick `Publish this Action to the GitHub Marketplace`, then publish it.
1. After publish, `SyncReleaseTags` moves the floating `vX` and `vX.Y` tags (for example `v0` and `v0.1`) to that release.

The action derives release asset names (`gozen_<version>_<os>_<arch>.<ext>`)
from gozen's [GoReleaser](https://goreleaser.com/) config. If gozen's release
naming changes, this action must be updated to match.

## Testing

| Technique | Bug class caught here |
|---|---|
| [Version input boundaries](scripts/version_test.sh) | `latest`, empty, whitespace, `v`-less and pre-release inputs resolving to the wrong tag, malformed versions reaching the download URL, and `latest` landing on a game package release that has no CLI binary |
| [go.mod parsing](scripts/gomod_test.sh) | Require blocks, `// indirect`, CRLF, quoted paths, `replace` and pseudo-versions read as the wrong gozen version |
| [go-mod-path safety](scripts/path_test.sh) | `..`, absolute, drive-letter, backslash and symbolic-link paths escaping the workspace |
| [Checksum verification](scripts/checksum_test.sh) | A mismatched or missing `checksums.txt` entry passing silently |
| [Release tag normalization](scripts/release_meta_test.sh) | Floating `vX` / `vX.Y` tags computed from a malformed release tag |
| [Real-runner installs](.github/workflows/test.yml) | Asset naming, extraction, tool cache and `PATH` breakage on Linux, macOS and Windows (amd64 / arm64), pinned and `v`-less versions installing something else, and invalid inputs or a missing release passing silently on Linux and Windows |

The unit scripts run on Linux, macOS (bash 3.2) and Windows (Git Bash) in the `unit` job:

```shell
shellcheck -x scripts/*.sh
for t in scripts/*_test.sh; do bash "$t"; done
```

## License

[MIT](./LICENSE) (c) CHIKAMATSU Naohiro
