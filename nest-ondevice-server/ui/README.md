# Schedule editor SPA

A minimal Solid.js + TypeScript single-page app for editing the thermostat's
weekly schedule. Bun bundles it to three files; `nest-ondevice-server/build.rs`
embeds those bytes into the server binary, so the device serves the editor from
`http://<nest>:8082/` with no filesystem, no reverse proxy and no second
listener.

```
src/index.html   the shell (hand-written, copied to dist/ verbatim)
src/index.tsx    mount
src/App.tsx      state, loading, save, toolbar, learning-mode switch
src/DayRow.tsx   one weekday: timeline, setpoint rows, copy-from-day
src/model.ts     the wire format, normalisation, validation, time/temp helpers
src/api.ts       fetch wrappers (same origin, relative paths)
src/app.css      styling (dark, mobile-first)
test/render.tsx  mounts the real <App/> against a stubbed API and asserts it works
```

## Build and test

```sh
./build ui          # bun build + render test, then rebuild the server to embed it
cd nest-ondevice-server/ui
bun run build.ts    # -> dist/{index.html,index.js,app.css}   (~50 KB, ~17 KB xz'd)
bun run test/run.ts # happy-dom render test (24 assertions)
bun x tsc --noEmit  # types
```

`dist/` is **committed** and `node_modules/` is not. The Nix build has no Bun,
and the firmware image must stay bit-reproducible, so the bundle is vendored
here the same way the patched Hubitat Groovy is vendored in `hubitat/`: edit
`src/`, run `./build ui`, commit `src/` **and** `dist/` together. `flake.nix`
lists `build.rs` and `ui/dist` in `serverSrc`, so a stale bundle cannot slip
into an image unnoticed — it changes the server's derivation.

Dependencies are pinned in `package-lock.json` (`npm ci` to reproduce). Note
`babel-preset-solid` still needs `@babel/core` 7.x, not 8.x.

## What it talks to

| Call | Used for |
|---|---|
| `GET /api/devices` | serial, name, `temperature_scale`, `mode`, `learning_mode`, `subscription_count` |
| `GET /api/schedule?serial=` | the `schedule.<serial>` bucket + `object_revision` |
| `POST /command {command:"set_schedule"}` | replace the bucket (full replacement, not a patch) |
| `POST /command {command:"set_device_setting", value:{learning_mode:bool}}` | stop the dial inventing setpoints |
| `POST /notify-device` | force the server to re-push every bucket down the long-poll |

## The wire format (what `model.ts` implements)

```json
{ "ver": 2, "name": "", "schedule_mode": "HEAT",
  "days": { "0": { "0": { "time": 23400, "type": "HEAT", "temp": 20.5,
                          "entry_type": "setpoint" } }, "1": { … }, … "6": { … } } }
```

* Day keys `"0"`–`"6"`, **0 = Monday**.
* A day is a **dict keyed by position** (the device-native form). Arrays are
  accepted on write and normalised to dicts on read (`normalizeDays` /
  `denormalizeDays`), because upstream's dashboard uses arrays.
* `time` is **seconds since local midnight** (0–86399); the editor snaps to the
  quarter hour like the Nest app.
* `type` is `HEAT`/`COOL`/`RANGE`; `RANGE` carries `temp-min`/`temp-max` instead
  of `temp`. Temperatures are **always Celsius on the wire** — the °F dial is a
  display setting, so the editor converts on the way in and out.
* `entry_type: "continuation"` is a device-native marker meaning "the previous
  setpoint still holds"; it carries **no** temperature and the editor never
  invents one for it.
* Unknown fields — top level (`schedule_algorithm`, `preconditioning`,
  `created_at`, …) or per entry — are carried through untouched. The server
  deliberately does not strip them either (see `cmd_set_schedule` in
  `src/control.rs`), because nlclient is the consumer of this bucket.

## What is *not* proven yet

Whether `nlclient` adopts a schedule it did not write. The server side is
verified (`test_smoke.py`: the bucket is replaced, the revision bumps, and the
new days are pushed down the held long-poll in the field order the device
requires), and upstream's own bug receipts say server-pushed buckets *do*
change device behaviour — but nobody has watched a real dial change its setpoint
from a pushed schedule. `AGENTS.md` trap 29 has the experiment. Until then the
editor shows the bucket revision and a **Re-read** button: if the revision moves
without you saving, the thermostat has overwritten the bucket with its own copy.
