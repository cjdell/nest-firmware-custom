import { For, Show, createEffect, createMemo, onMount } from "solid-js";
import { createStore, produce } from "solid-js/store";

import * as api from "./api";
import { DayRow, type Editor } from "./DayRow";
import {
  DAY_KEYS,
  MODES,
  type Days,
  type DeviceStatus,
  type Mode,
  type Schedule,
  blankWeek,
  clone,
  ensureDays,
  isFahrenheit,
  normalizeMode,
  normalizeSchedule,
  schedulePayload,
  setpointCount,
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
   * The thermostat regenerates the bucket when its HVAC mode changes, so a heat
   * schedule edited while the dial is in cool mode is edited against a bucket
   * that is about to be replaced. Warn; do not block.
   */
  const modeMismatch = () => {
    const wanted = state.schedule?.schedule_mode;
    const actual = String(device()?.mode ?? "").toLowerCase();
    if (!wanted || wanted === "RANGE" || !actual || actual === "off") return "";
    if (wanted === "HEAT" && actual !== "heat") return `heat schedule, dial in ${actual} mode`;
    if (wanted === "COOL" && actual !== "cool") return `cool schedule, dial in ${actual} mode`;
    return "";
  };

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
    const problems = validate(current);
    if (problems.length) {
      setState("error", problems.slice(0, 3).join(" · "));
      return;
    }
    setState({ saving: true, error: "", notice: "" });
    try {
      const res = await api.setSchedule(state.serial, schedulePayload(current));
      if (!res.success) throw new Error(res.message ?? "the server rejected the schedule");
      await loadSchedule(
        "Saved. This is what the cloud bucket holds now — if it changes again without you " +
          "touching anything, the thermostat re-published its own schedule over ours.",
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
    const mode = normalizeMode(device()?.schedule_mode ?? "HEAT");
    setState({
      schedule: { ver: 2, name: "", schedule_mode: mode, days: blankWeek(mode, fahrenheit()) },
      error: "",
      notice: "Built a weekday/weekend program locally. Save to push it to the thermostat.",
    });
  }

  const editor: Editor = {
    setDay: (dayKey, next) => mutate((days) => void (days[dayKey] = next)),
    copyDay: (from, to) => mutate((days) => void (days[to] = clone(days[from] ?? []))),
    setMode: (mode) => mutate((_days, s) => void (s.schedule_mode = mode)),
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

      <Show when={state.error}>
        <p class="error">{state.error}</p>
      </Show>
      <Show when={state.notice}>
        <p class="notice">{state.notice}</p>
      </Show>

      <Show when={modeMismatch()}>
        {(why) => (
          <p class="notice">
            {why()} — the thermostat rewrites the schedule bucket when its mode changes, so
            re-read after you switch modes.
          </p>
        )}
      </Show>

      <Show when={state.loadingDevices}>
        <p class="muted">Looking for thermostats…</p>
      </Show>

      <Show when={schedule()}>
        <Toolbar state={state} dirty={dirty} learning={learning} editor={editor} />
        <ol class="days">
          <For each={DAY_KEYS}>
            {(dayKey) => (
              <DayRow
                dayKey={dayKey}
                entries={() => schedule()?.days[dayKey] ?? []}
                mode={() => schedule()?.schedule_mode ?? "HEAT"}
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
          <code>set_schedule</code>. Day 0 is Monday, each setpoint runs until the next one, so the
          first entry of a day is the wake-up temperature. Times are stored as seconds since local
          midnight and temperatures as Celsius, whatever the dial shows.
        </p>
      </footer>
    </main>
  );
}

function Toolbar(props: {
  state: {
    readonly schedule: Schedule | null;
    readonly original: string;
    readonly revision: number;
    readonly lastSync: string;
    readonly serial: string;
    readonly loadingSchedule: boolean;
    readonly saving: boolean;
  };
  dirty: () => boolean;
  learning: () => boolean;
  editor: Editor;
}) {
  const schedule = () => props.state.schedule as Schedule;
  const errors = createMemo(() => validate(schedule()));

  return (
    <>
      <section class="toolbar">
        <label>
          Mode{" "}
          <select
            value={schedule().schedule_mode}
            onInput={(e) => props.editor.setMode(normalizeMode(e.currentTarget.value) as Mode)}
          >
            <For each={MODES}>{(m) => <option value={m}>{m}</option>}</For>
          </select>
        </label>
        <span class="muted">
          {setpointCount(schedule().days)} setpoints · rev {props.state.revision}
          <Show when={props.state.lastSync}> · read {props.state.lastSync}</Show>
        </span>
        <span class="grow" />
        <button onClick={props.editor.reload} disabled={props.state.loadingSchedule}>
          {props.state.loadingSchedule ? "Reading…" : "Re-read"}
        </button>
        <Show when={props.dirty()}>
          <button onClick={props.editor.discard}>Discard</button>
        </Show>
        <button class="primary" onClick={props.editor.save} disabled={!props.dirty() || props.state.saving}>
          {props.state.saving ? "Saving…" : props.dirty() ? "Save" : "Saved"}
        </button>
      </section>

      <Show when={props.dirty()}>
        <p class="notice">
          Unsaved changes. Save replaces the <code>schedule.{props.state.serial}</code> bucket and
          pushes it to the thermostat on its held long-poll connection.
        </p>
      </Show>
      <Show when={errors().length}>
        <p class="error">{errors().slice(0, 3).join(" · ")}</p>
      </Show>

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
