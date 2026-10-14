/**
 * Thin client for the on-device control API (default port 8082).
 *
 * Same-origin by construction: the server embeds and serves this bundle, so
 * every call is a relative path and there is nothing to configure.
 */
import type { DeviceStatus, ScheduleResponse, Mode } from "./model";

export interface CommandResult {
  success: boolean;
  message?: string;
  data?: { object_key?: string; values?: Record<string, unknown> };
}

async function request<T>(path: string, init?: RequestInit): Promise<T> {
  const res = await fetch(path, init);
  const text = await res.text();
  let body: unknown = null;
  if (text) {
    try {
      body = JSON.parse(text);
    } catch {
      throw new Error(`${res.status} ${res.statusText || ""}: ${text.slice(0, 120)}`);
    }
  }
  if (!res.ok) {
    const msg =
      body && typeof body === "object" && "message" in body
        ? String((body as { message: unknown }).message)
        : `${res.status} ${res.statusText}`;
    throw new Error(msg);
  }
  return body as T;
}

export async function listDevices(): Promise<DeviceStatus[]> {
  const body = await request<{ devices: DeviceStatus[]; total: number }>("/api/devices");
  return body.devices ?? [];
}

export async function getSchedule(serial: string): Promise<ScheduleResponse> {
  return request<ScheduleResponse>(`/api/schedule?serial=${encodeURIComponent(serial)}`);
}

export async function setSchedule(serial: string, schedule: unknown): Promise<CommandResult> {
  return request<CommandResult>("/command", {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ serial, command: "set_schedule", value: schedule }),
  });
}

export async function setScheduleMode(serial: string, mode: Mode): Promise<CommandResult> {
  return request<CommandResult>("/command", {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ serial, command: "set_schedule_mode", value: mode }),
  });
}

/**
 * Learning mode makes the dial invent its own setpoints after a manual
 * adjustment, so it has to be off for a hand-written schedule to stick
 * (the community workaround is to re-clear the schedule on every poll).
 */
export async function setLearningMode(serial: string, enabled: boolean): Promise<CommandResult> {
  return request<CommandResult>("/command", {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({
      serial,
      command: "set_device_setting",
      value: { learning_mode: enabled },
    }),
  });
}

/** Force the server to push the current buckets down the held long-poll. */
export async function notifyDevice(serial: string): Promise<unknown> {
  return request("/notify-device", {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ serial }),
  });
}
