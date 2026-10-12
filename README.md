# nest

Self-hosting for the Google Nest thermostat, built with Nix flakes.

Two pieces:

| Path | What it is |
|---|---|
| [`nest-ondevice-server/`](nest-ondevice-server/) | A compact **Rust** port of the NoLongerEvil Nest-protocol server, sized to run on the thermostat itself. |
| [`firmware/`](firmware/) | A **firmware image** (the GTVHacker `uImage`) that bundles that server into the initramfs. |

The protocol research and the design rationale live in
[`docs/nest-ondevice-protocol-research.md`](docs/nest-ondevice-protocol-research.md).

## Flake outputs

```sh
nix build .#nest-ondevice   # static armv7-soft-float-musl server (any system)
nix build .#firmware        # uImage with the server embedded   (Linux only)
nix build .#initramfs       # the intermediate patched cpio       (Linux only)
```

`.#firmware` needs the vendored GTVHacker checkout for the kernel, base
initramfs and 2008 ARM toolchain:

```sh
export NEST_ATTACK_DIR=$PWD/NestDFUAttack
nix build .#firmware
```

## Building on a Mac

`nix` on macOS cannot run a Linux builder, and the firmware build needs Linux
(`make`, `perl`, and an i686 cross toolchain under `qemu-i386`). `bin/macos/build.sh`
runs it in an Apple-container NixOS VM whose `/nix` persists between runs:

```sh
bash bin/macos/build.sh start firmware
bash bin/macos/build.sh wait  firmware    # 0 done, 1 failed, 2 still running
bash bin/macos/build.sh status            # artifacts + checksums
```

Artifacts (`uImage`, `nest-ondevice`, `initramfs.cpio`, manifests, checksums)
land in `~/.cache/nest-macos/out/`.

On a Linux host, `bin/macos/vm-build.sh` is the same build without the VM.

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

The vendored upstream trees (`NestDFUAttack/`, `NoLongerEvil-*`, `hubitatcontrol/`)
are git-ignored nested checkouts and are not part of the flake source.
