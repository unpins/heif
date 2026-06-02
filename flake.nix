{
  description = "Standalone build of the libheif image tools (heif-enc / heif-dec / heif-info)";

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
  # aom for AV1/AVIF) so heif-enc can actually write, then post-link the three
  # tools into a single `heif` binary (multicall.nix). The codec chain
  # (libde265/x265/aom/dav1d + png/jpeg) is the SAME one chafa/avif proved across
  # all nine targets, so the deps are cache hits.
  outputs = { self, unpins-lib }:
    let
      ulib = unpins-lib.lib;

      # libheif with apps + encoders ON, wired onto a (static) pkgs scope.
      # Codec-chain fixes mirror avif/chafa: x265 (pkgsStatic emits split
      # 8/10/12-bit archives + rm's the .a in postInstall — nativeFixes.x265
      # merges + preserves them, and rewrites x265.pc for static/mingw consumers)
      # everywhere; dav1d on darwin (meson cpu_family='arm64' literal);
      # libjpeg-turbo on riscv (RVV SIMD helper miscompiles, pulled via heifio's
      # JPEG reader). Each is identity off its gate, so other targets keep the
      # cache-hit lib. aom/libde265 need no lib-level fix — chafa already
      # cross-built them on every target.
      mkHeifTools = scope:
        let
          lib = scope.lib;
          host = scope.stdenv.hostPlatform;
          p = scope.extend (final: prev:
            {
              x265 = ulib.nativeFixes.x265 prev;
              # aom's vmaf-tuning code (vmaf.c.o) references libvmaf, but
              # libheif's FindAOM (unlike libavif's) does not reflect aom.pc's
              # `Requires: libvmaf` onto the link, so the encoder's pull of
              # vmaf.c.o leaves vmaf_* undefined. heif-enc never exposes
              # `--tune=vmaf`, so drop aom's vmaf support outright — zero loss,
              # and it removes libvmaf from the closure on every target.
              libaom = prev.libaom.override { enableVmaf = false; };
            } // lib.optionalAttrs host.isRiscV {
              libjpeg = ulib.nativeFixes."libjpeg-turbo" prev;
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
          buildInputs = dropUnused (old.buildInputs or [ ]);
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
            # tools: enc/dec/info only
            "-DWITH_EXAMPLES=ON"
            "-DWITH_EXAMPLE_HEIF_THUMB=OFF"  # heif-thumbnailer (not shipped)
            "-DWITH_EXAMPLE_HEIF_VIEW=OFF"   # heif-view (needs SDL2)
            "-DWITH_GDK_PIXBUF=OFF"
            "-DBUILD_TESTING=OFF"
            "-DBUILD_DOCUMENTATION=OFF"
          ];
          doCheck = false;
          # The library-install plumbing (pkg-config/cmake export, thumbnailer
          # wrapper) is irrelevant — multicall.nix only consumes the build-tree
          # objects + heif-enc's link.txt.
          postInstall = "";
        });

      mk = pkgs: scope: extra:
        import ./multicall.nix { lib = pkgs.lib // ulib; }
          ({ pkgs = scope; libheifTools = mkHeifTools scope; } // extra);
    in
    ulib.mkStandaloneFlake {
      inherit self;
      name = "heif";
      # Embed heif-enc/heif-dec/heif-info man on every platform. multicall.nix
      # installs the three static source pages into $out/share/man on every
      # target, so the windows .exe harvests its OWN man — same set as native,
      # no graft.
      # Multicall: `heif <applet> [args]` dispatches by argv[0]; the bare binary
      # takes the applet as its first arg. Smoke through that form.
      smoke = [ "heif-enc" "--version" ];
      smokePattern = "libheif";

      # Linux pkgsStatic links libstdc++ statically already. darwin: the C++
      # codec libs (x265/aom/libheif) pull `-lc++` → /usr/lib/libc++.1.dylib,
      # which the unpins darwin allowlist rejects; fold libc++ in statically.
      #
      # -force_load on the WHOLE libc++.a (not a plain scan, and not the separate
      # libc++abi.a): this nixpkgs libc++ is built with the ABI library merged
      # in (LIBCXX_ENABLE_STATIC_ABI_LIBRARY), so libc++.a already defines the
      # full libc++abi surface — `__cxa_throw`, `__cxa_allocate_exception`, the
      # type_info hierarchy (201 symbols shared with libc++abi.a). libheif is
      # heavy C++ and throws; with a plain scan the exception entry points stay
      # UNDEFINED in our objects and bind at runtime to the SYSTEM
      # /usr/lib/libc++abi.dylib (re-exported via libSystem). That system build
      # (macOS 15) uses "typed memory operations" operator new internally in its
      # exception path, whose static initializer lives in the system
      # libc++.dylib we are forbidden to link — so the first throw aborts:
      # "typed operator new invoked before its static initializer". A strong
      # operator-new override can't fix it because the bad call is made INSIDE
      # the system dylib. force_load pulls every libc++.a object so `__cxa_*`
      # and the whole runtime are DEFINED in the binary; libheif's throws bind
      # to our copy (21.1.7, plain operator new, no TMO) and never touch the
      # system dylib. force_load'ing libc++abi.a too would re-define those 201
      # shared symbols ("418 duplicate symbols"), so we use libc++.a alone.
      # avif's C codecs never throw, so its plain fold was fine.
      build = pkgs:
        let sp = pkgs.pkgsStatic; in
        mk pkgs sp (pkgs.lib.optionalAttrs sp.stdenv.hostPlatform.isDarwin {
          # avif-exact recipe (proven on the shipped avif): plain scan of both
          # static archives, no force_load, no operator-new override. Testing
          # whether heif's TMO abort was caused by our deviations (force_load +
          # opnew.o) rather than anything intrinsic.
          extraLinkFlags = "-nostdlib++ ${sp.libcxx}/lib/libc++.a ${sp.libcxx}/lib/libc++abi.a";
        });

      # mingw cross: fold the C++/thread runtime into the .exe (no libstdc++-6 /
      # libgcc_s / libwinpthread DLLs) with a plain static C++ link, but driven by
      # lld (-fuse-ld=lld) instead of binutils ld. The combined multicall link
      # trips a binutils 2.44 PE bug that discards present archive COMDAT members
      # (cxx11 _M_dispose / _Sp_counted_base::_M_release_last_use_cold / ios_failure
      # typeinfos); lld's PE/COFF COMDAT handling links them cleanly, so no
      # pre-merge / --start-group / --allow-multiple-definition is needed. -static
      # folds libc/winpthread/libgcc; -static-libstdc++ the C++ runtime.
      windowsBuild = pkgs:
        mk pkgs (ulib.mingwStaticCross pkgs) {
          extraLinkFlags = "-static -static-libgcc -static-libstdc++ -fuse-ld=lld";
        };
    };
}
