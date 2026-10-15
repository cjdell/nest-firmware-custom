import { For, Index, Show, createMemo } from "solid-js";

import {
  DAY_KEYS,
  DAY_NAMES,
  TEMP_MAX_C,
  TEMP_MIN_C,
  TIME_NUDGE,
  type Mode,
  type Setpoint,
  clamp,
  displayTemp,
  formatTime,
  inputStep,
  isContinuation,
  makeSetpoint,
  nextSlot,
  nudgeTemp,
  nudgeTime,
  parseTime,
  snapTime,
  storeTemp,
  tempLabel,
  tempNudge,
  toInputTime,
} from "./model";

/** The editor callbacks the App hands down; every mutation ends up in its store. */
export interface Editor {
  setDay(dayKey: string, next: Setpoint[]): void;
  copyDay(from: string, to: string): void;
  setMode(mode: Mode): void;
  reload(): void;
  save(): void;
  push(): void;
  discard(): void;
  setLearning(on: boolean): void;
  fahrenheit: () => boolean;
  clock24: boolean;
}

/**
 * Timeline geometry. The dots are now labelled pills (the temperature is written
 * inside each one), so two setpoints close together would overlap: they stack
 * into lanes instead. `LANE_GAP` is in seconds — setpoints under three and a half
 * hours apart go one below the other, which keeps the pills legible on a phone
 * without needing to measure the DOM.
 */
const LANE_GAP = 3.5 * 3600;
const LANE_H = 22;
const DOT_H = 20;
const DOT_TOP = 8;
const BAR_H = 7;
const MAX_LANES = 3;

/**
 * Lane index per entry (greedy: first lane whose previous pill has cleared).
 * Works on a time-sorted copy because entries are only *mostly* sorted while
 * editing, and returns one lane per *original* index.
 */
function lanesFor(entries: Setpoint[]): number[] {
  const lanes: number[] = new Array(entries.length).fill(0);
  const cleared: number[] = [];
  const order = entries
    .map((sp, i) => [sp.time, i] as const)
    .sort((a, b) => a[0] - b[0]);
  for (const [time, i] of order) {
    let lane = cleared.findIndex((t) => time - t >= LANE_GAP);
    if (lane === -1) {
      if (cleared.length < MAX_LANES) {
        lane = cleared.length;
        cleared.push(time);
      } else {
        lane = cleared.indexOf(Math.min(...cleared));
        cleared[lane] = time;
      }
    } else {
      cleared[lane] = time;
    }
    lanes[i] = lane;
  }
  return lanes;
}

/** What goes inside a dot. A continuation has no temperature; never invent one. */
function dotText(sp: Setpoint, fahrenheit: boolean): string {
  return isContinuation(sp) ? "hold" : `${tempLabel(sp, fahrenheit)}°`;
}

