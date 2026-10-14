/**
 * Dev server for the schedule SPA: one command, no thermostat, no Rust server.
 *
 *   cd nest-ondevice-server/ui && bun run dev.ts     # -> http://127.0.0.1:8083
 *
 * Serves the app *from src/* against the in-memory fake in `mock.ts`. There is
 * no separate watcher: every request for the bundle checks the mtimes under
 * `src/` and rebuilds if anything changed, so editing a .tsx and hitting refresh
 * is the whole loop (unminified, inline sourcemaps). The mock API is stateful,
 * so a save followed by Re-read round-trips through the same dict-of-dicts the
 * real device uses.
 *
 * Options (env): DEV_PORT=8083 DEV_SCALE=F DEV_RANGE=1 DEV_EMPTY=1 DEV_LEARNING=1
 *
 * Simulate the parts of the device that only misbehave on their own:
 *   curl -XPOST localhost:8083/mock/clobber   # dial re-publishes its own schedule
 *   curl -XPOST localhost:8083/mock/learn     # learning mode invents a setpoint
 *   curl -XPOST localhost:8083/mock/empty     # bucket empty ("never rebooted")
 *   curl -XPOST localhost:8083/mock/reset     # back to the published fixture
 *   curl      localhost:8083/mock/state       # what the bucket holds right now
 */
import { readdirSync, statSync } from "node:fs";
import { join } from "node:path";

import { SolidPlugin } from "bun-plugin-solid";

import { MockNest } from "./mock";

const port = Number(process.env.DEV_PORT ?? 8083);
const mock = new MockNest({
  scale: process.env.DEV_SCALE === "F" ? "F" : "C",
  range: process.env.DEV_RANGE === "1",
  empty: process.env.DEV_EMPTY === "1",
  learning: process.env.DEV_LEARNING === "1",
});

// --- bundle, rebuilt when anything under src/ changes -----------------------

let bundle: { code: string; builtAt: number } | null = null;
let bundleError = "";
function newestMtime(dir: string): number {
  let newest = 0;
  for (const entry of readdirSync(dir, { withFileTypes: true })) {
    const path = join(dir, entry.name);
    const time = entry.isDirectory() ? newestMtime(path) : statSync(path).mtimeMs;
    if (time > newest) newest = time;
  }
  return newest;
}

async function appJs(): Promise<Response> {
  const changed = bundle === null || newestMtime("src") > bundle.builtAt;
  if (changed) {
    // Bun.build rejects on some errors instead of returning success:false, and an
    // exception here would become Bun's HTML error page for /index.js.
    try {
      const result = await Bun.build({
        entrypoints: ["./src/index.tsx"],
        write: false,
        target: "browser",
        minify: false,
        sourcemap: "inline",
        plugins: [SolidPlugin()],
      });
      if (!result.success) {
        bundleError = result.logs.map((l) => String(l.message ?? l)).join("\n");
      } else {
        const code = await result.outputs[0]!.text(); // .text() is async in Bun
        bundle = { code, builtAt: Date.now() };
        bundleError = "";
        console.log(`built ${(code.length / 1024).toFixed(0)} KB`);
      }
    } catch (error: any) {
      // Bun rejects with AggregateError("Bundle failed"); the real babel/tsx
      // code frame is on the inner BuildMessage entries.
      const inner = Array.isArray(error?.errors) ? error.errors : [];
      bundleError = inner.length
        ? inner.map((e: any) => String(e?.message ?? e)).join("\n")
        : error instanceof Error
          ? error.message
          : String(error);
      console.log(`build failed:\n${bundleError}`);
    }
  }
  if (bundleError) {
    // A syntax error should be readable in the browser, not a blank page.
    return new Response(`throw new Error(${JSON.stringify(bundleError)});`, {
      headers: { "Content-Type": "text/javascript; charset=utf-8", "X-Dev-Error": "1" },
    });
  }
  return new Response(bundle!.code, {
    headers: { "Content-Type": "text/javascript; charset=utf-8", "Cache-Control": "no-store" },
  });
}

const file = (path: string, type: string) =>
  new Response(Bun.file(path), { headers: { "Content-Type": type, "Cache-Control": "no-store" } });

Bun.serve({
  port,
  async fetch(request) {
    const url = new URL(request.url);
    const path = url.pathname;

    const api = await mock.handle(request);
    if (api) return api;

    if (request.method === "GET") {
      if (path === "/" || path === "/index.html") return file("src/index.html", "text/html; charset=utf-8");
      if (path === "/index.js") return await appJs();
      if (path === "/app.css") return file("src/app.css", "text/css; charset=utf-8");
      if (path === "/favicon.ico") return new Response(null, { status: 204 });
    }
    return Response.json({ error: `dev server: no route for ${request.method} ${path}` }, { status: 404 });
  },
  development: true,
});

console.log(`
  schedule SPA (dev)   http://127.0.0.1:${port}/
  fake thermostat      ${mock.serial}  scale ${process.env.DEV_SCALE === "F" ? "F" : "C"}${process.env.DEV_RANGE === "1" ? "  RANGE" : "  HEAT"}${process.env.DEV_EMPTY === "1" ? "  (empty bucket)" : ""}
  rebuilds on refresh;  curl -XPOST http://127.0.0.1:${port}/mock/clobber  to let the dial overwrite you
`);
