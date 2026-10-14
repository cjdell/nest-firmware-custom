# Hubitat integration — NoLongerEvil Connect app + thermostat driver

Status: **installed and proven** on a real hub (firmware **2.5.2.135**),
2026-10-13.

This directory holds the *only* copy of the Hubitat code we use, and it is
tracked in git. It is the source of truth for the hub at `192.168.1.3`: edit
here, then push with [`push.sh`](push.sh) — never the other way round.

## Layout

| Path | What it is |
|---|---|
| `apps/nolongerevil-connect.groovy` | Hubitat app: finds the server, creates one child device per thermostat. **Byte-identical to upstream.** |
| `drivers/nolongerevil-thermostat.groovy` | Hubitat driver: polls the server, exposes the `Thermostat` capability. **Upstream + our two fixes.** |
| `push.sh` | Push either file to the hub over its REST API (app 210 / driver 940). |
| `LICENSE.nolongerevil` | MIT, upstream copyright — we vendor and modify upstream source. |
| `README.md` | This file: the deployment facts and the reverse-engineered hub API. |

There is deliberately **no** Docker Compose, `packageManifest.json`, mDNS
advertiser or upstream `DEPLOY.md` here. Those all assume the NoLongerEvil
server is a separate Docker/Python host; we run our own Rust server **on the
thermostat** (`nest-ondevice-server/`), install through the hub REST API rather
than Hubitat Package Manager, and the app discovers the server by probing
`GET /api/config` — so none of it applies. Details in
[docs/nest-ondevice-protocol-research.md](../docs/nest-ondevice-protocol-research.md).

## Provenance and our deltas

Both `.groovy` files are vendored from
[`codykociemba/NoLongerEvil-Hubitat`](https://github.com/codykociemba/NoLongerEvil-Hubitat)
(MIT, © 2025 Cody Kociemba), which we no longer keep a checkout of. Pristine
upstream checksums, so a future re-clone can be matched and diffed:

```sh
d40a53fa8eab31d0f46301517d7ac7616b15afc602d9fd57ebdba43ed540b1a1  drivers/nolongerevil-thermostat.groovy
4f5bc4ffe669c0e541026ab54a568fff4827a82fca5756197c49bc5cadd642af  apps/nolongerevil-connect.groovy
```

The driver carries two fixes that upstream does **not** have. They are recorded
in its file header too, because that text travels with a copy/paste into the
hub UI.

1. **Illegal GString** — upstream `effectiveServerUrl()` wraps a Groovy GString
   in double quotes, so `$"` is an illegal interpolation and *the driver does
   not compile at all*:

   ```groovy
   return url.toString().replaceAll("/+$", "")   // BROKEN (upstream, line 391)
   return url.toString().replaceAll('/+$', "")   // FIXED
   ```

2. **Heat-only units never publish `coolingSetpoint`** — the Hubitat Google
   Home app requires every attribute of the `Thermostat` capability, so a
   heat-only thermostat that only sets `heatingSetpoint` is marked *not
   compatible* (`googleHomeSupported=false`) and silently dropped from the
   Google Home device picker (AGENTS.md trap 18). The driver now also emits
   `coolingSetpoint` in the non-cool branch; the value is cosmetic because the
   Nest cannot cool.

Consequence: **never re-import the driver from upstream** (and never paste code
edited in the hub UI back over these files) — you would reintroduce a driver
that does not compile. Edit here, then `./hubitat/push.sh driver`.

To see our exact deltas against a fresh upstream clone:

```sh
git clone https://github.com/codykociemba/NoLongerEvil-Hubitat /tmp/nle-hubitat
diff -u /tmp/nle-hubitat/drivers/nolongerevil-thermostat.groovy \
        hubitat/drivers/nolongerevil-thermostat.groovy
```

The hub was unreachable when this vendoring was done (2026-10-14), so "the hub
runs what is here" is asserted from the install record, not re-read from the
hub. Next time you are on the LAN, `./hubitat/push.sh` makes it true by
construction.

## What the integration needs from our server

The contract between this Groovy and the Rust daemon — if you change a route,
check it still satisfies these:

| Used by | Call | Notes |
|---|---|---|
| app (scan) | `GET /api/config` | Accepted as "a NoLongerEvil server" if `api_origin` **or** `cloudregisterurl` is present |
| app (discover) | `GET /api/devices` | One child device per entry, DNI `nolongerevil-<serial>` |
| driver (poll) | `GET /status?serial=<serial>` | Device state in the Hubitat shape |
| driver (control) | `POST /command` | `{"serial":…,"command":"set_temperature",…}` |

Discovery is a `/24` probe of the hub's own subnet on port 8082 (or manual
host/port). The app also browses `_nolongerevil._tcp` if anything advertises
it; our server does not and does not need to, so the scan just takes ~15 s.

Upstream's docs also mention `POST /api/scan-network` and
`POST /api/configure-nest`, which re-point a thermostat at a server over the
LAN. Our server does not implement them and never will need to: the flashed
device is hardcoded to `127.0.0.1` (Option A), so there is nothing to
re-point. `/health` *is* implemented (`nest-ondevice-server/src/server.rs:116`).

## This deployment

| Thing | Value |
|---|---|
| Hub | "Brenda's Hub", MAC `34:e1:d1:81:70:16`, **static `192.168.1.3`**, scale **°C** |
| Thermostat | serial `02AA01AC2614065C`, on-device server `http://192.168.1.2:8082` |
| Device | id **16**, DNI `nolongerevil-02AA01AC2614065C`, label `Hallway Thermostat` |
| Driver (thermostat) | "NoLongerEvil Thermostat", id **940** |
| App (connect) | "NoLongerEvil Connect", app id **210**, installed instance **28** |

