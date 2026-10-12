# Nest on-device protocol research

**Question:** can we put a custom control protocol *on the Nest thermostat itself*
(so the device is self-contained and e.g. Hubitat can talk to it directly on the
LAN), instead of requiring a separate NoLongerEvil server?

**Date:** 2026-10-12
**Source clone:** `NestDFUAttack` (shallow, 2.0 GB)
**Also relevant:** `NoLongerEvil-Thermostat` (builder + installer)

---

## TL;DR

**Feasible, but not proven.** The Nest runs a real ARM Linux userland and already
contains several local IPC surfaces. The most robust route — **run the
NoLongerEvil/Nest-protocol server on the device itself and point the thermostat
app at `127.0.0.1`** — is technically viable and is the only route that truly
removes the external server. There are also two cheaper shortcuts (D-Bus bridge,
built-in Lua bot) that could give a quick prototype.

The main blocker for all app-level work: **`nlclient` (the thermostat app) is
proprietary and is *not* in the open NestDFUAttack dump.** It lives on the NAND
rootfs (`mtdblock7`). Everything about its internal interfaces must be confirmed
by dumping that partition from a rooted device.

| Route | Effort | Robustness | Meets "no external server" | Evidence status |
|---|---|---|---|---|
| **A. On-device protocol server** (port NLE server to C) | High | High | ✅ yes | Platform confirmed; protocol port needed |
| **B. D-Bus bridge** to `nlclient` | Low–Med | Medium | ✅ yes | Interface existence confirmed; methods unknown |
| **C. Built-in Lua bot** on TCP :8000 | Low | Low (UI automation) | ✅ yes | Code present; disabled by default |
| **D. State-file bridge** | Low | Low (mostly read-only) | ✅ yes | Files present; format partially known |

**Hard constraint:** the thermostat has only **64 MiB of RAM** (confirmed in the
x-loader/U-Boot/kernel board files — see §1). Any on-device server must be a lean
C implementation; the existing Python server cannot be used. See the RAM budget
in §1 before committing to Option A.

---

## 1. Platform

| | |
|---|---|
| SoC | TI OMAP3630 (ARMv7, Cortex-A8), Nest Gen 1 / Gen 2 |
| Kernel | **Linux 2.6.37** ("Flesh-Eating Bats with Fangs") — `NestDFUAttack/Dev/linux/Makefile` |
| Userland | BusyBox 1.x + select GNU tools; JFFS2 rootfs |
| Toolchain | `arm-2008q3` (`arm-none-linux-gnueabi-gcc`), bundled at `NestDFUAttack/Dev/toolchain/arm-2008q3` and used by the NLE builder |
| Scripting | No standalone `lua`/`python`/`perl` in the initramfs. `nlclient` embeds a Lua interpreter (see §4b) |
| Useful binaries present | busybox/busybox2, `curl`, `openssl`, `rsync`, `dbus-daemon`, `dbus-send`, `dbus-monitor`, `avahi-daemon`, `iptables`, `ip`, `wpa_supplicant`, `dropbearmulti` (NLE/rootme adds it) |

The kernel version matters later: any on-device binary must be built for ARMv7 +
old glibc with the 2008q3 toolchain (or be a static binary that avoids modern
syscalls).

### RAM budget — 64 MiB total (the binding constraint)

Hardware-confirmed, from multiple independent files:

- `Dev/x-loader/include/configs/diamond.h:185` → `#define CFG_SDRAM_SIZE_MB 64`
- `Dev/x-loader/include/configs/j49.h` (UK/EU board) → also **64 MiB**
- `Dev/u-boot/include/configs/diamond.h` → "Samsung K4X51163PI-FCG6 **64 MiB** DDR SDRAM"
- `Dev/linux/arch/arm/mach-omap2/board-diamond.c:16` → "512 Mb x 16 (**64 MiB**)"
- `Dev/x-loader/board/nest/diamond/mux.c:73-100` → interfaced **16-bit**;
  `SDRC_DATA[31:16]` explicitly muxed as **unused** ⇒ **one** 512 Mb x16 chip on CS0,
  not two.

The part is a single Samsung K4X51163PI-FCG6 (or Nanya NT6D) 512 Mbit x16 =
**64 MiB**. There is no second bank. Storage (256 MiB NAND, 46 MiB rootfs) is
**not** RAM.