export function DayRow(props: {
  dayKey: string;
  entries: () => Setpoint[];
  mode: () => Mode;
  editor: Editor;
}) {
  const dayKey = () => props.dayKey;
  const name = () => DAY_NAMES[Number(props.dayKey)] ?? props.dayKey;
  const isWeekend = () => props.dayKey === "5" || props.dayKey === "6";

  let track!: HTMLDivElement;

  const write = (next: Setpoint[]) => props.editor.setDay(dayKey(), next);

  const patch = (index: number, changes: Partial<Setpoint>) =>
    write(props.entries().map((sp, i) => (i === index ? { ...sp, ...changes } : sp)));

  const add = () => write([...props.entries(), makeSetpoint(props.mode(), nextSlot(props.entries()), props.editor.fahrenheit())]);

  const remove = (index: number) => write(props.entries().filter((_, i) => i !== index));

  const lanes = createMemo(() => lanesFor(props.entries()));
  const trackHeight = () =>
    (lanes().length ? Math.max(...lanes()) : 0) * LANE_H + DOT_TOP + DOT_H + BAR_H;

  /**
   * Re-assert focus on a dot after a mutation. `<Index>` reuses the node per
   * position so focus normally survives on its own; this covers the cases where
   * it does not (the list shrank, or the node was rebuilt), so the keyboard
   * never lands on <body> mid-edit. Deferred a microtask so it runs after Solid
   * has flushed the store change to the DOM.
   */
  const refocus = (index: number) =>
    queueMicrotask(() => {
      const dots = Array.from(track?.querySelectorAll<HTMLButtonElement>(".dot") ?? []);
      if (!dots.length) return;
      dots[clamp(index, 0, dots.length - 1)]?.focus();
    });

  /**
   * Keyboard editing of a selected dot: up/down ±one display degree, left/right
   * ±half an hour, Backspace/Delete removes it. The dot is a real button, so
   * "selected" is simply "focused" — Tab reaches it, and the ring is CSS.
   */
  const onDotKey = (e: KeyboardEvent, index: number) => {
    const sp = props.entries()[index];
    if (!sp) return;
    switch (e.key) {
      case "ArrowUp":
      case "ArrowDown": {
        e.preventDefault();
        const delta = (e.key === "ArrowUp" ? 1 : -1) * tempNudge(props.editor.fahrenheit());
        const changes = nudgeTemp(sp, delta, props.editor.fahrenheit());
        if (Object.keys(changes).length) patch(index, changes);
        break;
      }
      case "ArrowLeft":
      case "ArrowRight": {
        e.preventDefault();
        patch(index, { time: nudgeTime(sp.time, e.key === "ArrowRight" ? TIME_NUDGE : -TIME_NUDGE) });
        break;
      }
      case "Backspace":
      case "Delete": {
        e.preventDefault();
        remove(index);
        refocus(index); // clamps onto the entry that shifted in, or the new last one
        return;
      }
      default:
        return;
    }
    refocus(index);
  };

  return (
    <li class="day" classList={{ weekend: isWeekend() }}>
      <div class="day-head">
        <span class="day-name">{name()}</span>
        <span class="muted">
          {props.entries().length === 0
            ? "no setpoints — the dial holds whatever it was left with"
            : `${props.entries().length} setpoint${props.entries().length === 1 ? "" : "s"}`}
        </span>
        <span class="grow" />
        <select
          aria-label={`Copy a day into ${name()}`}
          value=""
          onInput={(e) => {
            const from = e.currentTarget.value;
            if (from) {
              props.editor.copyDay(from, dayKey());
              e.currentTarget.value = "";
            }
          }}
        >
          <option value="">copy…</option>
          <For each={DAY_KEYS}>
            {(k) => (
              <Show when={k !== props.dayKey}>
                <option value={k}>{DAY_NAMES[Number(k)]}</option>
              </Show>
            )}
          </For>
        </select>
        <button class="small" onClick={add} aria-label={`Add setpoint on ${name()}`}>
          + setpoint
        </button>
      </div>

      <Show when={props.entries().length > 0}>
        <div class="track" ref={track} style={{ height: `${trackHeight()}px` }}>
          <Index each={props.entries()}>
            {(sp, i) => (
              <button
                class="dot"
                classList={{ cool: sp().type === "COOL", range: sp().type === "RANGE" }}
                style={{
                  left: `${(sp().time / 86400) * 100}%`,
                  top: `${DOT_TOP - 2 + lanes()[i] * LANE_H}px`,
                }}
                title={`${formatTime(sp().time, props.editor.clock24)} · ${dotText(sp(), props.editor.fahrenheit())}`}
                aria-label={`${name()} setpoint at ${formatTime(sp().time, props.editor.clock24)}, ${tempLabel(sp(), props.editor.fahrenheit())} degrees`}
                // Safari does not focus a <button> on click, and "selected" here
                // means focused — without this the arrow keys do nothing after a
                // click on a Mac/iPhone.
                onClick={(e) => e.currentTarget.focus()}
                onKeyDown={(e) => onDotKey(e, i)}
              >
                {dotText(sp(), props.editor.fahrenheit())}
              </button>
            )}
          </Index>
          <span class="tick" aria-hidden="true">00</span>
          <span class="tick end" aria-hidden="true">24</span>
        </div>
      </Show>

      <Show
        when={props.entries().length > 0}
        fallback={<div class="muted pad">Nothing scheduled on {name()}.</div>}
      >
        {/* Folded by default: seven days of inputs is a wall, and the dots above
            already say what the day does. The summary lists the times instead. */}
        <details class="sp-fold">
          <summary>
            <span class="fold-title">Edit times and temperatures</span>
            <span class="muted fold-when">
              {props.entries().map((sp) => formatTime(sp.time, props.editor.clock24)).join(" · ")}
            </span>
          </summary>
          <ol class="sp-list">
            <Index each={props.entries()}>{(sp, i) => (
              <SetpointRow
                sp={sp()}
                index={i}
                mode={props.mode()}
                fahrenheit={props.editor.fahrenheit()}
                clock24={props.editor.clock24}
                onPatch={(changes) => patch(i, changes)}
                onRemove={() => remove(i)}
              />
            )}</Index>
          </ol>
        </details>
      </Show>
    </li>
  );
}

