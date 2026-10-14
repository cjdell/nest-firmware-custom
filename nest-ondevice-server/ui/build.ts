/**
 * Build the schedule SPA into ui/dist, which the Rust server embeds at compile
 * time (nest-ondevice-server/build.rs). Run with `./build ui` or, here, `bun run build`.
 *
 * Output names are deliberately unhashed (`app.js`, `app.css`): the binary
 * embeds the bytes, so the server's `Cache-Control: no-cache` is what keeps a
 * browser honest, not a filename.
 */
import { SolidPlugin } from "bun-plugin-solid";

const result = await Bun.build({
  entrypoints: ["./src/index.tsx", "./src/app.css"],
  outdir: "./dist",
  target: "browser",
  minify: true,
  naming: "[name].[ext]",
  plugins: [SolidPlugin()],
});

if (!result.success) {
  for (const log of result.logs) console.error(log);
  process.exit(1);
}

const html = await Bun.file("./src/index.html").text();
await Bun.write("./dist/index.html", html);

let total = 0;
for (const file of ["index.html", "index.js", "app.css"]) {
  const bytes = await Bun.file(`./dist/${file}`).size;
  total += bytes;
  console.log(`${file.padEnd(11)} ${String(bytes).padStart(7)} bytes`);
}
console.log(`${"total".padEnd(11)} ${String(total).padStart(7)} bytes embedded in the binary`);
