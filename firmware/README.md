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
the 2008 ARM cross toolchain — so on a Mac `bin/container.sh` runs the build in
an [Apple-container](https://github.com/apple/container) NixOS VM. Its `/nix`
persists between runs, so only changed derivations rebuild. The build itself is
`bin/nix-build.sh` on both hosts, which is why the images match; `./build` picks
the right one for the machine it is on.

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

`bin/container.sh` therefore archives `Dev/linux` **on the host** with
`git archive HEAD Dev/linux` — git reads the object database and is case-exact
— and hands the tarball to the VM. `bin/nix-build.sh` extracts it onto the
case-sensitive `/tmp` and points the build at it via `NEST_LINUX_DIR`. On a
native case-sensitive host `nix-build.sh` runs the same `git archive` itself;
either way the build sees the same content. Archiving from git is also a
reproducibility measure, not only a case fix: the build then sees exactly the
tracked tree, so an untracked or locally edited file in one checkout cannot make
that host's image differ.

**Which means: edit the kernel in the submodule's git, not in the working
tree.** An uncommitted change under `NestDFUAttack/Dev/linux` is invisible to
`./build firmware` — the archive step throws it away. Commit it to the submodule
(`cjdell/NestDFUAttack`, branch `nest-ondevice`) and move the parent's gitlink,
or point `NEST_LINUX_DIR` at a tree of your own for a throwaway experiment. The
asymmetry is a habit to unlearn: the *other* two vendored inputs —
`Dev/initramfs_data.cpio` and `Dev/toolchain/arm-2008q3` — are read straight from
the checkout, so edits there take effect immediately.

Nothing in `Dev/` is patched in git today. Everything we change is applied at
build time to a copy: `scripts/mkcompile_h` and the `timeconst.pl` Perl fix
(`firmware/default.nix`), the `realview` config toggles (`firmware/qemu.nix`),
the initramfs injection (`firmware/inject_initramfs.py`), and the toolchain
wrappers. So the fork's `nest-ondevice` branch is a landing place for kernel
work, not a delta — yet.

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

One entry point, both hosts:

```sh
./build firmware      # -> dist/uImage (+ uImage.sha256, firmware.manifest)
./build server        # -> dist/nest-ondevice (static ARM musl binary)
./build initramfs     # -> dist/initramfs.cpio (the intermediate cpio)
./build all           # firmware + server + initramfs
./build qemu          # boot the image under qemu-system-arm and assert HTTP works
./build repro         # prove the image is host-independent (see next section)
./build status        # what is in dist/, with checksums
./build clean         # remove dist/
```

On Linux (`x86_64` NixOS or any Linux with nix) that runs `bin/nix-build.sh`
directly — no VM, no case workaround. On macOS `./build` stages the repo into
the Apple-container VM, blocks while it builds (streaming the log), and copies
the artifacts back into `dist/`, so the two hosts look identical from here. Use
`NEST_DETACH=1 ./build firmware` to fire and forget, then `./build status` (or
`./build wait`) to collect; `bash bin/container.sh` exposes the lower-level
verbs (`run|start|wait|log|exec|status|path|stage|vm|stop`).

`NEST_ATTACK_DIR` must point at the vendored GTVHacker checkout (the
`NestDFUAttack` submodule; run `git submodule update --init` after cloning).
With it unset the flake still evaluates and `nix build .#nest-ondevice` works
anywhere. The raw nix commands still work too:

```sh
NEST_ATTACK_DIR=$PWD/NestDFUAttack nix build --impure .#firmware
NEST_SRC=$PWD NEST_OUT=$PWD/dist NEST_ATTACK=$PWD/NestDFUAttack sh bin/nix-build.sh firmware
```

Both hosts evaluate `bin/flake-src.sh`: a *filtered* copy of the tree (464 KB).
`builtins.getFlake` on the checkout itself copies 1.3 GB into the store on every
invocation — the `NestDFUAttack` submodule alone is 884 MB — and re-copies each
time an artifact lands in `dist/`. Nothing is lost: the kernel, initramfs and
toolchain the build reads arrive through `NEST_ATTACK_DIR`, an absolute path
outside the flake source.

## Reproducible images

The `uImage` is bit-reproducible: the same source builds to the same bytes on
either host, so "flash this image" is a checksum, not folklore. Everything that
could differ between machines is pinned in `firmware/default.nix`:

| Leak | Where it lands | Fix |
|---|---|---|
| `date` in `UTS_VERSION` | `linux_banner`, `/proc/version`, `uname -r` output | `KBUILD_BUILD_TIMESTAMP` (default `1970-01-01 00:00:00 UTC`) |
| `whoami` / `hostname` | same banner — 2.6.37 has **no** `KBUILD_BUILD_USER/HOST` | `firmware/mkcompile_h` replaces the kernel's generator and adds those knobs |
| `ctime()` in the generated `.config` | embedded by `CONFIG_IKCONFIG=y`, gzip'd into vmlinux | `KCONFIG_NOTIMESTAMP=1` |
| `time()` in the uImage header | bytes 8-11 of the 64-byte header (+ the header CRC) | `SOURCE_DATE_EPOCH=0`, which `mkimage` honours |
| build path / locale | any tool that echoes its argv | nix sandbox (`/build`), `TZ=UTC LC_ALL=C LANG=C` |
| `make -j<N>` width | link/compress order | unchanged (verified identical at `-j1` and `-j32`) |
| i686 toolchain run natively vs under `qemu-i386` | the compiler *invocation* only | verified identical (`NEST_TOOLCHAIN=native\|qemu`) |

The banner in a reproducible image reads
`Linux version 2.6.37 (nest@ondevice) (gcc version 4.3.2 (Sourcery G++ Lite 2008q3-72) ) #1  PREEMPT 1970-01-01 00:00:00 UTC`.
Override `NEST_BUILD_TIMESTAMP` / `NEST_BUILD_USER` / `NEST_BUILD_HOST` only to
reproduce an older image byte for byte.

Prove it on one machine with `./build repro` (`bin/repro-check.sh`): it rebuilds
the image under each difference the two hosts have — a forced rebuild in a fresh
`TMPDIR`, the container's `qemu-i386` toolchain path, `make -j1`, the
`git archive`d kernel — and builds the ARM server twice, comparing the two
binaries with each other. It prints one reference sha256 per artifact; the other
host must print the same numbers. Nix caches each variant, so a second run is
nearly free; `REPRO_FRESH=1 ./build repro` adds `--rebuild` and does the work
again. On aarch64 the native i686 toolchain cannot execute and `default.nix`
chooses qemu by itself, so the `qemu-toolchain` variant is a no-op there.

What the check does *not* cover is the last mile: the two hosts run different
`gcc` builds for the **host** tools (x86_64 vs aarch64) and different `xz`/`nix`
revisions if `flake.lock` is not honoured. Keep `flake.lock` committed and
untouched when comparing images, and compare `dist/uImage.sha256` after any
nixpkgs bump.

## Flashing

Use the existing `NestDFUAttack` flow (`Dev/build.sh`, `omap3_usbload`, the
`Release/Nest` scripts) and substitute the freshly built `uImage`. This repo
does not flash anything; `AGENTS.md` records the procedure used on the unit at
`192.168.1.2`.

## Verify before flashing

```sh
sha256sum -c uImage.sha256      # and compare the sha256 with the other build host
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

* The kernel is unchanged from GTVHacker except for the embedded initramfs and
  the deterministic `scripts/mkcompile_h`, so existing DFU/root assumptions
  still apply.
* `mkcompile_h` used to print `hostname: command not found` inside the nix
  sandbox; the replacement never shells out for identity, so that noise is gone.
* The build expects the case-damaged checkout to be fixed first (`nix-build.sh`
  does it); the fix restores the 13 collided sources but does not otherwise
  validate the vendored tree.
