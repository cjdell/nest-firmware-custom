# Hubitat integration — NoLongerEvil Connect app + thermostat driver

Status: **installed and proven** on a real hub (firmware **2.5.2.135**),
2026-10-13. The hub UI is a Vue SPA whose REST endpoints are undocumented;
`NoLongerEvil-Hubitat/DEPLOY.md` tells you to click through the UI, which cannot
be scripted. This file records the reverse-engineered calls so install, rename
and control are reproducible.

## This deployment

| Thing | Value |
|---|---|
| Hub | "Brenda's Hub", MAC `34:e1:d1:81:70:16`, **static `192.168.1.3`**, scale **°C** |
| Thermostat | serial `02AA01AC2614065C`, on-device server `http://192.168.1.2:8082` |
| Device | id **16**, DNI `nolongerevil-02AA01AC2614065C`, label `Hallway Thermostat` |
| Driver (thermostat) | "NoLongerEvil Thermostat", id **940** |
| App (connect) | "NoLongerEvil Connect", app id **210**, installed instance **28** |

## Required driver fix (upstream bug)

`drivers/nolongerevil-thermostat.groovy:391` wraps a Groovy GString in double
quotes, so `$"` is an illegal interpolation and the driver will not compile:

```groovy
return url.toString().replaceAll("/+$", "")   // BROKEN
return url.toString().replaceAll('/+$', "")   // FIXED
```

Apply `nolongerevil-thermostat-gstring.patch` to a `NoLongerEvil-Hubitat/`
checkout (that tree is a git-ignored sibling — AGENTS.md trap 10):

```sh
git -C NoLongerEvil-Hubitat apply ../hubitat/nolongerevil-thermostat-gstring.patch
```

## Install/update code through the hub API

The hub serves these on the LAN without a login; a cookie is fine but not
required, and `saveOrUpdateJson` needs no CSRF token. `id` null = create, then
read the assigned id from the response.

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

* Upstream app/driver source: `NoLongerEvil-Hubitat/` (git-ignored, trap 10).
* Maker-API client reference: `hubitatcontrol/` (git-ignored; needs a token).
