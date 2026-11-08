#!/usr/bin/env node
// Enforces the design system's prohibitions (see DESIGN.md, "Rules") across Web/.
// Usage: node design/lint.mjs [dir ...]   (defaults to the Web/ folder)
// Exits 1 and prints file:line for every violation. No dependencies.

import { readFileSync, readdirSync, statSync } from "node:fs";
import { join, relative, extname, dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const here = dirname(fileURLToPath(import.meta.url));
const webRoot = resolve(here, "..");
const roots = process.argv.slice(2).length ? process.argv.slice(2).map((p) => resolve(p)) : [webRoot];
const skipDirs = new Set(["node_modules", "dist", "build", ".build", "coverage", "vendor"]);
const self = fileURLToPath(import.meta.url);

const SYSTEM_FONT = "system-ui, -apple-system, BlinkMacSystemFont, sans-serif";
const NEUTRAL_EDGE = /^(var\(--ds-(border-subtle-0[01]|border-strong-01|border-disabled|grid-line)\)|transparent)$/;
const FORBIDDEN_NAMES = /(^|[-_])(chips?|pills?|badges?|tags?|tokens?|lozenges?|eyebrows?|overlines?|kickers?)($|[-_])/i;
const MONO_ELEMENTS = /<(code|pre|kbd|samp|tt|var)[\s>]/i;

// The accent colour must match the Apple app's AccentColor asset.
const accentAsset = resolve(webRoot, "../Apple/Shared/Resources/Assets.xcassets/AccentColor.colorset/Contents.json");
const APP_ACCENT = (() => {
  try {
    const { colors } = JSON.parse(readFileSync(accentAsset, "utf8"));
    const c = colors.find((entry) => !entry.appearances)?.color.components;
    const channel = (v) => {
      const n = String(v).startsWith("0x") ? parseInt(v, 16) : Math.round(parseFloat(v) * (parseFloat(v) <= 1 ? 255 : 1));
      return n.toString(16).padStart(2, "0");
    };
    return `#${channel(c.red)}${channel(c.green)}${channel(c.blue)}`;
  } catch {
    return null;
  }
})();

const problems = [];
const seen = new Set();
const report = (file, line, rule, detail) => {
  const key = `${file}:${line}:${rule}:${detail}`;
  if (!seen.has(key)) { seen.add(key); problems.push({ file, line, rule, detail }); }
};

function walk(dir) {
  for (const name of readdirSync(dir)) {
    if (name.startsWith(".") || skipDirs.has(name)) continue;
    const path = join(dir, name);
    if (statSync(path).isDirectory()) walk(path);
    else if (path !== self) lintFile(path);
  }
}

function lintFile(path) {
  const ext = extname(path);
  const text = readFileSync(path, "utf8");
  if (ext === ".css") lintCSS(path, text, 1);
  else if (ext === ".html") lintHTML(path, text);
  else if ([".js", ".mjs", ".ts", ".tsx", ".jsx"].includes(ext)) lintScript(path, text);
}

const lineAt = (text, index, base = 1) => base + text.slice(0, index).split("\n").length - 1;

// Minimal CSS walker: yields { selector, property, value, line } for every declaration.
function* declarations(css, baseLine) {
  const clean = css.replace(/\/\*[\s\S]*?\*\//g, (m) => m.replace(/[^\n]/g, " "));
  const stack = [];
  let buf = "";
  let bufStart = 0;
  let quote = null;
  for (let i = 0; i < clean.length; i++) {
    const c = clean[i];
    if (quote) {
      buf += c;
      if (c === quote && clean[i - 1] !== "\\") quote = null;
      continue;
    }
    if (c === '"' || c === "'") { quote = c; buf += c; continue; }
    if (c === "(") {
      // Keep url(...) and other functions intact even if they contain ; or {.
      let depth = 0, j = i;
      for (; j < clean.length; j++) {
        if (clean[j] === "(") depth++;
        else if (clean[j] === ")" && --depth === 0) break;
      }
      buf += clean.slice(i, j + 1);
      i = j;
      continue;
    }
    if (c === "{") { stack.push(buf.trim()); buf = ""; bufStart = i + 1; continue; }
    if (c === ";" || c === "}") {
      const decl = buf.trim();
      if (decl && stack.length) {
        const colon = decl.indexOf(":");
        if (colon > 0) {
          const offset = bufStart + buf.indexOf(decl);
          yield {
            selector: stack[stack.length - 1],
            property: decl.slice(0, colon).trim().toLowerCase(),
            value: decl.slice(colon + 1).trim(),
            line: lineAt(clean, offset, baseLine),
          };
        }
      }
      if (c === "}") stack.pop();
      buf = "";
      bufStart = i + 1;
      continue;
    }
    if (!buf.trim()) bufStart = i;
    buf += c;
  }
}

function lintCSS(file, css, baseLine) {
  for (const d of declarations(css, baseLine)) {
    lintDeclaration(file, d.selector, d.property, d.value, d.line);
    lintSelector(file, d.selector, d.line);
  }
}

function lintSelector(file, selector, line) {
  for (const cls of selector.matchAll(/\.([A-Za-z0-9_-]+)/g)) {
    if (FORBIDDEN_NAMES.test(cls[1])) report(file, line, "no-chips-or-eyebrows", `class .${cls[1]}`);
  }
}

function lintDeclaration(file, selector, prop, rawValue, line) {
  const value = rawValue.replace(/\s*!important$/, "").trim();
  const v = value.toLowerCase();

  // Cursor: pointer only on a real hyperlink.
  if (prop === "cursor" && v === "pointer") {
    const ok = selector.split(",").every((s) => /^a\[href\](:[a-z-]+)*$/.test(s.trim()));
    if (!ok) report(file, line, "no-pointer-cursor", `cursor: pointer on "${selector}"`);
  }

  // Shape: square everywhere. Only checkboxes, radios, switches, sliders and spinners may round off.
  if (/^border(-(top|bottom|start|end)-(left|right|start|end))?-radius$/.test(prop) && !/^(0(px)?|var\(--ds-radius\))$/.test(v)) {
    const ok = selector.split(",").every((s) => /check|radio|switch|slider|range|spinner/.test(s));
    if (!ok) report(file, line, "square-corners", `${prop}: ${value} on "${selector}"`);
  }

  // Selection: UI text is never selectable; only fields, editable regions and document content are.
  if ((prop === "user-select" || prop === "-webkit-user-select") && v !== "none") {
    const ok = selector.split(",").every((s) => /input|textarea|contenteditable|\.ds-document-content/.test(s));
    if (!ok) report(file, line, "no-selectable-ui-text", `${prop}: ${value} on "${selector}"`);
  }

  // Dragging: UI images never drag.
  if (prop === "-webkit-user-drag" && v !== "none") report(file, line, "no-draggable-images", `${prop}: ${value}`);

  // Case: never transform to capitals; never small caps.
  if (prop === "text-transform" && v !== "none") report(file, line, "no-all-caps", `text-transform: ${value}`);
  if ((prop === "font-variant-caps" || prop === "font-variant") && /(small|petite|titling)-caps|unicase/.test(v)) {
    report(file, line, "no-all-caps", `${prop}: ${value}`);
  }

  // Tracking: no letter-spacing at all. No expanded widths.
  if (prop === "letter-spacing" && !/^(0(px|em|rem)?|normal)$/.test(v)) {
    report(file, line, "no-wide-kerning", `letter-spacing: ${value}`);
  }
  if (prop === "font-stretch" && /expanded|1[1-9]\d%/.test(v)) report(file, line, "no-wide-kerning", `font-stretch: ${value}`);

  // Fonts: system sans-serif only.
  if (/monospace|courier|menlo|monaco|consolas|sf mono|ui-monospace/.test(v)) {
    report(file, line, "system-font-only", `${prop}: ${value}`);
  }
  if (prop === "--ds-accent" && APP_ACCENT && v !== APP_ACCENT) {
    report(file, line, "app-accent", `--ds-accent is ${value} but the app's AccentColor is ${APP_ACCENT}`);
  }
  if (prop === "--ds-font" && value !== SYSTEM_FONT) report(file, line, "system-font-only", `--ds-font changed to ${value}`);
  if (prop === "font-family" && !/^(inherit|var\(--ds-font\))$/.test(v)) {
    report(file, line, "system-font-only", `font-family: ${value}`);
  }
  if (prop === "font" && !/^(inherit|var\(--ds-type-[a-z0-9-]+\))$/.test(v)) {
    report(file, line, "system-font-only", `font: ${value} (use a --ds-type-* token)`);
  }
  if (/^--ds-type-/.test(prop) && !/var\(--ds-font\)$/.test(v)) report(file, line, "system-font-only", `${prop} must end in var(--ds-font)`);

  // Fingernail strips: no thick or coloured single-edge borders, no offset inset shadows.
  const edge = prop.match(/^border-(top|right|bottom|left|inline-start|inline-end|block-start|block-end)(-width|-color)?$/);
  if (edge) {
    const part = edge[2];
    if (part === "-width") {
      if (widthPx(v) > 1) report(file, line, "no-fingernail-strips", `${prop}: ${value}`);
    } else if (part === "-color") {
      if (!NEUTRAL_EDGE.test(v)) report(file, line, "no-fingernail-strips", `${prop}: ${value}`);
    } else if (v !== "0" && v !== "none") {
      const width = widthPx(v);
      const color = v.replace(/^[\d.]+(px|rem|em)?\s*/, "").replace(/^(solid|dashed|dotted|double)\s*/, "").trim();
      if (width > 1 || (color && !NEUTRAL_EDGE.test(color))) report(file, line, "no-fingernail-strips", `${prop}: ${value}`);
    }
  }
  if ((prop === "border-inline" || prop === "border-block" || prop === "border-inline-width" || prop === "border-block-width") && widthPx(v) > 1) {
    report(file, line, "no-fingernail-strips", `${prop}: ${value}`);
  }
  if (prop === "box-shadow") {
    for (const shadow of splitTopLevel(v)) {
      const m = shadow.trim().match(/^inset\s+(-?[\d.]+)(px)?\s+(-?[\d.]+)(px)?/);
      if (m && (parseFloat(m[1]) !== 0 || parseFloat(m[3]) !== 0)) {
        report(file, line, "no-fingernail-strips", `box-shadow: ${shadow.trim()}`);
      }
    }
  }
}

function widthPx(v) {
  const m = v.match(/^([\d.]+)(px)?/);
  if (m) return parseFloat(m[1]);
  if (/^(medium|thick)/.test(v)) return 3;
  if (/^thin/.test(v)) return 1;
  return 0;
}

function splitTopLevel(v) {
  const out = [];
  let depth = 0, cur = "";
  for (const c of v) {
    if (c === "(") depth++;
    if (c === ")") depth--;
    if (c === "," && depth === 0) { out.push(cur); cur = ""; } else cur += c;
  }
  out.push(cur);
  return out;
}

function lintHTML(file, html) {
  for (const m of html.matchAll(/<style[^>]*>([\s\S]*?)<\/style>/gi)) {
    lintCSS(file, m[1], lineAt(html, m.index + m[0].indexOf(">") + 1));
  }
  for (const m of html.matchAll(/\sstyle\s*=\s*"([^"]*)"/gi)) {
    const line = lineAt(html, m.index);
    const tag = html.slice(html.lastIndexOf("<", m.index), m.index);
    const selector = /^<a\b[^>]*\bhref=/i.test(tag) ? "a[href]" : "[style]";
    for (const decl of m[1].split(";")) {
      const colon = decl.indexOf(":");
      if (colon > 0) lintDeclaration(file, selector, decl.slice(0, colon).trim().toLowerCase(), decl.slice(colon + 1).trim(), line);
    }
  }
  for (const m of html.matchAll(/\sclass\s*=\s*"([^"]*)"/gi)) {
    for (const cls of m[1].split(/\s+/)) {
      if (cls && FORBIDDEN_NAMES.test(cls)) report(file, lineAt(html, m.index), "no-chips-or-eyebrows", `class "${cls}"`);
    }
  }
  for (const m of html.matchAll(/<img\b[^>]*>/gi)) {
    if (!/\sdraggable\s*=\s*"false"/i.test(m[0])) report(file, lineAt(html, m.index), "no-draggable-images", "<img> needs draggable=\"false\"");
  }
  for (const m of html.matchAll(/<(img|svg|picture|video|canvas)\b[^>]*\sdraggable\s*=\s*"true"/gi)) {
    report(file, lineAt(html, m.index), "no-draggable-images", `<${m[1]} draggable="true">`);
  }
  const body = html.replace(/<script[\s\S]*?<\/script>/gi, (s) => s.replace(/[^\n]/g, " "));
  for (const m of body.matchAll(new RegExp(MONO_ELEMENTS.source, "gi"))) {
    report(file, lineAt(body, m.index), "system-font-only", `<${m[1]}> renders monospace; use a span`);
  }
  for (const m of html.matchAll(/<script[^>]*>([\s\S]*?)<\/script>/gi)) {
    lintScript(file, m[1], lineAt(html, m.index));
  }
}

