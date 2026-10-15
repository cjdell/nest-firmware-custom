/**
 * The Nest schedule data model.
 *
 * Wire format (as the thermostat itself publishes it, and as `set_schedule`
 * expects it — see NoLongerEvil-SelfHosted command.py::validate_schedule):
 *
 *   {
 *     "ver": 2,
 *     "name": "",
 *     "schedule_mode": "HEAT" | "COOL" | "RANGE",
 *     "days": {
 *       "0": { "0": {"time": 23400, "type": "HEAT", "temp": 19.5}, "1": {...} },
 *       ...
 *       "6": {...}
 *     }
 *   }
 *
 * Day keys are "0".."6" with 0 = Monday. A day is a *dict of dicts* keyed by
 * position (the device-native form); the editor works with arrays and converts
 * on the way out. `time` is seconds since local midnight, temperatures are
 * always Celsius on the wire regardless of the unit's display scale.
 */

export type Mode = "HEAT" | "COOL" | "RANGE";

export const MODES: readonly Mode[] = ["HEAT", "COOL", "RANGE"];

/** Day keys "0".."6", 0 = Monday (upstream command.py:288). */
export const DAY_KEYS = ["0", "1", "2", "3", "4", "5", "6"] as const;

export const DAY_NAMES = [
  "Monday",
  "Tuesday",
  "Wednesday",
  "Thursday",
  "Friday",
  "Saturday",
  "Sunday",
];

/** Safety bounds enforced by the server (command.py:256-257). */
export const TEMP_MIN_C = 4.5;
export const TEMP_MAX_C = 32.0;

/** Setpoints snap to a quarter hour, like the Nest app. */
export const TIME_STEP = 900;

/**
 * Keyboard steps on a timeline dot. Left/right move half an hour; up/down move
 * one *display* step — 0.5 °C, or 1 °F on a Fahrenheit dial, which is what the
 * number inputs use too (`inputStep`).
 */
export const TIME_NUDGE = 1800;
export const TEMP_NUDGE_C = 0.5;
export const TEMP_NUDGE_F = 1;

export interface Setpoint {
  /** Seconds since local midnight, 0..86399. */
  time: number;
  type: Mode;
  /**
   * The device tags every entry: `"setpoint"` carries a temperature, `"continuation"`
   * is a marker saying "the previous setpoint still holds" (upstream's editor filters
   * them out when placing new entries — index.html:1064). We round-trip both.
   */
  entry_type?: "setpoint" | "continuation" | string;
  /** Celsius, for HEAT/COOL. */
  temp?: number;
  /** Celsius, for RANGE. */
  "temp-min"?: number;
  "temp-max"?: number;
  /** Anything the device sent that we do not model is round-tripped untouched. */
  [extra: string]: unknown;
}

/** A continuation entry holds no temperature of its own; never invent one. */
export function isContinuation(sp: Setpoint): boolean {
  return sp.entry_type === "continuation";
}

/** "0".."6" -> ordered setpoints. */
export type Days = Record<string, Setpoint[]>;

export interface Schedule {
  ver: number;
  name: string;
  schedule_mode: Mode;
  days: Days;
  [extra: string]: unknown;
}

export interface ScheduleResponse {
  serial: string;
  schedule: unknown;
  object_revision?: number;
  object_timestamp?: number;
}

export interface DeviceStatus {
  serial: string;
  name: string;
  temperature_scale?: string;
  schedule_mode?: string | null;
  /** The dial's current HVAC mode: "heat" | "cool" | "off" | "emergency-heat". */
  mode?: string | null;
  /** The dial rewrites the schedule itself when this is on. Boolean on the wire. */
  learning_mode?: unknown;
  is_available?: boolean;
  subscription_count?: number;
  capabilities?: { can_heat?: boolean; can_cool?: boolean };
}

export function clone<T>(value: T): T {
  return JSON.parse(JSON.stringify(value)) as T;
}