Reservations: ~1 MiB framebuffer (double-buffered 320x320x4, rounded to 512 KiB).
No swap. So the kernel sees ~63 MiB.

Rough boot budget (to be confirmed empirically on a rooted unit):

| Consumer | Est. RSS |
|---|---|
| Linux 2.6.37 + modules | 8–12 MB |
| busybox/init, dbus-daemon, connman, wpa_supplicant, avahi, monit, watchdogd | 10–20 MB |
| `nlclient` (embedded Lua, DSS, learning, state) | 15–30 MB |
| **Free / reclaimable** | **~5–15 MB** |

Implications for the options in §5:

- **Option A** must be a **single-threaded C** server (`select`/`poll`), HTTP only
  (the app↔localhost hop needs no TLS), no embedded scripting. Realistic RSS is
  ~1–3 MB — it fits, but the margin is thin.
- Option B (D-Bus CGI) ~1 MB; Option C (Lua bot) adds ~0 because it runs *inside*
  `nlclient`'s existing interpreter; Option D is trivial.
- **Python is not viable** — the runtime alone would eat most of the headroom.
  Same for Node/Go. (Note the stock NoLongerEvil server is Python, so it cannot
  simply be copied onto the device.)

Risks:

- The **OOM killer** typically targets the largest process — often `nlclient`.
  Killing the app can blank the thermostat and trigger a reset via the hardware
  watchdog (`watchdogd`). A self-hosted server competing for RAM is a genuine
  availability risk.
- No swap; a zram/swap file on `/media/scratch` is possible but slow and wears
  NAND.
- `nlclient`'s own usage fluctuates (learning, history, weather, graphics).

Measure before committing (rooted unit):

```sh
free
cat /proc/meminfo
top -b -n1
cat /proc/$(pidof nlclient)/status | grep -E 'VmRSS|VmSize'
```

**Verdict:** the hardware has enough RAM for a *lean* on-device C server, but not
for the existing Python server or any runtime-based port. Confirm real headroom
before building Option A.

---

## 2. Firmware layout and boot model

There are **two** Linux images, and this is the key to why the app is missing
from the open dump:

1. **Embedded initramfs** (`uImage`, ~20 MB `initramfs_data.cpio`). This is the
   early/provisioning environment. It contains BusyBox, D-Bus, avahi, connman,
   the init scripts, `client.config`, and the **GTVHacker `rootme`** exploit. It
   does **not** contain `/nestlabs` or `nlclient`.
2. **NAND rootfs** (`/dev/mtdblock7`). This is the *real* root filesystem with
   `/nestlabs/sbin/nlclient`, the app's libs, images, and the full
   `monit`/`dbus` service tree. **It is not included in NestDFUAttack.**

Boot flow (initramfs): BusyBox `init` → `/etc/init.d/rcS`:

```
rootme           # mounts mtdblock7, patches it, copies busybox2/dropbear, reboot
announce start
start            # early mount/setup
watchdog start
hwclock restore
timezone check
sysctl start
```

`rootme` (see `NestDFUAttack/Dev/root/etc/init.d/rootme`) mounts
`/dev/mtdblock7`, injects `busybox2`, `autossh`, Dropbear, a root hash, and
re-append lines to `mtdblock7:/etc/init.d/rcS`, then reboots. After reboot the
device runs the patched `mtdblock7` rootfs — that is where `nlclient` and the
real service graph live.

The NoLongerEvil builder (`firmware/builder/build.sh`) generates a richer
`rootme` that additionally:

- rewrites `<a key="cloudregisterurl" …>` in `mtdblock7:/etc/nestlabs/client.config`,
- embeds the NoLongerEvil CA cert in `/etc/ssl/certs/ca-bundle.pem`,
- optionally enables root/Dropbear,
- installs the `nleapi` init script + BusyBox `httpd` on **:8080** + the
  `settings`/`update`/`version` CGIs, and appends `${INITDIR}/nleapi start` to
  `mtdblock7:/etc/init.d/rcS`.

**Crucial:** NLE never replaces `nlclient`. The thermostat logic is always the
stock proprietary app; NLE only edits its config and bolts on a small web API.

### Partition table (from `Dev/root/etc/fstab` + `rootme`)

