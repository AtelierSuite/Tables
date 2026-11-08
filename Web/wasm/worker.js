// The engine's worker: loads tables-engine.wasm.gz and answers the page's requests
// one at a time, off the main thread, so opening or recalculating a large
// workbook never stops the window from responding.
//
// Messages in:  { id, request, payload? }
// Messages out: { id, response, payload? } or { id, error, fatal }

import { Engine } from "./engine.js";

// The page passes the user's time zone in the worker's address; Foundation reads it from TZ.
const timeZone = new URL(self.location.href).searchParams.get("tz");

/**
 * The engine, kept gzipped (build/tables-engine.wasm.gz) to fit hosts' file size limits.
 * Decompressed here, unless a server already did that on the way.
 */
async function engineModule() {
  const response = await fetch(new URL("../build/tables-engine.wasm.gz", import.meta.url));
  if (!response.ok) throw new Error(`Couldn't load the engine (${response.status})`);
  const bytes = new Uint8Array(await response.arrayBuffer());
  if (bytes[0] !== 0x1f || bytes[1] !== 0x8b) return bytes;
  const stream = new Blob([bytes]).stream().pipeThrough(new DecompressionStream("gzip"));
  return new Response(stream, { headers: { "Content-Type": "application/wasm" } });
}

const ready = Engine.load(engineModule(), {
  env: timeZone ? { TZ: timeZone } : {},
  stdout: (line) => console.log("[engine]", line),
  stderr: (line) => console.warn("[engine]", line),
});
let broken = null;

self.addEventListener("message", async (event) => {
  const { id, request, payload } = event.data;
  if (broken) {
    self.postMessage({ id, error: broken, fatal: true });
    return;
  }
  try {
    const engine = await ready;
    const { response, payload: output } = engine.call(request, payload);
    self.postMessage({ id, response, payload: output }, output ? [output.buffer] : []);
  } catch (error) {
    // A trap leaves the module's memory in an unknown state: nothing after it can be trusted.
    const fatal = error instanceof WebAssembly.RuntimeError;
    if (fatal) broken = String(error.message || error);
    self.postMessage({ id, error: String(error?.stack || error), fatal });
  }
});
