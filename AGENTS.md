# AGENTS.md — nest: self-hosted Nest thermostat server + firmware

**What this repo is.** A compact Rust port of the NoLongerEvil Nest-protocol
server (`nest-ondevice-server/`), sized to run *on the thermostat itself*, plus
a Nix flake that cross-compiles it and bakes it into a flashable `uImage`
(`firmware/`). The device is pointed at `127.0.0.1` (Option A in the research
doc), so the thermostat is self-contained and Hubitat talks to it on the LAN.

**Repo state (2026-10-13).** Committed, and **now running on real hardware** — a
2nd-gen UK/Heat-Link unit, serial `02AA01AC2614065C`, flashed over the OMAP3
BootROM DFU path. `NestDFUAttack/` is pinned as a git submodule at upstream
`exploiteers/NestDFUAttack` and carries **no patches of ours** — every change we
make to it happens to a copy at build time (trap 22) — so the gitlink is still
upstream's only commit, 930b834b (`ignore = dirty` because a macOS checkout
collapses its case-only paths). The build is green, the
image embeds the server, and the whole path (flash -> first-boot install -> app
talks to `127.0.0.1:8000` -> Hubitat can reach `:8082`) has been validated on
hardware. Four on-hardware bugs/behaviours were found and fixed (traps 11-14):
suspend is now disabled persistently, so the LAN server stays reachable (remote
reboot caveat: trap 15) — and those last two fixes are now **part of the image**
(`firmware/rootfs-install.sh`, exercised by `./firmware/test-image.sh`), so a
fresh flash needs no hand-editing; the unit at `.2` keeps its hand-applied copy.
Hubitat is installed at `192.168.1.3` (driver id 940,
device 16 label `Hallway Thermostat`), and the Nest now sits on the reserved
`192.168.1.2` — see `hubitat/README.md` and traps 16-17.

**Tidy-up (2026-10-14).** The Hubitat app/driver we run are **vendored and
patched in this repo** under `hubitat/` (tracked); `hubitat/push.sh` is how they
go onto the hub. The `NoLongerEvil-Hubitat/` sibling checkout — Docker
Compose, Hubitat Package Manager manifest, mDNS advertiser, `DEPLOY.md` — was
deleted: it all assumes a separate Docker/Python server, which we rejected when
we chose to run our own Rust server on the device (traps 10, 19).

Read this file, then `README.md`, then `firmware/README.md` if building images,
then `docs/nest-ondevice-protocol-research.md` for the protocol rationale.

## Doc map (source of truth, newest wins)

| Topic | File |
|---|---|
| Protocol, bucket semantics, Option A rationale | `docs/nest-ondevice-protocol-research.md` |
| **On-device observability (`/debug/*`, syslog, monit, Dropbear, UART)** | `firmware/README.md` § "Observability on the device" + `nest-ondevice-server/README.md` § "/debug/*" |
| **Hubitat: the Groovy we run + install/REST procedures (driver fixes, endpoints, rename)** | `hubitat/` (`apps/`, `drivers/`, `push.sh`) + `hubitat/README.md` |
| Server behaviour / control API / flashing-lite notes | `nest-ondevice-server/README.md` |
| **Firmware build constraints + traps + verification** | `firmware/README.md` |
| Top-level build/entry points | `README.md` |

## Hard constraints (do not fight these)

| Constraint | Consequence |
|---|---|
| Nest = ARMv7 Cortex-A8, **soft-float EABI** (`ld-linux.so.3`), Linux **2.6.37**, 64 MiB RAM | Target triple is `armv7-unknown-linux-musleabi` (**not** `…eabihf`). Static musl. Server is `std`, no tokio, small-stack threads; ARM binary ≈ 804 KB (735 KB before `panic = "unwind"`; ~624 KB before the `/debug/*` surface). On-device RSS ≈ 0.5-0.7 MB, measured with `/debug/status` (`proc.rss_kb`). |
| Kernel is GTVHacker's 2.6.37 in `NestDFUAttack/Dev/linux` | Any kernel change must survive `make ARCH=arm gtvhacker_defconfig` + the 2008 toolchain. |
| Cross toolchain `NestDFUAttack/Dev/toolchain/arm-2008q3` is **i686** (32-bit x86) | It cannot run natively on modern hosts. See traps. |
| `CONFIG_INITRAMFS_SOURCE="../initramfs_data.cpio"` (`gtvhacker_defconfig:81`) | The initramfs is the injection point; the server lands at `/usr/bin/nest-ondevice`. |
| macOS APFS is **case-insensitive** | The kernel git tree has 13 case-only collisions that get destroyed on checkout. See traps. |
| macOS `nix` is `*-darwin` | It can evaluate foreign drvs and substitute cached ones but can never **run** a Linux builder. |