| Device | Mount | Contents |
|---|---|---|
| `mtdblock7` | (root) | Real rootfs, `/nestlabs` (app), full init |
| `mtdblock10` | `/media/system-config` | `environment.plist`, monit state, NVS, ntp drift, ssh |
| `mtdblock11` | `/media/user-config` | `settings.config` (user settings), connman |
| `mtdblock12` | `/media/data` | scratch/state (`tempscreenoutput`, recovery files) |
| `mtdblock13` | `/media/log` | logs |
| `mtdblock14` | `/media/scratch` | scratch / OTA staging (`softwareupdatepath`) |

Also, `monitrc` runs an internal HTTP daemon on **127.0.0.1:2812** (localhost
only) for IPC.

---

## 3. Open vs proprietary

Nest's official open-source release
(`https://nest-open-source.googlesource.com/nest-learning-thermostat/5.9.4/`)
covers third-party packages only: `busybox`, `avahi`, `connman`, `bluez`,
`alsa-lib`, `alsa-utils`, `cypress-fmac-driver`, `wpa_supplicant`, `6tunnel`,
`beep`, etc. Plus the kernel/U-Boot/x-loader.

**Not open:** `nlclient`, `nlheartbeatd`, `nlscpmd`, `osm`, the Lua bots, and the
UI assets. Those are the parts that hold thermostat state.

---

## 4. Existing on-device interfaces (inventory)

### 4a. System D-Bus — `com.nestlabs.nlclient` (most promising for a bridge)

D-Bus policies in `Dev/root/etc/dbus-1/system.d/`:

- **`com.nestlabs.nlclient`** — owned by `nlclient`; **root-only** send.
  ```
  <policy user="root">
      <allow own="com.nestlabs.nlclient"/>
      <allow send_destination="com.nestlabs.nlclient"/>
      <allow send_interface="com.nestlabs.nlclient"/>
  </policy>
  <policy context="default"><deny send_destination="com.nestlabs.nlclient"/></policy>
  ```
- **`com.nestlabs.nlheartbeat`** — owned by `nlheartbeatd` (root-only).
- **`com.nestlabs.scpm`** — power management. Known object/method from
  `etc/init.d/scpm`:
  - service `com.nestlabs.scpm`
  - object path `/com/nestlabs/scpm/manager`
  - interface `com.nestlabs.scpm.main` (method `Quit` used to stop the daemon)
  - also referenced: `com.nestlabs.czsniffer.main`, `com.nestlabs.scpm.debug`

`etc/nestlabs/nlheartbeat.plist` shows the watchdog contract: `nlheartbeatd`
watches `nlclient` expecting periodic **"Unsolicited"** signals from
`com.nestlabs.nlclient`; on timeout it runs `/etc/init.d/nestlabs kill`.

**Unknown:** whether `com.nestlabs.nlclient` exposes thermostat getters/setters
(target temp, mode, away, humidity…). It may only be a heartbeat/watchdog
interface. This is the single most valuable thing to introspect (see §6).

Why it's attractive: the existing `nleapi` httpd already runs as **root**, and
the policy explicitly allows root to talk to `com.nestlabs.nlclient`. So a new
CGI could bridge D-Bus ↔ HTTP with no new privileges.

### 4b. Built-in Lua bot on TCP :8000 — present but disabled

`Dev/root/etc/nestlabs/bots/launcher.lua`:

```lua
local socket = require('socket')
local server = assert(socket.bind("*", 8000))   -- binds ALL interfaces
...
line = client:receive()
pcall(wrapper, loadstring("return ".. line), client)   -- arbitrary Lua execution
```

It runs inside `nlclient`'s embedded Lua interpreter, with the Lua standard
library (`io`, `os`, `socket`) **and** C functions the app exposes to Lua:
`click`, `clickDown`, `clickUp`, `rotateDial`, `jumpToScreen`, `showScreen`,
`hideScreen`, `sleep`, `logDebug`.

`Dev/root/etc/nestlabs/bots/sapphire_helper.lua` builds helpers on top:

- `getTargetTempC()` / `getCurrentTempC()` — parse
  `/media/data/tempscreenoutput` (`target:<int>` / `current:<int>`, value =
  `int / 2^16`)
- `setTemp(old,new,mode)`, `switchMode(mode)`, `setAwayLowTemp(s)`,
  `checkTargetTempChanged(...)`, `scrollTemp`, `scrollDegrees`, etc. — these
  drive the dial/UI rather than a state API.

Control flags in `Dev/root/etc/nestlabs/client.config`:

