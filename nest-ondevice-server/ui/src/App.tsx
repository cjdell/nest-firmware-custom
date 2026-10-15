import { For, Show, createEffect, createMemo, onMount } from "solid-js";
import { createStore, produce } from "solid-js/store";

import * as api from "./api";
import { DayRow, type Editor } from "./DayRow";
import {
  DAY_KEYS,
  type Days,
  type DeviceStatus,
  type Schedule,
  blankWeek,
  clone,
  ensureDays,
  isFahrenheit,
  normalizeSchedule,
  schedulePayload,
  setpointCount,
  tempNudge,
  use24h,
  validate,
} from "./model";

interface State {
  devices: DeviceStatus[];
  serial: string;
  schedule: Schedule | null;
  /** JSON text of the schedule as last read from / saved to the server. */
  original: string;
  revision: number;
  lastSync: string;
  loadingDevices: boolean;
  loadingSchedule: boolean;
  saving: boolean;
  error: string;
  notice: string;
}

export function App() {
  const [state, setState] = createStore<State>({
    devices: [],
    serial: "",
    schedule: null,
    original: "",
    revision: 0,
    lastSync: "",
    loadingDevices: true,
    loadingSchedule: false,
    saving: false,
    error: "",
    notice: "",
  });

  const clock24 = use24h();
  const device = () => state.devices.find((d) => d.serial === state.serial) ?? state.devices[0];
  const fahrenheit = () => isFahrenheit(device()?.temperature_scale);
  const schedule = () => state.schedule;
  const dirty = () => !!state.schedule && JSON.stringify(state.schedule) !== state.original;
  const learning = () => isOn(device()?.learning_mode);

  /**
   * The two ways this editor can be editing the wrong thing, neither of which
   * shows up in the bucket. The dial regenerates the schedule when its HVAC mode
   * changes, so a heat schedule edited while it sits in cool mode is edited
   * against a bucket that is about to be replaced; and a bucket that is not a
   * heat schedule cannot have been written by this dial (it only heats) and
   * cannot be created by this editor either — it can only be read back.
   */
  const modeWarning = () => {
    const wanted = state.schedule?.schedule_mode;
    if (wanted && wanted !== "HEAT") {
      return `this bucket is a ${wanted} schedule, which this heat-only dial did not write and this editor cannot write — it reads back untouched, but every setpoint you add is HEAT`;
    }
    const actual = String(device()?.mode ?? "").toLowerCase();
    if (!actual || actual === "heat" || actual === "off" || actual === "emergency-heat") return "";
    return `dial in ${actual} mode — the thermostat rewrites the schedule bucket when its mode changes, so re-read after you switch modes`;
  };

  /** Client-side mirror of the server's validation, shown in the status bar. */
  const problems = createMemo(() => (state.schedule ? validate(state.schedule) : []));

  async function loadDevices() {
    setState({ loadingDevices: true, error: "" });
    try {
      const devices = await api.listDevices();
      setState("devices", devices);
      if (devices.length && !state.serial) setState("serial", devices[0].serial);
      if (!devices.length) {
        setState("error", "No thermostat has talked to this server yet — pair the device first.");
      }
    } catch (e) {
      setState("error", `Devices: ${message(e)}`);
    } finally {
      setState("loadingDevices", false);
    }
  }

  async function loadSchedule(notice = "") {
    if (!state.serial) return;
    setState({ loadingSchedule: true, error: "", notice });
    try {
      const res = await api.getSchedule(state.serial);
      const loaded = normalizeSchedule(res.schedule);
      setState({
        schedule: loaded,
        original: loaded ? JSON.stringify(loaded) : "",
        revision: res.object_revision ?? 0,
        lastSync: new Date().toLocaleTimeString(),
      });
    } catch (e) {
      setState("error", `Schedule: ${message(e)}`);
    } finally {
      setState("loadingSchedule", false);
    }
  }

  async function save() {
    const current = state.schedule;
    if (!current) return;
    const bad = validate(current);
    if (bad.length) {
      setState("error", bad.slice(0, 3).join(" · "));
      return;
    }
    setState({ saving: true, error: "", notice: "" });
    try {
      const res = await api.setSchedule(state.serial, schedulePayload(current));
      if (!res.success) throw new Error(res.message ?? "the server rejected the schedule");
      await loadSchedule(
        "Saved — if the revision moves without you editing anything, the dial re-published its own schedule over ours.",
      );
    } catch (e) {
      setState("error", message(e));
    } finally {
      setState("saving", false);
    }
  }

  async function pushToDevice() {
    setState({ error: "", notice: "" });
    try {
      await api.notifyDevice(state.serial);
      setState("notice", "Asked the server to push its buckets down the long-poll.");
    } catch (e) {
      setState("error", message(e));
    }
  }

  async function setLearning(on: boolean) {
    setState({ error: "", notice: "" });
    try {
      const res = await api.setLearningMode(state.serial, on);
      if (!res.success) throw new Error(res.message ?? "the server rejected the setting");
      await loadDevices();
      setState(
        "notice",
        on
          ? "Learning mode on: the dial will add its own setpoints after manual adjustments."
          : "Learning mode off: this schedule is now the only thing writing the dial's setpoints.",
      );
    } catch (e) {
      setState("error", message(e));
    }
  }

  /** Every edit goes through here so the store stays the single source of truth. */
  function mutate(fn: (days: Days, schedule: Schedule) => void) {
    setState(
      produce((draft) => {
        if (!draft.schedule) return;
        fn(ensureDays(draft.schedule), draft.schedule);
      }),
    );
  }

  function startBlank() {
    setState({
      schedule: { ver: 2, name: "", schedule_mode: "HEAT", days: blankWeek(fahrenheit()) },
      error: "",
      notice: "Built a weekday/weekend program locally. Save to push it to the thermostat.",
    });
  }

  const editor: Editor = {
    setDay: (dayKey, next) => mutate((days) => void (days[dayKey] = next)),
    copyDay: (from, to) => mutate((days) => void (days[to] = clone(days[from] ?? []))),
    reload: () => void loadSchedule("Re-read the cloud bucket."),
    save: () => void save(),
    push: () => void pushToDevice(),
    discard: () =>
      setState({
        schedule: state.original ? JSON.parse(state.original) : null,
        notice: "Discarded local edits.",
        error: "",
      }),
    setLearning: (on) => void setLearning(on),
    fahrenheit,
    clock24,
  };

  onMount(loadDevices);
  createEffect(() => {
    if (state.serial) void loadSchedule();
  });

  return (
    <main class="wrap">
      <header>
        <h1>Nest schedule</h1>
        <Show when={state.devices.length > 1}>
          <select
            value={state.serial}
            onInput={(e) => setState("serial", e.currentTarget.value)}
            aria-label="Thermostat"
          >
            <For each={state.devices}>
              {(d) => <option value={d.serial}>{d.name || d.serial}</option>}
            </For>
          </select>
        </Show>
        <Show when={device()}>
          {(d) => (
            <span class="meta">
              {d().name || d().serial} · {fahrenheit() ? "°F" : "°C"} ·{" "}
              <span class={d().subscription_count ? "on" : "off"}>
                {d().subscription_count ? "device connected" : "device offline"}
              </span>
            </span>
          )}
        </Show>
      </header>

      {/*
       * Errors, confirmations and warnings all render in the fixed bar at the
       * bottom of this file, never in the flow — see .status in app.css.
       */}
      <Show when={state.loadingDevices}>
        <p class="muted">Looking for thermostats…</p>
      </Show>

      <Show when={schedule()}>
        <Toolbar state={state} dirty={dirty} learning={learning} editor={editor} />
        <p class="muted hint">
          Click a dot on a timeline to select it, then <kbd>↑</kbd>/<kbd>↓</kbd> for ±
          {tempNudge(fahrenheit())}°{fahrenheit() ? "F" : "C"}, <kbd>←</kbd>/<kbd>→</kbd> for ±30
          min, <kbd>⌫</kbd> to delete. Setpoint times are folded under each day.
        </p>
        <ol class="days">
          <For each={DAY_KEYS}>
            {(dayKey) => (
              <DayRow
                dayKey={dayKey}
                entries={() => schedule()?.days[dayKey] ?? []}
                editor={editor}
              />
            )}
          </For>
        </ol>
      </Show>

      <Show when={!state.loadingDevices && !state.loadingSchedule && !schedule()}>
        <section class="empty">
          <p>
            The <code>schedule.{state.serial}</code> bucket is empty. A thermostat publishes its
            schedule when it boots, so either it has not rebooted since it was paired, or it has no
            schedule at all.
          </p>
          <p class="row">
            <button onClick={() => void loadSchedule("Re-read the cloud bucket.")}>Re-read</button>
            <button class="primary" onClick={startBlank}>
              Start from a blank week
            </button>
          </p>
          <p class="muted">
            "Blank week" builds a weekday/weekend program in the browser; it only reaches the
            thermostat when you Save.
          </p>
        </section>
      </Show>

      <footer>
        <p class="muted">
          Reads <code>GET /api/schedule</code>; writes <code>POST /command</code> with{" "}
          <code>set_schedule</code> — Save replaces the whole <code>schedule.{state.serial}</code>{" "}
          bucket and pushes it to the dial on its held long-poll connection. Heat only: this dial
          has a Heat Link and cannot cool, so every setpoint is <code>HEAT</code>. Day 0 is Monday,
          each setpoint runs until the next one, so the first entry of a day is the wake-up
          temperature. Times are stored as seconds since local midnight and temperatures as Celsius,
          whatever the dial shows.
        </p>
      </footer>

      <Show when={state.error || state.notice || modeWarning() || problems().length}>
        <div class="status" role="status" aria-live="polite">
          <Show when={state.error}>
            <p class="error">{state.error}</p>
          </Show>
          <Show when={problems().length}>
            <p class="error">{problems().slice(0, 3).join(" · ")}</p>
          </Show>
          <Show when={state.notice}>
            <p class="notice">{state.notice}</p>
          </Show>
          <Show when={modeWarning()}>
            {(why) => <p class="notice">{why()}</p>}
          </Show>
        </div>
      </Show>
    </main>
  );
}

