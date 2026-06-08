# heif

The [libheif](https://github.com/strukturag/libheif) image programs — **encode,
decode and inspect HEIC / HEIF / AVIF** — as a single self-contained binary,
built natively for Linux, macOS, and Windows.

[![CI](https://github.com/unpins/heif/actions/workflows/heif.yml/badge.svg)](https://github.com/unpins/heif/actions)
![Linux](https://img.shields.io/badge/Linux-%E2%9C%93-success?logo=linux&logoColor=white)
![macOS](https://img.shields.io/badge/macOS-%E2%9C%93-success?logo=apple&logoColor=white)
![Windows](https://img.shields.io/badge/Windows-%E2%9C%93-success?logo=windows&logoColor=white)

Part of the [unpins](https://unpins.org) catalog; install it with [`unpin`](https://github.com/unpins/unpin): `unpin install heif`.

Codecs built in: **HEVC** encode (x265) + decode (libde265), **AV1** encode
(aom) + decode (dav1d/aom). Image I/O: PNG, JPEG.

## Usage

Run a program with [unpin](https://github.com/unpins/unpin):

```bash
unpin heif heif-enc input.png -o out.heic
unpin heif heif-dec out.heic out.png
unpin heif heif-info out.heic
```

`unpin install heif` also creates the commands `heif-enc` (encode), `heif-dec` (decode) and `heif-info` (inspect):

```bash
unpin install heif
```

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