```xml
<a key="enablebotautomation"  value="0"/>
<a key="botscript"            value="/nestlabs/etc/bots/launcher.lua"/>
<a key="tempscreenoutput"     value="/nestlabs/var/data/tempscreenoutput"/>
<a key="enabletempscreenoutput" value="0"/>
<a key="debug"                value="0"/>
```

**Verdict:** setting `enablebotautomation=1` + `enabletempscreenoutput=1` would
give an unauthenticated root-level Lua REPL on the LAN. Great for a quick
prototype; terrible security; UI-timing-dependent and not a stable protocol.

### 4c. `controlserver` on `localhost:8080`

`Dev/root/etc/nestlabs/client.config`:

```xml
<a key="controlserver"     value="localhost"/>
<a key="controlserverport" value="8080"/>
```

Unknown whether `nlclient` *connects to* or *listens on* this. It is present in
the simulator-oriented base config. Note the NLE firmware already binds a
BusyBox `httpd` to :8080, so any app use of :8080 would collide — worth
verifying with `netstat` on a live device.

### 4d. `nleapi` web API (the NoLongerEvil bolt-on)

BusyBox `httpd` on **:8080**, docroot `/var/www`, running as **root**. CGIs:

- `/cgi-bin/api/settings` — GET returns current `cloudregisterurl`; POST with
  `api_key` + `endpoint` rewrites `client.config` and restarts `nestlabs`.
  (Also has a first-boot 30-minute setup window.)
- `/cgi-bin/update`, `/cgi-bin/version`.

This is the natural place to host a new bridge CGI (D-Bus or file based).

### 4e. State files

- `/nestlabs/etc/user/settings.config` → `/media/user-config` (mtdblock11): user
  settings XML (`settingsfile` key).
- `/nestlabs/var/data/*.recovery`: `energystats`, `timetotemp`,
  `overundershoot`, `schedulemanager`, `smartthermostatmanager`,
  `schedulelearner`, `autoaway`, `sensorhistory`, `airwave`, `radiantcontrol`,
  `sunlightcorrection`, `usageestimator`, `tuneupmanager.json`, `tuneuplearner.json`,
  `drmanager.json`, `autodehum` (paths in `client.config`).
- `tempscreenoutput` (only when enabled): live current/target temps.
- `/nestlabs/etc/system/environment.plist` → `/media/system-config`.

Reads are feasible; writes are unreliable (app likely caches state in memory and
the cloud sync is authoritative).

### 4f. Other

- **avahi** userland + `etc/init.d/mdnsd` exist (`mdnsd.options` =
  `--daemonize --syslog`). Startup order wasn't in the initramfs `rcS`; on the
  real rootfs it may run. If so, the Nest could advertise an mDNS service that
  Hubitat could discover.
- **monit** internal HTTP on 127.0.0.1:2812 (localhost only).
- **dbus-daemon** system bus on the standard socket.

---

## 5. Feasibility of a custom on-device protocol

### Option A — run the Nest-protocol server on the device (recommended end state)

Idea: set `cloudregisterurl` to `http://127.0.0.1:<port>/entry` and run a small
server **on the Nest** that speaks the Nest device protocol. The app then talks
to localhost; the same process exposes a clean control API on the device's LAN
IP for Hubitat.

- Why it can work: the app already accepts **plain HTTP** `cloudregisterurl`
  (the installer and settings CGI set `http://<ip>:<port>/entry`), so no cert
  work is needed locally. The device is a real Linux box with sockets, and we
  already run a root `httpd` there.
- What must be implemented (subset of the NLE server):
  `/nest/entry`, `POST /nest/transport` subscribe (chunked, held open),
  `POST /nest/transport/put`, `GET /nest/transport/device/{serial}`,
  `/nest/passphrase`, `/nest/weather`, plus state buckets (`device`, `shared`,
  `structure`, `user`, `schedule`, …) and pairing/structure injection.
- Language: **C** built with the bundled `arm-2008q3` toolchain (no Python on the
  device; Go on kernel 2.6.37 is risky). Chunked long-poll is straightforward C.
- Persistence: `/media/data` (JFFS2) or `/media/scratch`.
- Pros: self-contained, no external server, keeps app semantics, exactly matches
  the control-API shape the Hubitat integration already targets.
- Cons: real implementation work; must get bucket/timestamp semantics right; the
  app is proprietary and may have quirks; NAND wear if too chatty.

