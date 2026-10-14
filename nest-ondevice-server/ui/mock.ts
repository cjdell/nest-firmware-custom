/**
 * In-memory fake of the on-device control API, for developing the SPA without a
 * thermostat (or a Rust server) in reach.
 *
 * Deliberately faithful to `src/control.rs` rather than convenient: the bucket
 * is stored in the device-native dict-of-dicts form, `set_schedule` is a *full
 * replacement* that bumps `object_revision` and stamps `object_timestamp`,
 * validation mirrors `cmd_set_schedule`, and errors come back as
 * `400 {success:false,message}`. It also simulates the two things that only the
 * real device does — re-publishing its own schedule over ours, and inventing
 * setpoints while learning mode is on — because those are the failure modes the
 * editor has to survive (AGENTS.md trap 29).
 */
import {
  DAY_KEYS,
  MODES,
  type DeviceStatus,
  type Mode,
  type Schedule,
  type Setpoint,
  clone,
  denormalizeDays,
  normalizeDays,
  normalizeMode,
  validate,
} from "./src/model";

export interface MockOptions {
  /** Display scale of the fake dial; wire temps stay Celsius either way. */
  scale?: "C" | "F";
  /** Fake a range (heat+cool) unit so the RANGE UI is reachable. */
  range?: boolean;
  /** Start with an empty `schedule.<serial>` bucket (the "never rebooted" case). */
  empty?: boolean;
  /** Learning mode on the fake dial, which then invents setpoints. */
  learning?: boolean;
}

export const SERIAL = "02AA01AC2614065C";

const ok = (data: unknown) =>
  Response.json({ success: true, data });
const fail = (message: string, status = 400) =>
  Response.json({ success: false, message }, { status });

export class MockNest {
  readonly serial = SERIAL;
  private devices: DeviceStatus[];
  private bucket: Record<string, unknown> | null = null;
  private revision = 0;
  private timestamp = 0;
  private opts: Required<MockOptions>;
  /** Every /command we were sent, newest last — handy when asserting by hand. */
  readonly commands: { command: string; value: unknown }[] = [];

  constructor(opts: MockOptions = {}) {
    this.opts = {
      scale: opts.scale ?? "C",
      range: opts.range ?? false,
      empty: opts.empty ?? false,
      learning: opts.learning ?? false,
    };
    this.devices = [
      {
        serial: this.serial,
        name: "Hallway Thermostat (mock)",
        temperature_scale: this.opts.scale,
        schedule_mode: this.opts.range ? "RANGE" : "HEAT",
        mode: this.opts.range ? "heat" : "heat",
        learning_mode: this.opts.learning,
        is_available: true,
        subscription_count: 1,
        capabilities: { can_heat: true, can_cool: this.opts.range },
      },
    ];
    if (!this.opts.empty) this.reset();
  }

  /** Restore a plausible device-published schedule (dict-of-dicts, with a continuation). */
  reset(): void {
    const at = (h: number, m = 0) => h * 3600 + m * 60;
    const sp = (time: number, temp: number): Setpoint => ({
      time,
      type: this.opts.range ? "RANGE" : "HEAT",
      ...(this.opts.range ? { "temp-min": temp - 2, "temp-max": temp + 2 } : { temp }),
      entry_type: "setpoint",
    });
    const days: Record<string, Record<string, Setpoint>> = {};
    for (const key of DAY_KEYS) {
      const weekend = key === "5" || key === "6";
      const entries: Setpoint[] = weekend
        ? [sp(at(8), 21), sp(at(12), 19), sp(at(18), 21.5), sp(at(22), 17)]
        : [sp(at(6, 30), 20.5), sp(at(9), 17), sp(at(17), 21), sp(at(22), 17)];
      // The device marks "the previous setpoint still holds" entries.
      entries.push({ time: at(23), type: this.opts.range ? "RANGE" : "HEAT", entry_type: "continuation" });
      const byIndex: Record<string, Setpoint> = {};
      entries.forEach((entry, i) => void (byIndex[String(i)] = entry));
      days[key] = byIndex;
    }
    this.bucket = {
      ver: 2,
      name: "",
      schedule_mode: this.opts.range ? "RANGE" : "HEAT",
      // Fields the server does not model, as the real device sends them.
      schedule_algorithm: "PROGRAM",
      preconditioning_enabled: true,
      created_at: 1_700_000_000_000,
      days,
    };
    this.revision = 1;
    this.timestamp = Date.now() - 60_000;
  }

  clearBucket(): void {
    this.bucket = null;
    this.revision = 0;
    this.timestamp = 0;
  }

  /**
   * The dial re-publishes its own copy: newest timestamp wins, so this is what
   * "our save silently disappeared" looks like from the editor's point of view.
   */
  deviceRepublishes(): { revision: number; changedDay: string } {
    if (!this.bucket) this.reset();
    const days = (this.bucket!.days ?? {}) as Record<string, Record<string, Setpoint>>;
    const day = days["2"] ?? (days["2"] = {});
    const keys = Object.keys(day).filter((k) => day[k].entry_type !== "continuation");
    const target = day[keys[0] ?? "0"];
    if (target) {
      if (target.temp !== undefined) target.temp = Math.round((target.temp + 1.5) * 2) / 2;
      if (target["temp-min"] !== undefined) target["temp-min"] = (target["temp-min"] as number) + 1.5;
    }
    this.revision += 1;
    this.timestamp = Date.now();
    return { revision: this.revision, changedDay: "2" };
  }

