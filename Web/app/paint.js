// Draws the engine's drawing operations (Web/engine/swift/Sources/TablesWasm/Renderer.swift)
// onto a canvas. The engine decides what goes where; this measures and lays out
// text, which only the browser can do, following the Mac's CellRenderer:
// clipped text, #s for a number too wide, wrapping, rotation and accounting fills.
//
// All coordinates are sheet points; the caller scales the context for zoom.

const FONT_STACK = "system-ui, -apple-system, BlinkMacSystemFont, sans-serif";

/** "AARRGGBB" from the engine as a CSS colour. */
export function cssColor(argb) {
  if (!argb) return null;
  const a = parseInt(argb.slice(0, 2), 16) / 255;
  const r = parseInt(argb.slice(2, 4), 16);
  const g = parseInt(argb.slice(4, 6), 16);
  const b = parseInt(argb.slice(6, 8), 16);
  return `rgba(${r}, ${g}, ${b}, ${a.toFixed(3)})`;
}

/** The theme colours drawing needs, read from the design tokens. */
export function readPalette(element = document.documentElement) {
  const style = getComputedStyle(element);
  const token = (name) => style.getPropertyValue(name).trim();
  return {
    paper: token("--ds-background"),
    grid: token("--ds-grid-line"),
    text: token("--ds-text-primary"),
    error: token("--ds-support-error"),
    accent: token("--ds-interactive"),
    onAccent: token("--ds-text-on-color"),
    border: token("--ds-text-primary"),
  };
}

/** A family name quoted for a CSS font string. */
export function quoteFamily(name) {
  return `"${String(name).replace(/["\\]/g, "\\$&")}"`;
}

/** The family list for a cell: its own, falling back to the system font when not installed. */
export function familyFor(family) {
  return family ? `${quoteFamily(family)}, ${FONT_STACK}` : FONT_STACK;
}

/** The canvas font for a text operation: the cell's family, size, bold and italic. */
export function fontFor(op) {
  return `${op.i ? "italic " : ""}${op.b ? "bold " : ""}${op.fs}px ${familyFor(op.ff)}`;
}

function intersect(a, b) {
  const x = Math.max(a[0], b[0]), y = Math.max(a[1], b[1]);
  const right = Math.min(a[0] + a[2], b[0] + b[2]), bottom = Math.min(a[1] + a[3], b[1] + b[3]);
  return [x, y, Math.max(0, right - x), Math.max(0, bottom - y)];
}

function union(a, b) {
  const x = Math.min(a[0], b[0]), y = Math.min(a[1], b[1]);
  return [x, y, Math.max(a[0] + a[2], b[0] + b[2]) - x, Math.max(a[1] + a[3], b[1] + b[3]) - y];
}

/**
 * @param {CanvasRenderingContext2D} ctx scaled so one unit is one sheet point
 * @param {{ ops: object[], paper?: string }} list
 * @param {ReturnType<typeof readPalette>} palette
 */
export function paint(ctx, list, palette) {
  const paper = cssColor(list.paper) ?? palette.paper;
  let clipped = false;
  for (const op of list.ops) {
    switch (op.k) {
      case "grid":
        strokeSegments(ctx, op.p, palette.grid, op.w ?? 1);
        break;
      case "fill":
        ctx.fillStyle = cssColor(op.c);
        ctx.fillRect(op.r[0], op.r[1], op.r[2], op.r[3]);
        break;
      case "pattern":
        drawPattern(ctx, op);
        break;
      case "lgrad": {
        const gradient = ctx.createLinearGradient(op.p[0], op.p[1], op.p[2], op.p[3]);
        for (const [position, color] of op.s) gradient.addColorStop(Math.min(Math.max(position, 0), 1), cssColor(color));
        ctx.fillStyle = gradient;
        ctx.fillRect(op.r[0], op.r[1], op.r[2], op.r[3]);
        break;
      }
      case "paper":
        ctx.fillStyle = paper;
        ctx.fillRect(op.r[0], op.r[1], op.r[2], op.r[3]);
        break;
      case "text":
        drawText(ctx, op, palette);
        break;
      case "check":
        drawCheckbox(ctx, op, palette);
        break;
      case "clip":
        ctx.save();
        ctx.beginPath();
        ctx.rect(op.r[0], op.r[1], op.r[2], op.r[3]);
        ctx.clip();
        clipped = true;
        break;
      case "unclip":
        if (clipped) ctx.restore();
        clipped = false;
        break;
      case "line":
        ctx.setLineDash(op.d ?? []);
        strokeSegments(ctx, op.p, cssColor(op.c) ?? palette.border, op.w);
        ctx.setLineDash([]);
        break;
      case "tri":
        ctx.fillStyle = cssColor(op.c);
        ctx.beginPath();
        ctx.moveTo(op.p[0], op.p[1]);
        ctx.lineTo(op.p[2], op.p[3]);
        ctx.lineTo(op.p[4], op.p[5]);
        ctx.closePath();
        ctx.fill();
        break;
    }
  }
  if (clipped) ctx.restore();
}

