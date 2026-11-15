# Changelog

## [Unreleased]

### Added

- `heif-thumbnailer`, and `heif-convert` as another name for `heif-dec`, as
  libheif installs them.

### Fixed

- TIFF works: `heif-enc` reads it and `heif-dec` writes it. Before,
  `heif-dec out.tif` said TIFF was not built in and exited 1.

- On Linux x86_64, i686 and aarch64, HEIC encoding with x265 ignored NUMA: on
  a machine with several NUMA nodes it ran one thread pool across all of them
  instead of one per node. NUMA support is back, as in nixpkgs.

## [1.23.4-1] - 2026-09-26

### Fixed

- **`heif-enc` could not write HEIC on the 32-bit x86 (`i686-linux`) build.**
  x265 rejected its own parameters — "Psy-rd strength must be between 0 and
  5.0" — and the encode ended in `Invalid image size`. AVIF encoding, and every
  decoder, kept working; no other platform was affected. The released
  `v1.21.2-1` binaries predate this and encode normally.

### Added

- The build now encodes a small image to both HEIC and AVIF and decodes it
  back, on every platform it can run the tools on. A codec that registers but
  cannot encode is otherwise invisible: `heif-enc --version` prints the same
  line either way.

### Changed

- Updated to libheif 1.23.4.
- README: `unpin heif heif-enc …` never selected a program; the form is
  `unpin heif --unpin-program=heif-enc …`, or install the binary and call
  `heif-enc` directly. Added the codec table and a note that TIFF output is not
  built in.