### Option B — D-Bus bridge

If `com.nestlabs.nlclient` exposes thermostat methods/properties, add a CGI to
the existing root `httpd` that calls D-Bus and returns JSON. Lowest effort, if
the interface exists. Requires a `mtdblock7` dump + introspection first.

### Option C — Lua bot bridge

Enable `enablebotautomation`/`enabletempscreenoutput`, connect to TCP :8000, and
send Lua expressions (`getTargetTempC()`, `setTemp(...)`, `switchMode(...)`).
Fast to prototype, but UI-level automation, unauthenticated, binds all
interfaces, and timing-fragile. Not production.

### Option D — state-file bridge

Parse `tempscreenoutput`/`settings.config`/`*.recovery`. Mostly read-only and
fragile; not a control path.

---

## 5b. Engineering effort: porting the server to C

The reference implementation is the MIT-licensed Python server
(`NoLongerEvil-SelfHosted`, cloned alongside this repo). Sizing it:

| Area | LOC (Python) | Needed on-device? |
|---|---:|---|
| `routes/nest/` (device protocol; `transport.py` alone 1,012) | 1,571 | **Yes** — core |
| core services (state, subscriptions, availability) | ~1,169 | **Yes** — core |
| `sqlmodel_service.py` (SQLite ORM) | 1,073 | No — replace with simple store/file |
| `models/` + `converters.py` | 562 | Mostly no — ORM plumbing |
| middleware (`device_auth`, heartbeat, url_normalizer) | ~283 | Partly |
| control routes (`status`, `command`, …) | 1,829 | **status + command yes** (~1,150) |
| integrations/MQTT + HA discovery | 2,324 | **No** — HA-only |
| webui, debug logger, misc | ~570 | No |
| **Total** | **10,969** | **~4,500 relevant** |

### What a C port actually has to build

1. **HTTP/1.1 server with chunked, held-open responses** — `POST /nest/transport`
   returns `Transfer-Encoding: chunked` immediately and stays open (300–600 s),
   pushing state on change. This is the single defining requirement. Use
   `civetweb`, `mongoose`, or `libmicrohttpd`, or a hand-rolled `poll()` loop.
2. **Bucket store + merge semantics** — objects keyed by `(serial, object_key)`
   (`device.*`, `shared.*`, `structure.*`, `user.*`, `schedule.*`) with
   `object_revision` / `object_timestamp`; shallow merge
   (`{**old, **new}`); revision comparison to decide what to push.
3. **Subscription/notification manager** — per-device long-poll queues, push on
   change, re-subscribe window, buffer and replay on broken connections.
4. **`/nest/entry`** — trivial: returns the service URL map.
5. **`/nest/transport/put`** — apply device deltas into buckets and fan out.
6. **Structure/user injection** — the server creates/owns `structure.*` and
   `user.*` so the app believes it is paired and shows its UI. **This is where
   the app's undocumented expectations live and where schedule risk concentrates.**
7. **Control API** (`/status`, `/command`) — the Hubitat-facing surface; ~45
   whitelisted device fields, command→bucket mapping already documented in
   `routes/control/command.py` (e.g. `set_temperature`→`shared`, `set_fan`→`device`,
   `set_away`→`structure.manual_eco_all`).
8. **Persistence** (optional) — simple file or `sqlite3` C library.
9. **No TLS** — the app↔localhost hop uses HTTP. Skipping TLS saves weeks.
10. **No MQTT / HA discovery / web UI** — not needed for the on-device goal.

### C code volume

- Using `cJSON`/`yyjson` + an embedded HTTP library: **~3,500–6,000 LOC C** for a
  single-device minimal server (MVS).
- Hand-rolled HTTP: add ~1,500–3,000 LOC.
- Full parity with the Python server (pairing, weather, multi-device, persistence,
  edge cases): **~8,000–14,000 LOC C**.

Rule of thumb: C is ~1.5–2.5× the Python LOC for the same semantics because of
manual JSON/string handling, explicit memory management, and no asyncio/dict
comprehensions.

### Schedule (one senior systems engineer)

