/**
 * Compile the render test with the Solid plugin and run it under happy-dom.
 * `bun test` cannot be used: Bun's test runner does not apply build plugins, so
 * the .tsx would be transpiled without Solid's compiler transform.
 */
import { GlobalRegistrator } from "@happy-dom/global-registrator";
import { SolidPlugin } from "bun-plugin-solid";

GlobalRegistrator.register({ url: "http://127.0.0.1:8082/" });

const outdir = "./test/.out";
const result = await Bun.build({
  entrypoints: ["./test/render.tsx"],
  outdir,
  target: "browser",
  minify: false,
  plugins: [SolidPlugin()],
});

if (!result.success) {
  for (const log of result.logs) console.error(log);
  process.exit(1);
}

await import(new URL("./.out/render.js", import.meta.url).href);