// Pattern tiles, by bits, colour and device pixels to a bit.
const patternTiles = new Map();

/**
 * A fill pattern: eight rows of eight bits, the leftmost the high bit, set bits
 * in the pattern colour. Tiled from the sheet's origin so a patterned range
 * joins up, and a bit is a CSS pixel on screen at every zoom, as in Excel.
 */
function drawPattern(ctx, op) {
  const transform = ctx.getTransform();
  const scale = Math.hypot(transform.a, transform.b) || 1; // device pixels per sheet point
  const ratio = globalThis.devicePixelRatio || 1;
  const pixels = Math.max(1, Math.round(ratio)); // device pixels to a bit
  const key = `${op.b.join(",")}|${op.c}|${pixels}`;
  let tile = patternTiles.get(key);
  if (!tile) {
    tile = document.createElement("canvas");
    tile.width = tile.height = 8 * pixels;
    const tileContext = tile.getContext("2d");
    tileContext.fillStyle = cssColor(op.c);
    for (let row = 0; row < 8; row++) {
      for (let column = 0; column < 8; column++) {
        if (op.b[row] & (0x80 >> column)) tileContext.fillRect(column * pixels, row * pixels, pixels, pixels);
      }
    }
    if (patternTiles.size > 256) patternTiles.clear();
    patternTiles.set(key, tile);
  }
  const pattern = ctx.createPattern(tile, "repeat");
  // One tile pixel to 1/pixels of a CSS pixel: sheet points are scale / ratio CSS pixels.
  const unit = ratio / (pixels * scale);
  pattern.setTransform(new DOMMatrix([unit, 0, 0, unit, 0, 0]));
  ctx.save();
  ctx.imageSmoothingEnabled = false;
  ctx.fillStyle = pattern;
  ctx.fillRect(op.r[0], op.r[1], op.r[2], op.r[3]);
  ctx.restore();
}

function strokeSegments(ctx, points, color, width) {
  if (!points.length) return;
  ctx.strokeStyle = color;
  ctx.lineWidth = width;
  ctx.beginPath();
  for (let i = 0; i + 3 < points.length; i += 4) {
    ctx.moveTo(points[i], points[i + 1]);
    ctx.lineTo(points[i + 2], points[i + 3]);
  }
  ctx.stroke();
}

function drawCheckbox(ctx, op, palette) {
  const [x, y, w, h] = op.r;
  const radius = 2.5;
  ctx.beginPath();
  ctx.roundRect(x, y, w, h, radius);
  if (!op.on) {
    ctx.strokeStyle = cssColor(op.c) ?? palette.text;
    ctx.globalAlpha = 0.6;
    ctx.lineWidth = 1;
    ctx.stroke();
    ctx.globalAlpha = 1;
    return;
  }
  ctx.fillStyle = palette.accent;
  ctx.fill();
  ctx.strokeStyle = palette.onAccent;
  ctx.lineWidth = 1.8;
  ctx.lineCap = "round";
  ctx.lineJoin = "round";
  ctx.beginPath();
  ctx.moveTo(op.m[0], op.m[1]);
  ctx.lineTo(op.m[2], op.m[3]);
  ctx.lineTo(op.m[4], op.m[5]);
  ctx.stroke();
}

