# AGENTS.md — nest: self-hosted Nest thermostat server + firmware

**What this repo is.** A compact Rust port of the NoLongerEvil Nest-protocol
server (`nest-ondevice-server/`), sized to run *on the thermostat itself*, plus
a Nix flake that cross-compiles it and bakes it into a flashable `uImage`
(`firmware/`). The device is pointed at `127.0.0.1` (Option A in the research
doc), so the thermostat is self-contained and Hubitat talks to it on the LAN.

**Repo state (2026-10-12).** Committed. `NestDFUAttack/` is pinned as a git
submodule at upstream `exploiteers/NestDFUAttack` (the exact commit is in the
index; `ignore = dirty` because a macOS checkout collapses its case-only paths).
The build is green and the image is verified to contain the server, but
**nothing has run on real hardware yet**.

Read this file, then `README.md`, then `firmware/README.md` if building images,
then `docs/nest-ondevice-protocol-research.md` for the protocol rationale.

## Doc map (source of truth, newest wins)

| Topic | File |
|---|---|
| Protocol, bucket semantics, Option A rationale | `docs/nest-ondevice-protocol-research.md` |
| Server behaviour / control API / flashing-lite notes | `nest-ondevice-server/README.md` |
| **Firmware build constraints + traps + verification** | `firmware/README.md` |
| Top-level build/entry points | `README.md` |

## Hard constraints (do not fight these)

| Constraint | Consequence |
|---|---|
| Nest = ARMv7 Cortex-A8, **soft-float EABI** (`ld-linux.so.3`), Linux **2.6.37**, 64 MiB RAM | Target triple is `armv7-unknown-linux-musleabi` (**not** `…eabihf`). Static musl. Server is `std`, no tokio, small-stack threads; ARM binary ≈ 624 KB, measured ~1.7 MB RSS (host proxy, not yet on glass). |
| Kernel is GTVHacker's 2.6.37 in `NestDFUAttack/Dev/linux` | Any kernel change must survive `make ARCH=arm gtvhacker_defconfig` + the 2008 toolchain. |
| Cross toolchain `NestDFUAttack/Dev/toolchain/arm-2008q3` is **i686** (32-bit x86) | It cannot run natively on modern hosts. See traps. |
| `CONFIG_INITRAMFS_SOURCE="../initramfs_data.cpio"` (`gtvhacker_defconfig:81`) | The initramfs is the injection point; the server lands at `/usr/bin/nest-ondevice`. |
| macOS APFS is **case-insensitive** | The kernel git tree has 13 case-only collisions that get destroyed on checkout. See traps. |
| macOS `nix` is `*-darwin` | It can evaluate foreign drvs and substitute cached ones but can never **run** a Linux builder. |

## Build & verify

```sh
# Server only (works on the Mac directly; rust-lld, no ARM linker needed)
nix build .#nest-ondevice

# Firmware image (needs Linux + the vendored tree)
git submodule update --init NestDFUAttack   # fresh clone only
export NEST_ATTACK_DIR=$PWD/NestDFUAttack
nix build .#firmware            # -> uImage
nix build .#initramfs           # -> initramfs.cpio

# On a Mac: Apple-container NixOS VM drives the Linux build
bash bin/macos/build.sh start firmware
bash bin/macos/build.sh wait  firmware   # rc 0 done, 1 failed, 2 still running
bash bin/macos/build.sh log   firmware
bash bin/macos/build.sh status           # artifacts + sha256
bash bin/macos/build.sh vm               # shell inside the build VM

# Native Linux host (no VM)
NEST_ATTACK_DIR=$PWD/NestDFUAttack ./bin/macos/vm-build.sh firmware

# Server smoke test (host build)
cargo build --release --manifest-path nest-ondevice-server/Cargo.toml
SERVER_PORT=18000 CONTROL_PORT=18082 API_ORIGIN=http://127.0.0.1:18000 \
  DATA_DIR=/tmp/nest-test-data ./nest-ondevice-server/target/release/nest-ondevice &
python3 nest-ondevice-server/test_smoke.py
```

**Verified build (2026-10-12):** `nix build .#firmware` →
`/nix/store/djmp6d5mi02b4gkkw0kdd8s6g236mq31-nest-firmware-1.0.0`,
`uImage` sha256 `2f0a61ca5fd093fe06f87d4e4770dd688a4cc13cb34d9bd18610a5db3fec026e`,
7,231,740 bytes. Kernel build ≈ **3m40s under qemu-i386**. Re-running the build
is cached (same store path, no rebuild).

Decompress-and-grep check that the server is *inside* the image:

```sh
python3 - <<'PY'
import lzma
d=open('uImage','rb').read()[64:]
i=d.find(b'\x5d\x00\x00')
out=lzma.decompress(d[i:], format=lzma.FORMAT_ALONE)
print(len(out), b'usr/bin/nest-ondevice' in out, b'nest-ondevice (injected' in out)
PY
```

## Traps already paid for (read before changing the build)

1. **i686 does not run under Apple-container/Rosetta.** Verified:
   `container run --rosetta --platform linux/amd64 … /path/to/i686-binary`
   → `Exec format error`; an `amd64` image also has no `ld-linux.so.2`. OrbStack
   Docker is not a workaround. **Fix:** run the toolchain under **`qemu-i386`**
   with an i386 sysroot (`pkgsCross.gnu32` glibc/zlib/ncurses →
   `${qemu}/bin/qemu-i386 -L <root>`), in `firmware/default.nix`.

