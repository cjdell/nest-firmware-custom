# Nest firmware image

`packages.<system>.firmware` builds a flashable **`uImage`**: the GTVHacker
Linux 2.6.37 kernel with its initramfs replaced by one that already contains the
`nest-ondevice` server. Flashing it via the existing DFU attack installs the
server onto the thermostat's flash at first boot.

```
uImage                      # kernel + initramfs (the firmware image)
uImage.sha256               # checksum to verify before flashing
```

`packages.<system>.initramfs` is the intermediate cpio, useful for inspection;
`packages.<system>.nest-ondevice` is the static ARM binary on its own.

## Why a Linux builder (and why Apple container)

`nix` on macOS is `*-darwin`: it can *evaluate* foreign derivations and
*substitute* cached ones, but it can never **run** an `aarch64-linux` builder.
The firmware build needs a Linux machine — `make`, `perl`, `bc`, `mkimage`, plus
the 2008 ARM cross toolchain — so `bin/macos/build.sh` runs the build in an
[Apple-container](https://github.com/apple/container) NixOS VM. Its `/nix`
persists between runs, so only changed derivations rebuild.

## The 2008 toolchain: native on x86_64, qemu-i386 elsewhere

`NestDFUAttack/Dev/toolchain/arm-2008q3` is a 32-bit **i686** CodeSourcery
toolchain (ELF interpreter `/lib/ld-linux.so.2`). `firmware/default.nix` builds
it two ways:

* **x86_64 Linux — the fast path.** The host kernel has `CONFIG_IA32_EMULATION`
on, so i686 code runs natively. The derivation copies the toolchain into a
writable tree and rewrites every i686 ELF's interpreter + RPATH to the store's
i386 loader/libs with `patchelf`, then runs it directly. No emulation and no
wrappers: the full kernel build takes ~35 s.
* **Anywhere else** (aarch64-linux, macOS) it falls back to `qemu-i386` user
emulation, with the i386 glibc/zlib/ncurses it links against coming from
`pkgsCross.gnu32`. Here every program the driver may exec (`gcc`, `cc1`,
`collect2`, `as`, `ld`, …) is replaced in place by a native wrapper:

```sh
#!/nix/store/…-bash/bin/bash
export COMPILER_PATH="$out/libexec"
exec /nix/store/…-qemu-…/bin/qemu-i386 -L /nix/store/…-nest-i386-sysroot \
     "$out/bin/arm-none-linux-gnueabi-gcc.real" "$@"
```

Wrapping in place (rather than setting `COMPILER_PATH`/`-B` globally) matters:
a global `COMPILER_PATH` also hijacks the **native** host compiler's `cc1`
lookup and the host tools fail with `bad value (armv8-a) for -march=`.
Kernel compilation under qemu takes roughly 4 minutes.

## Case-insensitive filesystems corrupt the kernel tree

The kernel is a git checkout in which **13 paths differ only in case**, e.g.
`net/netfilter/xt_HL.c` vs `net/netfilter/xt_hl.c` (they are different files
with different contents — legacy UAPI header aliases such as `xt_mark.h` /
`xt_MARK.h`). macOS APFS is case-insensitive, so a checkout there materialises
only one of each pair and `make` fails with `No rule to make target
'net/netfilter/xt_HL.o'`. The virtiofs mount of that checkout carries the same
damage into the VM.

`bin/macos/build.sh` therefore archives `Dev/linux` **on the host** with
`git archive HEAD Dev/linux` — git reads the object database and is case-exact
— and hands the tarball to the VM. `bin/macos/vm-build.sh` extracts it onto the
case-sensitive `/tmp` and points the build at it via `NEST_LINUX_DIR`. On a
native case-sensitive host `vm-build.sh` falls back to `git archive` directly;
either way the build sees the same content.

## How the server gets in

`firmware/inject_initramfs.py` rewrites the base cpio at the archive level, so
no root/`mknod` is needed (Nix builds are unprivileged and cannot recreate the
device nodes). It:

1. copies every existing entry byte-for-byte, including each device node's
   major/minor (they used to be zeroed — masked on-device by devtmpfs, but
   fatal to an initramfs that relies on its static `/dev`),
2. adds `/usr/bin/nest-ondevice`, `/etc/init.d/nest-ondevice`, and
   `/etc/monit.d/nest-ondevice.monitrc`,
3. patches `/etc/init.d/rootme` — the script that installs persistent files to
   `mtdblock7` — **before** it runs `umount /tmp/1`, so the server, its init
   script and the monit config are copied to the flash and
   `${INITDIR}/nest-ondevice start` is appended to `rcS`.

The kernel's `CONFIG_INITRAMFS_SOURCE="../initramfs_data.cpio"` then embeds the
patched cpio, and `mkimage` produces the `uImage`.

At runtime `nest-ondevice` listens on the device port (default 8000) and the
control port (default 8082) with state under `/media/data/nest-ondevice`; see
`../nest-ondevice-server/README.md`.

## Observability on the device

Flashing this image gives agents four layers of visibility, cheapest first:

1. **`/debug/*` on the control port** — read-only structured JSON: `/debug/report`
   is a one-shot bundle (status + logs + request trace + dmesg + `free`/`ps`/
   `ifconfig`/`route`/`df`/`mount`). Set `DEBUG_TOKEN` in
   `/etc/init.d/nest-ondevice` before relying on it on an untrusted LAN. The
   daemon mirrors its log as JSONL to `/media/data/nest-ondevice/nest-ondevice.jsonl`
   (size-rotated); raw stdout/stderr goes to `nest-ondevice.out`.
2. **Dropbear SSH** — the GTVHacker `rootme` already copies `dropbearmulti` to
   `mtdblock7` and appends `/bin/dropbear` (+ the `autossh` reverse tunnel) to
   `rcS`, so this is *already installed*; nothing here adds it.
3. **Persistent logs + supervision** — `/etc/init.d/nest-ondevice` starts
   `syslogd/klogd` writing to `/media/log/messages` (jffs2; the vendor default
   `/var/log` is tmpfs and loses everything on reboot), supervises the daemon
   with the shipped `monit` (falling back to its own `wait`-based loop when monit
   is absent), and appends each exit status to
   `/media/data/nest-ondevice/last-exit`.
4. **UART** — `/etc/init.d/start` already spawns a root shell on `/dev/ttyO0`
   at 115200; the only channel that sees pre-userspace failures.

## QEMU smoke test (no thermostat needed)

`packages.<system>.nestQemuKernel` builds the same 2.6.37 kernel tree + the same
injected cpio for **ARM RealView PB-A8** (Cortex-A8/ARMv7), a board
`qemu-system-arm` emulates, and `firmware/qemu-smoke.sh` boots it and asserts the
server answers:

```sh
bash firmware/qemu-smoke.sh
```

The boot is the real thing (same kernel, same rootfs, the static musl server),
with a qemu-only `/qemu-init` used as `rdinit` that skips the hardware-only
`rcS` (mtdblock7/tiwlan/`rootme`'s reboot). It prints the guest's
`/proc/version`, starts the server, self-tests over loopback with busybox `nc`
(including `/debug/status` and `/debug/report`, which exercises the busybox
`dmesg`/`free`/`ps` applets on the real rootfs), and the script also hits
`:18000`/`:18082` through qemu's user-net port forwards.

Three RealView/PB-A8 traps are baked into `firmware/qemu.nix`:

* **`REALVIEW_HIGH_PHYS_OFFSET`.** `realview_defconfig` enables
  `MACH_REALVIEW_PB1176`, which makes `REALVIEW_HIGH_PHYS_OFFSET` (`depends on
  MMU && !MACH_REALVIEW_PB1176`) invisible. Without it `zreladdr` is
  `0x00008000`, but qemu's PB-A8 has RAM at `0x70000000`, so the decompressed
  kernel is jumped into unmapped memory and runs away. The build disables the
  PB1176/EB/PB11MP boards and re-enables the option.
* **`-m 512M`.** The kernel's `realview_fixup` hardcodes a 512 MB bank at
  `0x70000000`; booting with less hangs in `paging_init()`. Give qemu 512 MB.
* **NIC.** qemu's PB-A8 only models a **lan9118** (`smsc911x` driver), while the
  2.6.37 board file instantiates the `smc91x` AMBA device. Point `-nic` at
  `model=lan9118`; `CONFIG_SMSC911X` is enabled so `eth0` comes up.

The rootfs's `/usr/bin/curl` needs `libcurl.so.4` (not in the initramfs), so the
in-guest self-test speaks HTTP/1.0 over busybox `nc`. Interfaces come up with
`/sbin/ifconfig` — there is no `/bin/ifconfig` on this rootfs.

## Building

On a Mac (Apple container is started automatically):

```sh
bash bin/macos/build.sh start firmware
bash bin/macos/build.sh wait  firmware    # 0 done, 1 failed, 2 still running
bash bin/macos/build.sh log   firmware
bash bin/macos/build.sh status
```

Artifacts land in `~/.cache/nest-macos/out/` together with a `.manifest`
(source revision, nix/VM versions, store paths) and `.sha256`.

On any Linux host with Nix (the clean path — no VM and no case workaround):

```sh
NEST_ATTACK_DIR=$PWD/NestDFUAttack nix build --impure .#firmware
# or the artifact + manifest wrapper:
NEST_ATTACK_DIR=$PWD/NestDFUAttack ./bin/macos/vm-build.sh firmware
```

`NEST_ATTACK_DIR` must point at the vendored GTVHacker checkout (the `NestDFUAttack`
submodule; run `git submodule update --init` after cloning). With it unset the
flake still evaluates and `nix build .#nest-ondevice` works anywhere.

## Flashing (untested on hardware)

Use the existing `NestDFUAttack` flow (`Dev/build.sh`, `omap3_usbload`, the
`Release/Nest` scripts) and substitute the freshly built `uImage`. This repo
does not flash anything.

## Verify before flashing

```sh
sha256sum -c uImage.sha256
```

The initramfs inside the image should contain the server:

```sh
python3 - <<'PY'
import lzma
d=open('uImage','rb').read()[64:]
i=d.find(b'\x5d\x00\x00')
print(len(lzma.decompress(d[i:], format=lzma.FORMAT_ALONE)))
PY
```

or build `.#initramfs` and inspect the cpio with `cpio -it`.

## Caveats

* **Not yet run on a real thermostat.** The image builds, embeds the server and
  the on-flash install step is written to run before the unmount, but the
  end-to-end first boot and the app↔localhost protocol have not been validated
  on hardware.
* The kernel is unchanged from GTVHacker except for the embedded initramfs, so
  existing DFU/root assumptions still apply.
* `hostname: command not found` during the kernel build only affects the
  `#define` in `compile.h`; it is harmless.
* The build expects the case-damaged checkout; the case-fix restores the 13
  collided sources but does not otherwise validate the vendored tree.