// MARK: - Text

/**
 * How an operation's text is measured and drawn: in the cell's one font, or,
 * for a cell with runs (`op.runs`), each stretch in the font of its run.
 *
 * A line is a piece of `op.t` and where it starts in it, counted in UTF-16
 * units, which is how a stretch finds its run: the runs' text adds up to
 * `op.t`.
 */
function typesetter(ctx, op) {
  const cellFont = fontFor(op);
  ctx.font = cellFont;
  const metricsOf = (size) => {
    const metrics = ctx.measureText("Hg");
    return [metrics.fontBoundingBoxAscent ?? size * 0.8, metrics.fontBoundingBoxDescent ?? size * 0.2];
  };
  const rule = (run, x, width, baseline, ascent) => {
    if (!run.u && !run.s) return;
    ctx.lineWidth = Math.max(1, run.fs / 14);
    ctx.beginPath();
    if (run.u) {
      ctx.moveTo(x, baseline + Math.max(1.5, run.fs * 0.12));
      ctx.lineTo(x + width, baseline + Math.max(1.5, run.fs * 0.12));
    }
    if (run.s) {
      ctx.moveTo(x, baseline - ascent * 0.32);
      ctx.lineTo(x + width, baseline - ascent * 0.32);
    }
    ctx.stroke();
  };

  if (!op.runs) {
    const [ascent, descent] = metricsOf(op.fs);
    return {
      ascent,
      descent,
      width: (text) => ctx.measureText(text).width,
      /** Draws `text` from `x` rightwards, in `color`. */
      draw(text, offset, x, baseline, color) {
        ctx.fillStyle = color;
        ctx.strokeStyle = color;
        ctx.textAlign = "left";
        ctx.fillText(text, x, baseline);
        rule(op, x, ctx.measureText(text).width, baseline, ascent);
      },
    };
  }

  let start = 0;
  let ascent = 0;
  let descent = 0;
  const runs = op.runs.map((run) => {
    const font = fontFor(run);
    ctx.font = font;
    const [runAscent, runDescent] = metricsOf(run.fs);
    const lift = run.dy ?? 0;
    ascent = Math.max(ascent, runAscent + lift);
    descent = Math.max(descent, runDescent - lift);
    const entry = { ...run, font, start, ascent: runAscent };
    start += run.t.length;
    return entry;
  });
  /** The stretches of `text`, which starts at `offset` in `op.t`, by run. */
  const stretches = (text, offset) => {
    const found = [];
    let index = runs.findIndex((run) => offset < run.start + run.t.length);
    if (index < 0) index = runs.length - 1;
    let position = 0;
    while (position < text.length) {
      const run = runs[index];
      const end = index === runs.length - 1 ? text.length : Math.min(text.length, run.start + run.t.length - offset);
      if (end > position) found.push({ run, text: text.slice(position, end) });
      position = Math.max(end, position);
      if (index < runs.length - 1) index++;
    }
    return found;
  };
  const measured = (stretch) => {
    ctx.font = stretch.run.font;
    return ctx.measureText(stretch.text).width;
  };
  return {
    ascent,
    descent,
    width: (text, offset) => stretches(text, offset).reduce((sum, stretch) => sum + measured(stretch), 0),
    draw(text, offset, x, baseline, color) {
      const parts = stretches(text, offset);
      // Read right to left, the first stretch is the rightmost.
      if (op.rtl) parts.reverse();
      ctx.textAlign = "left";
      for (const stretch of parts) {
        const width = measured(stretch);
        const ink = cssColor(stretch.run.c) ?? color;
        ctx.fillStyle = ink;
        ctx.strokeStyle = ink;
        const line = baseline - (stretch.run.dy ?? 0);
        ctx.fillText(stretch.text, x, line);
        rule(stretch.run, x, width, line, stretch.run.ascent);
        x += width;
      }
    },
  };
}

/**
 * Lines of `text` wrapped to `width`, breaking at spaces and, for long words,
 * anywhere: each with where it starts in `text`, for `measure` to find its font by.
 */