| Phase | Deliverable | Estimate |
|---|---|---:|
| 0 | Trace capture + differential test harness (proxy between real Nest and Python server) | 1–3 wks |
| 1 | Walking skeleton: entry + chunked long-poll + put + `/status` | 3–5 wks |
| 2 | Bucket merge/revisions + subscription fan-out + structure/user injection | 4–8 wks |
| 3 | Control API + command→bucket mapping | 2–3 wks |
| 4 | Persistence + weather + robustness | 2–4 wks |
| 5 | On-device integration (`rootme`/`rcS`/`monit`) + RAM/OOM/watchdog tuning | 2–4 wks |
| 6 | Hardening, tests, docs | 2–4 wks |
| | **Total** | **16–31 wks ≈ 4–7 months** |

A throwaway prototype that works on one device is ~2 months. A small team
(2–3 engineers) could compress the calendar to **~2–3 months** by splitting
HTTP/protocol vs. control/testing, at some coordination cost.

### Assumptions and main risks

- **Assumption:** a bench/test thermostat is available — there is no way to
declare "done" without one.
- **Highest risk: the app's undocumented bucket expectations.** Finding the
minimal set of `structure`/`user`/`device` fields that makes the app show
correct state and accept commands is empirical and could add weeks.
- **RAM ceiling (64 MiB)** and the OOM killer possibly targeting `nlclient`.
- **Kernel 2.6.37 + old toolchain** compatibility; a static musl build is safest.
- Protocol drift between firmware versions.

### What lowers the effort

1. Embedded HTTP + JSON libraries (`civetweb`/`mongoose`/`libmicrohttpd` +
   `cJSON`/`yyjson`): −2–3 wks.
2. HTTP-only localhost (no TLS): −2–4 wks.
3. Single-thermostat assumption (no multi-device/multi-user): simplifies state.
4. Skip pairing; use the Python server as a differential-test oracle.
5. Consider a non-C implementation:
   - **Lua** (device already has an interpreter; ship standalone Lua + tiny HTTP):
     protocol in ~1,500–2,500 LOC, fast iteration, ~1–2 MB RAM → **~4–8 wks**.
   - **Rust (musl static, `tiny_http`/`hyper`)**: ~2–4 MB RSS, memory-safe,
     easier concurrency → **~2–3 months**, but kernel-2.6.37 std compatibility
     needs validation.
   - **Go**: `net/http` makes chunked long-poll trivial, but a static Go binary's
     runtime RSS (~5–10 MB) is probably too much alongside `nlclient`.

### Rust `no_std` — assessment

**Device facts that constrain this:**

- The Nest userland is **soft-float EABI**: `Dev/root/bin/busybox` is
  `ELF 32-bit LSB, ARM, EABI5 …, interpreter /lib/ld-linux.so.3`, and the vendor
  toolchain is `arm-none-linux-gnueabi` (hard-float would be
  `ld-linux-armhf.so.3`). So the correct Rust target is
  **`armv7-unknown-linux-musleabi`**, not `…eabihf`.
- Kernel **2.6.37**, glibc from ~2008 (glibc 2.8-era).

**Why `no_std` is usually the wrong first move:** the kernel/glibc compatibility
problem it is meant to solve is better solved by a **statically linked musl
`std`** binary. A static musl binary is self-contained and never touches the
device's ancient glibc, which sidesteps the glibc-symbol-version problem that
breaks a dynamic `gnueabi` build. Single-threaded `std` only needs 2.5–2.6-era
syscalls (`epoll`, `eventfd`, `futex`, `mmap`, `open`, `write`); newer ones
(`getrandom`, `statx`, `clone3`, `pidfd`) have fallbacks or are unused if you
avoid threads/process APIs. The one thing to verify is musl's own minimum kernel
version (historically ~2.6.39 for some builds) with a hello-world on the device.

**What `no_std` actually buys:**

- No `std` runtime init; optionally no libc at all (raw syscalls).
- A fixed/bounded allocator and binary ~100–300 KB, RSS <1 MB.
- Total control over which syscalls/ABI are used.

**What it costs:**

- You lose `std::net`, `std::io`, `std::time`, `std::thread`, `std::error::Error`.
- `hyper`, `tiny_http`, `tokio`, `mio` are all `std`-only → **hand-roll HTTP/1.1**
  (request parser + chunked encoder, ~500–1,000 LOC). `smoltcp` is the wrong tool
  (a userspace TCP/IP stack, not Linux sockets).
- JSON: `serde-json-core` / `nanoserde` or a hand-rolled DOM (~500–1,000 LOC).
- You must provide `#[panic_handler]`, an entry point (`_start`, or musl's crt via
  `#![no_main]` + `extern "C" fn main`), and a `#[global_allocator]`.
