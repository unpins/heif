# heif

Standalone, self-contained build of the [libheif](https://github.com/strukturag/libheif)
image tools — **encode, decode and inspect HEIC / HEIF / AVIF**.

[![CI](https://github.com/unpins/heif/actions/workflows/heif.yml/badge.svg)](https://github.com/unpins/heif/actions)
![Linux](https://img.shields.io/badge/Linux-%E2%9C%93-success?logo=linux&logoColor=white)
![macOS](https://img.shields.io/badge/macOS-%E2%9C%93-success?logo=apple&logoColor=white)
![Windows](https://img.shields.io/badge/Windows-%E2%9C%93-success?logo=windows&logoColor=white)

One static binary, no dependencies to install. Ships three tools as a single
multicall binary (dispatch by program name):

| applet | what it does |
| --- | --- |
| `heif-enc` | encode PNG/JPEG → HEIC (HEVC) or AVIF (AV1) |
| `heif-dec` | decode HEIC/HEIF/AVIF → PNG/JPEG/Y4M |
| `heif-info` | print metadata about a HEIF/AVIF file |

```console
$ heif-enc input.png -o out.heic
$ heif-dec out.heic out.png
$ heif-info out.heic
```

Codecs built in: **HEVC** encode (x265) + decode (libde265), **AV1** encode
(aom) + decode (dav1d/aom). Image I/O: PNG, JPEG.

## Install

```console
$ unpin install heif
```

`unpin` recreates the per-tool shims (`heif-enc`, `heif-dec`, `heif-info`) so
each name dispatches to the right applet. You can also call the bare binary:
`heif heif-enc …`.

## Man pages

`heif-enc.1`, `heif-dec.1` and `heif-info.1` are embedded in the binary — read
with `unpin man heif <tool>`. `heif-thumbnailer.1` is excluded; that tool isn't
shipped.

## Build notes

- Single multicall binary: libheif builds `heif-enc`/`heif-dec`/`heif-info` as
  separate "examples". We post-link them into one `heif` (`multicall.nix`),
  reusing `heif-enc`'s CMake `link.txt` (widest lib set) and splicing in the
  other tools' `main` objects + an argv[0] dispatcher.
- Encoders re-enabled: the shared nix-lib overlay (used by `chafa`) builds
  libheif decode-only; here x265 (HEVC) + aom (AV1) are turned back on so
  `heif-enc` can write.
- `rav1e` (heavy Rust AV1 encoder), the gdk-pixbuf loader, AVC (x264/openh264),
  VVC, SVT-AV1 and the thumbnailer/SDL2 viewer tools are all dropped — `heif-*`
  with x265 + aom covers HEIC and AVIF.
- Static everywhere: musl on Linux, static libc++ on macOS (only `libSystem`
  remains), `-static` mingw on Windows (no companion DLLs).
