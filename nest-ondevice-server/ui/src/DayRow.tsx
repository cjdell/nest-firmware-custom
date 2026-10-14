import { For, Show } from "solid-js";

import {
  DAY_KEYS,
  DAY_NAMES,
  TEMP_MAX_C,
  TEMP_MIN_C,
  type Mode,
  type Setpoint,
  displayTemp,
  formatTime,
  inputStep,
  isContinuation,
  makeSetpoint,
  nextSlot,
  parseTime,
  snapTime,
  storeTemp,
  tempLabel,
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

export function DayRow(props: {
  dayKey: string;
  entries: () => Setpoint[];
  mode: () => Mode;
  editor: Editor;
}) {
  const dayKey = () => props.dayKey;
  const name = () => DAY_NAMES[Number(props.dayKey)] ?? props.dayKey;
  const isWeekend = () => props.dayKey === "5" || props.dayKey === "6";

  const write = (next: Setpoint[]) => props.editor.setDay(dayKey(), next);

  const patch = (index: number, changes: Partial<Setpoint>) =>
    write(props.entries().map((sp, i) => (i === index ? { ...sp, ...changes } : sp)));

  const add = () => write([...props.entries(), makeSetpoint(props.mode(), nextSlot(props.entries()), props.editor.fahrenheit())]);

  const remove = (index: number) => write(props.entries().filter((_, i) => i !== index));

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
        <div class="track" aria-hidden="true">
          <For each={props.entries()}>
            {(sp) => (
              <span
                class="dot"
                classList={{ cool: sp.type === "COOL", range: sp.type === "RANGE" }}
                style={{ left: `${(sp.time / 86400) * 100}%` }}
                title={`${formatTime(sp.time, props.editor.clock24)} · ${tempLabel(sp, props.editor.fahrenheit())}°`}
              />
            )}
          </For>
        </div>
      </Show>

      <Show
        when={props.entries().length > 0}
        fallback={<div class="muted pad">Nothing scheduled on {name()}.</div>}
      >
        <ol class="sp-list">
          <For each={props.entries()}>{(sp, i) => <SetpointRow
            sp={sp}
            index={i()}
            mode={props.mode()}
            fahrenheit={props.editor.fahrenheit()}
            clock24={props.editor.clock24}
            onPatch={(changes) => patch(i(), changes)}
            onRemove={() => remove(i())}
          />}</For>
        </ol>
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
