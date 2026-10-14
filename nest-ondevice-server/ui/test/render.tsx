/**
 * Render test: mount the real <App/> against a stubbed control API and assert
 * the editor actually paints, edits and saves.
 *
 * Run with `bun run test/run.ts` (which compiles this file with the Solid
 * plugin first — `bun test` does not apply build plugins). happy-dom supplies
 * the DOM; `fetch` is replaced below, so nothing leaves the process.
 */
import { render } from "solid-js/web";

import { App } from "../src/App";

let failures = 0;
function check(name: string, cond: boolean) {
  console.log(`${cond ? "PASS" : "FAIL"} ${name}`);
  if (!cond) failures++;
}

const tick = (ms = 30) => new Promise((r) => setTimeout(r, ms));

const SCHEDULE = {
  ver: 2,
  name: "",
  schedule_mode: "HEAT",
  // Fields the server does not model must survive a round-trip untouched.
  schedule_algorithm: "PROGRAM",
  days: {
    "0": {
      "0": { time: 23400, type: "HEAT", temp: 20.5, entry_type: "setpoint" },
      "1": { time: 32400, type: "HEAT", entry_type: "continuation" },
    },
    "1": { "0": { time: 25200, type: "HEAT", temp: 19, entry_type: "setpoint" } },
    "2": {},
    "3": {},
    "4": {},
    "5": {},
    "6": {},
  },
};

const saved: { body: string }[] = [];

function reply(payload: unknown) {
  // Only `ok`, `status` and `text()` are used by src/api.ts.
  return { ok: true, status: 200, text: async () => JSON.stringify(payload) };
}

globalThis.fetch = (async (input: RequestInfo | URL, init?: RequestInit) => {
  const path = String(input);
  if (path.startsWith("/api/devices")) {
    return reply({
      devices: [
        {
          serial: "ABC123",
          name: "Hallway Thermostat",
          temperature_scale: "C",
          subscription_count: 1,
          schedule_mode: "HEAT",
        },
      ],
      total: 1,
    });
  }
  if (path.startsWith("/api/schedule")) return reply({ serial: "ABC123", schedule: SCHEDULE, object_revision: 7 });
  if (path === "/command") {
    saved.push({ body: String(init?.body) });
    return reply({ success: true, data: { object_key: "schedule.ABC123", values: SCHEDULE } });
  }
  if (path === "/notify-device") return reply({ notified: 1 });
  throw new Error(`unexpected fetch: ${path}`);
}) as typeof fetch;

const root = document.createElement("div");
root.id = "app";
document.body.appendChild(root);

render(() => <App />, root);
await tick(80);

const text = () => root.textContent ?? "";
const days = () => Array.from(root.querySelectorAll("li.day"));
const setpoints = () => Array.from(root.querySelectorAll("li.sp"));
const buttons = () => Array.from(root.querySelectorAll("button"));
const button = (label: string) =>
  buttons().find((b) => (b.textContent ?? "").trim().startsWith(label));

check("device name rendered", text().includes("Hallway Thermostat"));
check("device connection state rendered", text().includes("device connected"));
check("seven day rows", days().length === 7);
check("day names rendered", text().includes("Monday") && text().includes("Sunday"));
check("bucket revision shown", text().includes("rev 7"));
const tempInputs = () => Array.from(root.querySelectorAll('input[type="number"]')) as HTMLInputElement[];
check("setpoint temperature shown", tempInputs()[0]?.value === "20.5");
check("setpoint time shown", (root.querySelector('input[type="time"]') as HTMLInputElement | null)?.value === "06:30");
check("continuation entry has no invented temperature", text().includes("holds the previous setpoint"));
check("two setpoints on Monday, one on Tuesday", setpoints().length === 3);
check("empty day says so", text().includes("Nothing scheduled on Wednesday"));
check("save is disabled with nothing to do", button("Save")?.disabled === true);
check("learning-mode switch rendered", !!root.querySelector<HTMLInputElement>('input[type="checkbox"]'));
check("push button rendered", !!button("Push bucket to device now"));

// Edit: add a setpoint to Wednesday, then save and inspect the payload.
const addButton = buttons().find((b) => b.getAttribute("aria-label")?.startsWith("Add setpoint on Wednesday"));
check("Wednesday has an add button", !!addButton);
addButton?.click();
await tick(30);

check("adding a setpoint adds a row", setpoints().length === 4);
check("dirty state enables save", button("Save")?.disabled === false);
check("dirty banner explains the write", text().includes("Unsaved changes"));

button("Save")?.click();
await tick(80);

check("save posted set_schedule", saved.length === 1 && saved[0].body.includes('"set_schedule"'));
const payload = saved.length
  ? (JSON.parse(saved[0].body) as { command: string; value: { days: Record<string, unknown>; schedule_algorithm?: string } })
  : null;
const wed = payload?.value.days?.["2"] as Record<string, { time: number; entry_type?: string }> | undefined;
check("days sent as the device-native dict-of-dicts", !!wed && Object.keys(wed).join(",") === "0");
check("day keys are 0-6 with Monday first", Object.keys(JSON.parse(saved[0].body).value.days).join(",") === "0,1,2,3,4,5,6");
check("new setpoint carries entry_type", wed?.["0"]?.entry_type === "setpoint");
check("unknown top-level fields preserved", payload?.value.schedule_algorithm === "PROGRAM");
check("save re-reads the bucket", text().includes("Saved."));

// Time editing writes seconds since midnight, snapped to the quarter hour.
const timeInput = root.querySelector('input[type="time"]') as HTMLInputElement | null;
check("time inputs are populated", !!timeInput && timeInput.value === "06:30");
if (timeInput) {
  timeInput.value = "07:07";
  timeInput.dispatchEvent(new Event("input", { bubbles: true }));
  await tick(30);
  button("Save")?.click();
  await tick(80);
  const mon = JSON.parse(saved[1].body).value.days["0"] as Record<string, { time: number }>;
  check("time edit snapped to 15 minutes and became 07:00", mon["0"].time === 25200);
  check("continuation entry survived the edit", (JSON.parse(saved[1].body).value.days["0"]["1"] as { entry_type?: string }).entry_type === "continuation");
}

if (failures) {
  console.log(`\n${failures} RENDER TEST FAILURE(S)`);
  process.exit(1);
}
console.log("\nRENDER TEST PASSED");