## Build & verify

One entry point, both hosts: `./build` runs nix directly on Linux and drives the
Apple-container NixOS VM on macOS. Both call the same `bin/nix-build.sh`, and
the image is **bit-reproducible**, so the two hosts must print the same sha256.

```sh
git submodule update --init NestDFUAttack   # fresh clone only

./build firmware     # -> dist/uImage (+ .sha256, .manifest)
./build server       # -> dist/nest-ondevice (static armv7 musl binary)
./build initramfs    # -> dist/initramfs.cpio
./build all          # all three
./build qemu         # boot under qemu-system-arm (RealView PB-A8), assert HTTP
./build test         # the on-device half of the image, against fixtures
./build repro        # rebuild under every host-dependent difference; compare bytes
./build status       # dist/ listing + checksums
./build shell        # nix develop (cargo + python)
```

Lower level, when you need it:

```sh
# --impure is required because firmware/default.nix reads NEST_ATTACK_DIR with
# builtins.getEnv and flakes default to pure evaluation.
export NEST_ATTACK_DIR=$PWD/NestDFUAttack
nix build --impure .#firmware            # -> uImage in the store
nix build --impure .#initramfs           # -> initramfs.cpio
./firmware/test-image.sh                 # the on-device half, against fixtures
nix build .#nest-ondevice                # server only, any system
NEST_SRC=$PWD NEST_OUT=$PWD/dist NEST_ATTACK=$attack sh bin/nix-build.sh firmware

# On a Mac: the container VM, driven by hand
bash bin/container.sh run firmware       # stage + build + wait (what ./build does)
bash bin/container.sh start firmware     # detached; then wait|log|status|vm|stop
bash bin/container.sh exec sh -c 'nix --version'   # one command in the VM

# Server smoke test (host build)
cargo build --release --manifest-path nest-ondevice-server/Cargo.toml
SERVER_PORT=18000 CONTROL_PORT=18082 API_ORIGIN=http://127.0.0.1:18000 \
  DATA_DIR=/tmp/nest-test-data ./nest-ondevice-server/target/release/nest-ondevice &
python3 nest-ondevice-server/test_smoke.py
```