## Install/update code through the hub API

Use the script — it is the supported path and it cannot forget a fix:

```sh
./hubitat/push.sh            # both files (needs curl + jq)
./hubitat/push.sh driver     # or: app
```

What it does, and the shape of the endpoint for everything else (a fresh hub:
`id: null` creates, then read the assigned id from the response). The hub
serves these on the LAN without a login; a cookie is fine but not required, and
`saveOrUpdateJson` needs no CSRF token.

```sh
# thermostat driver
jq -Rs '{"id":940,"source":.,"version":1}' drivers/nolongerevil-thermostat.groovy |
  curl -s -X POST http://192.168.1.3/driver/saveOrUpdateJson \
    -H 'Content-Type: application/json' --data-binary @-
# connect app
jq -Rs '{"id":210,"source":.,"version":1}' apps/nolongerevil-connect.groovy |
  curl -s -X POST http://192.168.1.3/app/saveOrUpdateJson \
    -H 'Content-Type: application/json' --data-binary @-
```

| Action | Call |
|---|---|
| create app instance | `POST /installedapp/create` |
| configure instance | `POST /installedapp/configure` |
| save settings | `POST /installedapp/update/json` |
| fire a button | `POST /installedapp/btn` |
| list devices | `GET /hub2/devicesList` |
| full device JSON | `GET /device/fullJson/<id>` |

**Settings must be namespaced.** The install inputs are `settings[serverHost]`
and `settings[serverPort]` (not bare `serverHost`/`serverPort`), posted as
`application/x-www-form-urlencoded` to `/installedapp/update/json`. With bare
names the values silently do not stick and the app cannot reach the thermostat.

## Discover the thermostat

```sh
# app instance 28 = NoLongerEvil Connect
curl -s -X POST http://192.168.1.3/installedapp/btn \
  -H 'Content-Type: application/json' \
  -d '{"id":28,"name":"discoverBtn","stateAttribute":"","discoverBtn":"clicked","discoverBtn.type":"button"}'
```

This creates a device with DNI `nolongerevil-<serial>`.

## Send a command (the acceptance test)

```sh
curl -s -X POST http://192.168.1.3/device/runmethod -H 'Content-Type: application/json' \
  -d '{"id":16,"method":"setHeatingSetpoint","args":[{"type":"NUMBER","value":"21.0"}]}'
# -> {"success":true,"message":null}; the Nest target_temperature follows in ~3 s
```

Read back: `GET /device/eventsJson/<id>` (event array, newest last).

## Google Home

The hub's built-in **Google Home** app (app type 78, instance 3) is already
OAuth-linked to a Google account. It exposes only devices the hub reports as
`googleHomeSupported=true`. That flag needs **all attributes of the device's
capabilities to be populated**; for a `Thermostat` that includes
`coolingSetpoint`. A heat-only thermostat that never sets `coolingSetpoint` is
rejected and silently removed from the device picker — which is exactly what
delta 2 above fixes.

To expose the thermostat: **Hubitat → Apps → Google Home → tick the thermostat →
Update → Done.** It then appears in the Google Home / Assistant app (the account
link already exists; no re-link needed). `googleHomeSupported` is returned by
`GET /device/fullJson/<id>` — re-check it *after* a driver change takes effect
(the device must re-poll, or be re-saved, before the flag recomputes).

## Rename / edit a device (undocumented)

The drawer's Save posts the **whole** `deviceModel` to `/device/update` (existing
device) or `/device/save` (new), urlencoded. Booleans: `true` -> `on`,
`false` -> the literal `false`; nulls -> empty.

```sh
curl -s http://192.168.1.3/device/fullJson/16      # read device.name/label/…
# POST form fields (all of them, or you can blank one out):
#   name,label,zigbeeId,maxEvents,maxStates,spammyThreshold,deviceNetworkId,
#   deviceTypeId,deviceTypeReadableType,roomId,meshEnabled,retryEnabled,
#   meshFullSync,homeKitEnabled,locationId,hubId,groupId,dashboardIds,tags,
#   defaultIcon,notes,id,version,controllerType
```

`name` is the identifier-ish name (here `NLE 02AA01AC2614065C`); `label` is what
the UI and apps display (renamed `NoLongerEvil Thermostat` -> `Hallway
Thermostat`). `/hub2/devicesList` reports `name` = label and `secondaryName` =
name; the driver `type` stays "NoLongerEvil Thermostat" (do not change it).

## Hub network settings (undocumented)

```sh
GET /hub2/networkConfiguration          # usingStaticIP, staticIP, lanAddr, dnsServers…
GET /hub/advanced/switchToStaticIp?address=<ip>&netmask=<mask>&gateway=<gw>&nameserver=<dns>
GET /hub/advanced/switchToDhcp?nameserver=<dns>&useDNSFallover=true
POST /hub/reboot
```

Called from the `vue-hub2-networking-drawer` chunk; no visible link in the SPA.
AGENTS.md trap 17 explains why we used `switchToStaticIp`.

## Related

* Server these files talk to: [`nest-ondevice-server/`](../nest-ondevice-server/)
  (runs on the thermostat at `192.168.1.2:8082`).
* Maker-API client reference: `hubitatcontrol/` (git-ignored sibling clone;
  needs a token). Useful for endpoints this SPA does not use.