function wrapLines(measure, text, width) {
  const lines = [];
  let start = 0;
  for (const paragraph of text.split("\n")) {
    if (paragraph === "") {
      lines.push({ text: "", offset: start });
      start += 1;
      continue;
    }
    let line = "";
    let lineOffset = start;
    let cursor = start;
    for (const word of paragraph.split(/(\s+)/)) {
      const candidate = line + word;
      if (line === "" || measure(candidate, lineOffset) <= width) {
        line = candidate;
        cursor += word.length;
        continue;
      }
      lines.push({ text: line.trimEnd(), offset: lineOffset });
      line = word.trimStart();
      lineOffset = cursor + word.length - line.length;
      cursor += word.length;
      // A single word wider than the box breaks between characters.
      while (line.length > 1 && measure(line, lineOffset) > width) {
        let cut = line.length - 1;
        while (cut > 1 && measure(line.slice(0, cut), lineOffset) > width) cut--;
        lines.push({ text: line.slice(0, cut), offset: lineOffset });
        line = line.slice(cut);
        lineOffset += cut;
      }
    }
    lines.push({ text: line, offset: lineOffset });
    start += paragraph.length + 1;
  }
  return lines;
}

/**
 * The length a line `lineHeight` tall may run along its baseline in a box
 * `width` by `height`, turned `degrees` counter-clockwise: the box's width
 * upright, its height a quarter turn either way, and in between as long as
 * keeps the turned line inside the box. Mirrors the engine's
 * `TextFitting.runLength(in:rotationDegrees:lineHeight:)`.
 */
function runLength(width, height, degrees, lineHeight) {
  const angle = (degrees * Math.PI) / 180;
  // Snapped so 90° does not leave a cosine of 6e-17 to divide by.
  const snapped = (value) => (Math.abs(value) < 1e-12 ? 0 : Math.abs(value));
  const cosine = snapped(Math.cos(angle));
  const sine = snapped(Math.sin(angle));
  let length = Infinity;
  if (cosine > 0) length = Math.min(length, (width - lineHeight * sine) / cosine);
  if (sine > 0) length = Math.min(length, (height - lineHeight * cosine) / sine);
  return Math.max(length, 0);
}

/** As many #s as fit in `width`: what Excel shows for a number its cell is too narrow for. */
function hashes(ctx, width) {
  const one = ctx.measureText("#").width;
  return one > 0 ? "#".repeat(Math.max(Math.floor(width / one), 1)) : "";
}

