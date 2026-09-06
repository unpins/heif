# Changelog

## [Unreleased]

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

- README: `unpin heif heif-enc …` never selected a program; the form is
  `unpin heif --unpin-program=heif-enc …`, or install the binary and call
  `heif-enc` directly. Added the codec table and a note that TIFF output is not
  built in.
