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

**The VM is arm64, and that is worth knowing before you compare checksums.** The
container runtime also offers an amd64 VM under Rosetta (`NEST_VM_ARCH=amd64`),
but it cannot build this image: Rosetta-for-Linux does not preserve a custom
`argv[0]` across `exec` — `bash -c 'exec -a MARKER bash -c "echo $0"'` prints the
resolved binary path under Rosetta and `MARKER` on a native host, arm64 or
x86_64. nixpkgs' python environments are C trampolines that locate their prefix
from `argv[0]`, so under Rosetta the env-python reports the bare interpreter as
its prefix and every `autoPatchelfHook` fails; the first thing the firmware
build hits is `rust-std`: `ModuleNotFoundError: No module named 'elftools'`.
A host that rewrites `argv[0]` can also change build output silently, which is
worse than failing. `binfmt_misc` cannot be mounted inside an Apple container
(`mount: permission denied`), so `qemu-x86_64` user emulation is not available
as a substitute either. To get the x86_64 image bytes from a Mac, build on a
real x86_64 host — `./build firmware` will drive one over ssh, see
"Build-host architecture" below.

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
`./build firmware` — the archive step throws it away. The submodule is upstream
`exploiteers/NestDFUAttack` and we keep no patches in it, so a real kernel change
means forking it and moving the gitlink; for a throwaway experiment point
`NEST_LINUX_DIR` at a tree of your own. The asymmetry is a habit to unlearn: the
*other* two vendored inputs — `Dev/initramfs_data.cpio` and
`Dev/toolchain/arm-2008q3` — are read straight from the checkout, so edits there
take effect immediately.

Nothing in `Dev/` is patched in git today. Everything we change is applied at
build time to a copy: `scripts/mkcompile_h` and the `timeconst.pl` Perl fix
(`firmware/default.nix`), the `realview` config toggles (`firmware/qemu.nix`),
the initramfs injection (`firmware/inject_initramfs.py`), and the toolchain
wrappers. The flashable config is `gtvhacker_defconfig` as shipped, which is why
the gitlink is still upstream's single commit, 930b834b (AGENTS.md trap 22).

## How the server gets in

`firmware/inject_initramfs.py` rewrites the base cpio at the archive level, so
no root/`mknod` is needed (Nix builds are unprivileged and cannot recreate the
device nodes). It:

1. copies every existing entry byte-for-byte, including each device node's
   major/minor (they used to be zeroed — masked on-device by devtmpfs, but
   fatal to an initramfs that relies on its static `/dev`),
2. adds five files: `/usr/bin/nest-ondevice` (the server),
   `/etc/init.d/nest-ondevice` (its init script), `/etc/init.d/nosleep`
   (`firmware/nosleep.init`, the suspend kill-switch),
   `/etc/init.d/nest-ondevice-install` (`firmware/rootfs-install.sh`, the
   flash-root installer) and `/etc/monit.d/nest-ondevice.monitrc`,
3. patches `/etc/init.d/rootme` — the script that installs persistent files to
   `mtdblock7` — with one line, `sh /etc/init.d/nest-ondevice-install`, inserted
   **before** its `umount /tmp/1`, so the install happens on the flash and not in
   the initramfs tmpfs (AGENTS.md trap 5). Re-injecting an already-injected cpio
   updates those entries in place rather than appending a second copy.

The kernel's `CONFIG_INITRAMFS_SOURCE="../initramfs_data.cpio"` then embeds the
patched cpio, and `mkimage` produces the `uImage`.

At runtime `nest-ondevice` listens on the device port (default 8000) and the
control port (default 8082) with state under `/media/data/nest-ondevice`; see
`../nest-ondevice-server/README.md`.

### What the installer changes on the flash root

`firmware/rootfs-install.sh` is the whole persistent half of the image: the
on-device fixes that were first applied by hand to the unit at `192.168.1.2`
(AGENTS.md traps 14/15) are now part of a flash. It copies the server, its init
script, `nosleep` and its monit config to `mtdblock7`, includes the monit config
from `/etc/monitrc`, and then:

| Change | Why |
|---|---|
| delete `/bin/sshconnect` from `rcS`, de-dupe `/bin/dropbear` | the autossh loop never returns, so `rcS` stopped before the server started (trap 11) |
| comment `${INITDIR}/nlsleep start` in `rcS` and the `check process nlsleepd` block in `/etc/monit.d/nlscpm.monitrc`; add `${INITDIR}/nosleep start` | `nlsleepd` deep-sleeps the SoC when the display sleeps and the LAN server goes down with the radio (trap 14). `nlshutdownd` is deliberately left supervised — it is the shutdown path |
| comment `${INITDIR}/nlsleep stop` in `rcH` | with `nlsleepd` unmonitored, `monit stop nlsleepd` always fails and `rcH` retries for 1+3+9+27+81+243 s, so a reboot looks like it does nothing (trap 15). Commenting the *call* rather than editing `nlsleep`'s `stop)` case is deliberate: `nlsleep` is a file the installer cannot read while it writes, and an `exit 0` inserted blind near its top would also end `rcH` if `rcH` sourced it |
| set the diagnostic `root` line in `/etc/shadow` | this is a diagnostic image; drop that block before treating a flash as anything else |

