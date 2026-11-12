// Draws the engine's drawing operations (Web/engine/swift/Sources/TablesWasm/Renderer.swift)
// onto a canvas. The engine decides what goes where; this measures and lays out
// text, which only the browser can do, following the Mac's CellRenderer:
// elided text, #s for a number too wide, wrapping, rotation and accounting fills.
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

/** Lines of `text` wrapped to `width`, breaking at spaces and, for long words, anywhere. */
function wrapLines(ctx, text, width) {
  const lines = [];
  for (const paragraph of text.split("\n")) {
    if (paragraph === "") {
      lines.push("");
      continue;
    }
    let line = "";
    for (const word of paragraph.split(/(\s+)/)) {
      const candidate = line + word;
      if (line === "" || ctx.measureText(candidate).width <= width) {
        line = candidate;
        continue;
      }
      lines.push(line.trimEnd());
      line = word.trimStart();
      // A single word wider than the box breaks between characters.
      while (line.length > 1 && ctx.measureText(line).width > width) {
        let cut = line.length - 1;
        while (cut > 1 && ctx.measureText(line.slice(0, cut)).width > width) cut--;
        lines.push(line.slice(0, cut));
        line = line.slice(cut);
      }
    }
    lines.push(line);
  }
  return lines;
}

/** The longest prefix that fits in `width`, with an ellipsis. */
function elided(ctx, text, width) {
  const characters = Array.from(text);
  let low = 0;
  let high = characters.length - 1;
  let best = "…";
  while (low <= high) {
    const middle = (low + high) >> 1;
    const candidate = characters.slice(0, middle).join("") + "…";
    if (ctx.measureText(candidate).width <= width) {
      best = candidate;
      low = middle + 1;
    } else {
      high = middle - 1;
    }
  }
  return best;
}

/** As many #s as fit in `width`: what Excel shows for a number its cell is too narrow for. */
function hashes(ctx, width) {
  const one = ctx.measureText("#").width;
  return one > 0 ? "#".repeat(Math.max(Math.floor(width / one), 1)) : "";
}

function drawText(ctx, op, palette) {
  const frame = op.r;
  if (frame[2] <= 0 || frame[3] <= 0) return;
  ctx.font = fontFor(op);
  const color = cssColor(op.c) ?? (op.err ? palette.error : palette.text);
  const metrics = ctx.measureText("Hg");
  const ascent = metrics.fontBoundingBoxAscent ?? op.fs * 0.8;
  const descent = metrics.fontBoundingBoxDescent ?? op.fs * 0.2;
  const lineHeight = ascent + descent;

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
    lines = wrapLines(ctx, text, box[2]);
    measuredWidth = box[2];
  } else {
    lines = text.split("\n");
    measuredWidth = Math.max(...lines.map((line) => ctx.measureText(line).width));
    // A number a hair too wide may take some of the cell's padding before it gives way to #s.
    if (op.num && measuredWidth > room && measuredWidth <= frame[2] - 2) {
      const spare = (frame[2] - 2 - box[2]) / 2;
      box = [box[0] - spare, box[1], box[2] + 2 * spare, box[3]];
      room = box[2];
    }
    if (measuredWidth > room) {
      lines = lines.map((line) => (op.num ? hashes(ctx, room) : ctx.measureText(line).width > room ? elided(ctx, line, room) : line));
      measuredWidth = Math.max(...lines.map((line) => ctx.measureText(line).width));
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
  if (op.rot) {
    ctx.translate(target[0] + target[2] / 2, target[1] + target[3] / 2);
    ctx.rotate(-angle);
    ctx.translate(-(target[0] + target[2] / 2), -(target[1] + target[3] / 2));
  }
  const align = op.h === "r" ? "right" : op.h === "c" ? "center" : "left";
  ctx.textAlign = align;
  const anchorX = align === "right" ? target[0] + target[2] : align === "center" ? target[0] + target[2] / 2 : target[0];
  lines.forEach((line, index) => {
    const baseline = target[1] + index * lineHeight + ascent;
    ctx.fillText(line, anchorX, baseline);
    if (op.u || op.s) {
      const width = ctx.measureText(line).width;
      const startX = align === "right" ? anchorX - width : align === "center" ? anchorX - width / 2 : anchorX;
      ctx.lineWidth = Math.max(1, op.fs / 14);
      ctx.beginPath();
      if (op.u) {
        ctx.moveTo(startX, baseline + Math.max(1.5, op.fs * 0.12));
        ctx.lineTo(startX + width, baseline + Math.max(1.5, op.fs * 0.12));
      }
      if (op.s) {
        ctx.moveTo(startX, baseline - ascent * 0.32);
        ctx.lineTo(startX + width, baseline - ascent * 0.32);
      }
      ctx.stroke();
    }
  });
  ctx.restore();
}

export { intersect };