function Toolbar(props: {
  state: {
    readonly schedule: Schedule | null;
    readonly original: string;
    readonly revision: number;
    readonly lastSync: string;
    readonly loadingSchedule: boolean;
    readonly saving: boolean;
  };
  dirty: () => boolean;
  learning: () => boolean;
  editor: Editor;
}) {
  const schedule = () => props.state.schedule as Schedule;
  const count = () => setpointCount(schedule().days);

  return (
    <>
      {/*
       * One row of a fixed shape, because a toolbar that changes size moves the
       * seven day rows under your thumb: the schedule mode is stated as text (a
       * heat-only dial has no mode to pick, and a dropdown that can only ever
       * say HEAT is a lie about capability), Discard is always present and
       * merely disabled, and the saved/unsaved marker always holds its slot.
       * What Save *does* is written once in the footer instead of being
       * announced every time the buffer goes dirty.
       */}
      <section class="toolbar">
        <span class="muted">
          {schedule().schedule_mode} schedule · {count()} setpoint{count() === 1 ? "" : "s"} · rev{" "}
          {props.state.revision}
          <Show when={props.state.lastSync}> · read {props.state.lastSync}</Show>
          {" · "}
          <span class={props.dirty() ? "dirty" : "clean"}>
            {props.dirty() ? "unsaved" : "saved"}
          </span>
        </span>
        <span class="grow" />
        <button onClick={props.editor.reload} disabled={props.state.loadingSchedule}>
          {props.state.loadingSchedule ? "Reading…" : "Re-read"}
        </button>
        <button onClick={props.editor.discard} disabled={!props.dirty() || props.state.saving}>
          Discard
        </button>
        <button
          class="primary save"
          onClick={props.editor.save}
          disabled={!props.dirty() || props.state.saving}
        >
          {props.state.saving ? "Saving…" : props.dirty() ? "Save" : "Saved"}
        </button>
      </section>

      <section class="toolbar bottom">
        <label class="switch">
          <input
            type="checkbox"
            checked={props.learning()}
            onInput={(e) => props.editor.setLearning(e.currentTarget.checked)}
          />
          Learning mode
        </label>
        <Show
          when={props.learning()}
          fallback={
            <span class="muted">
              Learning mode is off, so nothing rewrites these setpoints behind your back.
            </span>
          }
        >
          <span class="muted">
            The dial invents new setpoints after manual adjustments — it will fight this editor.
          </span>
        </Show>
        <span class="grow" />
        <button onClick={props.editor.push}>Push bucket to device now</button>
        <span class="muted">
          Forces the server to re-send every bucket the thermostat thinks it already has.
        </span>
      </section>
    </>
  );
}

function message(e: unknown): string {
  return e instanceof Error ? e.message : String(e);
}

/** `learning_mode` is a boolean on the wire; older firmware has been seen using strings. */
function isOn(value: unknown): boolean {
  return value === true || value === "true" || value === 1;
}