function isRecord(v: unknown): v is Record<string, unknown> {
  return typeof v === "object" && v !== null && !Array.isArray(v);
}

/**
 * Accept either shape the device/server may hand us: the native dict-of-dicts
 * keyed by position, or a plain array. Always returns arrays sorted by time.
 */
export function normalizeDays(raw: unknown): Days {
  const out: Days = {};
  if (!isRecord(raw)) return out;
  for (const key of Object.keys(raw)) {
    const day = raw[key];
    let entries: unknown[];
    if (Array.isArray(day)) {
      entries = day;
    } else if (isRecord(day)) {
      entries = Object.keys(day)
        .sort((a, b) => Number(a) - Number(b))
        .map((k) => day[k]);
    } else {
      continue;
    }
    out[key] = entries
      .filter(isRecord)
      .map((e) => normalizeSetpoint(e))
      .sort((a, b) => a.time - b.time);
  }
  return out;
}

/** Convert back to the device-native dict-of-dicts before saving. */
export function denormalizeDays(days: Days): Record<string, Record<string, Setpoint>> {
  const out: Record<string, Record<string, Setpoint>> = {};
  for (const key of Object.keys(days)) {
    const day: Record<string, Setpoint> = {};
    days[key]
      .slice()
      .sort((a, b) => a.time - b.time)
      .forEach((entry, i) => {
        day[String(i)] = entry;
      });
    out[key] = day;
  }
  return out;
}

function normalizeSetpoint(raw: Record<string, unknown>): Setpoint {
  const time = typeof raw.time === "number" ? raw.time : Number(raw.time) || 0;
  const type = normalizeMode(raw.type);
  const sp: Setpoint = { ...raw, time: clamp(time, 0, 86399), type };
  if (isContinuation(sp)) return sp;
  if (type === "RANGE") {
    sp["temp-min"] = num(raw["temp-min"] ?? raw.temp, 18.5);
    sp["temp-max"] = num(raw["temp-max"] ?? raw.temp, 24);
    delete sp.temp;
  } else {
    sp.temp = num(raw.temp ?? raw["temp-max"] ?? raw["temp-min"], 20);
    delete sp["temp-min"];
    delete sp["temp-max"];
  }
  return sp;
}

export function normalizeMode(raw: unknown): Mode {
  const s = String(raw ?? "").toUpperCase();
  return (MODES as readonly string[]).includes(s) ? (s as Mode) : "HEAT";
}

/** Wrap whatever the server returned into our model, keeping unknown top-level keys. */
export function normalizeSchedule(raw: unknown): Schedule | null {
  if (!isRecord(raw)) return null;
  const { days, schedule_mode, mode, name, ver, ...rest } = raw;
  void mode;
  return {
    ...rest,
    ver: typeof ver === "number" ? ver : 2,
    name: typeof name === "string" ? name : "",
    schedule_mode: normalizeMode(schedule_mode),
    days: normalizeDays(days),
  };
}

/** The exact payload `POST /command {command:"set_schedule"}` wants. */
export function schedulePayload(s: Schedule): Record<string, unknown> {
  const { days, ...rest } = s;
  return { ...rest, ver: 2, days: denormalizeDays(days) };
}

export function ensureDays(s: Schedule): Days {
  for (const key of DAY_KEYS) {
    if (!Array.isArray(s.days[key])) s.days[key] = [];
  }
  return s.days;
}

export function setpointCount(days: Days): number {
  return DAY_KEYS.reduce((n, k) => n + (days[k]?.length ?? 0), 0);
}

// ---------------------------------------------------------------------------
// Time and temperature formatting
// ---------------------------------------------------------------------------

export function clamp(n: number, lo: number, hi: number): number {
  return Math.min(hi, Math.max(lo, n));
}

function num(v: unknown, fallback: number): number {
  const n = typeof v === "number" ? v : Number(v);
  return Number.isFinite(n) ? n : fallback;
}

