# Firmware image builder: embeds the Rust server into the GTVHacker kernel's
# initramfs and rebuilds the uImage the DFU attack flashes.
#
# This only evaluates/built on Linux (see flake.nix). It reads the vendored
# GTVHacker tree (kernel, base initramfs, 2008 ARM toolchain) from
# NEST_ATTACK_DIR; with no env it evaluates to { } so a bare `nix build
# .#nest-ondevice` still works.
#
# The 2008 toolchain is 32-bit x86 (i686) Linux, which no longer runs on
# modern macs (Apple container/Rosetta is x86_64-only). It is therefore run
# under qemu-i386; the i386 glibc it links against comes from pkgsCross.gnu32.
# gcc's own subprocesses (cc1/as/ld/collect2) are reached through native
# wrapper scripts via COMPILER_PATH, so no binfmt_misc is needed.
#
# The image is *reproducible*: the same source builds to the same uImage bytes
# on any host. See firmware/README.md ("Reproducible images") and the knobs
# below, all read impurely like NEST_ATTACK_DIR.
{ pkgs, lib, nest-ondevice }:
let
  dir = builtins.getEnv "NEST_ATTACK_DIR";
  linuxEnv = builtins.getEnv "NEST_LINUX_DIR";

  envOr = name: def: let v = builtins.getEnv name; in if v == "" then def else v;

  # Build identity baked into vmlinux. Fixed so the clock and the machine never
  # reach the image; override only to reproduce an older image byte for byte.
  buildStamp = envOr "NEST_BUILD_TIMESTAMP" "1970-01-01 00:00:00 UTC";
  buildUser = envOr "NEST_BUILD_USER" "nest";
  buildHost = envOr "NEST_BUILD_HOST" "ondevice";

  # `make -j` width. Empty = whatever nix allocated. bin/repro-check.sh varies
  # it to prove parallelism does not change the output.
  makeJobs = envOr "NEST_MAKE_JOBS" "";
  jobsFlag =
    if makeJobs == "" then
      "$NIX_BUILD_CORES"
    else if builtins.match "[0-9]+" makeJobs == null then
      throw "NEST_MAKE_JOBS must be a positive integer, got '${makeJobs}'"
    else
      makeJobs;

  # Which way to run the i686 2008 toolchain. `auto` = native on x86_64 Linux,
  # qemu-i386 elsewhere (aarch64-linux = the macOS container). Forcing one is
  # how the repro check proves both paths yield identical bytes.
  toolchainFlavour = envOr "NEST_TOOLCHAIN" "auto";
in
if dir == "" then
  { }