- Sparse Linux `no_std` examples; more `unsafe`.
- Roughly **+1–2 months** over `std` Rust (more for fully raw-syscall, no-libc).

**Most of the footprint win is available without `no_std`:**

- `std` + static musl + `panic = "abort"`, `lto`, `opt-level = "z"`, `strip`
  yields a ~200–500 KB binary and ~1–2 MB RSS.
- A bounded custom `#[global_allocator]` (e.g. `talc` / `linked_list_allocator`
  over a reserved arena) caps memory and makes OOM behaviour deterministic — the
  main reason to care on a 64 MiB device.
- Avoid async runtimes; use one `poll`/`epoll` loop.

**Nice pattern:** keep the protocol/state core as a `no_std`+`alloc` library that
can be unit-tested on the host with `std`, and build the device binary around it.
The hard part (app bucket semantics) is language-independent and gets tested
without a thermostat.

**Recommended sequence:**

1. Cross-compile a static `armv7-unknown-linux-musleabi` hello-world + socket
   echo, run on the device (days). This validates musl/VFP/kernel.
2. Build the server with `std` + bounded allocator; core library `no_std`-capable.
3. Only if (1) fails, or footprint is still too large, go `no_std` — first with
   libc, then raw syscalls.

**Bottom line on `no_std`:** it is a footprint/compat hedge, not a shortcut. The
multi-month cost is the protocol reverse-engineering; `no_std` adds scaffolding
on top of it. Start with static musl `std` and reach for `no_std` only if a
concrete blocker appears.

### Bottom line

Porting the server to C is a **multi-month, real systems project** dominated by
protocol/app-behaviour reverse-engineering, not by writing the HTTP code. The
walking skeleton is small (~1,500–2,500 LOC, ~6–8 weeks); the long tail
(structure injection, app happy-path, RAM tuning) is most of the calendar. If an
external server is acceptable, it remains dramatically cheaper. If it is not,
**Lua is the pragmatic middle path** and C is the durable one.

---

## 6. Concrete investigation plan (next deep dive)

1. **Dump `mtdblock7`** from a rooted unit. Build NLE with `--enable-root-access`,
   SSH in as root, then:
   ```sh
   cat /proc/mtd
   dd if=/dev/mtdblock7 of=/media/scratch/mtdblock7.img bs=64k
   # copy off via scp (dropbear) for offline analysis
   ```
   Dump `mtdblock10..14` too for config/state formats.
2. **Static analysis of `nlclient`** (from the dump):
   ```sh
   file nestlabs/sbin/nlclient
   readelf -d nestlabs/sbin/nlclient        # libs, lua, dbus
   strings -a nestlabs/sbin/nlclient | grep -iE 'com\.nestlabs|nlclient|controlserver|Introspect|SetTarget|target_temperature|hvac'
   nm -D nestlabs/sbin/nlclient 2>/dev/null | head
   ```
   Look for D-Bus method tables / object paths and the `controlserver` logic.
3. **Runtime D-Bus introspection** (root, live):
   ```sh
   dbus-monitor --system                 # exercise the UI, watch nlclient traffic
   dbus-send --system --print-reply --dest=com.nestlabs.nlclient \
       / org.freedesktop.DBus.Introspectable.Introspect
   # try candidate paths: /, /com/nestlabs/nlclient, /com/nestlabs/nlclient/main
   ```
4. **Probe the Lua bot** in a scratch build: patch `client.config` to set
   `enablebotautomation=1` and `enabletempscreenoutput=1`, flash, then:
   ```sh
   nc <nest-ip> 8000
   getCurrentTempC()
   getTargetTempC()
   ```
   Then try `rotateDial`/`switchMode` movements.
5. **Check `controlserver`**: on device `netstat -tlnp` (busybox) — see what
   listens on :8080 and whether `nlclient` opens a connection to it.
6. **Confirm avahi startup** on the real rootfs and whether it advertises
   `_http._tcp`/anything useful for Hubitat discovery.
7. **Prototype Option A** on a bench unit: minimal C server + `settings` change,
   then grow the protocol.