export function snapTime(secs: number): number {
  return clamp(Math.round(secs / TIME_STEP) * TIME_STEP, 0, 86400 - TIME_STEP);
}

/** "HH:MM" (from <input type=time>) -> seconds since midnight. */
export function parseTime(value: string): number {
  const [h, m] = value.split(":").map((x) => parseInt(x, 10));
  if (Number.isNaN(h) || Number.isNaN(m)) return 0;
  return clamp(h * 3600 + m * 60, 0, 86399);
}

/** Seconds since midnight -> "HH:MM" for an <input type=time>. */
export function toInputTime(secs: number): string {
  const h = Math.floor(secs / 3600);
  const m = Math.floor((secs % 3600) / 60);
  return `${String(h).padStart(2, "0")}:${String(m).padStart(2, "0")}`;
}

export function formatTime(secs: number, use24h: boolean): string {
  const h = Math.floor(secs / 3600);
  const m = Math.floor((secs % 3600) / 60);
  const mm = String(m).padStart(2, "0");
  if (use24h) return `${String(h).padStart(2, "0")}:${mm}`;
  const ampm = h >= 12 ? "PM" : "AM";
  const h12 = h === 0 ? 12 : h > 12 ? h - 12 : h;
  return `${h12}:${mm} ${ampm}`;
}

export function use24h(): boolean {
  try {
    return !new Intl.DateTimeFormat(navigator.language, { hour: "numeric" })
      .format(0)
      .match(/AM|PM/i);
  } catch {
    return true;
  }
}

export function isFahrenheit(scale?: string): boolean {
  return String(scale ?? "C").toUpperCase() === "F";
}

/** Wire temps are Celsius; the display scale only ever affects what we show. */
export function displayTemp(c: number, fahrenheit: boolean): number {
  return fahrenheit ? Math.round((c * 9) / 5 + 32) : Math.round(c * 2) / 2;
}

export function inputStep(fahrenheit: boolean): number {
  return fahrenheit ? 1 : 0.5;
}

/** Inverse of displayTemp: what the user typed -> Celsius for the wire. */
export function storeTemp(shown: number, fahrenheit: boolean): number {
  const c = fahrenheit ? ((shown - 32) * 5) / 9 : shown;
  return Math.round(clamp(c, TEMP_MIN_C, TEMP_MAX_C) * 2) / 2;
}

/** The keyboard step in displayed degrees for this dial's scale. */
export function tempNudge(fahrenheit: boolean): number {
  return fahrenheit ? TEMP_NUDGE_F : TEMP_NUDGE_C;
}

/**
 * Nudge a setpoint by `delta` *displayed* degrees (so ±0.5 on a °C dial, ±1 on
 * a °F one). Returns the patch to apply, going through the same display/store
 * conversion as the number inputs — which is also what clamps it to the server's
 * 4.5-32 °C bounds. A RANGE moves both ends so the band keeps its width; a
 * continuation carries no temperature, so it returns an empty patch and the
 * caller changes nothing rather than inventing one.
 */
export function nudgeTemp(sp: Setpoint, delta: number, fahrenheit: boolean): Partial<Setpoint> {
  if (isContinuation(sp)) return {};
  const step = (celsius: number) => storeTemp(displayTemp(celsius, fahrenheit) + delta, fahrenheit);
  if (sp.type === "RANGE") {
    return {
      "temp-min": step(sp["temp-min"] ?? 0),
      "temp-max": step(sp["temp-max"] ?? 0),
    };
  }
  return { temp: step(sp.temp ?? 0) };
}

/** Move a setpoint in time by `delta` seconds, clamped inside the day. */
export function nudgeTime(secs: number, delta: number): number {
  return snapTime(secs + delta);
}

