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

`unpin install heif` creates the `heif-enc`, `heif-dec`, `heif-info` and
`heif-thumbnailer` commands, and `heif-convert`, upstream's older name for
`heif-dec`.

## Programs

| command | what it does |
| --- | --- |
| `heif-enc` | encode PNG, JPEG or TIFF to HEIC / AVIF |
| `heif-dec` | decode HEIC / AVIF to PNG, JPEG, TIFF or y4m |
| `heif-info` | print what is inside a HEIF file |
| `heif-thumbnailer` | write a small PNG preview of a HEIF file |

## Codecs

| format | encode | decode |
| --- | --- | --- |
| HEIC (HEVC) | x265 | libde265 |
| AVIF (AV1) | aom | dav1d, aom |

`heif-enc --list-encoders` and `heif-dec --list-decoders` print the same list
from the binary you are holding.

Image input and output is PNG, JPEG and TIFF.

## Man pages

`heif-enc.1`, `heif-dec.1`, `heif-info.1` and `heif-thumbnailer.1` are embedded
in the binary — read one with `unpin man heif <program>`, e.g.
`unpin man heif heif-enc`.

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

- **Not included:** `heif-view` (it needs SDL2), the gdk-pixbuf loader (a
  plugin for other programs, not a command), AVC (x264 / OpenH264, off in
  nixpkgs too) and WebP input (nixpkgs' libheif has none either).