function lintScript(file, js, baseLine = 1) {
  const rules = [
    [/cursor\s*[:=]\s*["'`]\s*pointer/g, "no-pointer-cursor"],
    [/["'`]cursor\s*:\s*pointer/g, "no-pointer-cursor"],
    [/setProperty\(\s*["'`]cursor["'`]\s*,\s*["'`]pointer/g, "no-pointer-cursor"],
    [/(textTransform|text-transform)\s*[:=]\s*["'`](uppercase|capitalize|full-width)/g, "no-all-caps"],
    [/(letterSpacing|letter-spacing)\s*[:=]\s*["'`](?!0(px)?["'`]|normal)/g, "no-wide-kerning"],
    [/monospace/g, "system-font-only"],
    [/(userSelect|user-select)\s*[:=]\s*["'`](text|all|auto|contain)/g, "no-selectable-ui-text"],
    [/(webkitUserDrag|user-drag)\s*[:=]\s*["'`](auto|element)/g, "no-draggable-images"],
  ];
  for (const [re, rule] of rules) {
    for (const m of js.matchAll(re)) {
      const line = lineAt(js, m.index, baseLine);
      const lineText = js.split("\n")[line - baseLine] ?? "";
      if (/design-lint-allow/.test(lineText)) continue;
      report(file, line, rule, m[0]);
    }
  }
}

for (const root of roots) walk(root);

if (problems.length) {
  for (const p of problems) console.log(`${relative(process.cwd(), p.file)}:${p.line}  ${p.rule}  ${p.detail}`);
  console.log(`\n${problems.length} design-system violation${problems.length === 1 ? "" : "s"}.`);
  process.exit(1);
} else {
  console.log("Design system lint passed.");
}