It is guarded and idempotent — rootme runs on every boot taken through the DFU
image, so re-running is the recovery path for an interrupted flash — it never
fails the boot (every edit is skipped when the file it wants is absent, and a
root that is not mounted is a no-op), and it logs what it decided to
`/etc/nest-ondevice-install.log` on the flash root, because it runs blind.
`NEST_ROOT` is the tree to install into and `NEST_SRC` where the initramfs files
come from, which is what makes it testable off-device.

### Testing the on-device half without a thermostat

```sh
./build test
```

Suite 1 runs the installer against a fixture that imitates the factory flash
root — the real one is not in this repo, `NestDFUAttack/Dev/root` is an older
dump with no `nlsleep` at all — twice, and checks both what it changes and that
the second run changes nothing (including that a line someone already disabled
by hand does not get marked twice, and that `nlshutdownd` survives). Suite 2
runs the injector against a synthetic cpio and checks the embedded modes, that
rootme calls the installer before it unmounts the flash (trap 5), and that
`/dev/console` keeps major/minor 1,3 (trap 6). Suite 3, if a built initramfs is
around (`./build initramfs`, or `NEST_INITRAMFS=path ./build test`), extracts the
installer from that image and runs *that* against the fixture.

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
./build test          # the on-device half of the image, against fixtures
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

To build the canonical x86_64 image from the Mac, point `./build` at an x86_64
Linux host. It rsyncs the tree (minus `.git` and the submodule, so the collapsed
case-only paths cannot travel, trap 3) into a scratch directory it owns, refuses
to start unless that host's `NestDFUAttack` is at the commit this repo pins, and
copies back only what the build listed:

```sh
NEST_BUILD_HOST=user@host NEST_BUILD_ATTACK=~/nest/NestDFUAttack ./build firmware
```

Two container traps, both now guarded in `bin/container.sh`:

* **virtiofs mounts are fixed when the container is created**, and `container
  create` is skipped if the name already exists — so a builder left over from
  another checkout, or from before `NEST_VM_CACHE` moved, keeps mounting the old
  directories and silently builds stale sources while reporting success. It
  writes into directories that no longer exist on the host, so nothing even
  arrives in `dist/`. `assert_mounts` compares the container's config against
  the paths this checkout needs and dies with the recreate command.
* **`NEST_LINUX_TAR` must name the path the VM sees** (`/out/…`, not the host's
  `$out/…`). If it does not exist inside the VM, `bin/nix-build.sh` falls back to
  `git archive` there, and that cannot work either: the submodule's gitdir lives
  outside the mount, so only the host can produce the case-exact archive. The
  symptom is `fatal: not a git repository: /nest/attack/../.git/modules/…`
  followed by `does not look like a tar archive`.

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

The `uImage` is bit-reproducible **for a given build-host architecture**: the
same source rebuilds to the same bytes on the same kind of machine, so "flash
this image" is a checksum, not folklore. x86_64-linux is the reference — the
digest quoted in `AGENTS.md` is an x86_64 digest, and an aarch64 builder prints
a different one ("Build-host architecture" below). Everything that could differ
between machines of the *same* architecture is pinned in `firmware/default.nix`:

| Leak | Where it lands | Fix |
|---|---|---|
| `date` in `UTS_VERSION` | `linux_banner`, `/proc/version`, `uname -r` output | `KBUILD_BUILD_TIMESTAMP` (default `1970-01-01 00:00:00 UTC`) |
| `whoami` / `hostname` | same banner — 2.6.37 has **no** `KBUILD_BUILD_USER/HOST` | `firmware/mkcompile_h` replaces the kernel's generator and adds those knobs |
| `ctime()` in the generated `.config` | embedded by `CONFIG_IKCONFIG=y`, gzip'd into vmlinux | `KCONFIG_NOTIMESTAMP=1` |
| `time()` in the uImage header | bytes 8-11 of the 64-byte header (+ the header CRC) | `SOURCE_DATE_EPOCH=0`, which `mkimage` honours |
| build path / locale | any tool that echoes its argv | nix sandbox (`/build`), `TZ=UTC LC_ALL=C LANG=C` |
| nix's sandbox switched off in the image's `nix.conf` | the build dir becomes the real `/nix/store`, not `/build`: some fixups change and `rust-std`'s `autoPatchelfHook` dies outright | `sandbox = true` in `bin/nix-build.sh`, not left to the image default |
| `make -j<N>` width | link/compress order | unchanged (verified identical at `-j1` and `-j32`) |
| i686 toolchain run natively vs under `qemu-i386` | the compiler *invocation* only | verified identical **on one host** (`NEST_TOOLCHAIN=native\|qemu`); across architectures it is not (below) |

