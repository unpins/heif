{
  description = "the libheif image tools (heif-enc / heif-dec / heif-info) as a single self-contained binary";

  nixConfig = {
    extra-substituters = [ "https://unpins.cachix.org" ];
    extra-trusted-public-keys = [ "unpins.cachix.org-1:DDaShjbZ8VvcqxeTcAU3kV9vxZQBlyb7V/uLBHfTynI=" ];
  };

  inputs.unpins-lib.url = "github:unpins/nix-lib";

  # libheif's programs (heif-enc, heif-dec, heif-info, heif-thumbnailer) are
  # built from nixpkgs' libheif with its encoders on (x265 for HEIC, aom for
  # AVIF), and folded into one `heif` binary.
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

      # x265 is the one dep that cannot take full LTO on 32-bit x86. Under
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
      # other targets byte for byte. Everything else takes the engine's
      # set-wide stdenv.
      x265Stdenv = pkgs:
        let sp = pkgs.pkgsStatic; in
        if !sp.stdenv.hostPlatform.isi686 then null
        else ulib.unpinAdapterStdenv {
          inherit pkgs;
          lto = false;
          target = sp.stdenv.hostPlatform.config;
          native = pkgs.stdenv.buildPlatform.system == pkgs.stdenv.hostPlatform.system;
          cxx = true;
          captureLinks = true;
        };

      # libheif with the programs and encoders on, over a static pkgs scope.
      # x265 everywhere and dav1d on darwin take nix-lib's fixes.
      mkHeifTools = { x265Stdenv ? null }: scope:
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
          scope' =
            if x265Stdenv == null then scope
            else scope.extend (final: prev: {
              x265 = prev.x265.override { stdenv = x265Stdenv; };
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
          # Inputs heif does not use: rav1e (off upstream by default; AV1 encode is
          # aom's) and gdk-pixbuf (the loader module, turned off below), and on
          # mingw make-shell-wrapper-hook, which splices to a bash that cannot
          # cross-compile.
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
          patches = (old.patches or [ ]) ++ [ ./heif-test-exclude-from-all.patch ];
          cmakeFlags = [
            "-DBUILD_SHARED_LIBS=OFF"
            "-DENABLE_PLUGIN_LOADING=OFF"   # static: codecs link in, no dlopen .so
            # decoders
            "-DWITH_LIBDE265=ON"            # HEVC (HEIC)
            "-DWITH_DAV1D=ON"              # AV1 (AVIF) — fast decode
            "-DWITH_AOM_DECODER=ON"
            # encoders
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
          # it roughly triples the build of a package whose useful part is four
          # programs, and its encoder tests SKIP when an encoder is missing. The
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
          # wrapper) is irrelevant: only the programs and their man pages ship.
          postInstall = "";
        });

    in
    ulib.mkStandaloneFlake {
      inherit self;
      name = "heif";
      # libheif's own cmake install stages the programs' man pages on every
      # platform, Windows included, so each binary embeds its own.
      # Multicall: the applet is chosen by argv[0] (the names `unpin install`
      # puts on PATH) or by `--unpin-program=`; the bare binary lists them.
      #
      # Smoke on `--list-encoders`, not `--version`: this package exists to turn
      # the encoders on, and `heif-enc --version` prints the same line with no
      # encoder registered at all. The pattern is a single grep -E line
      # (that is all action-build applies), so it can name ONE of them: x265,
      # the one with a history of breaking.
      smoke = [ "--unpin-program=heif-enc" "--list-encoders" ];
      smokePattern = "^- x265 = x265 HEVC encoder";

      # The engine builds libheif and its C++ codec libs (libde265, x265, libaom)
      # against its own libc++, Windows included, hence requires.cxx.
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
      build = pkgs: mkHeifTools { x265Stdenv = x265Stdenv pkgs; } pkgs.pkgsStatic;

      windowsBuild = pkgs: mkHeifTools { } (ulib.mingwStaticCross pkgs);
    };
}
