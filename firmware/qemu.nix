# QEMU bring-up image — a smoke test for the *firmware*, not the device.
#
# It builds the same 2.6.37 kernel tree (with the same 2008 ARM toolchain and
# the same baked-in cpio) but for a machine qemu-system-arm can actually
# emulate: ARM RealView PB-A8 (Cortex-A8 / ARMv7-A, machine id 1897 in
# arch/arm/tools/mach-types — the same id qemu sends for -M realview-pb-a8).
# The initramfs is the real injected one (real server + /etc/init.d/nest-ondevice)
# plus a qemu-only /qemu-init used as rdinit; that path bypasses the Nest
# hardware bring-up (mtdblock7, tiwlan, rootme's reboot) which cannot run under
# emulation.
#
# Nothing here touches the shipped firmware path (./default.nix `firmware`).
{ pkgs, lib, nest-ondevice, crossToolchain, attack, initramfs }:
let
  qemuInitramfs = pkgs.runCommand "nest-qemu-initramfs" {
    nativeBuildInputs = [ pkgs.python3 ];
  } ''
    mkdir -p $out
    python3 ${./inject_qemu_init.py} \
      ${initramfs}/initramfs.cpio "$out/initramfs.cpio" \
      ${./qemu-init.sh} ${./inject_initramfs.py}
  '';

  # initrd = null builds a control kernel with no initramfs. Used to tell a
  # machine/CPU bug apart from a "too much data to inflate" bug: if the control
  # reaches "Linux version 2.6.37" the board works and the payload is the issue.
  mkKernel =
    {
      pname,
      initrd,
    }:
    pkgs.stdenv.mkDerivation {
      inherit pname;
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
        file
      ];

      buildPhase = ''
        runHook preBuild

        export PATH=${crossToolchain}/bin:$PATH
        export CROSS_COMPILE=${crossToolchain}/bin/arm-none-linux-gnueabi-
        export HOSTCC=${pkgs.stdenv.cc}/bin/cc HOSTCXX=${pkgs.stdenv.cc}/bin/cxx

        mkdir -p build
        cp -r ${attack.linux} build/linux
        chmod -R u+w build/linux
        ${lib.optionalString (initrd != null) ''
          cp ${initrd}/initramfs.cpio build/initramfs_data.cpio
        ''}

        cd build/linux
        make ARCH=arm distclean
        make ARCH=arm realview_defconfig

        # realview_defconfig is ARMv6-only (EB / PB1176 / PB11MP) and, because
        # it enables MACH_REALVIEW_PB1176, hides REALVIEW_HIGH_PHYS_OFFSET —
        # whose `depends on MMU && !MACH_REALVIEW_PB1176`. Without it the
        # kernel links for low phys offset (zreladdr 0x00008000), but qemu's
        # PB-A8 has RAM at 0x70000000, so the decompressed image is jumped to
        # unmapped memory and runs away. Select the Cortex-A8 board, drop the
        # PB1176 board that blocks the option, and turn it back on.
        # scripts/config ships a /bin/bash shebang that is absent in the Nix
        # sandbox; invoke it through the interpreter make already uses.
        bash scripts/config --enable CPU_V7
        bash scripts/config --enable MACH_REALVIEW_PBA8
        bash scripts/config --disable MACH_REALVIEW_PB1176
        bash scripts/config --disable MACH_REALVIEW_EB
        bash scripts/config --disable MACH_REALVIEW_PB11MP
        bash scripts/config --enable REALVIEW_HIGH_PHYS_OFFSET
        # Early console on the PL011 (0x10009000) so an early fault is visible
        # on the serial line instead of looping silently in the high vectors.
        bash scripts/config --enable DEBUG_LL
        bash scripts/config --enable EARLY_PRINTK
        ${lib.optionalString (initrd != null) ''
          bash scripts/config --enable BLK_DEV_INITRD
          bash scripts/config --set-str INITRAMFS_SOURCE "../initramfs_data.cpio"
        ''}
        ${lib.optionalString (initrd == null) ''
          bash scripts/config --disable BLK_DEV_INITRD
          bash scripts/config --set-str INITRAMFS_SOURCE ""
        ''}
        make ARCH=arm oldconfig < /dev/null

        # Perl 5.22+ removed defined(@array); 2.6.37's timeconst.pl still uses it.
        sed -i 's/defined(@\(.*\))/\@\1/' kernel/timeconst.pl

        grep -E "CONFIG_CPU_V7=|CONFIG_MACH_REALVIEW_PBA8=|CONFIG_REALVIEW_HIGH_PHYS_OFFSET=|CONFIG_INITRAMFS_SOURCE=|CONFIG_BLK_DEV_INITRD=" .config || true

        make ARCH=arm \
          CROSS_COMPILE="$CROSS_COMPILE" \
          HOSTCC="$HOSTCC" HOSTCXX="$HOSTCXX" \
          zImage -j"$NIX_BUILD_CORES"

        runHook postBuild
      '';

      installPhase = ''
        runHook preInstall
        mkdir -p $out
        install -Dm644 arch/arm/boot/zImage "$out/zImage"
        install -Dm644 vmlinux "$out/vmlinux"
        ${lib.optionalString (initrd != null) ''cp ${initrd}/initramfs.cpio "$out/initramfs.cpio"''}
        install -Dm644 .config "$out/kernel.config"

        cat > "$out/run.sh" <<EOF
#!/bin/sh
# Boot the qemu bring-up image. Console is on stdio; -nographic multiplexes it.
here="\$(dirname "\$0")"
exec ${pkgs.qemu}/bin/qemu-system-arm \\
  -M realview-pb-a8 -cpu cortex-a8 -m 512M \\
  -kernel "\$here/zImage" \\
  -append "console=ttyAMA0${lib.optionalString (initrd != null) " rdinit=/qemu-init"}" \\
  -nic user,model=lan9118,hostfwd=tcp:127.0.0.1:18000-:8000,hostfwd=tcp:127.0.0.1:18082-:8082 \\
  -nographic "\$@"
EOF
        chmod +x "$out/run.sh"
        runHook postInstall
      '';

      meta = {
        description = "2.6.37 ARMv7 kernel for qemu-system-arm bring-up";
        license = lib.licenses.gpl2Only;
      };
    };

  kernel = mkKernel {
    pname = "nest-qemu-kernel";
    initrd = qemuInitramfs;
  };
  kernelNoInit = mkKernel {
    pname = "nest-qemu-kernel-noinit";
    initrd = null;
  };
in
{
  nestQemuKernel = kernel;
  nestQemuKernelNoInit = kernelNoInit;
  nestQemuInitramfs = qemuInitramfs;
}
