{
  description = "the libheif image tools (heif-enc / heif-dec / heif-info) as a single self-contained binary";

  nixConfig = {
    extra-substituters = [ "https://unpins.cachix.org" ];
    extra-trusted-public-keys = [ "unpins.cachix.org-1:DDaShjbZ8VvcqxeTcAU3kV9vxZQBlyb7V/uLBHfTynI=" ];
  };

  inputs.unpins-lib.url = "github:unpins/nix-lib";

  # libheif ships its CLI tools (heif-enc / heif-dec / heif-info) under
  # WITH_EXAMPLES. The shared nix-lib overlay used by chafa builds the library
  # DECODE-ONLY (examples off, encoders off — chafa just wants libheif.a to read
  # HEIC/AVIF): see nix-lib/native-overlay/libheif.nix. Here we turn the tools
  # back on AND re-enable the encoders the overlay dropped (x265 for HEVC/HEIC,
  # aom for AV1/AVIF) so heif-enc can actually write, then let nix-lib self-fold
  # the three tools into a single `heif` binary. The codec chain
  # (libde265/x265/aom/dav1d + png/jpeg) is the SAME one chafa/avif proved across
  # all nine targets, so the deps are cache hits.
  outputs = { self, unpins-lib }:
    let
      ulib = unpins-lib.lib;

      # 16x16 RGB PNG, base64. Input for the installCheck round-trip below; it
      # lives here so the check needs no fetch and no extra source path.
      probePngB64 =
        "iVBORw0KGgoAAAANSUhEUgAAABAAAAAQCAIAAACQkWg2AAAByElEQVR42g2SURHAMAhDkYAEJFQC"
        + "EpCAhElAAhKQUAlIQAISKmHZx27XMpI8ICJiYiE5dJTUyJz8oy8okrKoLt2mHpqlffRQjoeEz2FR"
        + "NmN1/j724EyO4nu5mme4l9/jJRJhOSJ0hFXc5HPRTyykUm5JXMmWHXkr/WSI0Br1eB3S89lxP/Yd"
        + "jXPzVJ28J/q8Obtn3mkiVVYT9aOfKpmyq3x6Qjt1Svfqa43RXK2nlwi2TQVNzRWfRm4QkrBJ67J3"
        + "bdtyLNbusyJyZ//E9bipizk80eccvumvvK9Pe43f9XieRECCnDAPR5DBvzj4KL6X39Y39+v+7ny1"
        + "Xz7QpgiOlKgTV6MtxmO/eBGUwRVy43TohG34i48IuDMEMLIUVrMdjXIDx0mVgCWdCKSbEHWiKq4r"
        + "FadSa62eV381UZIFrnSLu3wK/vSVEWGUmA+g31BgQDYYvh2QRB9cXuqLKL4XyJSom3uk9/TTDuv0"
        + "rq9vtGZbtd9GaprmbXl9iLAm04IhzirQTzjATAXijBbExhslQzsYuBDt8j7ZPju6ZQvt+DZjPRcs"
        + "9a71yix2g94yEVYQe4VlwQZgrJgVBgCqQIX8CAWnkEdPFD76AU9OaBB/sIpCAAAAAElFTkSuQmCC";

      # Engine path (native Linux): the unpin-llvm adapter stdenv, exactly as
      # avif. libheif throws and is heavy C++; its external C++ codec libs
      # (libde265/x265/libaom — all gcc/libstdc++ by default) are the tier-2
      # wall, so rebuild THEM with the engine → libc++, matching libheif. All
      # full-LTO: the asm SIMD (x265/aom nasm and .S) stays native inside an
      # otherwise-bitcode archive and the mega link reads mixed archives fine.
      # dav1d + png/jpeg are C → stay gcc (C ABI links into a libc++ binary).
      engStdenvs = pkgs:
        let
          sp = pkgs.pkgsStatic;
          adapter = lto: ulib.unpinAdapterStdenv {
            inherit pkgs lto;
            target = sp.stdenv.hostPlatform.config;
            native = pkgs.stdenv.buildPlatform.system == pkgs.stdenv.hostPlatform.system;
            cxx = true;
            captureLinks = true;
          };
        in {
          lto = adapter true;
          # x265 is the ONE dep that cannot take full LTO on 32-bit x86. Under
          # `lto = true` the i686 build comes out with a `strtod` that returns
          # garbage: every `x265_param_parse` of a floating-point option lands
          # outside its own range, so libheif's fixed `psy-rd=1.0` / `psy-rdoq=
          # 1.0` are rejected ("Psy-rd strength must be between 0 and 5.0") and
          # heif-enc cannot write HEIC at all — while AVIF and every decoder
          # keep working, so nothing but a real encode shows it. Isolated: the
          # integer options parse fine, `psy-rd=0` (the one value that skips
          # `atof`) is accepted, and ffmpeg's own i686 x265 — same engine, no
          # `lto = true` — parses `psy-rd=1.0` correctly. armv7l is 32-bit and
          # unaffected, so this is x86-32 codegen, not a 32-bit ABI. Dropping
          # LTO for x265 alone restores it: the i686 .heic then matches the
          # other targets byte for byte.
          x265 = adapter (!sp.stdenv.hostPlatform.isi686);
        };

      # libheif with apps + encoders ON, wired onto a (static) pkgs scope.
      # Codec-chain fixes mirror avif/chafa: x265 (pkgsStatic emits split
      # 8/10/12-bit archives + rm's the .a in postInstall — nativeFixes.x265
      # merges + preserves them, and rewrites x265.pc for static/mingw consumers)
      # everywhere; dav1d on darwin (meson cpu_family='arm64' literal). Each is
      # identity off its gate, so other targets keep the cache-hit lib.
      # aom/libde265 need no lib-level fix — chafa already cross-built them on
      # every target.
      # `eng` is the per-package stdenv swap the NATIVE path needs (its engine
      # swap is scoped to pkgsStatic); on the mingw cross multicall.windows =
      # true swaps the whole set, so `eng` is null there.
      mkHeifTools = { eng ? null }: scope:
        let
          tiffDeps = ''
            include(CMakeFindDependencyMacro)
            find_dependency(ZLIB)
            find_dependency(JPEG)
            find_dependency(LibLZMA)
            find_dependency(libdeflate CONFIG)
            find_dependency(zstd CONFIG)
            ${lib.optionalString (tiffHas "libwebp") "find_dependency(WebP CONFIG)"}
            foreach(_tiff_dep IN ITEMS
                "Deflate::Deflate=libdeflate::libdeflate_static"
                "liblzma::liblzma=LibLZMA::LibLZMA"
                "ZSTD::ZSTD=zstd::libzstd_static")
              string(REPLACE "=" ";" _tiff_dep "''${_tiff_dep}")
              list(GET _tiff_dep 0 _tiff_name)
              list(GET _tiff_dep 1 _tiff_real)
              if(NOT TARGET ''${_tiff_name})
                add_library(''${_tiff_name} INTERFACE IMPORTED)
                set_target_properties(''${_tiff_name} PROPERTIES
                  INTERFACE_LINK_LIBRARIES ''${_tiff_real})
              endif()
            endforeach()'';
          lib = scope.lib;
          host = scope.stdenv.hostPlatform;
          tiffHas = n: lib.any (d: (d.pname or "") == n)
            (scope.libtiff.buildInputs ++ scope.libtiff.propagatedBuildInputs);
          # Engine pre-extend: swap the stdenv of the C++ codec libs and libheif
          # BEFORE the nativeFix/vmaf extend below, so the
          # x265 fix + libaom enableVmaf override compose ON TOP of the engine
          # stdenv (.override/.overrideAttrs chain through). No-op off-engine.
          scope' =
            if eng == null then scope
            else scope.extend (final: prev: {
              x265 = prev.x265.override { stdenv = eng.x265; };
              libde265 = prev.libde265.override { stdenv = eng.lto; };
              libaom = prev.libaom.override { stdenv = eng.lto; };
              libheif = prev.libheif.override { stdenv = eng.lto; };
            });
          p = scope'.extend (final: prev:
            {
              x265 = ulib.nativeFixes.x265 prev;
              # aom's vmaf-tuning code (vmaf.c.o) references libvmaf, but
              # libheif's FindAOM (unlike libavif's) does not reflect aom.pc's
              # `Requires: libvmaf` onto the link, so the encoder's pull of
              # vmaf.c.o leaves vmaf_* undefined. heif-enc never exposes
              # `--tune=vmaf`, so drop aom's vmaf support outright — zero loss,
              # and it removes libvmaf from the closure on every target.
              libaom = prev.libaom.override { enableVmaf = false; };
              # libtiff's static CMake config leaves "import dependencies" a
              # TODO, so TIFF::tiff links targets nobody defines and
              # find_package(TIFF) fails on Deflate::Deflate. Fill it in.
              libtiff = prev.libtiff.overrideAttrs (o: {
                postFixup = (o.postFixup or "") + ''
                  substituteInPlace $dev/lib/cmake/tiff/tiff-config.cmake \
                    --replace-fail '    # TODO: import dependencies' '${tiffDeps}'
                '';
              } // lib.optionalAttrs host.isMinGW {
                # pkgsStatic propagates a static library's inputs, the mingw set
                # does not, and the fold links only the propagated closure.
                propagatedBuildInputs = (o.propagatedBuildInputs or [ ])
                  ++ (o.buildInputs or [ ]);
              });
            } // lib.optionalAttrs host.isDarwin {
              dav1d = ulib.nativeFixes.dav1d prev;
            });
          # rav1e is a Rust AV1 encoder vendoring a multi-hundred-MB cargo tree
          # (a tmpfs-filler) — aom covers AV1 encode, so drop it. gdk-pixbuf is
          # the loader module we disable; it also transitively drags libtiff
          # (whose static CMake export breaks heifio's find_package(TIFF)) and,
          # on mingw, make-shell-wrapper-hook (splices to a bash that can't
          # cross-compile). None are needed for the tools, so drop them.
          dropUnused = lib.filter
            (x: !(builtins.elem (x.pname or x.name or "")
              [ "rav1e" "gdk-pixbuf" "make-shell-wrapper-hook" ]));
        in
        p.libheif.overrideAttrs (old: {
          pname = "heif-tools";
          nativeBuildInputs =
            if host.isMinGW then dropUnused (old.nativeBuildInputs or [ ])
            else (old.nativeBuildInputs or [ ]);
          # pkgsStatic auto-promotes buildInputs → propagatedBuildInputs, so the
          # drops must hit BOTH or the old closure (and rav1e's build) survives.
          buildInputs = dropUnused (old.buildInputs or [ ]) ++ [ p.libtiff ];
          propagatedBuildInputs = dropUnused (old.propagatedBuildInputs or [ ]);
          # mingw: de265.h decorates its API with __declspec(dllimport) under
          # _WIN32 unless LIBDE265_STATIC_BUILD is defined, but libde265.pc
          # doesn't carry it in Cflags, so libheif.a references __imp_de265_*
          # thunks the static libde265.a can't satisfy. Define it for libheif's
          # own compile (same as nix-lib's decode-only overlay).
          #
          NIX_CFLAGS_COMPILE = (old.NIX_CFLAGS_COMPILE or "")
            + lib.optionalString host.isMinGW " -DLIBDE265_STATIC_BUILD";
          postPatch = (old.postPatch or "") + ''
            # examples/CMakeLists.txt builds heif-test unconditionally (no
            # install, no option gate). We ship only enc/dec/info — exclude it
            # from `all` so it is neither built nor able to break the build.
            substituteInPlace examples/CMakeLists.txt \
              --replace-fail 'add_executable(heif-test ''${getopt_sources}' \
                             'add_executable(heif-test EXCLUDE_FROM_ALL ''${getopt_sources}'
          '';
          cmakeFlags = [
            "-DBUILD_SHARED_LIBS=OFF"
            "-DENABLE_PLUGIN_LOADING=OFF"   # static: codecs link in, no dlopen .so
            # decoders
            "-DWITH_LIBDE265=ON"            # HEVC (HEIC)
            "-DWITH_DAV1D=ON"              # AV1 (AVIF) — fast decode
            "-DWITH_AOM_DECODER=ON"
            # encoders (the whole point of heif-enc; overlay had these OFF)
            "-DWITH_X265=ON"               # HEVC (HEIC)
            "-DWITH_AOM_ENCODER=ON"        # AV1 (AVIF)
            # codecs we don't ship a dep for / don't want pulled in
            "-DWITH_X264=OFF"              # AVC-in-HEIF (niche; no x264 pkg)
            "-DWITH_OpenH264_DECODER=OFF"
            "-DWITH_RAV1E=OFF"
            "-DWITH_SvtEnc=OFF"
            # programs: enc/dec/info/thumbnailer
            "-DWITH_EXAMPLES=ON"
            "-DWITH_EXAMPLE_HEIF_VIEW=OFF"   # heif-view (needs SDL2)
            "-DWITH_GDK_PIXBUF=OFF"
            "-DBUILD_TESTING=OFF"
            "-DBUILD_DOCUMENTATION=OFF"
            # libtiff can bring libwebp along; nixpkgs' libheif has no WebP input.
            "-DCMAKE_DISABLE_FIND_PACKAGE_WEBP=ON"
          ] ++ lib.optionals host.isMinGW [
            # CMake looks in <prefix>/lib/cmake/<name> only for Unix targets, so
            # on Windows FindTIFF missed libtiff's config and took a bare
            # libtiff.a without the codecs it links. Name the configs.
            "-DTiff_DIR=${lib.getDev p.libtiff}/lib/cmake/tiff"
            "-Dlibdeflate_DIR=${lib.getDev p.libdeflate}/lib/cmake/libdeflate"
            "-Dzstd_DIR=${lib.getDev p.zstd}/lib/cmake/zstd"
          ];
          # libheif's own suite is `BUILD_TESTING` (catch2 + ~25 test binaries):
          # it roughly triples the build of a package whose useful part is three
          # CLI tools, and its encoder tests SKIP when an encoder is missing. The
          # installCheck below is the cheap half that matters here — it runs a
          # real encode.
          doCheck = false;
          # A codec that fails to REGISTER and a codec that registers and cannot
          # encode both leave `heif-enc --version` printing the same line. The
          # second one shipped: full LTO on i686 broke x265's parameter parsing
          # and HEIC encoding was dead for seven weeks with CI green. So encode
          # for real, in the build, on every target the builder can execute.
          # Both round-trips are lossless from the same source, so the two
          # decoded PNGs must come out byte-identical; that one `cmp` covers
          # x265 -> libde265 and aom -> dav1d at once.
          doInstallCheck = scope.stdenv.buildPlatform.canExecute host;
          inherit probePngB64;
          installCheckPhase = ''
            runHook preInstallCheck
            _b="''${bin:-$out}/bin"
            "$_b/heif-enc" --list-encoders > enc.txt
            "$_b/heif-dec" --list-decoders > dec.txt
            for want in "^- x265 = " "^- aom = "; do
              grep -q "$want" enc.txt || { echo "missing encoder: $want"; cat enc.txt; exit 1; }
            done
            for want in "^- libde265 = " "^- dav1d = " "^- aom = "; do
              grep -q "$want" dec.txt || { echo "missing decoder: $want"; cat dec.txt; exit 1; }
            done
            printf %s "$probePngB64" | base64 -d > probe.png
            "$_b/heif-enc" -L -o probe.heic probe.png
            "$_b/heif-enc" -A -L -o probe.avif probe.png
            "$_b/heif-dec" probe.heic from-heic.png
            "$_b/heif-dec" probe.avif from-avif.png
            cmp from-heic.png from-avif.png
            echo "installCheck: HEIC and AVIF lossless round-trips agree"
            runHook postInstallCheck
          '';
          # The library-install plumbing (pkg-config/cmake export, thumbnailer
          # wrapper) is irrelevant — only the three tools and their man ship.
          postInstall = "";
        });

    in
    ulib.mkStandaloneFlake {
      inherit self;
      name = "heif";
      # Embed heif-enc/heif-dec/heif-info man on every platform: libheif's own
      # cmake install stages the three pages, so the windows .exe harvests its
      # OWN man — same set as native, no graft.
      # Multicall: the applet is chosen by argv[0] (the names `unpin install`
      # puts on PATH) or by `--unpin-program=`; the bare binary lists them.
      #
      # Smoke on `--list-encoders`, not `--version`: this package exists to turn
      # the encoders back on over a shared overlay that builds libheif
      # decode-only, and `heif-enc --version` prints the same `libheif: 1.21.2`
      # with no encoder registered at all. The pattern is a single grep -E line
      # (that is all action-build applies), so it can name ONE of them; x265 is
      # the one the overlay drops.
      smoke = [ "--unpin-program=heif-enc" "--list-encoders" ];
      smokePattern = "^- x265 = x265 HEVC encoder";

      # Engine + bitcode self-fold: libheif (apps on) → bitcode,
      # heif-enc/heif-dec/heif-info self-fold into one `heif`. The C++ comes from
      # libheif AND the SYSTEM codec libs libde265/x265/libaom (rebuilt with the
      # engine → libc++); requires.cxx. Only windows keeps the objcopy fold.
      engine = "unpin-llvm";
      multicall = {
        windows = true;
        programs = [
          { name = "heif-enc"; }
          {
            name = "heif-dec";
            # upstream's old name for heif-dec, still installed beside it
            aliases = [ { name = "heif-convert"; noMan = true; } ];
          }
          { name = "heif-info"; }
          { name = "heif-thumbnailer"; }
        ];
        requires.cxx = true;
      };

      # The self-fold settles what the old hand-rolled darwin link kept
      # failing at. libheif is heavy C++ and throws; a plain scan of libc++.a
      # left `__cxa_throw` & co. UNDEFINED, so they bound at runtime to the
      # SYSTEM /usr/lib/libc++abi.dylib, whose macOS-15 exception path uses a
      # "typed memory operations" operator new whose static initializer lives in
      # the system libc++.dylib the allowlist forbids — first throw aborted with
      # "typed operator new invoked before its static initializer". requires.cxx
      # folds the engine's own libc++ statically into the binary, so the
      # exception runtime is DEFINED locally and never reaches the system dylib.
      build = pkgs: mkHeifTools { eng = engStdenvs pkgs; } pkgs.pkgsStatic;

      windowsBuild = pkgs: mkHeifTools { } (ulib.mingwStaticCross pkgs);
    };
}
