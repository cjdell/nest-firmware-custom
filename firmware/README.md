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

## The 2008 toolchain is i686 — so it runs under qemu-i386

`NestDFUAttack/Dev/toolchain/arm-2008q3` is a 32-bit **x86** (i686) CodeSourcery
toolchain. That no longer runs on modern machines: Apple-container/Rosetta
executes `x86_64` but **not** `i686` (`Exec format error`), and an `amd64`
container has no `ld-linux.so.2`. So the toolchain is executed under
`qemu-i386`, with the i386 glibc/zlib/ncurses it links against coming from
`pkgsCross.gnu32`.

`firmware/default.nix` copies the toolchain into a writable tree and replaces
every program the driver may exec (`gcc`, `cc1`, `collect2`, `as`, `ld`, …) with
a native wrapper:

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

1. copies every existing entry byte-for-byte,
2. adds `/usr/bin/nest-ondevice` and `/etc/init.d/nest-ondevice`,
3. patches `/etc/init.d/rootme` — the script that installs persistent files to
   `mtdblock7` — **before** it runs `umount /tmp/1`, so the server is copied to
   the flash and `${INITDIR}/nest-ondevice start` is appended to `rcS`.

The kernel's `CONFIG_INITRAMFS_SOURCE="../initramfs_data.cpio"` then embeds the
patched cpio, and `mkimage` produces the `uImage`.

At runtime `nest-ondevice` listens on the device port (default 8000) and the
control port (default 8082) with state under `/media/data/nest-ondevice`; see
`../nest-ondevice-server/README.md`.

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

On any Linux host with Nix:

```sh
NEST_ATTACK_DIR=$PWD/NestDFUAttack ./bin/macos/vm-build.sh firmware
nix build .#firmware          # from an aarch64-linux / x86_64-linux host
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