### Useful one-liners already used in this research
```sh
cpio -it < NestDFUAttack/Dev/initramfs_data.cpio | grep -i nestlabs
grep -rIn 'com\.nestlabs' NestDFUAttack/Dev/root/etc
grep -rIn 'enablebotautomation\|tempscreenoutput\|controlserver' \
     NestDFUAttack/Dev/root/etc/nestlabs/client.config
```

---

## 7. Build integration notes

- The `rootme` script is generated at build time in
  `NoLongerEvil-Thermostat/firmware/builder/build.sh`; that's where to add
  `client.config` edits (bot flags) or new file deployments.
- New on-device services follow existing patterns: an `/etc/init.d` script + an
  `/etc/monit.d/*.monitrc`, or simply append `${INITDIR}/<svc> start` to
  `mtdblock7:/etc/init.d/rcS` (as NLE does for `nleapi`).
- New web endpoints can be added as CGIs under `/var/www/cgi-bin/` next to
  `settings`.
- Cross-compile only inside the Docker builder
  (`firmware/builder/docker-build.sh`), which wires up the 2008q3 toolchain; the
  toolchain binaries are x86-Linux and won't run on macOS.

---

## 8. Risks and caveats

- **No `mtdblock7`/`nlclient` available yet** — every app-interface claim in §4
  is inferred from config/policy/scripts, not from the binary.
- App **OTA/cloud update** paths exist (`cloudupdateenable=1`,
  `softwareupdatecommand`); pin/verify behavior before relying on patched config
  persisting.
- The Lua bot is **unauthenticated root RCE on the LAN** — prototype only.
- JFFS2/NAND wear: don't write state on every poll.
- D-Bus policy is root-only; our httpd is root, so workable, but any non-root
  helper cannot talk to `nlclient`.
- Legal/ownership: `nlclient` and bots are proprietary Nest code; be mindful
  about redistribution (this doc references, not ships, it).

---

## 9. Implications for the Hubitat integration

- **Today:** an external NoLongerEvil server is still required; the Hubitat
  app/driver in `NoLongerEvil-Hubitat/` targets its control API.
- **If Option A lands:** the thermostat becomes the server. Hubitat (or the
  existing app/driver, with the URL pointed at the thermostat) can talk to the
  Nest directly on the LAN — no other host. This is the only route that fully
  satisfies the "just the Hubitat hub" requirement.
- **If Option B/C lands:** a thin on-device bridge exposes an HTTP API that the
  Hubitat app/driver can consume; the external server is still removable.

---

## Appendix

### A. D-Bus names found
| Name | Owner | Notes |
|---|---|---|
| `com.nestlabs.nlclient` | `nlclient` | root-only; heartbeat "Unsolicited" signals; state methods **TBC** |
| `com.nestlabs.nlheartbeat` | `nlheartbeatd` | watchdog |
| `com.nestlabs.scpm` | `nlscpmd` | `/com/nestlabs/scpm/manager`, iface `com.nestlabs.scpm.main`, method `Quit` |

### B. Key config keys (`/etc/nestlabs/client.config` in initramfs; the live one is on mtdblock7)
`cloudregisterurl`, `czauth`, `controlserver`, `controlserverport`, `debug`,
`enablebotautomation`, `botscript`, `tempscreenoutput`,
`enabletempscreenoutput`, `settingsfile`, `environmentplistpath`,
`softwareupdatecommand`, `cloudupdateenable`.

### C. Lua surface (from `bots/sapphire_helper.lua`)
C functions: `click`, `clickDown`, `clickUp`, `rotateDial`, `jumpToScreen`,
`showScreen`, `hideScreen`, `sleep`, `logDebug`.
Lua helpers: `getTargetTempC`, `getCurrentTempC`, `setTemp`, `switchMode`,
`setAwayLowTemp`, `checkTargetTempChanged`, `scrollTemp`, `scrollItem`,
`scrollSettings`, `setSetpoint`, plus interview/demo helpers.

### D. NLE `settings` CGI (read/write `cloudregisterurl`)
`/var/www/cgi-bin/api/settings`, served by BusyBox httpd `:8080` as root.
Uses `/etc/nestlabs/apikey.txt` and `client.config`; restarts `nestlabs` after a
successful endpoint change.

### E. Clone/working paths
- `NestDFUAttack` (shallow): the pinned submodule at `NestDFUAttack/`
- Firmware builder: `NoLongerEvil-Thermostat` (sibling clone)
- Hubitat integration: `NoLongerEvil-Hubitat` (sibling clone)
