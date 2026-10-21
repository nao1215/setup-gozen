# setup-gozen

[![Test](https://github.com/nao1215/setup-gozen/actions/workflows/test.yml/badge.svg)](https://github.com/nao1215/setup-gozen/actions/workflows/test.yml)

GitHub Action to install the [gozen](https://github.com/nao1215/gozen) CLI.

It downloads a prebuilt release binary, so your workflow needs no Go setup and
no compile step. The version can follow your game's `go.mod`. Works on Linux,
macOS, and Windows (amd64 / arm64).

## Quick start

```yaml
steps:
  - uses: actions/checkout@v7
  - uses: nao1215/setup-gozen@v0
  - run: gozen check game
```

By default the action reads the version of `github.com/nao1215/gozen` from the
`go.mod` in the repository root, so the CLI always matches the library your game
is built with.

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

An explicit version:

```yaml
- uses: nao1215/setup-gozen@v0
  with:
    version: v0.2.0
```

A `go.mod` in a subdirectory (a monorepo). The path can be a directory or the
`go.mod` file, and is relative to the workspace:

```yaml
- uses: nao1215/setup-gozen@v0
  with:
    go-mod-path: games/rpg
```

## Pin the action to a commit SHA

Tags can be moved. For a workflow that must not change underneath you, pin the
action to a full commit SHA and keep the tag in a comment:

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

The binary is stored in the runner tool cache
(`$RUNNER_TOOL_CACHE/gozen/<version>/<arch>`), so a second step or job on the
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

- `go-mod-path` is resolved against `GITHUB_WORKSPACE`. The action refuses absolute
  paths, drive letters (`C:\...`), UNC paths, and any path with a `..` segment.
  Backslashes count as separators, so `..\..\etc` is refused too. After that, the
  path is resolved to its real location (symbolic links followed) and must still
  lie inside the real workspace; a link that points outside fails the step.
  The target must be a directory containing `go.mod`, or a file named `go.mod`.
- The explicit `version` input must be a plain release version, because it ends
  up in a download URL and a cache path.
- The archive is checked against the `checksums.txt` of the same release, and a
  mismatch or a missing entry stops the install. Set `verify-checksum: false`
  only if you accept the risk.
- `verify-attestation: true` additionally runs `gh attestation verify` against
  the gozen repository (requires the `gh` CLI, present on GitHub-hosted runners).
  gozen releases also publish a cosign-signed `checksums.txt` and SLSA provenance
  (`multiple.intoto.jsonl`), which you can check by hand.
- `github-token` is sent only to `api.github.com`, never to release download
  hosts, and is never printed.

## Compared with `go run github.com/nao1215/gozen/cmd/gozen`

`go run` also works and needs nothing but Go, but it compiles the CLI and its
dependencies (Ebitengine included) on every fresh runner. This action downloads
a prebuilt, checksum-verified binary in a few seconds. Because `version: go.mod`
follows your `go.mod`, you keep the same guarantee that `go run` gives: the CLI
version matches the library version.

## Maintainer release flow

1. Run the `PrepareRelease` workflow from the Actions tab with `vX.Y.Z` (or `X.Y.Z`).
1. Open the draft GitHub release it creates, tick `Publish this Action to the GitHub Marketplace`, then publish it.
1. After publish, `SyncReleaseTags` moves the floating `vX` and `vX.Y` tags (for example `v0` and `v0.1`) to that release.

The action derives release asset names (`gozen_<version>_<os>_<arch>.<ext>`)
from gozen's [GoReleaser](https://goreleaser.com/) config. If gozen's release
naming changes, this action must be updated to match.

## License

[MIT](./LICENSE) (c) CHIKAMATSU Naohiro
