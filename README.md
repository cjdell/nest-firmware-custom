# nest

Self-hosting for the Google Nest thermostat, built with Nix flakes.

Three pieces:

| Path | What it is |
|---|---|
| [`nest-ondevice-server/`](nest-ondevice-server/) | A compact **Rust** port of the NoLongerEvil Nest-protocol server, sized to run on the thermostat itself, with a read-only `/debug/*` observability API for agent/remote debugging. |
| [`firmware/`](firmware/) | A **firmware image** (the GTVHacker `uImage`) that bundles that server into the initramfs. |
| [`hubitat/`](hubitat/) | The **Hubitat app + driver** we run (vendored from upstream, patched), plus `push.sh` and the reverse-engineered hub REST procedures. |

The protocol research and the design rationale live in
[`docs/nest-ondevice-protocol-research.md`](docs/nest-ondevice-protocol-research.md).

## Build

One command, both hosts — `./build` runs nix directly on Linux and drives an
Apple-container NixOS VM on macOS (nix on macOS cannot run a Linux builder, and
the firmware build needs Linux userland plus the 2008 i686 ARM toolchain):

```sh
git submodule update --init NestDFUAttack   # fresh clone only

./build firmware     # uImage to flash            -> dist/uImage
./build server       # the ARM server binary      -> dist/nest-ondevice
./build initramfs    # the patched initramfs      -> dist/initramfs.cpio
./build all          # all three
./build qemu         # boot the image under qemu-system-arm, assert HTTP works
./build test         # the on-device half of the image, against fixtures
./build repro        # prove the image is host-independent (see below)
./build status       # dist/ listing + checksums
./build shell        # nix develop (cargo + python for the server)
```

Every artifact lands in `dist/` with a `.sha256` and a `.manifest` (source
revision, nix version, store paths) whichever host built it.

## Reproducible images

The `uImage` is bit-reproducible **per build-host architecture**: the same source
produces the same bytes on the same kind of machine, so "which image is this" is
a checksum. The kernel links its build identity into vmlinux (banner,
`uname -r`) and, with `CONFIG_IKCONFIG`, the `.config` text too, so
`firmware/default.nix` pins the clock, the build user/host, the `.config` stamp
and the uImage header time — see `firmware/README.md` § "Reproducible images".

```sh
./build repro
# baseline        123bd52b0fea6732…  reference   (the uImage)
# rebuild         123bd52b0fea6732…  identical   (forced rebuild, fresh TMPDIR)
# qemu-toolchain  123bd52b0fea6732…  identical   (i686 tools forced through qemu-i386)
# jobs1           123bd52b0fea6732…  identical   (make -j1 vs -j32)
# kernel-git      123bd52b0fea6732…  identical   (kernel via git archive, as on macOS)
# server-a        ca738fe2e280d35b…  reference   (the Rust binary inside the image)
# server-b        ca738fe2e280d35b…  identical   (built again, different TMPDIR)
```

Those are x86_64 digests, and **an Apple-silicon Mac does not print them**. The
Mac's Linux builder is an arm64 VM, and the compiler is architecture-sensitive:
the same tree builds `498af4439f801882…` there (328 bytes of kernel text differ,
and rustc adds one `.ARM.exidx` entry to the server, shifting it by 16 bytes).
It is deterministic — rebuild it twice and it matches itself — it is simply not
x86_64's image. `firmware/README.md` § "Build-host architecture" has the
measurements.

So on the Mac, either accept the arm64 image (fine for development) or build the
canonical one on a real x86_64 host, which `./build` will drive for you:

```sh
NEST_BUILD_HOST=user@host NEST_BUILD_ATTACK=~/nest/NestDFUAttack ./build all
```

A digest belongs to a commit, so these are labelled. `dist/*.manifest` records
the revision, nix version and store paths of whatever is in `dist/`.

| Built from | Arch | `uImage` | `nest-ondevice` | `initramfs.cpio` |
|---|---|---|---|---|
| `e5cd8d8` as committed | x86_64 | `123bd52b0fea6732…` | `ca738fe2e280d35b…` | `23a2c1fe920688da…` |
| + the `sed -i` fix (trap 28) | x86_64 | `51f54eccfdd5c011…` | `ca738fe2e280d35b…` | `902d1e5fcb942b0e…` |
| + the same fix | arm64 (Mac) | `4b4fdd025be5bb73…` | `fd5624aad588866a…` | `eba8deca14ac102a…` |

