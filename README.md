# nest

Self-hosting for the Google Nest thermostat, built with Nix flakes.

Two pieces:

| Path | What it is |
|---|---|
| [`nest-ondevice-server/`](nest-ondevice-server/) | A compact **Rust** port of the NoLongerEvil Nest-protocol server, sized to run on the thermostat itself, with a read-only `/debug/*` observability API for agent/remote debugging. |
| [`firmware/`](firmware/) | A **firmware image** (the GTVHacker `uImage`) that bundles that server into the initramfs. |

The protocol research and the design rationale live in
[`docs/nest-ondevice-protocol-research.md`](docs/nest-ondevice-protocol-research.md).

## Flake outputs

```sh
nix build .#nest-ondevice            # static armv7-soft-float-musl server (any system)
nix build --impure .#firmware        # uImage with the server embedded   (Linux only)
nix build --impure .#initramfs       # the intermediate patched cpio       (Linux only)
nix build --impure .#nestQemuKernel  # same kernel+rootfs for qemu-system-arm
bash firmware/qemu-smoke.sh          # boot it under qemu and assert HTTP works
```

`.#firmware` needs the vendored GTVHacker checkout for the kernel, base
initramfs and 2008 ARM toolchain. It is the `NestDFUAttack` submodule, pinned
to an upstream commit:

```sh
git submodule update --init NestDFUAttack   # fresh clone only
export NEST_ATTACK_DIR=$PWD/NestDFUAttack
nix build --impure .#firmware
```

`--impure` is required: `firmware/default.nix` reads `NEST_ATTACK_DIR` with
`builtins.getEnv`, which flakes only honour under impure evaluation.

## Building on Linux (primary)

On a case-sensitive Linux filesystem the submodule checks out cleanly — both
`xt_HL.c` and `xt_hl.c` exist — so nothing special is needed beyond Nix with
flakes enabled:

```sh
git submodule update --init NestDFUAttack   # fresh clone only
NEST_ATTACK_DIR=$PWD/NestDFUAttack nix build --impure .#firmware
```

For the artifact + manifest + checksum workflow, `bin/macos/vm-build.sh` also
runs natively on Linux (despite the directory name):

```sh
NEST_ATTACK_DIR=$PWD/NestDFUAttack ./bin/macos/vm-build.sh firmware
```

## Building on a Mac (alternative)

`nix` on macOS cannot run a Linux builder, and the firmware build needs Linux
(`make`, `perl`, and an i686 cross toolchain under `qemu-i386`). `bin/macos/build.sh`
runs it in an Apple-container NixOS VM whose `/nix` persists between runs:

```sh
bash bin/macos/build.sh start firmware
bash bin/macos/build.sh wait  firmware    # 0 done, 1 failed, 2 still running
bash bin/macos/build.sh status            # artifacts + checksums
```

Artifacts (`uImage`, `nest-ondevice`, `initramfs.cpio`, manifests, checksums)
land in `~/.cache/nest-macos/out/`. The macOS path re-materialises the kernel
case-exactly (see `firmware/README.md`); Linux never needs that.

## Repository layout

```
flake.nix                     # deps + packages (Rust server, firmware, initramfs)
firmware/
  default.nix                 # kernel + qemu-i386 toolchain wrappers + uImage
  inject_initramfs.py         # archive-level server injection + rootme patch
  nest-ondevice.init          # on-device /etc/init.d script
  README.md                   # build/flash notes and constraints
bin/macos/
  build.sh                    # Mac driver: stage + Apple-container VM
  vm-build.sh                 # the actual build (runs inside the VM)
nest-ondevice-server/         # the Rust server
docs/nest-ondevice-protocol-research.md
```

`NestDFUAttack/` is a **submodule** pinned to an upstream commit and tracked
via `.gitmodules` (run `git submodule update --init` after cloning). The other
upstream trees (`NoLongerEvil-*`, `hubitatcontrol/`) are git-ignored sibling
checkouts used only as references; none are flake inputs. The build reads
`NestDFUAttack/` via `NEST_ATTACK_DIR` (directly on Linux, staged into the VM
on macOS).