The banner in a reproducible image reads
`Linux version 2.6.37 (nest@ondevice) (gcc version 4.3.2 (Sourcery G++ Lite 2008q3-72) ) #1  PREEMPT 1970-01-01 00:00:00 UTC`.
Override `NEST_BUILD_TIMESTAMP` / `NEST_BUILD_USER` / `NEST_BUILD_HOST` only to
reproduce an older image byte for byte.

Prove it on one machine with `./build repro` (`bin/repro-check.sh`): it rebuilds
the image under each difference the two hosts have — a forced rebuild in a fresh
`TMPDIR`, the `qemu-i386` toolchain path, `make -j1`, the `git archive`d kernel —
and builds the ARM server twice, comparing the two binaries with each other. It
prints one reference sha256 per artifact; the same architecture on another
machine must print the same numbers. Nix caches each variant, so a second run is
nearly free; `REPRO_FRESH=1 ./build repro` adds `--rebuild` and does the work
again. On aarch64 the native i686 toolchain cannot execute and `default.nix`
chooses qemu by itself, so the `qemu-toolchain` variant is a no-op there.

That variant was a no-op *everywhere* until 2026-10-14: it exported
`NEST_FORCE_QEMU=1`, which nothing reads (`default.nix` reads `NEST_TOOLCHAIN`),
so it rebuilt the baseline and reported "identical". A variant that cannot
change anything cannot fail. `NEST_TOOLCHAIN` is what it sets now, and the claim
it backs was re-measured by hand: an x86_64 host forced through `qemu-i386`
produces the same `123bd52b0fea…` as the same host running the tools natively.

### Build-host architecture

The build host's architecture is an input to the bytes, and no knob fixes it.
Measured on 2026-10-14 from the same clean tree (`e5cd8d8`), x86_64 Linux versus
the aarch64 macOS container:

| Artifact | x86_64 | aarch64 | Difference |
|---|---|---|---|
| `nest-ondevice` | `ca738fe2e280d35b…` (804,444 B) | `fd5624aad588866a…` (804,460 B) | rustc 1.99.0 emits one extra `.ARM.exidx` entry; the 16-byte size change shifts every later section, so 85% of bytes differ while the code is the same |
| `initramfs.cpio` | `23a2c1fe920688da…` | `4517baa6262911e1…` | that binary, plus the installer script's new size rounding the cpio pad by 4 B |
| `uImage` | `123bd52b0fea6732…` | `498af4439f801882…` | the initramfs above, plus **328 bytes of kernel text**: the 2008 i686 compiler under `qemu-i386` on aarch64 allocates registers differently than the same compiler on x86_64 (168 clusters, all inside the first 0x2246c bytes) |

Both builders are self-consistent — two forced rebuilds on the aarch64 container
reproduce `498af443…` exactly — so this is not a determinism bug, it is two
deterministic compilers. The kernel difference is the interesting one: the same
i686 `gcc` binary, the same `qemu-i386`, the same inputs, different ARM output.

So the rule is: **quote the digest together with the architecture that built
it**, and build release images on x86_64 Linux. From a Mac that means the ssh
route above, which is verified to print `123bd52b0fea…` for `uImage`,
`ca738fe2e280d35b…` for `nest-ondevice` and `23a2c1fe920688da…` for
`initramfs.cpio` — the same three numbers the x86_64 host prints directly.

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

After a flash, the installer's own record is on the flash root — read that
before debugging anything else:

```sh
nssh cat /etc/nest-ondevice-install.log     # what it changed, and what it skipped
nssh 'cat /sys/kernel/debug/pm_debug/enable_off_mode \
        /sys/kernel/debug/pm_debug/sleep_while_idle \
        /sys/kernel/debug/pm_debug/voltage_off_while_idle'   # want 0 0 0
nssh monit\ summary                          # want nlsleepd gone, nlshutdownd kept
nssh 'grep -c DISABLED-by-nest-ondevice /etc/init.d/rcS /etc/init.d/rcH /etc/monit.d/nlscpm.monitrc'
```

The image carrying the traps 14/15 fixes (`uImage` sha256 starting
`123bd52b0fea`) was built and reproducible-checked but **not yet flashed** — the
unit was unreachable off-site. The unit at `192.168.1.2` runs the older image
plus the hand-applied fixes, which the installer detects and leaves alone.

## Verify before flashing

```sh
sha256sum -c uImage.sha256   # and compare the sha256 with the other build host
./build test                 # = firmware/test-image.sh: the on-device half, against
                             # fixtures — no thermostat needed
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