  /** Learning mode: the dial appends a setpoint where the user adjusted by hand. */
  learningAddsSetpoint(): { revision: number } {
    if (!this.bucket) this.reset();
    const days = (this.bucket!.days ?? {}) as Record<string, Record<string, Setpoint>>;
    const day = days["4"] ?? (days["4"] = {});
    const next = String(Object.keys(day).length);
    day[next] = {
      time: 15 * 3600,
      type: normalizeMode(this.bucket!.schedule_mode) as Mode,
      temp: 22,
      entry_type: "setpoint",
    };
    this.revision += 1;
    this.timestamp = Date.now();
    return { revision: this.revision };
  }

  private setLearningMode(on: boolean) {
    this.devices = this.devices.map((d) => ({ ...d, learning_mode: on }));
    return ok({ object_key: `device.${this.serial}`, values: { learning_mode: on } });
  }

  /** Mirrors `cmd_set_schedule`: validate, then replace the bucket wholesale. */
  private setSchedule(value: unknown) {
    if (typeof value !== "object" || value === null) return fail("Schedule must be a JSON object");
    const raw = value as Record<string, unknown>;
    if (raw.ver !== 2) return fail("Schedule ver must be 2");
    const mode = String(raw.schedule_mode ?? raw.mode ?? "").toUpperCase();
    if (!MODES.includes(mode as Mode)) return fail("schedule_mode must be HEAT, COOL or RANGE");
    if (typeof raw.days !== "object" || raw.days === null) return fail("Schedule must contain a 'days' object");

    const schedule = {
      ...raw,
      ver: 2,
      name: typeof raw.name === "string" ? raw.name : "",
      schedule_mode: mode as Mode,
      days: normalizeDays(raw.days),
    } satisfies Schedule;
    const problems = validate(schedule);
    if (problems.length) return fail(problems[0]);

    // Unknown top-level fields survive; days go back out device-native.
    this.bucket = {
      ...raw,
      ver: 2,
      name: schedule.name,
      schedule_mode: mode,
      days: denormalizeDays(schedule.days),
    };
    this.revision += 1;
    this.timestamp = Date.now();
    return ok({ object_key: `schedule.${this.serial}`, values: this.bucket });
  }

  async handle(request: Request): Promise<Response | null> {
    const url = new URL(request.url);
    const path = url.pathname;
    const body = (async () => {
      try {
        return (await request.json()) as Record<string, unknown>;
      } catch {
        return {};
      }
    })();

    if (request.method === "GET" && path === "/api/devices") {
      return Response.json({ devices: this.devices, total: this.devices.length });
    }
    if (request.method === "GET" && path === "/api/schedule") {
      return Response.json({
        serial: this.serial,
        schedule: this.bucket,
        object_revision: this.revision,
        object_timestamp: this.timestamp,
      });
    }
    if (request.method === "GET" && path === "/status") {
      const d = this.devices[0];
      return Response.json({ ...d, target_temperature: 21, current_temperature: 20.4 });
    }
    if (request.method === "POST" && path === "/notify-device") {
      await body;
      return Response.json({ notified: 1 });
    }
    if (request.method === "POST" && path === "/command") {
      const payload = await body;
      const command = String(payload.command ?? "");
      this.commands.push({ command, value: payload.value });
      switch (command) {
        case "set_schedule":
          return this.setSchedule(payload.value);
        case "set_schedule_mode": {
          const mode = String(payload.value ?? "").toUpperCase();
          if (!MODES.includes(mode as Mode)) return fail("schedule_mode must be HEAT, COOL or RANGE");
          if (this.bucket) this.bucket.schedule_mode = mode;
          this.revision += 1;
          this.timestamp = Date.now();
          return ok({ object_key: `shared.${this.serial}`, values: { schedule_mode: mode } });
        }
        case "set_device_setting": {
          const value = (payload.value ?? {}) as Record<string, unknown>;
          if ("learning_mode" in value) return this.setLearningMode(!!value.learning_mode);
          return ok({ object_key: `device.${this.serial}`, values: value });
        }
        case "set_temperature":
          return ok({ object_key: `shared.${this.serial}`, values: { target_temperature: payload.value } });
        default:
          return fail(`Unknown command: ${command}`);
      }
    }

    // Dev controls: simulate the device, not the API.
    if (request.method === "POST" && path === "/mock/clobber") {
      return Response.json({ device_republished: this.deviceRepublishes() });
    }
    if (request.method === "POST" && path === "/mock/learn") {
      return Response.json(this.learningAddsSetpoint());
    }
    if (request.method === "POST" && path === "/mock/reset") {
      this.reset();
      return Response.json({ ok: true, object_revision: this.revision });
    }
    if (request.method === "POST" && path === "/mock/empty") {
      this.clearBucket();
      return Response.json({ ok: true });
    }
    if (request.method === "GET" && path === "/mock/state") {
      return Response.json({
        devices: this.devices,
        object_revision: this.revision,
        object_timestamp: this.timestamp,
        schedule: this.bucket,
        commands: this.commands.slice(-20),
      });
    }
    return null;
  }

  /** Deep copy of the bucket, for tests that must not alias the mock's state. */
  snapshot(): Record<string, unknown> | null {
    return this.bucket ? clone(this.bucket) : null;
  }
}
