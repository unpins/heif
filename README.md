# heif

The [libheif](https://github.com/strukturag/libheif) image programs — **encode,
decode and inspect HEIC / HEIF / AVIF** — as a single self-contained binary,
built natively for Linux, macOS, and Windows.

[![CI](https://github.com/unpins/heif/actions/workflows/heif.yml/badge.svg)](https://github.com/unpins/heif/actions)
![Linux](https://img.shields.io/badge/Linux-%E2%9C%93-success?logo=linux&logoColor=white)
![macOS](https://img.shields.io/badge/macOS-%E2%9C%93-success?logo=apple&logoColor=white)
![Windows](https://img.shields.io/badge/Windows-%E2%9C%93-success?logo=windows&logoColor=white)

Part of the [unpins](https://unpins.org) catalog; install it with [`unpin`](https://github.com/unpins/unpin): `unpin install heif`.

## Usage

Run a program with [unpin](https://github.com/unpins/unpin):

```bash
unpin heif --unpin-program=heif-enc input.png -o out.heic
unpin heif --unpin-program=heif-dec out.heic out.png
unpin heif --unpin-program=heif-info out.heic
```

To install the programs onto your PATH:

```bash
unpin install heif
```

`unpin install heif` creates the `heif-enc`, `heif-dec` and `heif-info` commands.

## Programs

| command | what it does |
| --- | --- |
| `heif-enc` | encode PNG or JPEG to HEIC / AVIF |
| `heif-dec` | decode HEIC / AVIF to PNG, JPEG or y4m |
| `heif-info` | print what is inside a HEIF file |

## Codecs

| format | encode | decode |
| --- | --- | --- |
| HEIC (HEVC) | x265 | libde265 |
| AVIF (AV1) | aom | dav1d, aom |

`heif-enc --list-encoders` and `heif-dec --list-decoders` print the same list
from the binary you are holding.

Image input and output is PNG and JPEG. TIFF output is not built in;
`heif-dec out.tif` says so and exits 1.

## Man pages

`heif-enc.1`, `heif-dec.1` and `heif-info.1` are embedded in the binary — read
one with `unpin man heif <tool>`, e.g. `unpin man heif heif-enc`.
`heif-thumbnailer.1` is not embedded: that tool isn't shipped.

## Build locally

```bash
nix build github:unpins/heif
./result/bin/heif --unpin-program=heif-enc --help
```

Or run directly:

```bash
nix run github:unpins/heif -- --unpin-program=heif-info out.heic
```

The first invocation will offer to add the [unpins.cachix.org](https://unpins.cachix.org) substituter so most pulls come pre-built.

## Manual download

The [Releases](https://github.com/unpins/heif/releases) page has standalone binaries for manual download.

## Build notes

- **All three tools, one binary.** `unpin install heif` gives you `heif-enc`,
  `heif-dec` and `heif-info` as ordinary commands; without installing, pick one
  with `--unpin-program=heif-enc`.
- **Encoders re-enabled.** The shared nix-lib overlay (the one
  [chafa](https://github.com/unpins/chafa) uses) builds libheif decode-only;
  here x265 (HEVC) and aom (AV1) are turned back on so `heif-enc` can write.
- **Dropped:** `rav1e` (a heavy Rust AV1 encoder — aom already covers AV1), the
  gdk-pixbuf loader, AVC (x264 / openh264), VVC, SVT-AV1, and the
  thumbnailer / SDL2 viewer tools.
- **Static everywhere:** musl on Linux, static libc++ on macOS (only
  `libSystem` remains), `-static` mingw on Windows (no companion DLLs).
