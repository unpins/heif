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
  # aom for AV1/AVIF) so heif-enc can actually write, then post-link the three
  # tools into a single `heif` binary (multicall.nix). The codec chain
  # (libde265/x265/aom/dav1d + png/jpeg) is the SAME one chafa/avif proved across
  # all nine targets, so the deps are cache hits.
  outputs = { self, unpins-lib }:
    let
      ulib = unpins-lib.lib;

      # Engine path (native Linux): two unpin-llvm adapter stdenvs, exactly as
      # avif. libheif throws and is heavy C++; its external C++ codec libs
      # (libde265/x265/libaom — all gcc/libstdc++ by default) are the tier-2
      # wall, so rebuild THEM with the engine → libc++, matching libheif. lto
      # stdenv for libheif (its app objects must be bitcode for the self-fold);
      # no-lto ELF stdenv for the codec libs (their asm SIMD — x265/aom nasm,
      # libde265 intrinsics — can't be bitcode, so stays plain ELF archives).
      # dav1d + png/jpeg are C → stay gcc (C ABI links into a libc++ binary).
      engStdenvs = pkgs:
        let sp = pkgs.pkgsStatic;
            mkEng = lto: ulib.unpinAdapterStdenv {
              inherit pkgs;
              target = sp.stdenv.hostPlatform.config;
              native = pkgs.stdenv.buildPlatform.system == pkgs.stdenv.hostPlatform.system;
              cxx = true;
              inherit lto;
              captureLinks = lto;
            };
        in { lto = mkEng true; elf = mkEng false; };

      # libheif with apps + encoders ON, wired onto a (static) pkgs scope.
      # Codec-chain fixes mirror avif/chafa: x265 (pkgsStatic emits split
      # 8/10/12-bit archives + rm's the .a in postInstall — nativeFixes.x265
      # merges + preserves them, and rewrites x265.pc for static/mingw consumers)
      # everywhere; dav1d on darwin (meson cpu_family='arm64' literal);
      # libjpeg-turbo on riscv (RVV SIMD helper miscompiles, pulled via heifio's
      # JPEG reader). Each is identity off its gate, so other targets keep the
      # cache-hit lib. aom/libde265 need no lib-level fix — chafa already
      # cross-built them on every target.
      mkHeifTools = eng: scope:
        let
          lib = scope.lib;
          host = scope.stdenv.hostPlatform;
          # Engine pre-extend: swap the stdenv of the C++ codec libs (no-lto ELF)
          # and libheif (lto) BEFORE the nativeFix/vmaf extend below, so the
          # x265 fix + libaom enableVmaf override compose ON TOP of the engine
          # stdenv (.override/.overrideAttrs chain through). No-op off-engine.
          scope' =
            if eng == null then scope
            else scope.extend (final: prev: {
              x265 = prev.x265.override { stdenv = eng.elf; };
              libde265 = prev.libde265.override { stdenv = eng.elf; };
              libaom = prev.libaom.override { stdenv = eng.elf; };
              libheif = prev.libheif.override { stdenv = eng.lto; };
            });
          p = scope'.extend (final: prev:
            {
              x265 =
                let fixed = ulib.nativeFixes.x265 prev;
                in if eng == null then fixed
                else fixed.overrideAttrs (o: {
                  # Engine: x265's 8/10/12-bit multilib merge is broken under the
                  # engine on TWO fronts. (1) Every `ar -M` MRI ADDLIB merge —
                  # CMake's own EXTRA_LIB combine AND the nativeFix's — DEDUPS
                  # members by name (verified for both llvm-ar and GNU ar), and
                  # all three bit-depths share object names (api.cpp.o, …), so
                  # only the 8-bit copy survives → x265_10bit/x265_12bit::
                  # x265_api_query stay UNDEFINED and heif-enc fails to link.
                  # (2) Even a correct postBuild merge gets discarded: `ninja
                  # install` re-runs CMake's combine, regenerating the deduped
                  # 8-bit libx265.a. So merge in postINSTALL, on the INSTALLED
                  # $out/lib/libx265.a, after nothing else can overwrite it.
                  # Reliable merge = EXTRACT each bit-depth under unique names
                  # then re-archive. The 10/12-bit archives are build-dir symlinks
                  # with RELATIVE targets, so resolve them with `readlink -f`
                  # while still in the build dir (postInstall cwd) BEFORE cd-ing
                  # into the extract subdirs.
                  postInstall = ''
                    if [ -e libx265-10.a ] && [ -e libx265-12.a ] && [ -e "$out/lib/libx265.a" ]; then
                      echo "engine: rebuilding x265 multilib from pure per-bit-depth objects"
                      _l10=$(readlink -f libx265-10.a)
                      _l12=$(readlink -f libx265-12.a)
                      rm -rf _x265m && mkdir -p _x265m/b _x265m/c
                      ( cd _x265m/b && $AR x "$_l10" && for f in *.o; do mv "$f" "u10_$f"; done )
                      ( cd _x265m/c && $AR x "$_l12" && for f in *.o; do mv "$f" "u12_$f"; done )
                      # Pure 8-bit objects come from THIS build dir's CMake target
                      # object files (build-10bits/build-12bits are siblings, not
                      # under cwd). The installed libx265.a can't be the 8-bit
                      # source: it's the llvm-ar-DEDUPED EXTRA_LIB combine, which
                      # dropped the 8-bit public api.cpp.o (plain x265_api_get /
                      # x265_cleanup) for a namespaced copy. Exclude CMake's
                      # compiler-probe temp objects.
                      mapfile -t _o8 < <(find . -path '*CMakeFiles*' -name '*.o' \
                        -not -path '*/CMakeTmp/*' -not -path '*/CMakeScratch/*' \
                        -not -path '*CompilerId*' -not -path './_x265m/*')
                      echo "engine: 8-bit objs=''${#_o8[@]} 10-bit=$(ls _x265m/b | wc -l) 12-bit=$(ls _x265m/c | wc -l)"
                      rm -f "$out/lib/libx265.a"
                      $AR qcs "$out/lib/libx265.a" "''${_o8[@]}" _x265m/b/*.o _x265m/c/*.o
                      rm -rf _x265m
                    fi
                  '';
                });
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
          ({ pkgs = scope; libheifTools = mkHeifTools null scope; } // extra);
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
      smoke = [ "--unpin-program=heif-enc" "--version" ];
      smokePattern = "libheif";

      # Engine + bitcode self-fold (native Linux): libheif (apps on) → bitcode,
      # heif-enc/heif-dec/heif-info self-fold into one `heif`. The C++ comes from
      # libheif AND the SYSTEM codec libs libde265/x265/libaom (rebuilt with the
      # engine → libc++); requires.cxx. darwin/windows keep the objcopy fold.
      engine = "unpin-llvm";
      multicall = {
        programs = [
          { name = "heif-enc"; }
          { name = "heif-dec"; }
          { name = "heif-info"; }
        ];
        requires.cxx = true;
      };

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
        if pkgs.stdenv.hostPlatform.isLinux
        then mkHeifTools (engStdenvs pkgs) pkgs.pkgsStatic   # engine path → selfFold
        else
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