function drawText(ctx, op, palette) {
  const frame = op.r;
  if (frame[2] <= 0 || frame[3] <= 0) return;
  const set = typesetter(ctx, op);
  const measure = set.width;
  const color = cssColor(op.c) ?? (op.err ? palette.error : palette.text);
  // A cell with runs has every line as tall as its tallest run.
  const ascent = set.ascent;
  const lineHeight = ascent + set.descent;

  // The same padding the cell editor has, so opening it does not shift the text.
  let box = [frame[0] + 6, frame[1] + 2, frame[2] - 12, frame[3] - 4];
  const indent = op.ind ?? 0;
  if (indent > 0) {
    if (op.h !== "r") box[0] += indent;
    box[2] -= indent;
  }
  if (box[2] <= 0 || box[3] <= 0) return;

  const wraps = Boolean(op.wrap);
  let room = box[2];
  if (op.ov && !wraps) {
    const reach = [op.ov[0] + 6, op.ov[1], op.ov[2] - 12, op.ov[3]];
    const boxMaxX = box[0] + box[2], reachMaxX = reach[0] + reach[2];
    if (op.h === "r") room = boxMaxX - reach[0];
    else if (op.h === "c") room = 2 * Math.min(box[0] + box[2] / 2 - reach[0], reachMaxX - (box[0] + box[2] / 2));
    else room = reachMaxX - box[0];
    room = Math.max(room, box[2]);
  }

  let text = op.t;
  let lines;
  let measuredWidth;
  if (wraps) {
    lines = wrapLines(measure, text, box[2]);
    measuredWidth = box[2];
  } else {
    let start = 0;
    lines = text.split("\n").map((line) => {
      const entry = { text: line, offset: start };
      start += line.length + 1;
      return entry;
    });
    const widest = () => Math.max(...lines.map((line) => measure(line.text, line.offset)));
    measuredWidth = widest();
    // Turned text runs along its turned box rather than across the cell.
    if (op.rot) room = runLength(box[2], box[3], op.rot, lineHeight * lines.length);
    // A number a hair too wide may take some of the cell's padding before it gives way to #s.
    if (op.num && !op.rot && measuredWidth > room && measuredWidth <= frame[2] - 2) {
      const spare = (frame[2] - 2 - box[2]) / 2;
      box = [box[0] - spare, box[1], box[2] + 2 * spare, box[3]];
      room = box[2];
    }
    // Text too long for its room runs on from the edge it is aligned to and
    // is clipped at the cell's edge, as Excel and Numbers clip it.
    if (op.num && measuredWidth > room) {
      lines = lines.map((line) => ({ text: hashes(ctx, room), offset: line.offset }));
      measuredWidth = widest();
    }
  }
  const size = [wraps ? box[2] : Math.min(measuredWidth, room), lines.length * lineHeight];
  const angle = ((op.rot ?? 0) * Math.PI) / 180;
  const extent = [
    Math.abs(size[0] * Math.cos(angle)) + Math.abs(size[1] * Math.sin(angle)),
    Math.abs(size[0] * Math.sin(angle)) + Math.abs(size[1] * Math.cos(angle)),
  ];
  const midX = op.h === "r" ? box[0] + box[2] - extent[0] / 2 : op.h === "c" ? box[0] + box[2] / 2 : box[0] + extent[0] / 2;
  const midY = op.v === "t" ? box[1] + extent[1] / 2 : op.v === "b" ? box[1] + box[3] - extent[1] / 2 : box[1] + box[3] / 2;
  const target = [midX - size[0] / 2, midY - size[1] / 2, size[0], size[1]];

  ctx.fillStyle = color;
  ctx.strokeStyle = color;
  ctx.textBaseline = "alphabetic";

  // A format's fill spreads the text across the cell: an accounting symbol at
  // the left edge, the amount at the right.
  if (!wraps && !op.rot && op.parts && measuredWidth <= box[2]) {
    ctx.save();
    ctx.beginPath();
    ctx.rect(frame[0], frame[1], frame[2], frame[3]);
    ctx.clip();
    const baseline = target[1] + ascent;
    ctx.font = fontFor(op);
    ctx.textAlign = "left";
    ctx.fillText(op.parts[0], box[0], baseline);
    ctx.textAlign = "right";
    ctx.fillText(op.parts[1], box[0] + box[2], baseline);
    ctx.restore();
    return;
  }

  ctx.save();
  const clip = op.ov ? union(op.ov, frame) : frame;
  ctx.beginPath();
  ctx.rect(clip[0], clip[1], clip[2], clip[3]);
  ctx.clip();
  // Text read right to left is set that way whatever it starts with, as the
  // engine's `TextFitting.baseDirection(of:)` finds it; "left" and "right"
  // alignment stay where they are.
  ctx.direction = op.rtl ? "rtl" : "ltr";
  if (op.rot) {
    ctx.translate(target[0] + target[2] / 2, target[1] + target[3] / 2);
    ctx.rotate(-angle);
    ctx.translate(-(target[0] + target[2] / 2), -(target[1] + target[3] / 2));
  }
  const align = op.h === "r" ? "right" : op.h === "c" ? "center" : "left";
  const anchorX = align === "right" ? target[0] + target[2] : align === "center" ? target[0] + target[2] / 2 : target[0];
  lines.forEach((line, index) => {
    const baseline = target[1] + index * lineHeight + ascent;
    const width = measure(line.text, line.offset);
    const startX = align === "right" ? anchorX - width : align === "center" ? anchorX - width / 2 : anchorX;
    set.draw(line.text, line.offset, startX, baseline, color);
  });
  ctx.restore();
}

export { intersect };