function SetpointRow(props: {
  sp: Setpoint;
  index: number;
  mode: Mode;
  fahrenheit: boolean;
  clock24: boolean;
  onPatch: (changes: Partial<Setpoint>) => void;
  onRemove: () => void;
}) {
  const range = () => props.sp.type === "RANGE";

  const editTemp = (shown: number) => {
    const value = storeTemp(shown, props.fahrenheit);
    if (range()) {
      // Keep min <= max without fighting the user mid-keystroke.
      props.onPatch({ "temp-min": Math.min(value, props.sp["temp-max"] ?? value) });
    } else {
      props.onPatch({ temp: value });
    }
  };

  const editTempMax = (shown: number) => {
    const value = storeTemp(shown, props.fahrenheit);
    props.onPatch({ "temp-max": Math.max(value, props.sp["temp-min"] ?? value) });
  };

  const bounds = () => ({
    min: props.fahrenheit ? 41 : TEMP_MIN_C,
    max: props.fahrenheit ? 90 : TEMP_MAX_C,
    step: inputStep(props.fahrenheit),
  });

  return (
    <li class="sp">
      <input
        type="time"
        step={900}
        value={toInputTime(props.sp.time)}
        aria-label="Setpoint time"
        onInput={(e) => props.onPatch({ time: snapTime(parseTime(e.currentTarget.value)) })}
      />
      <Show
        when={isContinuation(props.sp)}
        fallback={
          <Show
            when={range()}
            fallback={
              <span class="temp">
                <input
                  type="number"
                  {...bounds()}
                  value={displayTemp(props.sp.temp ?? 0, props.fahrenheit)}
                  aria-label="Temperature"
                  onInput={(e) => editTemp(Number(e.currentTarget.value))}
                />
                <span class="unit">°{props.fahrenheit ? "F" : "C"}</span>
              </span>
            }
          >
            <span class="temp range">
              <input
                type="number"
                {...bounds()}
                value={displayTemp(props.sp["temp-min"] ?? 0, props.fahrenheit)}
                aria-label="Minimum temperature"
                onInput={(e) => editTemp(Number(e.currentTarget.value))}
              />
              <span class="unit">–</span>
              <input
                type="number"
                {...bounds()}
                value={displayTemp(props.sp["temp-max"] ?? 0, props.fahrenheit)}
                aria-label="Maximum temperature"
                onInput={(e) => editTempMax(Number(e.currentTarget.value))}
              />
              <span class="unit">°{props.fahrenheit ? "F" : "C"}</span>
            </span>
          </Show>
        }
      >
        <span class="muted">holds the previous setpoint</span>
      </Show>
      <span class="muted when">{formatTime(props.sp.time, props.clock24)}</span>
      <span class="grow" />
      <button class="small danger" onClick={props.onRemove} aria-label="Delete setpoint">
        delete
      </button>
    </li>
  );
}