export function tempLabel(sp: Setpoint, fahrenheit: boolean): string {
  if (isContinuation(sp)) return "holds";
  if (sp.type === "RANGE") {
    return `${displayTemp(sp["temp-min"] ?? 0, fahrenheit)}–${displayTemp(sp["temp-max"] ?? 0, fahrenheit)}`;
  }
  return String(displayTemp(sp.temp ?? 0, fahrenheit));
}

// ---------------------------------------------------------------------------
// Editing
// ---------------------------------------------------------------------------

/** A plausible slot for a new setpoint: an hour after the last, else 07:00. */
export function nextSlot(existing: Setpoint[]): number {
  if (existing.length === 0) return 7 * 3600;
  const last = existing[existing.length - 1]?.time ?? 0;
  return snapTime(Math.min(last + 3 * 3600, 86400 - TIME_STEP));
}

export function makeSetpoint(mode: Mode, time: number, fahrenheit: boolean): Setpoint {
  const base: Setpoint = { time: snapTime(time), type: mode, entry_type: "setpoint" };
  if (mode === "RANGE") {
    base["temp-min"] = storeTemp(fahrenheit ? 64 : 18, fahrenheit);
    base["temp-max"] = storeTemp(fahrenheit ? 74 : 24, fahrenheit);
  } else {
    base.temp = storeTemp(fahrenheit ? 68 : 20, fahrenheit);
  }
  return base;
}

/** Weekday/weekend template, for when the cloud bucket has no schedule yet. */
export function blankWeek(mode: Mode, fahrenheit: boolean): Days {
  const at = (h: number) => h * 3600;
  const weekday = (t: number) => makeSetpoint(mode, t, fahrenheit);
  const days: Days = {};
  for (const key of DAY_KEYS) {
    const weekend = key === "5" || key === "6";
    const times = weekend
      ? [at(8), at(12), at(18), at(22)]
      : [at(6), at(9), at(17), at(22)];
    days[key] = times.map((t) => {
      const sp = weekday(t);
      if (mode === "RANGE") {
        sp["temp-min"] = storeTemp(fahrenheit ? 60 : 16, fahrenheit);
        sp["temp-max"] = storeTemp(fahrenheit ? 76 : 24, fahrenheit);
      } else {
        sp.temp = storeTemp(fahrenheit ? 61 : 16, fahrenheit);
      }
      return sp;
    });
  }
  return days;
}

/** Client-side mirror of the server's validate_schedule (command.py:260-331). */
export function validate(s: Schedule): string[] {
  const errors: string[] = [];
  if (s.ver !== 2) errors.push("schedule ver must be 2");
  if (!MODES.includes(s.schedule_mode)) errors.push("schedule_mode must be HEAT, COOL or RANGE");
  for (const key of DAY_KEYS) {
    for (const [i, sp] of (s.days[key] ?? []).entries()) {
      const where = `${DAY_NAMES[Number(key)]} #${i + 1}`;
      if (sp.time < 0 || sp.time >= 86400) errors.push(`${where}: time out of range`);
      if (isContinuation(sp)) continue;
      if (sp.type === "RANGE") {
        for (const k of ["temp-min", "temp-max"] as const) {
          const t = sp[k];
          if (t === undefined) errors.push(`${where}: missing ${k}`);
          else if (t < TEMP_MIN_C || t > TEMP_MAX_C) errors.push(`${where}: ${k} outside ${TEMP_MIN_C}-${TEMP_MAX_C}°C`);
        }
        if ((sp["temp-min"] ?? 0) > (sp["temp-max"] ?? 0)) errors.push(`${where}: temp-min above temp-max`);
      } else {
        const t = sp.temp;
        if (t === undefined) errors.push(`${where}: missing temp`);
        else if (t < TEMP_MIN_C || t > TEMP_MAX_C) errors.push(`${where}: temp outside ${TEMP_MIN_C}-${TEMP_MAX_C}°C`);
      }
    }
  }
  return errors;
}
