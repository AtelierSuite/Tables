// Smoke tests for the WebAssembly engine, run with Node's built-ins only:
//
//   node Web/engine/tests/smoke.mjs [file.xlsx|file.numbers|file.csv ...]
//
// Loads build/tables-engine.wasm through the same engine.js the app uses,
// edits a workbook, saves and reopens it, and opens any files given.

import { readFile } from "node:fs/promises";
import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { strict as assert } from "node:assert";
import { Engine } from "../engine.js";

const web = new URL("../../", import.meta.url);
const engine = await Engine.load(readFile(fileURLToPath(new URL("build/tables-engine.wasm", web))));
const strings = JSON.parse(await readFile(fileURLToPath(new URL("build/strings/app-en.json", web)), "utf8"));

let failures = 0;
function test(name, body) {
  try {
    body();
    console.log(`✔ ${name}`);
  } catch (error) {
    failures++;
    console.log(`✘ ${name}\n  ${error.message}`);
  }
}

function call(cmd, args = {}, payload) {
  const { response, payload: output } = engine.call({ cmd, ...args }, payload);
  assert.ok(response.ok, `${cmd} failed: ${response.error}`);
  return { result: response.result, state: response.state, payload: output };
}

const texts = () => call("render", { x: 0, y: 0, w: 2000, h: 2000 }).result.ops.filter((op) => op.k === "text");

test("starts with the strings loaded", () => {
  call("init", { strings });
  const { result } = call("new", { name: "Smoke" });
  assert.deepEqual(result.sheets.map((sheet) => sheet.name), ["Sheet 1"]);
});

test("calculates formulas as cells are entered", () => {
  call("commit", { row: 0, column: 0, text: "10" });
  call("commit", { row: 1, column: 0, text: "32" });
  call("commit", { row: 2, column: 0, text: "=SUM(A1:A2)" });
  call("commit", { row: 3, column: 0, text: "=A3/0" });
  const shown = texts().map((op) => op.t);
  assert.ok(shown.includes("42"), `expected 42 in ${shown}`);
  assert.ok(shown.includes("#DIV/0!"), `expected #DIV/0! in ${shown}`);
});

test("undoes and redoes", () => {
  call("commit", { row: 0, column: 0, text: "11" });
  assert.ok(texts().some((op) => op.t === "43"));
  call("undo");
  assert.ok(texts().some((op) => op.t === "42"));
  call("redo");
  assert.ok(texts().some((op) => op.t === "43"));
});

test("formats the selection", () => {
  call("selectRange", { row: 0, column: 0, endRow: 2, endColumn: 0 });
  call("style", { toggle: "bold" });
  call("border", { preset: "outside" });
  const { state } = call("state");
  assert.equal(state.style.bold, true);
  assert.equal(state.status.sum, 11 + 32 + 43);
  assert.ok(call("render", { x: 0, y: 0, w: 500, h: 500 }).result.ops.some((op) => op.k === "line"));
});

test("inserts rows and keeps formulas pointing at their cells", () => {
  call("select", { row: 0, column: 0 });
  call("insertRows", { above: true });
  call("select", { row: 3, column: 0 });
  assert.equal(call("state").state.editText, "=SUM(A2:A3)");
});

test("saves as XLSX and reopens", () => {
  const { payload, result } = call("save", { format: "xlsx" });
  assert.equal(result.fileName, "Smoke.xlsx");
  assert.ok(payload.length > 1000);
  call("open", { name: "Smoke.xlsx" }, payload);
  assert.ok(texts().some((op) => op.t === "43" && op.b), "bold total survives the round trip");
});

test("saves and reads CSV", () => {
  const { payload } = call("save", { format: "csv", keep: true });
  const csv = new TextDecoder().decode(payload);
  assert.match(csv, /11,*\r?\n32,*\r?\n43/);
  call("open", { name: "data.csv" }, new TextEncoder().encode("a,b\n1,2\n"));
  assert.deepEqual(texts().map((op) => op.t), ["a", "b", "1", "2"]);
});

for (const path of process.argv.slice(2)) {
  const name = path.split("/").pop();
  test(`opens ${name}`, () => {
    const started = performance.now();
    const { result } = call("open", { name }, new Uint8Array(readFileSync(path)));
    const ops = call("render", { x: 0, y: 0, w: 1200, h: 900 }).result.ops;
    console.log(`  ${result.sheets.length} sheets, ${ops.length} drawing operations, ${Math.round(performance.now() - started)} ms`);
  });
}

if (failures) {
  console.log(`\n${failures} failed`);
  process.exit(1);
}
console.log("\nAll passed");
