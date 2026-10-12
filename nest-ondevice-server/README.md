# nest-ondevice

A compact Rust port of the [NoLongerEvil](https://github.com/codykociemba/NoLongerEvil-SelfHosted)
Nest-protocol server, designed to run **on the Nest thermostat itself** so the
device is self-contained and Hubitat can talk to it directly on the LAN.

It implements Option A from [`docs/nest-ondevice-protocol-research.md`](../docs/nest-ondevice-protocol-research.md):
the thermostat's `cloudregisterurl` is pointed at `127.0.0.1`, a small local
server speaks the Nest device protocol, and the same process exposes the control
API (`/status`, `/command`, `/api/devices`) that the Hubitat driver already uses.

## Why Rust + these choices

The binding constraint is the Nest's **64 MiB RAM** and **Linux 2.6.37**:

* `std`, **no async runtime, no threads-per-request pool** — a handful of small
  (256 KiB stack) threads: one per listener and one per connection. Long-poll
  connections block on a channel, so there is no busy-waiting and no `tokio`.
* **No TLS** — the app↔localhost hop is plain HTTP, exactly as the reference
  server already supports for localhost.
* Hand-rolled HTTP/1.1 (request parse + chunked encoder) and a hand-rolled
  `poll`-free connection model, so the only dependencies are `serde`/`serde_json`.
* Values are hashed with a deterministic bounded allocator (`std`), `panic=abort`,
  `lto`, `opt-level="z"`, stripped: the host build is ~0.5 MB; a static
  `armv7-unknown-linux-musleabi` build should land in the same range with a
  ~1–2 MB RSS budget.
* Persistence is a single debounced JSON snapshot (every 15 s, only when dirty)
  written to `/media/data` to respect NAND wear.

If the musl/VFP/kernel combination ever misbehaves on the device, the protocol
core is ordinary `std` and can be moved to `no_std` incrementally — see the
research doc §5b "Rust `no_std`".

## What it implements

Device protocol (served on the **device port**, default `8000`):

| Endpoint | Notes |
|---|---|
| `GET/POST /nest/entry` | service discovery (`czfe_url`, `transport_url`, …) |
| `POST /nest/transport` | subscribe; **chunked long-poll** with inter-chunk batching |
| `POST /nest/transport/{ver}/subscribe` | versioned subscribe |
| `POST /nest/transport/put`, `…/{ver}/put` | state deltas, CAS + fan-timer preservation |
| `GET /nest/transport/device/{serial}` | object metadata list |
| `GET /nest/passphrase`, `/nest/passphrase/status` | entry-key pairing |
| `GET /nest/weather/v1` | stub (see caveats) |
| `POST /nest/upload` | optional device-log sink |
| `GET /nest/pro_info/{code}` | installer info |
| `GET /info` | provisioning details |

Bucket semantics match the reference server: timestamp is the sole authority,
shallow merge, revisions bump only when values actually change, PUT responses
return **rev/ts/key only** (no value echo), and `target_change_pending` is
special-cased. `user.*` and `structure.*` buckets are injected to complete
pairing; in open mode the device is auto-claimed by the configured local user, so
a factory-reset thermostat pairs without an external server.

Control API (served on the **control port**, default `8082`; both ports serve the
same routes, so a single port also works):

| Endpoint | Notes |
|---|---|
| `POST /command` | `set_temperature`, `set_mode`, `set_away`, `set_fan`, `set_eco_temperatures`, `set_schedule`, `set_schedule_mode`, `set_device_setting` |
| `GET /status?serial=` | full device status (Hubitat shape) |
| `GET /api/devices` | device list with `subscription_count` |
| `GET /api/schedule?serial=` | weekly schedule |
| `POST /notify-device` | force push current state |
| `GET /api/config`, `/api/stats`, `/health` | diagnostics |
| `POST /api/register`, `GET /api/registered-devices`, `POST /api/ensure-user` | registration |

## Observability (`/debug/*`)

Built for agents debugging a device nobody can console into. Served on both
ports, read-only except `/debug/loglevel`, gated by `DEBUG_TOKEN` when set
(`?token=` or `Authorization: Bearer`). Everything is ring-buffered and hard
capped so a runaway client cannot grow the device heap.

| Endpoint | Notes |
|---|---|
| `GET /debug` | endpoint index |
| `GET /debug/status` | pid, uptime, RSS/threads/fds from `/proc`, request counters, config, device availability |
| `GET /debug/logs?n=&level=&format=json\|text` | ring-buffered log lines (`level` 0=error…3=debug) |
| `GET /debug/trace?n=&format=` | recent HTTP exchanges with duration + body snippet (auth header never stored, `api_key`/`token`/`secret`/`password` values scrubbed) |
| `GET /debug/dmesg?n=` | kernel ring buffer via busybox `dmesg` |
| `GET /debug/state` | serial/owner/object-key summary (no values) |
| `GET /debug/report?n=` | **one-shot bundle**: status + logs + trace + dmesg + `uname/free/ps/ifconfig/route/df/mount/uptime/date` + config |
| `POST\|PUT /debug/loglevel?level=0..3` | change verbosity at runtime |

Env: `DEBUG_ENABLED` (default true), `DEBUG_TOKEN` (unset = open), `LOG_LEVEL`
(default 2), `DEBUG_LOG_FILE` (optional JSONL mirror, size-rotated at 512 KiB).
The interactive shell is Dropbear (installed by the GTVHacker `rootme`), not
this API.

## Build

Through the repo flake (recommended — same toolchain on every host):

```sh
nix build .#nest-ondevice          # static armv7-unknown-linux-musleabi
```

Directly with cargo (host build / tests):

```sh
cargo build --release
```

Cross-compile for the Nest without Nix (soft-float musl):

```sh
./build.sh            # uses `cross`, else `cargo zigbuild`, else plain cargo
```

The device is **soft-float EABI**, so the target must be
`armv7-unknown-linux-musleabi` — **not** `…eabihf`. A static musl binary avoids
the device's 2008-era glibc. Validate the musl minimum-kernel requirement with a
trivial hello-world + socket echo on a rooted unit before relying on it (see
research doc §5b, recommended sequence step 1).

## Deploy on the thermostat

1. Cross-compile and copy the binary:

   ```sh
   scp target/armv7-unknown-linux-musleabi/release/nest-ondevice \
       root@<nest>:/media/scratch/nest-ondevice
   ```

2. Install the init script:

   ```sh
   scp deploy/nest-ondevice.init root@<nest>:/etc/init.d/nest-ondevice
   ssh root@<nest> 'chmod +x /etc/init.d/nest-ondevice && /etc/init.d/nest-ondevice start'
   ```

3. Point the app at localhost. Set `cloudregisterurl` in
   `/etc/nestlabs/client.config` to `http://127.0.0.1:8000/entry` (the existing
   NLE `settings` CGI does this) and restart `nestlabs`:

   ```sh
   ssh root@<nest> '/etc/init.d/nestlabs restart'
   ```

   Optionally add `${INITDIR}/nest-ondevice start` to `/etc/init.d/rcS` (the same
   pattern NLE uses for `nleapi`). The init script already starts syslog into
   `/media/log/messages`, supervises the daemon with the shipped `monit` (or its
   own loop when monit is absent), and records the last exit status under
   `/media/data/nest-ondevice/last-exit`.

4. Point Hubitat at `http://<nest-lan-ip>:8082`.

### Configuration

All via environment (see `deploy/nest-ondevice.init`): `API_ORIGIN`,
`SERVER_PORT`, `CONTROL_PORT`, `DATA_DIR`, `SUSPEND_TIME_MAX`,
`DEFER_DEVICE_WINDOW`, `DISABLE_DEFER_WINDOW`, `REQUIRE_DEVICE_PAIRING`,
`ENTRY_KEY_TTL_SECONDS`, `USER_ID`, `STORE_DEVICE_LOGS`, `SERVER_HOST`, and the
observability knobs `DEBUG_ENABLED`, `DEBUG_TOKEN`, `LOG_LEVEL`,
`DEBUG_LOG_FILE`.

`API_ORIGIN` is the address handed back to the thermostat; use its LAN IP (not
`127.0.0.1`) if you also want Hubitat or other hosts to reach it.

## Smoke test

`test_smoke.py` exercises the whole path against a running host build:

```sh
SERVER_PORT=18000 CONTROL_PORT=18082 API_ORIGIN=http://127.0.0.1:18000 \
  DATA_DIR=/tmp/nest-test-data ./target/release/nest-ondevice &
python3 test_smoke.py
```

It covers entry discovery, first subscribe + auto-pairing, PUT semantics, a held
chunked subscribe receiving a command push, status/devices/command on the
control API, and the `/debug/*` surface (status/logs/trace/report/loglevel/state,
including a check that the auth password never leaks into a trace).

## Caveats

* **Sunset path:** the on-device scheduler/learning in `nlclient` is proprietary
  and still authoritative; this server only speaks the transport/control surface.
* **Timing** defaults to `suspend_time_max=300`, `connection_hold_timeout=290`,
  matching the reference server (must stay under the WiFi keepalive constraint).
* **Weather** returns `{}` rather than proxying `weather.nest.com` (no TLS in
  `std`); the thermostat still functions without it.
* **Calibrate against real traffic.** The highest-risk area is the exact set of
  `structure`/`user` fields the app expects. Use the Python server as a
  differential oracle (research doc §5b, "Assumptions and main risks").
* Confirm real memory headroom on a rooted unit (`free`, `VmRSS`) before running
  alongside `nlclient`, and keep an eye on the OOM killer.
