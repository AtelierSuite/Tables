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

test("lays tables out together on a canvas", () => {
  const { result: opened } = call("new", { name: "Canvas" });
  const first = opened.sheets[0].id;
  call("commit", { row: 0, column: 0, text: "first" });
  call("addTable");
  call("commit", { row: 0, column: 0, text: "second" });
  let { result: info } = call("info");
  assert.equal(info.canvases.length, 1);
  const [canvas] = info.canvases;
  assert.equal(canvas.tables[0].id, first);
  const second = canvas.tables[1].id;
  assert.ok(canvas.tables[1].y > canvas.tables[0].y, "the new table goes below");
  // Any table draws, not just the active one.
  const drawn = (id) => call("render", { id, x: 0, y: 0, w: 500, h: 200 }).result.ops.filter((op) => op.k === "text").map((op) => op.t);
  assert.deepEqual(drawn(first), ["first"]);
  assert.deepEqual(drawn(second), ["second"]);
  assert.equal(call("layout", { id: first }).result.sheet, first);
  call("moveTable", { id: second, x: 400, y: 66 });
  call("showTableName", { id: first, shown: false });
  call("renameTable", { id: second, name: "Totals" });
  call("renameCanvas", { id: first, name: "Summary" });
  info = call("info").result;
  assert.equal(info.canvases[0].name, "Summary");
  assert.deepEqual([info.canvases[0].tables[1].x, info.canvases[0].tables[1].y], [400, 66]);
  assert.equal(info.canvases[0].tables[0].showsName, false);
  assert.equal(info.canvases[0].tables[1].name, "Totals");
  // The layout survives a save, and moving a table can be undone.
  const { payload } = call("save", { format: "xlsx" });
  info = call("open", { name: "Canvas.xlsx" }, payload).result;
  assert.equal(info.canvases[0].name, "Summary");
  assert.equal(info.canvases[0].tables[1].x, 400);
  const id = info.canvases[0].tables[1].id;
  call("moveTable", { id, x: 40, y: 400 });
  call("undo");
  assert.equal(call("info").result.canvases[0].tables[1].x, 400);
  call("removeFromCanvas", { id });
  assert.equal(call("info").result.canvases.length, 0);
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
