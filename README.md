# govm

`govm` is a Go version manager built with Zig.

It installs official Go SDK releases, keeps them under a single root directory,
and switches the active version through a stable `current` link. The project is
small on purpose: the commands are simple, the storage layout is explicit, and
the tool only uses official Go release metadata and archives.

## Features

- Install Go SDKs from the official `go.dev` release feed.
- Cache downloaded archives under `downloads/` and reuse them after checksum verification.
- Keep installed SDKs under `sdks/go<version>/`.
- Switch the active Go version through `<root>/current`.
- Show the active SDK directory with `current` and the active Go binary with `which`.
- Prevent removing the version currently pointed to by `current`.
- Persist the chosen `--root` path so it only needs to be provided once.

## Build

```bash
zig build
```

The executable will be available at:

```text
zig-out/bin/govm
```

Run tests with:

```bash
zig build test
```

## Commands

```text
govm [--root <path>] list [--installed] [--stable-only] [--head N|--tail N] [--reverse]
govm [--root <path>] install <version>
govm [--root <path>] use <version>
govm [--root <path>] current
govm [--root <path>] which
govm [--root <path>] remove <version>
```

## Root Resolution

`govm` resolves the installation root in this order:

1. `--root <path>`
2. `GOVM_ROOT`
3. `~/.govm/config.json`

When `--root <path>` is provided, `govm` also saves it to
`~/.govm/config.json` for future runs.

## Typical Usage

First time:

```bash
govm --root /path/to/govm-root install go1.26.1
govm use go1.26.1
```

Later:

```bash
govm list --stable-only --tail 10
govm current
govm which
govm remove go1.25.4
```

## Directory Layout

Inside the chosen root directory, `govm` uses this layout:

```text
<root>/
  downloads/
  sdks/
    go1.26.0/
    go1.26.1/
  current/
```

- `downloads/` stores downloaded archives.
- `sdks/` stores extracted Go SDKs.
- `current/` points to the active SDK.

## Notes

- `install` reuses an existing archive from `downloads/` if it is already present
  and passes checksum verification.
- `remove` will fail for the version currently in use.
- `list` is sorted in ascending version order by default. Use `--tail N` to see
  the newest entries and `--reverse` to flip the output order.
