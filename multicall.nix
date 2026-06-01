# libheif builds three CLI tools — heif-enc (encode), heif-dec (decode) and
# heif-info (inspect) — under WITH_EXAMPLES. To honour the unpins one-pkg-one-bin
# rule we post-link them into a single multicall binary at $out/bin/heif;
# `lib.withAliases` then embeds the tool names as an UNPIN_META block so unpin's
# installer can recreate the argv[0] shims.
#
# Link mechanics (same family as avif/jxl CMake-link.txt, vs libvpx/recursive-make,
# srt/CMake-query, rtmpdump/Makefile):
#
#   * libheif uses the CMake "Unix Makefiles" generator (no ninja in
#     nativeBuildInputs), so every target gets a `CMakeFiles/<t>.dir/link.txt`
#     holding its exact link command — compiler, flags, objects, and the full
#     lib list (heif, heifio, x265, aom, libde265, dav1d, png, jpeg, …) resolved
#     for the platform. We reuse heif-enc's link.txt (the encoder — it pulls the
#     widest lib set: heifio + every encoder, a superset of what dec/info need)
#     and splice in the other two tools' main objects + the dispatcher,
#     retargeting the output. That sidesteps re-deriving the per-platform lib
#     list by hand (the e2fsprogs landmine).
#
#   * Unlike avif's single avif_apps.a, libheif compiles its shared helpers
#     (common.cc, plus benchmark.cc/SAI_datafile.cc for the encoder) into EACH
#     target's own object dir. We splice only the per-tool MAIN objects
#     (heif_{enc,dec,info}.cc.o); heif-enc's own common.cc.o (already in its
#     link.txt) resolves the common-helper references the dec/info mains make.
#     So the only strong clash is `main`, renamed per-tool below; the iterative
#     pass is insurance against any future strong clash.
#
#   * Tool name != source object name and contains a hyphen (heif-enc ←
#     heif_enc.cc), which is not a valid C identifier. TOOLS carries three
#     fields: `tool` (applet name / symlink / dispatcher string), `src` (main
#     source basename) and `fn` (a C-safe entry-point stem, e.g. heif_enc →
#     heif_enc_main).
#
#   * The tools are C++ (heif/x265/aom); on darwin clang++ would resolve -lc++
#     to /usr/lib/libc++.1.dylib (forbidden by the single-binary policy);
#     `extraLinkFlags` folds the static libc++ in. On mingw `-static
#     -static-libgcc -static-libstdc++` keeps the runtime out of companion DLLs.
{ lib }:
{ pkgs, libheifTools, name ? "heif", extraLinkFlags ? "" }:
let
  # mingw: the combined multicall link is driven through lld (-fuse-ld=lld, set
  # in windowsBuild) instead of GNU ld. The per-tool .exe links CMake emits link
  # fine with binutils ld, but the COMBINED link (heif-enc objects + the dec/info
  # mains) trips a binutils 2.44 PE bug: it discards the archive COMDAT members
  # that define cxx11 basic_string::_M_dispose / _Sp_counted_base::
  # _M_release_last_use_cold / ios_failure typeinfos, leaving them "undefined"
  # though present. lld's PE/COFF COMDAT selection doesn't have that bug, so a
  # plain static C++ link just works — no --start-group, no archive pre-merge,
  # no --allow-multiple-definition. linux/darwin use their native linker.
  isMinGW = pkgs.stdenv.hostPlatform.isMinGW or false;
  grpStart = "";
  grpEnd = "";
  isDarwin = pkgs.stdenv.hostPlatform.isDarwin or false;

  # applet -> { main source basename, C-safe entry-point stem }
  TOOLS = [
    { tool = "heif-enc"; src = "heif_enc.cc"; fn = "heif_enc"; }
    { tool = "heif-dec"; src = "heif_dec.cc"; fn = "heif_dec"; }
    { tool = "heif-info"; src = "heif_info.cc"; fn = "heif_info"; }
  ];
  toolsBash = lib.concatMapStringsSep " " (t: "${t.tool}:${t.src}:${t.fn}") TOOLS;

  multicall = libheifTools.overrideAttrs (old: {
    pname = "heif-multi";

    # mingw: lld (build-platform) for the combined link's -fuse-ld=lld. The cross
    # gcc driver invokes `ld.lld` from PATH; only the combined multicall link uses
    # it (CMake's per-tool links keep binutils ld).
    nativeBuildInputs = (old.nativeBuildInputs or [ ])
      ++ lib.optional isMinGW pkgs.buildPackages.lld;

    # Ship only the multicall binary.
    outputs = [ "out" ];
    separateDebugInfo = false;
    postInstall = "";
    # libheif's nixpkgs postFixup rewrites $dev/lib/cmake/libheif-config.cmake;
    # with only the `out` output that path is gone (sed: No such file). The
    # cmake/pkg-config export is meaningless for a single-binary package — drop
    # it. (The Windows .exe rename is appended on the aliased derivation below.)
    postFixup = "";

    postBuild = (old.postBuild or "") + ''
      mkdir -p multicall
      printf '%s\n' ${lib.escapeShellArg toolsBash} | tr ' ' '\n' > multicall/tools.map

      # CMake names compiled objects `.o` on ELF/Mach-O but `.obj` when
      # targeting Windows (mingw). Detect from heif-enc's main object.
      oext=o
      [ -n "$(find . -path '*heif-enc.dir/heif_enc.cc.obj' -print -quit)" ] && oext=obj

      # Resolve each tool's main object; existence gates a platform that ever
      # drops a tool. Record the applet list + fn map for later phases.
      : > multicall/apps.list
      : > multicall/fn.map
      declare -A OBJ FN
      while IFS=: read -r tool src fn; do
        [ -n "$tool" ] || continue
        obj="$(find . -path "*$tool.dir/$src.$oext" | head -1)"
        [ -n "$obj" ] || { echo "multicall: object for $tool ($src.$oext) not found" >&2; exit 1; }
        OBJ[$tool]="$obj"; FN[$tool]="$fn"
        echo "$tool" >> multicall/apps.list
        echo "$tool:$fn" >> multicall/fn.map
      done < multicall/tools.map
      [ -s multicall/apps.list ] || { echo "multicall: no tool objects found" >&2; exit 1; }

      linktxt="$(find . -path '*heif-enc.dir/link.txt' | head -1)"
      [ -n "$linktxt" ] || { echo "multicall: heif-enc link.txt not found (non-Makefile generator?)" >&2; exit 1; }

      # Symbol prefix (Mach-O leads C symbols with '_'), read once from heif-enc.
      if $NM --defined-only "''${OBJ[heif-enc]}" | awk '$3=="_main"{f=1} END{exit !f}'; then
        up=_
      else
        up=""
      fi

      # Each tool's main .cc defines its OWN file-scope strong globals under
      # shared names (main, output_filename, show_help, option_disable_limits,
      # …), so linking the three mains together would be a wall of "multiple
      # definition" clashes — not just `main`. Per-tool symbol renaming is
      # fragile (the linker reports demangled C++ names like
      # `output_filename[abi:cxx11]` while nm/objcopy speak mangled), so instead:
      # rename each main → <fn>_main, then localize ONLY the program globals that
      # are defined in MORE THAN ONE tool object (the genuine duplicates). Each
      # tool keeps a private copy of those; everything else — including a tool's
      # unique strong globals and the COMDAT typeinfo/vtable symbols the C++
      # runtime's iostream/exception objects bind to — stays global so normal
      # resolution is untouched. (An earlier version localized ALL strong
      # globals, which over-reached and broke the mingw static C++ link.)
      #
      # Collected globals exclude: the entry point; weak/COMDAT symbols (nm type
      # W/V, which merge rather than clash); and compiler-emitted COMDAT helpers
      # like i686's `__x86.get_pc_thunk.bx` — recognizable by the '.' in their
      # name, which no C/C++ program (nor mangled `_Z…`) symbol ever contains
      # (localizing one breaks its group's cross-object dedup).
      : > multicall/all.syms
      while IFS= read -r tool; do
        obj="''${OBJ[$tool]}"; entry="''${up}''${FN[$tool]}_main"
        $OBJCOPY --redefine-sym "''${up}main=$entry" "$obj"
        $NM --defined-only "$obj" \
          | awk -v keep="$entry" '$2 ~ /^[A-Z]$/ && $2 != "W" && $2 != "V" && $3 != keep && index($3,".")==0 {print $3}' \
          | sort -u >> multicall/all.syms
      done < multicall/apps.list
      # Symbols appearing for ≥2 tools are the real clashes; localize just those.
      sort multicall/all.syms | uniq -d > multicall/clash.syms
      if [ -s multicall/clash.syms ]; then
        while IFS= read -r tool; do
          $OBJCOPY --localize-symbols=multicall/clash.syms "''${OBJ[$tool]}"
        done < multicall/apps.list
      fi

      # Dispatcher: basename(argv[0]) → <fn>_main, '.exe' stripped, plus a
      # `${name} <applet> [args]` form so the bare binary stays callable.
      # Dispatcher (shared canonical generator — see nix-lib
      # lib.multicallDispatcherC). It derives each applet's C symbol from the
      # applet name in multicall/apps.list via `tr -c 'A-Za-z0-9_' '_'`, which
      # equals the `fn` this recipe renamed each main to (heif-enc → heif_enc),
      # so no separate fn.map is needed at the dispatcher.
${lib.multicallDispatcherC { inherit name; }}
      $CC -O2 -c -o multicall/dispatcher.o multicall/dispatcher.c

      # darwin: stop dyld from REPLACING our statically-linked libc++ with the
      # system one. We fold libc++.a/libc++abi.a (21.1.7) in statically, but libc++
      # emits its symbols — operator new/delete (in __TEXT,__lcxx_override), every
      # explicitly-instantiated iostream/locale/string method, the type_info and
      # vtables — as *weak external*. At load time dyld coalesces those weak defs
      # with the STRONG copies the macOS 15 system libc++.1.dylib / libc++abi.dylib
      # re-export (via libSystem), so the SYSTEM code runs instead of ours. The
      # system build uses "typed memory operations" (TMO); e.g. opening the input
      # file goes std::ifstream -> system basic_filebuf::setbuf -> system typed
      # operator new, whose TMO startup initializer never ran in our binary ->
      # abort "typed operator new invoked before its static initializer". Proven
      # via crash backtrace: the abort frames are system libc++.1.dylib /
      # libc++abi.dylib, reached from our basic_ifstream ctor by weak coalescing
      # (426 std::__1 weak-external symbols in the binary). Bites only on macOS
      # with TMO (15+); a 14 builder/CI would PASS but ship a binary that crashes
      # for 15 users — so the fix must hold on every macOS, not dodge it.
      #
      # Fix: make the WHOLE libc++/libc++abi symbol surface NON-exported in the
      # final link (-unexported_symbols_list). A non-exported (private-extern)
      # symbol is not a coalesced global, so dyld keeps OUR static definitions —
      # no system libc++, no TMO — regardless of host macOS. An executable needs
      # to export nothing, so hiding these is safe. Patterns cover the Itanium
      # mangling of std:: (_ZNSt/_ZNKSt/_ZSt), __cxxabiv1, the new/delete operators
      # (_Znw/_Zna/_Zdl/_Zda) and their vtables/type_info (_ZTV/_ZTI/_ZTS …).
      darwin_link_extra=""
      ${lib.optionalString isDarwin ''
        cat > multicall/unexport.syms <<'EOF'
        __Znw*
        __Zna*
        __Zdl*
        __Zda*
        __ZNSt*
        __ZNKSt*
        __ZNVSt*
        __ZSt*
        __ZTVSt*
        __ZTVNSt*
        __ZTISt*
        __ZTINSt*
        __ZTSSt*
        __ZTSNSt*
        __ZN10__cxxabiv1*
        __ZNK10__cxxabiv1*
        __ZTVN10__cxxabiv1*
        __ZTIN10__cxxabiv1*
        __ZTSN10__cxxabiv1*
        EOF
        # the nix indented string dedents to col 0, but strip any residual
        # leading space so ld64 does not treat it as part of the symbol name.
        sed -i 's/^[[:space:]]*//' multicall/unexport.syms
        darwin_link_extra="-Wl,-unexported_symbols_list,$PWD/multicall/unexport.syms"
      ''}

      # mingw drives this link through lld (-fuse-ld=lld) which links the static
      # C++ archives directly — no pre-merged runtime object is needed (the GNU-ld
      # PE-COMDAT workaround that used to live here is gone).
      stdcxx_obj=""

      # Reuse heif-enc's link command: splice the other tools' main objects +
      # the dispatcher in front of the output, retarget to multicall/${name}, and
      # append the runtime-folding flags. heif-enc's object is already in the
      # command (renamed in place); the rest resolve <fn>_main + main.
      #
      # libheif builds its tools under `examples/`, so heif-enc's link.txt holds
      # paths relative to that subdir (CMakeFiles/heif-enc.dir/…, ../libheif/…).
      # Run the link from that dir so they resolve; the objects/dispatcher/output
      # we splice in are made absolute so they survive the cd.
      top="$PWD"
      linkdir="''${linktxt%/CMakeFiles/*}"
      out_bin="$top/multicall/${name}"
      disp="$top/multicall/dispatcher.o"
      extra_objs=""
      while IFS= read -r tool; do
        [ "$tool" = heif-enc ] && continue
        extra_objs="$extra_objs $top/''${OBJ[$tool]#./}"
      done < multicall/apps.list
      # Reuse heif-enc's link command, splicing the extra tool mains + the
      # dispatcher before the output and retargeting it. On mingw --start-group
      # opens right after `-o <out>` so it wraps the whole library list that
      # follows (CMake's @linkLibs.rsp) plus the appended runtime libs; --end-
      # group closes at the very end. darwin folds libc++ via extraLinkFlags;
      # linux needs neither.
      linkbase="$(sed -E "s| -o (\"?)heif-enc(\.exe)?(\"?)|$extra_objs $disp $stdcxx_obj -o $out_bin${grpStart}|" "$linktxt") ${extraLinkFlags} $darwin_link_extra${grpEnd}"

      # Single link: the localize pass above made every tool object export only
      # its <fn>_main, so there are no strong duplicates left to resolve.
      ( cd "$linkdir" && eval "$linkbase" )

      # mingw gcc may auto-append .exe; normalize to the suffixless name
      # installPhase + withAliases expect (Windows postFixup re-adds .exe).
      [ -f multicall/${name} ] || mv multicall/${name}.exe multicall/${name}
    '';

    installPhase = ''
      runHook preInstall
      mkdir -p "$out/bin"
      install -m755 multicall/${name} "$out/bin/${name}"
      while IFS= read -r a; do
        [ -n "$a" ] && ln -s ${name} "$out/bin/$a"
      done < multicall/apps.list

      # The custom installPhase replaces CMake's `make install`, which would have
      # installed examples/heif-{enc,dec,info}.1. Re-install those three static
      # source pages (drop heif-thumbnailer.1 — that tool isn't built) so withMan
      # embeds them. They're identical across platforms, so each target harvests
      # its own unpacked source — no cross-arch reference.
      mkdir -p "$out/share/man/man1"
      for m in heif-enc heif-dec heif-info; do
        f="$(find "$NIX_BUILD_TOP" -path "*/examples/$m.1" -print -quit)"
        [ -n "$f" ] || { echo "multicall: man page $m.1 not found in source" >&2; exit 1; }
        install -m644 "$f" "$out/share/man/man1/$m.1"
      done
      runHook postInstall
    '';
  });
  aliased = lib.withAliases pkgs
    {
      primary = name;
      aliasesFromSymlinksIn = "bin";
    }
    multicall;
in
if pkgs.stdenv.hostPlatform.isWindows
then aliased.overrideAttrs (o: {
  postFixup = (o.postFixup or "") + ''
    [ -f "$out/bin/${name}" ] && mv "$out/bin/${name}" "$out/bin/${name}.exe"
  '';
})
else aliased
