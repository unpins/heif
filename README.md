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

## Build locally

```bash
nix build github:unpins/heif
./result/bin/heif heif-enc --help
```

Or run directly:

```bash
nix run github:unpins/heif -- heif-info out.heic
```

The first invocation will offer to add the [unpins.cachix.org](https://unpins.cachix.org) substituter so most pulls come pre-built.

## Manual download

The [Releases](https://github.com/unpins/heif/releases) page has standalone binaries for manual download.

## Build notes

- Single multicall binary: libheif builds `heif-enc`/`heif-dec`/`heif-info` as
  separate "examples". The unpin-llvm engine folds the three into one `heif` on
  every platform, Windows included; which tool runs is decided by the name you
  call it by.
- Encoders re-enabled: the shared nix-lib overlay (used by `chafa`) builds
  libheif decode-only; here x265 (HEVC) + aom (AV1) are turned back on so
  `heif-enc` can write.
- `rav1e` (heavy Rust AV1 encoder), the gdk-pixbuf loader, AVC (x264/openh264),
  VVC, SVT-AV1 and the thumbnailer/SDL2 viewer tools are all dropped — `heif-*`
  with x265 + aom covers HEIC and AVIF.
- Static everywhere: musl on Linux, static libc++ on macOS (only `libSystem`
  remains), `-static` mingw on Windows (no companion DLLs).