else
  let
    # A git checkout of the kernel on a case-insensitive filesystem collapses
    # the 13 case-distinct netfilter sources (xt_HL.c/xt_hl.c, ...) onto one
    # on-disk name, so make cannot find them. bin/nix-build.sh re-materialises
    # Dev/linux from git and points NEST_LINUX_DIR at it.
    linuxPath = if linuxEnv == "" then dir + "/Dev/linux" else linuxEnv;
    attack = {
      linux = builtins.path {
        path = linuxPath;
        name = "gtvhacker-linux-2.6.37";
      };
      initramfs = builtins.path {
        path = dir + "/Dev/initramfs_data.cpio";
        name = "initramfs_data.cpio";
      };
      toolchain = builtins.path {
        path = dir + "/Dev/toolchain/arm-2008q3";
        name = "arm-2008q3";
      };
    };

    qemu = pkgs.qemu;
    qemuBin = "${qemu}/bin/qemu-i386";

    # i386 userland the old toolchain links against (glibc, zlib, ncurses,
    # libstdc++/libgcc_s). Assembled into a single prefix for qemu -L.
    i386Pkgs = pkgs.pkgsCross.gnu32;
    i386Root = pkgs.runCommand "nest-i386-sysroot" { } ''
      mkdir -p $out/lib
      add() {
        for f in "$1"/lib/*; do
          [ -e "$f" ] || continue
          ln -sf "$f" "$out/lib/$(basename "$f")"
        done
      }
      add ${i386Pkgs.glibc}
      add ${i386Pkgs.zlib}
      add ${i386Pkgs.ncurses}
      add ${i386Pkgs.stdenv.cc.cc.lib}
    '';

    # The 2008 toolchain is i686. On an x86_64 Linux host the kernel runs
    # IA32 binaries natively (CONFIG_IA32_EMULATION=y on any modern distro),
    # so we only need to rewrite each i686 ELF's interpreter/RPATH to the
    # store's i386 loader + libs and run it directly. This is dramatically
    # faster than qemu-i386 user emulation and needs no wrappers: gcc finds
    # cc1/collect2/as/ld at their normal relative locations.
    nativeToolchain = pkgs.runCommand "nest-cross-toolchain-native" {
      nativeBuildInputs = [ pkgs.patchelf ];
    } ''
      mkdir -p $out
      cp -r ${attack.toolchain}/. $out/
      chmod -R u+w $out
      find $out -type f -print0 | while IFS= read -r -d "" f; do
        interp=$(patchelf --print-interpreter "$f" 2>/dev/null) || continue
        case "$interp" in
          */ld-linux.so.2)
            patchelf --set-interpreter ${i386Root}/lib/ld-linux.so.2 \
                     --set-rpath ${i386Root}/lib "$f"
            ;;
        esac
      done
    '';

    # Portable fallback (aarch64-linux / darwin hosts): copy the toolchain into
    # a writable tree and replace every host executable the driver/collect2 may
    # exec with a native wrapper that runs the real i686 binary under qemu-i386.
    # Wrapping in place means gcc finds cc1/collect2/as/ld at their normal
    # locations, so no COMPILER_PATH/-B black magic is needed (and the native
    # host compiler is left untouched).
    qemuToolchain = pkgs.runCommand "nest-cross-toolchain" { } ''
      mkdir -p $out
      cp -r ${attack.toolchain}/. $out/
      chmod -R u+w $out
      wrap() {
        real="$1"
        mv "$real" "$real.real"
        cat > "$real" <<EOF
#!${pkgs.runtimeShell}
export COMPILER_PATH="$out/libexec"
exec ${qemuBin} -L ${i386Root} "$real.real" "\$@"
EOF
        chmod +x "$real"
      }
      for t in gcc g++ cpp gcc-4.3.2 as ld ar nm strip objcopy objdump ranlib; do
        wrap "$out/bin/arm-none-linux-gnueabi-$t"
      done
      for t in cc1 cc1plus collect2; do
        wrap "$out/libexec/gcc/arm-none-linux-gnueabi/4.3.2/$t"
      done
      # bare names for gcc/collect2 subprogram lookups
      mkdir -p $out/libexec
      for t in as ld ar nm strip objcopy objdump ranlib cpp; do
        ln -sf "$out/bin/arm-none-linux-gnueabi-$t" "$out/libexec/$t"
      done
    '';

    crossToolchain =
      if toolchainFlavour == "native" then
        nativeToolchain
      else if toolchainFlavour == "qemu" then
        qemuToolchain
      else if toolchainFlavour == "auto" then
        if pkgs.stdenv.hostPlatform.isLinux && pkgs.stdenv.hostPlatform.isx86_64 then
          nativeToolchain
        else
          qemuToolchain
      else
        throw "NEST_TOOLCHAIN must be auto|native|qemu, got '${toolchainFlavour}'";

    # Base initramfs + the server binary + its init script.
    initramfs = pkgs.runCommand "nest-initramfs" {
      nativeBuildInputs = [ pkgs.python3 ];
    } ''
      mkdir -p $out
      python3 ${./inject_initramfs.py} \
        ${attack.initramfs} "$out/initramfs.cpio" \
        ${nest-ondevice}/bin/nest-ondevice \
        ${./nest-ondevice.init} \
        ${./nest-ondevice.monitrc}
    '';

    firmware = pkgs.stdenv.mkDerivation {
      pname = "nest-firmware";
      version = "1.0.0";
      dontUnpack = true;

      nativeBuildInputs = with pkgs; [
        gnumake
        bash
        perl
        bc
        cpio
        which
        gzip
        xz
        ubootTools
        file
        diffutils   # ./mkcompile_h compares with `cmp -s` before replacing
      ];

      buildPhase = ''
        runHook preBuild

        export PATH=${crossToolchain}/bin:$PATH
        export CROSS_COMPILE=${crossToolchain}/bin/arm-none-linux-gnueabi-
        export HOSTCC=${pkgs.stdenv.cc}/bin/cc HOSTCXX=${pkgs.stdenv.cc}/bin/cxx

        # --- reproducible build identity --------------------------------------
        # The kernel links its build identity into vmlinux (the "Linux version"
        # banner, UTS_VERSION, /proc/version) and, because CONFIG_IKCONFIG=y,
        # the .config text as well. Pin every clock/identity input so the image
        # depends only on the source:
        #   KBUILD_BUILD_*     -> scripts/mkcompile_h (replaced; 2.6.37 has no
        #                         KBUILD_BUILD_USER/HOST, ours does)
        #   KCONFIG_NOTIMESTAMP-> the "# <date>" line inside the embedded .config
        #   SOURCE_DATE_EPOCH  -> the uImage header time field (mkimage honours it)
        export KBUILD_BUILD_TIMESTAMP=${lib.escapeShellArg buildStamp}
        export KBUILD_BUILD_USER=${lib.escapeShellArg buildUser}
        export KBUILD_BUILD_HOST=${lib.escapeShellArg buildHost}
        export KBUILD_BUILD_VERSION=1
        export KCONFIG_NOTIMESTAMP=1
        export SOURCE_DATE_EPOCH=0
        export TZ=UTC LC_ALL=C LANG=C

        mkdir -p build
        cp -r ${attack.linux} build/linux
        chmod -R u+w build/linux
        # CONFIG_INITRAMFS_SOURCE="../initramfs_data.cpio" is relative to the
        # kernel dir, so the cpio lives one level up.
        cp ${initramfs}/initramfs.cpio build/initramfs_data.cpio
        # Deterministic stand-in for the kernel's build-identity generator.
        cp ${./mkcompile_h} build/linux/scripts/mkcompile_h
        chmod 755 build/linux/scripts/mkcompile_h

        cd build/linux
        make ARCH=arm distclean
        make ARCH=arm gtvhacker_defconfig

        # Perl 5.22+ removed defined(@array); 2.6.37's timeconst.pl still uses it.
        sed -i 's/defined(@\(.*\))/\@\1/' kernel/timeconst.pl

        make ARCH=arm \
          CROSS_COMPILE="$CROSS_COMPILE" \
          HOSTCC="$HOSTCC" HOSTCXX="$HOSTCXX" \
          uImage -j"${jobsFlag}"

        runHook postBuild
      '';

      installPhase = ''
        runHook preInstall
        install -Dm644 arch/arm/boot/uImage "$out/uImage"
        ( cd "$out" && sha256sum uImage > uImage.sha256 )
        runHook postInstall
      '';

      meta = {
        description = "Nest thermostat uImage bundling the nest-ondevice server";
        license = lib.licenses.gpl2Only;
      };
    };
    # QEMU smoke-test image (real kernel tree + injected cpio, emulated board).
    # Kept in its own file so the shipped firmware path above is untouched.
    qemuPackages = import ./qemu.nix {
      inherit pkgs lib nest-ondevice crossToolchain attack initramfs;
    };
  in
  {
    inherit initramfs firmware crossToolchain;
    default = firmware;
  }
  // qemuPackages
