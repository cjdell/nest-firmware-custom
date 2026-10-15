# Schedule editor SPA

A minimal Solid.js + TypeScript single-page app for editing the thermostat's
weekly schedule. Bun bundles it to three files; `nest-ondevice-server/build.rs`
embeds those bytes into the server binary, so the device serves the editor from
`http://<nest>:8082/` with no filesystem, no reverse proxy and no second
listener.

```
src/index.html   the shell (hand-written, copied to dist/ verbatim)
src/index.tsx    mount
src/App.tsx      state, loading, save, toolbar, learning-mode switch, status bar
src/DayRow.tsx   one weekday: timeline of temperature dots, folded setpoint rows, copy-from-day
src/model.ts     the wire format, normalisation, validation, time/temp helpers
src/api.ts       fetch wrappers (same origin, relative paths)
src/app.css      styling (dark, mobile-first)
test/render.tsx  mounts the real <App/> against a stubbed API and asserts it works
```

## Heat only — there is no mode picker

The dial is a 2nd-generation UK unit with a Heat Link: it heats and cannot cool
(the same fact that forces the driver to publish a cosmetic `coolingSetpoint`,
AGENTS.md trap 18). So the editor writes `schedule_mode: "HEAT"`, every setpoint
it creates is `type: "HEAT"`, and the toolbar *states* the mode as text instead
of offering a dropdown that could only ever say one thing.

What is deliberately **not** removed is the model's knowledge of `COOL` and
`RANGE`: `MODES`, `normalizeSetpoint`, `nudgeTemp`, `tempLabel`, `validate` and
the two-input branch of `SetpointRow` all still handle them, because the server
validates all three and a bucket this editor cannot create must still read back
and round-trip untouched rather than be silently collapsed onto `temp`. If a
bucket ever arrives as `RANGE` the status bar says so. `DEV_RANGE=1` below is
how that path is exercised.

## Nothing moves to talk to you

Every message — errors, validation, the post-save receipt, the mode warning —
renders in `.status`, a bar pinned to the bottom of the viewport, and the
toolbar has a fixed shape: the mode is text, `Discard` is always present and
merely disabled, and the `saved`/`unsaved` marker always holds its slot.

Both halves are the fix for the same bug: the messages used to sit in the flow
between the toolbar and the day rows, and `dirty` used to insert an "Unsaved
changes" paragraph, so the page grew by two lines on the first keystroke and
after every save — which on a phone slid the dot you were editing out from under
your thumb mid-drag. The render test asserts the mechanism, not just the copy:
no `.status` element exists until there is something to say, and editing marks
the toolbar dirty without rendering anything in the flow.

## Editing a day

Each day is a 24-hour **timeline of dots, and the temperature is written inside
each dot** (a `RANGE` shows `16–24°`; a `continuation` shows `hold`, because it
carries no temperature and the editor never invents one). Dots that would
overlap stack into up to three lanes — `lanesFor` in `src/DayRow.tsx` uses a
fixed 3.5 h gap rather than measuring the DOM, so the layout is deterministic
(and testable) at any viewport width.

A dot is a real `<button>`: **focused is selected** — Tab or click to select it,
then

| Key | Does |
|---|---|
| `↑` / `↓` | temperature ±0.5 °C (±1 °F on a Fahrenheit dial — one `inputStep`, so the on-screen number always moves by one of its own steps) |
| `←` / `→` | time ±30 min (still on the quarter-hour grid; clamped inside the day) |
| `Backspace` / `Delete` | remove the setpoint; focus moves to its neighbour so the arrows keep working |

`nudgeTemp` / `nudgeTime` in `src/model.ts` do the arithmetic, going through the
same display↔wire conversion as the number inputs — which is also what clamps to
the server's 4.5–32 °C bounds and keeps a `RANGE` band's width. A `continuation`
returns an empty patch, so `↑` on one changes nothing.

The rows of time/temperature inputs under each timeline are **folded by default**
(a `<details>` whose summary lists the times, hidden once open). The full list of
inputs for seven days is a wall you rarely need, and everything the dots show is
readable without it. They stay in the DOM when folded, which is why the render
test can still assert against them.

Both the dots and the input rows render with `<Index>`, so a store write updates
the node under the cursor in place instead of rebuilding the row on every
keystroke, and `refocus()` re-asserts focus after each mutation (deleting the
selected dot can leave focus nowhere — in a browser, removing the focused
element parks it on `<body>`, and the next arrow key would be swallowed). Note
happy-dom does **not** reproduce that lost-focus case, so the test proves the
arrows work but cannot prove `refocus` is what keeps them working.

## Build and test

```sh
./build ui          # bun build + render test, then rebuild the server to embed it
cd nest-ondevice-server/ui
bun run build.ts    # -> dist/{index.html,index.js,app.css}   (~54 KB, ~17 KB xz'd)
bun run test/run.ts # happy-dom render test (53 assertions)
bun x tsc --noEmit  # types
```

## Dev server (no thermostat, no Rust server)

```sh
./build ui-dev      # == bun run dev.ts  ->  http://127.0.0.1:8083
just ui-dev         # same thing through the justfile
```

`dev.ts` serves the app **from `src/`** against `mock.ts`, an in-memory fake of
the control API. There is no watcher process: every request for the bundle
compares the mtimes under `src/` and rebuilds if anything changed, so editing a
`.tsx` and hitting refresh is the whole loop. The dev bundle is unminified with
inline sourcemaps, and a build error is served as
`throw new Error("src/App.tsx: Unexpected token (393:6) …")` so the code frame
lands in the browser console instead of a blank page.

Options are env vars: `DEV_PORT=8083 DEV_SCALE=F DEV_RANGE=1 DEV_EMPTY=1
DEV_LEARNING=1` — scale changes the dial's display unit only (the wire stays
Celsius), `DEV_RANGE` fakes a heat+cool unit so the read-only RANGE path is
reachable (the editor renders and edits a `RANGE` bucket but will not create
one), and `DEV_EMPTY` starts with an empty bucket (the "device never rebooted"
case).

The fake is deliberately faithful to `src/control.rs`: the bucket is stored
device-native (dict-of-dicts), `set_schedule` is a full replacement that bumps
`object_revision` and stamps `object_timestamp`, unknown top-level fields
survive, and validation mirrors `cmd_set_schedule` and answers
`400 {success:false,message}`. On top of that it can simulate the two things
only the real dial does — and that the editor has to survive:

```sh
curl -XPOST localhost:8083/mock/clobber   # dial re-publishes its own schedule
curl -XPOST localhost:8083/mock/learn     # learning mode invents a setpoint
curl -XPOST localhost:8083/mock/empty     # bucket empty ("never rebooted")
curl -XPOST localhost:8083/mock/reset     # back to the published fixture
curl       localhost:8083/mock/state      # bucket + revision + commands seen
```

What it cannot prove is the one thing that actually matters: that the dial
*adopts* a pushed schedule (see `../README.md` and AGENTS.md trap 29). The mock
always accepts.

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
  of `temp`. The editor only ever **writes** `HEAT` (see "Heat only" above) but
  reads and round-trips all three. Temperatures are **always Celsius on the
  wire** — the °F dial is a display setting, so the editor converts on the way in
  and out.
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