**Verified reproducible build (2026-10-14).** Native x86_64-linux
(`zen3-nixos`), `./build repro`: `uImage` sha256
`123bd52b0fea673248981f1100eaf576e432894e039f9581bca7fcaa48ea24cf`, 7,298,616
bytes, ~**30 s** per build with the native
i686 toolchain (~4 min under `qemu-i386`, which produces the same bytes).
Before the determinism work two builds of the *same* tree on this machine
differed in 381,517 bytes and in length (the build clock reaches vmlinux via
`UTS_VERSION` and via the gzip'd `.config` that `CONFIG_IKCONFIG` embeds) — see
trap 20 and `firmware/README.md` § "Reproducible images".

The banner in a reproducible image is
`Linux version 2.6.37 (nest@ondevice) (gcc version 4.3.2 (Sourcery G++ Lite 2008q3-72) ) #1  PREEMPT 1970-01-01 00:00:00 UTC`.

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

## On-device operations (SSH, reboot)

The unit is at `192.168.1.2` (DHCP reservation on the Vodafone router — traps
16-17; re-check) and accepts **password** SSH as `root` only, and has **no
`scp`/`sftp`** — stream files over stdin. The password is a diagnostic one baked
into `firmware/inject_initramfs.py`; remove it before a "production" flash.

```sh
SP=$(nix build --print-out-paths nixpkgs#sshpass)/bin/sshpass
nssh() { $SP -p nestpass ssh -o StrictHostKeyChecking=no \
    -o PreferredAuthentications=password -o PubkeyAuthentication=no \
    root@192.168.1.2 "$@"; }
cat local.bin | nssh 'cat > /usr/bin/x && chmod 755 /usr/bin/x'
```

If SSH/HTTP times out the display is asleep — **touch the screen to wake it**,
then retry. (Suspend is now disabled, trap 14, so this should not recur.)

### Rebooting remotely (read trap 15 first)

```sh
nssh '/sbin/reboot'      # graceful: busybox init runs /etc/init.d/rcH
nssh '/sbin/reboot -f'   # force: sync() then reboot(2), skips rcH — escape hatch
```

Confirm the reboot by watching ICMP drop then return (boot is ~40 s) and
checking `uptime` is ~0 min. A still-answering `ping` does **not** mean "not
rebooting": `rcH` can sit in a retry backoff for ~6 minutes while the network is
still up (trap 15). If a graceful reboot stalls, use `/sbin/reboot -f`, or kill
the hung `/bin/sleep` child of the running `/etc/init.d/nlsleep stop` so its
backoff loop breaks and `rcH` continues.

## Hubitat integration (installed 2026-10-13)

The hub is `Brenda's Hub` at **`192.168.1.3`** (static — trap 17), firmware
**2.5.2.135**, temperature scale **°C**. The NoLongerEvil Connect app (id 210,
instance 28) and thermostat driver (id 940) are installed, and the thermostat
device (id 16, DNI `nolongerevil-02AA01AC2614065C`, label `Hallway Thermostat`)
is paired to the on-device server at `http://192.168.1.2:8082`. **Bidirectional
control is proven**: `setHeatingSetpoint` from the hub moved the Nest's
`target_temperature`. The driver needed two upstream fixes (an illegal Groovy
GString; and heat-only units must also publish `coolingSetpoint` or the Hubitat
Google Home app rejects them — trap 18). Full install, endpoint, rename, Google
Home and network procedures are
in **`hubitat/README.md`**.

## Traps already paid for (read before changing the build)

1. **The 2008 toolchain is i686.** On **x86_64 Linux** the kernel has
   `CONFIG_IA32_EMULATION`, so `firmware/default.nix` rewrites every i686 ELF's
   interpreter/RPATH to the store's i386 loader (`patchelf`) and runs it
   **natively** — the full kernel build is ~35 s. Everywhere else
   (aarch64-linux, macOS — Rosetta is x86_64-only → `Exec format error`, and an
   `amd64` container has no `ld-linux.so.2`) it falls back to **`qemu-i386`**
   with an i386 sysroot (`pkgsCross.gnu32` glibc/zlib/ncurses →
   `${qemu}/bin/qemu-i386 -L <root>`).

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
   `bin/container.sh` archives `Dev/linux` on the *host* with
   `git -C $attack archive HEAD Dev/linux` (case-exact: git reads the object
   DB, not the collapsed checkout), writes `$out/.attack-linux.tar`, and
   `bin/nix-build.sh` extracts it to `/tmp/nest-linux-fixed`, exporting
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
   **Preserve the device major/minor**: `header()` used to emit `0,0` for every
   entry, silently zeroing every `/dev` node. That is masked on-device by
   devtmpfs but fatal to an initramfs with no devtmpfs (breaks `/dev/console`).
   `parse()`/`emit()` now carry `rmaj`/`rmin` through.

7. **`nixpkgs-unstable` dropped `x86_64-darwin`** (26.11). `flake.nix`'s
   `systems` therefore omits it; `--all-systems` fails on it, not on us.

8. **Deprecated `stdenv.isLinux`** → use `pkgs.stdenv.hostPlatform.isLinux`.

9. **Doc edits must not rebuild the kernel.** The server `src` is filtered with
   `lib.fileset.toSource` (only `Cargo.toml`, `Cargo.lock`, `src/`), so editing
   a README no longer invalidates the ~3m40s kernel build. Keep it that way.

10. **The vendored trees are not flake inputs.** `NestDFUAttack/` is a pinned
    git submodule (`.gitmodules`); `NoLongerEvil-SelfHosted/`,
    `NoLongerEvil-Thermostat/` and `hubitatcontrol/` are git-ignored sibling
    checkouts kept only as references. All are read *impurely* via
    `NEST_ATTACK_DIR` (and `NEST_LINUX_DIR`). With them unset the flake still
    evaluates and `.#nest-ondevice` builds, so a fresh clone only needs
    `git submodule update --init` before `.#firmware`. The Hubitat app/driver
    are **not** part of this scheme any more — they are tracked under `hubitat/`
    (trap 19).

11. **`rootme`'s `/bin/sshconnect` blocks `rcS`.** The GTVHacker `rootme`
    appends `/bin/dropbear` and `/bin/sshconnect` to the *flash* `rcS`.
    `sshconnect` is a `while true; sleep 600` autossh loop that runs in the
    foreground, so every line after it — including the injected
    `${INITDIR}/nest-ondevice start` — never runs. `firmware/rootfs-install.sh`
    (embedded as `/etc/init.d/nest-ondevice-install`, called by rootme) now
    deletes `/bin/sshconnect`, de-dupes `/bin/dropbear`, and adds the monit
    include before appending the start line — `./firmware/test-image.sh` checks
    it. Symptom of the pre-fix image:
    Dropbear is up but nothing listens on `:8000`/`:8082`, and `rcS` (pid 56) is
    parked in `sleep`.

12. **The Nest app registers at `POST /entry`, not `/nest/entry`.** `nlclient`
    POSTs form data (`reset=false&mac=…&model=Display-2.8&…`) to
    `cloudregisterurl`, and only subscribes after that. The server advertises
    `cloudregisterurl = <origin>/entry` in `/info` and `/api/config`, but
    `nest.rs` only routed `/nest/entry`, so the app got a 404 loop and never
    subscribed (`subscriptions_total: 0`). Fixed: `/entry` is now an alias for
    `/nest/entry`.

13. **`String::truncate` panics on a UTF-8 boundary; `panic = "abort"` made it
    fatal.** `debug.rs` truncated the request-body snippet with
    `raw.truncate(MAX_SNIPPET)`; a non-ASCII body at that byte offset aborted the
    daemon (`assertion failed: self.is_char_boundary`). Now uses the existing
    char-safe `truncate()` helper, and the release profile switched to
    `panic = "unwind"` so one bad request can no longer take down the process.

14. **The display deep-slept; a persistent LAN server needed that disabled.**
    `nlsleepd` (`/etc/init.d/nlsleep`, supervised by
    `/etc/monit.d/nlscpm.monitrc`) set
    `/sys/kernel/debug/pm_debug/{enable_off_mode,sleep_while_idle,voltage_off_while_idle}=1`;
    the kernel then suspended to RAM when idle, the Wi-Fi radio went off, and the
    server was only reachable while the device was awake (`PM: Entering mem sleep`
    in dmesg). **Fixed and persisted on the flash root** (`/dev/root`, jffs2 —
    edits there survive reboot, no reflash needed):
    * `#DISABLED` the `nlsleepd` `check process` lines in
      `/etc/monit.d/nlscpm.monitrc` (kept `nlshutdownd`), then `monit reload`;
    * `#DISABLED` `${INITDIR}/nlsleep start` in `/etc/init.d/rcS`;
    * added **`/etc/init.d/nosleep`** (idempotent; mounts debugfs if needed) which
      writes the three knobs to `0`, called from `rcS` just before
      `nest-ondevice start`;
    then `sync`. Verified across a reboot: the knobs read `0/0/0`, `nlsleepd` is
    not running and is gone from `monit summary`, and `dmesg | grep -ci 'mem
    sleep'` is `0`. Removing `nlsleepd` from monit breaks the shutdown stop path
    — see trap 15.

    **Now part of the image** (2026-10-14): `firmware/rootfs-install.sh` does all
    of that during a flash and `firmware/nosleep.init` is the `/etc/init.d/nosleep`
    it installs, so a fresh unit needs no SSH. The unit at `192.168.1.2` still has
    the hand-applied version; the installer is idempotent and uses the same
    `DISABLED-by-nest-ondevice` markers, so re-flashing over it is fine. That
    image (`uImage` sha256 `123bd52b0fea…`, `./build repro` clean) is **not
    flashed yet** — the unit was unreachable off-site; check
    `/etc/nest-ondevice-install.log` on the flash root after the next flash.

15. **A "graceful" `/sbin/reboot` can hang ~6 minutes in `rcH`.** busybox init
    runs `::shutdown:/etc/init.d/rcH`, which calls `${INITDIR}/nlsleep stop`.
    That goes through `monit_service_action stop nlsleepd` in `/etc/init.d/dm`,
    whose retry loop sleeps `1,3,9,27,81,243` s (~364 s total) whenever
    `monit stop` returns non-zero. Once `nlsleepd` was removed from
    `/etc/monit.d/nlscpm.monitrc` (trap 14), `monit stop nlsleepd` *always*
    failed, so every shutdown stalled ~6 min with the network still up — it
    looked like "reboot does nothing". **Fixed** in `/etc/init.d/nlsleep`'s
    `stop)` case: if `pidof nlsleepd`, call `stop_nlsleepd` (direct KILL) instead
    of monit. Escape hatches for a stalled shutdown on a pre-fix image: `kill`
    the `/bin/sleep` child of the running `/etc/init.d/nlsleep stop` (the loop
    then hits its `retry == 5` break and `rcH` continues), or
    `ssh root@… /sbin/reboot -f` (sync + `reboot(2)`, skips `rcH`).

    **Now part of the image** (2026-10-14): `firmware/rootfs-install.sh` comments
    the `${INITDIR}/nlsleep stop` line in `rcH` rather than editing `nlsleep`'s
    `stop)` case — the installer cannot read `nlsleep` while it writes, and an
    `exit 0` inserted blind near its top would also end `rcH` if `rcH` sourced it.
    With `nlsleepd` unmonitored and never started there is nothing left for that
    call to stop. The hand-applied `/etc/init.d/nlsleep` edit on `192.168.1.2`
    stays and is harmless once the call is commented.

16. **The Vodafone router's static-DHCP "UPDATE" silently no-ops; use DELETE+ADD.**
    Router is a Vodafone Power Hub / Sagemcom at `http://192.168.1.1` (user
    `vodafone`). The LAN page `modals/settings/lan.lp` saves by posting
    `/modals/settings/lan.lp` with *every* LAN field plus a `tableRequest` JSON
    blob `{"ADD":[…],"UPDATE":[…],"DELETE":[…]}`. `UPDATE` is accepted but ignored
    by this firmware; a rule only changes if you `DELETE` the old row and `ADD`
    the new one. `DELETE` takes the **encrypted rule handles** (opaque
    `@B004C362…:@D340B691…` strings) read from
    `GET /home.lp?getAllStaticDHCPDevices=true&auto_update=true`
    (`deviceNameInfo:[{name,mac,ip}]`). The web backend rate-limits with `nginx
    503` after rapid probing — back off, don't hammer `/`. Login is SRP on
    `/authenticate` (not scripted); we drove it with a live `sessionID` cookie
    plus the `CSRFtoken` meta token from `GET /`, sent with
    `X-Requested-With: XMLHttpRequest`.

17. **A DHCP reservation does not take an IP away from a client already holding
    it.** After reserving Nest `18:B4:30:10:28:26`→`.2`, Hubitat
    `34:E1:D1:81:70:16`→`.3`, Watch `86:B2:3E:4E:C6:95`→`.10`, the hub kept
    coming up on its remembered `192.168.1.29`: this firmware honours the
    client's remembered lease while it is free, and the Watch still held `.3` on
    an **infinite** lease (it never renews, so it never moves). There is no
    lease-delete in the router UI/API. **Fix:** set the device's *own* static IP
    so it stops asking for the stale one — `GET
    /hub/advanced/switchToStaticIp?address=192.168.1.3&netmask=255.255.255.0&gateway=192.168.1.1&nameserver=192.168.1.1`
    (endpoint in `hubitat/README.md`). The hub then owned `.3` and the Watch
    moved off to its reserved `.10`. The router reservation stays and now agrees
    with the hub's static IP. Current map: Nest `.2`, Hubitat `.3`, Watch `.10`.

18. **A heat-only thermostat is invisible to Google Home until it publishes
    `coolingSetpoint`.** The Hubitat Google Home app reports a device as
    `googleHomeSupported` only when **every attribute of its capabilities is
    populated**; `capability "Thermostat"` includes `coolingSetpoint`, so a
    heat-only driver that only ever calls
    `sendEvent(name: "heatingSetpoint", …)` is reported *not compatible* and is
    **silently dropped from the Google Home device picker** (submitting it in a
    save does nothing). The built-in *Virtual Thermostat* is supported because it
    sets both setpoints; a copy that omits `coolingSetpoint` flips back to
    `googleHomeSupported=false`. Note a *custom* driver is fine (a hand-written
    user switch/thermostat with its attributes populated is accepted) — it is the
    missing attribute, not the user-driver-ness, that matters. Fix: also emit
    `coolingSetpoint` in the non-cool branch (the value is cosmetic — the Nest
    cannot cool). See `hubitat/README.md` § Google Home and
    `hubitat/drivers/nolongerevil-thermostat.groovy`.

19. **The Hubitat Groovy is vendored here; upstream's driver does not
    compile.** We keep `hubitat/apps/nolongerevil-connect.groovy` (byte-identical
    to upstream) and `hubitat/drivers/nolongerevil-thermostat.groovy` (upstream +
    the trap 18 fix + an **illegal-GString** fix: upstream's
    `replaceAll("/+$", "")` is a double-quoted GString, so the driver fails to
    compile at all). There is no separate `.patch` any more — the fixes are
    applied in the file, and `hubitat/README.md` records the pristine upstream
    sha256s. **Never re-import from upstream or paste hub-UI edits back over
    these files**; edit here and `./hubitat/push.sh driver`. Upstream's Docker
    Compose / Package Manager / mDNS-advertiser deploy path was deleted, not
    moved: the hub finds our server by probing `GET /api/config`, and the server
    runs on the thermostat.

20. **The kernel bakes its build identity into the image, and on 2.6.37 two
    knobs are not enough.** Before 2026-10-14 two builds of the *same* tree on
    the same machine differed in 381,517 bytes and in total length, because the
    clock reaches vmlinux by three routes: `UTS_VERSION` (`date` in
    `scripts/mkcompile_h`), the generated `.config` (`ctime()` in its header —
    `CONFIG_IKCONFIG=y` embeds it, gzip'd, which is why the *length* moved), and
    the uImage header `time` field (`mkimage`). Pinning
    `KBUILD_BUILD_TIMESTAMP` alone does not fix it: **2.6.37's `mkcompile_h` has
    no `KBUILD_BUILD_USER`/`_HOST`** (2.6.39 added them) so it shells out to
    `whoami`/`hostname`, and the `.config` stamp has no knob at all. So
    `firmware/mkcompile_h` *replaces* the kernel's generator (adds those knobs,
    defaults every one to a fixed value) and `firmware/default.nix` exports
    `KCONFIG_NOTIMESTAMP=1`, `SOURCE_DATE_EPOCH=0` (`mkimage` honours it — its
    `-t` is FIT-only), `KBUILD_BUILD_VERSION=1`, `TZ=UTC LC_ALL=C LANG=C`.
    `./build repro` then proves the bytes are also invariant across the axes the
    two hosts differ on: the container's `qemu-i386` toolchain path, `-j1`, the
    `git archive`d kernel, a forced rebuild. Keep `diffutils` in the firmware
    `nativeBuildInputs` (the replacement `mkcompile_h` uses `cmp`), and re-run
    the repro check after any nixpkgs bump — `xz`/`ubootTools`/`rust-bin`
    changes legitimately change the image.

21. **A stale host-side server makes the QEMU smoke test pass vacuously.**
    `firmware/qemu-smoke.sh` asserts over `127.0.0.1:18000`/`18082`, which qemu
    forwards *from the host* — so a leftover `SERVER_PORT=18000 … nest-ondevice`
    (the manual recipe in this file) answers every check while qemu sits there
    having printed `Could not set up host forwarding rule` and never bound a
    port. A whole run passed like that. The script now refuses to start if
    either port already answers; if you ever see five PASS lines with no guest
    dmesg in the log tail, that is what happened.

22. **We change the vendored tree without patching it, and `Dev/linux` edits in
    the checkout are silently ignored.** `NestDFUAttack/` stays at upstream
    930b834b with no commits of ours; the changes are applied to a *copy* at
    build time — `scripts/mkcompile_h` and the `timeconst.pl` Perl fix
    (`firmware/default.nix:222`, `:230`), the `realview` config toggles
    (`firmware/qemu.nix:89-100`), the initramfs injection
    (`firmware/inject_initramfs.py`), the toolchain wrappers
    (`firmware/default.nix:98-132`). The flashable config is `gtvhacker_defconfig`
    as shipped. The asymmetry bites: `bin/nix-build.sh` re-materialises
    `Dev/linux` with `git archive HEAD` (case-exactness + reproducibility), so an
    uncommitted kernel edit never reaches the build — whereas
    `Dev/initramfs_data.cpio` and `Dev/toolchain/arm-2008q3` are read straight
    from the checkout and take effect immediately. To try a kernel change: commit
    it in a fork and move the gitlink, or point `NEST_LINUX_DIR` at your own tree
    for a throwaway. A fork was made and dropped for exactly this reason — with
    no delta in it, it only added a place for the build to drift.

## Layout

```
flake.nix                     deps + packages (nest-ondevice, firmware, initramfs) + devShell
.gitmodules                   pins NestDFUAttack/ to upstream exploiteers/NestDFUAttack (unpatched)
firmware/
  default.nix                 qemu-i386 toolchain wrappers + kernel make + mkimage
  mkcompile_h                 deterministic replacement for the kernel's build-identity generator
  inject_initramfs.py         archive-level injection + rootme patch (order-sensitive)
  rootfs-install.sh           the persistent half of the image: what runs on the device (traps 5/11/14/15)
  nosleep.init                /etc/init.d/nosleep — clears the pm_debug suspend knobs (trap 14)
  nest-ondevice.init          on-device /etc/init.d script, installed to /usr/bin
  nest-ondevice.monitrc       monit supervision for the daemon
  test-image.sh               exercises both on-device halves against fixtures (no thermostat)
  qemu.nix, qemu-init.sh, inject_qemu_init.py, qemu-smoke.sh   RealView PB-A8 smoke test
  README.md                   constraints/traps/verify (the long form of this file)
nest-ondevice-server/         Rust server (src/, Cargo.*, test_smoke.py, deploy/)
hubitat/
  apps/, drivers/             Hubitat Groovy we run (vendored from upstream + patched)
  push.sh                     push them to the hub (app 210 / driver 940) over REST
  LICENSE.nolongerevil        MIT, upstream copyright (we vendor + modify)
  README.md                   hub deployment facts + reverse-engineered hub REST API
docs/nest-ondevice-protocol-research.md
build                         THE build command (dispatches native vs container)
bin/
  nix-build.sh                the real build: nix + artifacts + manifest (both hosts)
  container.sh                Apple-container NixOS VM lifecycle (macOS builder)
  flake-src.sh                filtered flake source (464 KB, not the 1.3 GB tree)
  repro-check.sh              rebuild under each host difference, compare sha256
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

* **Hubitat — done (2026-10-13).** NoLongerEvil Connect app (id 210, instance
  28) + thermostat driver (id 940) installed on the hub at `192.168.1.3`;
  thermostat device id 16 (label `Hallway Thermostat`) talks to
  `http://192.168.1.2:8082`; bidirectional control verified. Procedures and the
  driver GString fix are in `hubitat/README.md`.
* Calibrate the app's expected `structure.*`/`user.*` fields against captured
  real traffic, using the Python NoLongerEvil server as a differential oracle.
* Optional: shrink the firmware build by using a user-mode-only qemu instead of
  the full `pkgs.qemu` closure.