2. **Wrap the toolchain *in place*; never set `COMPILER_PATH` globally.**
   A global `COMPILER_PATH` also hijacks the **native host** compiler's `cc1`
   lookup, and the kernel's host tools die with
   `bad value (armv8-a) for -march=`. `firmware/default.nix` copies the
   toolchain writable and replaces `gcc/cc1/collect2/as/ld/…` with native
   wrappers that `exec qemu-i386 … .real "$@"`. `-B`/`COMPILER_PATH` are set
   inside the cross-gcc wrapper only. Host tools use `HOSTCC`/`HOSTCXX` =
   `${pkgs.stdenv.cc}`.

3. **Case-insensitive FS destroys the kernel tree.** 13 paths differ only in
   case (`net/netfilter/xt_HL.c` ↔ `xt_hl.c`, `xt_MARK.h` ↔ `xt_mark.h`, …) with
   **different contents**; a macOS checkout keeps one and `make` fails with
   `No rule to make target 'net/netfilter/xt_HL.o'`. **Fix:**
   `bin/macos/build.sh` archives `Dev/linux` on the *host* with
   `git -C $attack archive HEAD Dev/linux` (case-exact: git reads the object
   DB, not the collapsed checkout), writes `$out/.attack-linux.tar`, and
   `vm-build.sh` extracts it to `/tmp/nest-linux-fixed`, exporting
   `NEST_LINUX_DIR`. (A native Linux host falls back to `git archive | tar -x`
   in the VM.) Do **not** "fix" this by renaming files — they are distinct
   modules.

4. **`buildRustPackage` hooks force `--target <host>`.** nixpkgs'
   `cargo-build-hook` passes `--target @rustcTargetSpec@`, which silently
   produced a Mach-O binary. **Fix:** in `flake.nix` override `buildPhase` /
   `installPhase` and set `CARGO_BUILD_TARGET=armv7-unknown-linux-musleabi`
   (install from `target/$triple/release/`).

5. **`rootme` injection order.** `/etc/init.d/rootme` installs persistent files
   to `mtdblock7` via `/tmp/1`, then `umount /tmp/1`, then `reboot`. The server
   install block **must go before the `umount`**, or it writes to the initramfs
   tmpfs and vanishes. `firmware/inject_initramfs.py::patch_rootme` anchors
   before `umount … /tmp/1`.

6. **Nix builds are unprivileged** and cannot `mknod`. So
   `inject_initramfs.py` edits the cpio at the **archive level** (copy entries
   verbatim) rather than extracting `/dev/*`. Do not switch to extract+repack.

7. **`nixpkgs-unstable` dropped `x86_64-darwin`** (26.11). `flake.nix`'s
   `systems` therefore omits it; `--all-systems` fails on it, not on us.

8. **Deprecated `stdenv.isLinux`** → use `pkgs.stdenv.hostPlatform.isLinux`.

9. **Doc edits must not rebuild the kernel.** The server `src` is filtered with
   `lib.fileset.toSource` (only `Cargo.toml`, `Cargo.lock`, `src/`), so editing
   a README no longer invalidates the ~3m40s kernel build. Keep it that way.

10. **The vendored trees are not flake inputs.** `NestDFUAttack/` is a pinned
    git submodule (`.gitmodules`); the `NoLongerEvil-*` and `hubitatcontrol/`
    trees are git-ignored sibling checkouts. All are read *impurely* via
    `NEST_ATTACK_DIR` (and `NEST_LINUX_DIR`). With them unset the flake still
    evaluates and `.#nest-ondevice` builds, so a fresh clone only needs
    `git submodule update --init` before `.#firmware`.

## Layout

```
flake.nix                     deps + packages (nest-ondevice, firmware, initramfs) + devShell
.gitmodules                   pins NestDFUAttack/ to upstream exploiteers/NestDFUAttack
firmware/
  default.nix                 qemu-i386 toolchain wrappers + kernel make + mkimage
  inject_initramfs.py         archive-level injection + rootme patch (order-sensitive)
  nest-ondevice.init          on-device /etc/init.d script, installed to /usr/bin
  README.md                   constraints/traps/verify (the long form of this file)
bin/macos/
  build.sh                    Mac driver: stage -> Apple-container VM, verbs start|wait|log|status|stage|vm|stop
  vm-build.sh                 the real build; case-fix, nix build, collect artifacts+manifests
nest-ondevice-server/         Rust server (src/, Cargo.*, test_smoke.py, deploy/)
docs/nest-ondevice-protocol-research.md
```

## Conventions

* **Apple containers, not Docker**, for any Linux builder on the Mac
  (`container` CLI; image `docker.io/rzmapp/nixos-vm:26.05`). The reference
  pattern lives in `~/Projects/gemini-nixos/bin/macos/`.
* Keep the flake outputs working on all three `systems`; the firmware attr only
  appears on Linux.
* Prefer receipts in comments (the *why*), matching the traps above.
* The server code is deliberately dependency-light (`serde`/`serde_json` only)
  and `std`-only for footprint reasons — do not add tokio/heavy crates.

## Next steps (not done)

* **On-hardware validation** — flash the `uImage` via the existing
  `NestDFUAttack` flow (`Release/Nest`, `omap3_usbload`) and confirm: first boot
  copies the server to flash, `rcS` starts it, the app talks to `127.0.0.1:8000`,
  and Hubitat reaches `:8082`. Measure real RSS (`free`, `/proc/*/status`).
* Calibrate the app's expected `structure.*`/`user.*` fields against captured
  real traffic, using the Python NoLongerEvil server as a differential oracle.
* Optional: shrink the firmware build by using a user-mode-only qemu instead of
  the full `pkgs.qemu` closure.