The two x86_64 rows print identically from the x86_64 host directly and from the
Mac driving it over ssh. The server binary did not change with the installer fix
(it is not in the installer); the initramfs and image did.

`REPRO_FRESH=1 ./build repro` forces the rebuilds instead of reusing what nix
already has.

## Flake outputs (what `./build` calls)

```sh
nix build .#nest-ondevice            # static armv7-soft-float-musl server (any system)
nix build --impure .#firmware        # uImage with the server embedded   (Linux only)
nix build --impure .#initramfs       # the intermediate patched cpio       (Linux only)
nix build --impure .#nestQemuKernel  # same kernel+rootfs for qemu-system-arm
sh firmware/qemu-smoke.sh            # boot it under qemu and assert HTTP works
```

`.#firmware` needs the vendored GTVHacker checkout for the kernel, base
initramfs and 2008 ARM toolchain: the `NestDFUAttack` submodule, pinned to
upstream `exploiteers/NestDFUAttack` and read via `NEST_ATTACK_DIR`. It carries
no patches of ours — see `firmware/README.md` for what the build changes at
runtime instead. `--impure` is required because
`firmware/default.nix` reads that variable with `builtins.getEnv`, which flakes
only honour under impure evaluation:

```sh
export NEST_ATTACK_DIR=$PWD/NestDFUAttack
nix build --impure .#firmware
```

## The two build hosts

| Host | What runs | Notes |
|---|---|---|
| Linux / NixOS amd64 | `bin/nix-build.sh` in place | The i686 2008 toolchain runs **natively** (x86_64 kernels emulate i386), so a full kernel build is ~30 s. A case-sensitive FS means the submodule checks out cleanly, but the kernel is still re-materialised from git so the input is exactly the tracked tree. |
| macOS (Apple silicon) | `bin/container.sh` → NixOS VM → `bin/nix-build.sh` | nix on macOS is `*-darwin`: it can evaluate foreign drvs and substitute cached ones but can never run a Linux builder. The VM's `/nix` persists, so iteration only rebuilds what changed; the toolchain runs under `qemu-i386` (~4 min) and `Dev/linux` is re-archived case-exactly on the host (APFS collapses `xt_HL.c`/`xt_hl.c`). |

Both paths end in the same script with the same inputs, which is what makes the
checksums comparable. `bash bin/container.sh` lists the lower-level verbs
(`run|start|wait|log|exec|status|path|stage|vm|stop`); `NEST_DETACH=1
./build firmware` starts a container build without waiting.

## Repository layout

```
flake.nix                     # deps + packages (Rust server, firmware, initramfs)
build                         # THE build command (native on Linux, container on macOS)
bin/
  nix-build.sh                # the real build: nix + artifacts + manifest (both hosts)
  container.sh                # Apple-container NixOS VM lifecycle (the macOS builder)
  repro-check.sh              # rebuild under each host difference, compare sha256
firmware/
  default.nix                 # kernel + qemu-i386 toolchain wrappers + uImage
  mkcompile_h                 # deterministic replacement for the kernel's build identity
  inject_initramfs.py         # archive-level server injection + rootme patch
  rootfs-install.sh           # what runs on the device: the persistent half of the image
  nosleep.init                # /etc/init.d/nosleep — keeps suspend off (trap 14)
  nest-ondevice.init          # on-device /etc/init.d script
  test-image.sh               # runs both on-device halves against fixtures
  qemu-smoke.sh               # boot the image under qemu-system-arm
  README.md                   # build/flash notes, determinism, constraints
nest-ondevice-server/         # the Rust server
hubitat/
  apps/, drivers/             # Hubitat Groovy we run (vendored + patched)
  push.sh                     # push them to the hub over its REST API
  README.md                   # hub install/control/rename procedures
docs/nest-ondevice-protocol-research.md
```

`NestDFUAttack/` is a **submodule** pinned to an upstream commit and tracked
via `.gitmodules` (run `git submodule update --init` after cloning). The other
upstream trees (`NoLongerEvil-SelfHosted/`, `NoLongerEvil-Thermostat/`,
`hubitatcontrol/`) are git-ignored sibling checkouts used only as references;
none are flake inputs. The build reads `NestDFUAttack/` via `NEST_ATTACK_DIR`
(directly on Linux, staged into the VM on macOS).
