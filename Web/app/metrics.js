// Row and column positions for the active sheet, ported from the engine's
// SheetMetrics so the page can scroll and hit-test without asking the worker.
//
// An axis whose lines are all the same size keeps no offsets at all and answers
// with arithmetic; only an axis with custom sizes or hidden lines builds a
// running-total array. All values are in sheet points at 100%.

class Axis {
  constructor(count, size, overrides) {
    this.count = count;
    this.size = size;
    this.offsets = null;
    if (overrides.length) {
      const sizes = new Float64Array(count).fill(size);
      for (let i = 0; i < overrides.length; i += 2) {
        const index = overrides[i];
        if (index < count) sizes[index] = overrides[i + 1];
      }
      this.offsets = new Float64Array(count + 1);
      for (let i = 0; i < count; i++) this.offsets[i + 1] = this.offsets[i] + sizes[i];
    }
  }

  get total() {
    return this.offsets ? this.offsets[this.count] : this.count * this.size;
  }

  start(index) {
    const i = Math.min(Math.max(0, index), this.count);
    return this.offsets ? this.offsets[i] : i * this.size;
  }

  length(index) {
    if (index < 0 || index >= this.count) return 0;
    return this.offsets ? this.offsets[index + 1] - this.offsets[index] : this.size;
  }

  /** The line at `position`, clamped to the sheet. */
  at(position) {
    if (this.count === 0) return 0;
    let index;
    if (!this.offsets) {
      index = this.size > 0 && position > 0 ? Math.floor(position / this.size) : 0;
    } else {
      let low = 0;
      let high = this.count;
      while (low < high) {
        const middle = (low + high + 1) >> 1;
        if (this.offsets[middle] <= position) low = middle;
        else high = middle - 1;
      }
      index = low;
    }
    return Math.min(Math.max(0, index), this.count - 1);
  }

  /** The nearest boundary within `slop` of `position`, as the index of the line it ends. */
  boundaryNear(position, slop) {
    if (position < 0 || position > this.total + slop) return -1;
    const index = this.at(position);
    const end = this.start(index) + this.length(index);
    if (Math.abs(position - end) <= slop) {
      // Hidden lines share a boundary with the line before them: resize the visible one.
      return index;
    }
    const begin = this.start(index);
    if (index > 0 && Math.abs(position - begin) <= slop) {
      let previous = index - 1;
      while (previous > 0 && this.length(previous) === 0) previous--;
      return previous;
    }
    return -1;
  }
}

export class SheetMetrics {
  constructor(layout) {
    this.layout = layout;
    this.columns = new Axis(layout.columns, layout.columnWidth, layout.widths);
    this.rows = new Axis(layout.rows, layout.rowHeight, layout.heights);
    this.frozenRows = layout.frozenRows;
    this.frozenColumns = layout.frozenColumns;
    this.merges = layout.merges;
  }

  get totalWidth() { return this.columns.total; }
  get totalHeight() { return this.rows.total; }
  get frozenWidth() { return this.columns.start(this.frozenColumns); }
  get frozenHeight() { return this.rows.start(this.frozenRows); }

  x(column) { return this.columns.start(column); }
  y(row) { return this.rows.start(row); }
  width(column) { return this.columns.length(column); }
  height(row) { return this.rows.length(row); }
  columnAt(x) { return this.columns.at(x); }
  rowAt(y) { return this.rows.at(y); }

  /** The merged range containing a cell, as [row1, column1, row2, column2], or null. */
  mergeAt(row, column) {
    for (const merge of this.merges) {
      if (row >= merge[0] && row <= merge[2] && column >= merge[1] && column <= merge[3]) return merge;
    }
    return null;
  }

  /** The frame of a range [row1, column1, row2, column2] (in any order). */
  frame(row1, column1, row2 = row1, column2 = column1) {
    const top = Math.min(row1, row2), bottom = Math.max(row1, row2);
    const left = Math.min(column1, column2), right = Math.max(column1, column2);
    const x = this.x(left), y = this.y(top);
    return { x, y, width: this.x(right) + this.width(right) - x, height: this.y(bottom) + this.height(bottom) - y };
  }

  /** A cell's frame, grown to its merge when it is in one. */
  cellFrame(row, column) {
    const merge = this.mergeAt(row, column);
    return merge ? this.frame(...merge) : this.frame(row, column);
  }
}

/** "A", "B", … "Z", "AA", … */
export function columnName(index) {
  let name = "";
  let n = index + 1;
  while (n > 0) {
    const remainder = (n - 1) % 26;
    name = String.fromCharCode(65 + remainder) + name;
    n = Math.floor((n - 1) / 26);
  }
  return name;
}
