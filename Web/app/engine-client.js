// The page's side of the engine worker: sends requests, keeps the latest
// selection state, and tells listeners what changed.
//
//   const engine = new EngineClient();
//   engine.addEventListener("state", ...)    // every response
//   engine.addEventListener("content", ...)  // cells changed: redraw
//   engine.addEventListener("layout", ...)   // rows, columns or the active sheet changed
//   engine.addEventListener("document", ...) // sheets, file or capabilities changed
//   engine.addEventListener("progress", ...) // while starting: { loaded, total } bytes of the engine downloaded

export class EngineError extends Error {
  constructor(message, { fatal = false } = {}) {
    super(message);
    this.fatal = fatal;
  }
}

export class EngineClient extends EventTarget {
  /** @param {{ keepForOffline?: boolean }} [options] keepForOffline: leave the downloaded engine for the service worker's first install */
  constructor({ keepForOffline = false } = {}) {
    super();
    const url = new URL("../engine/worker.js", import.meta.url);
    url.searchParams.set("tz", Intl.DateTimeFormat().resolvedOptions().timeZone ?? "UTC");
    if (keepForOffline) url.searchParams.set("keep", "1");
    this.worker = new Worker(url, { type: "module" });
    this.pending = new Map();
    this.nextId = 1;
    this.state = null;
    this.info = null;
    this.layout = null;
    this.versions = { content: -1, layout: -1 };
    this.worker.addEventListener("message", (event) => this.receive(event.data));
    this.worker.addEventListener("error", (event) => {
      for (const { reject } of this.pending.values()) reject(new EngineError(event.message || "The engine could not start.", { fatal: true }));
      this.pending.clear();
      this.dispatchEvent(new CustomEvent("fatal", { detail: event.message }));
    });
  }

  receive({ id, response, payload, error, fatal, progress }) {
    if (progress) {
      this.dispatchEvent(new CustomEvent("progress", { detail: progress }));
      return;
    }
    const entry = this.pending.get(id);
    if (!entry) return;
    this.pending.delete(id);
    if (error) {
      entry.reject(new EngineError(error, { fatal }));
      if (fatal) this.dispatchEvent(new CustomEvent("fatal", { detail: error }));
      return;
    }
    entry.resolve({ response, payload });
  }

  /** Sends a raw request; resolves with { response, payload }. */
  send(request, payload) {
    const id = this.nextId++;
    return new Promise((resolve, reject) => {
      this.pending.set(id, { resolve, reject });
      this.worker.postMessage({ id, request, payload }, payload ? [payload.buffer] : []);
    });
  }

  /**
   * Runs a command and applies the state it returns. Resolves with the
   * command's result; rejects with the engine's message when it fails.
   */
  async call(cmd, args = {}, payload) {
    const { response, payload: output } = await this.send({ cmd, ...args }, payload);
    await this.apply(response.state, cmd);
    if (!response.ok) throw new EngineError(response.error);
    if (output) return { result: response.result, payload: output };
    return response.result;
  }

  async apply(state, cmd) {
    if (!state) return;
    const previous = this.versions;
    this.state = state;
    this.versions = state.versions;
    const documentCommand = ["new", "open", "rename", "addSheet", "duplicateSheet", "deleteSheet", "renameSheet",
      "hideSheet", "sheetColor", "moveSheet", "undo", "redo", "selectSheet", "save"].includes(cmd);
    if (documentCommand || !this.info) {
      const { response } = await this.send({ cmd: "info" });
      this.info = response.result;
      this.dispatchEvent(new CustomEvent("document", { detail: this.info }));
    }
    if (state.versions.layout !== previous.layout || !this.layout || this.layout.sheet !== state.sheet) {
      const { response } = await this.send({ cmd: "layout" });
      this.layout = response.result;
      this.dispatchEvent(new CustomEvent("layout", { detail: this.layout }));
    }
    if (state.versions.content !== previous.content) {
      this.dispatchEvent(new CustomEvent("content", { detail: state.versions }));
    }
    this.dispatchEvent(new CustomEvent("state", { detail: state }));
  }

  /** Drawing operations for part of the active sheet, in sheet coordinates. */
  async render(rect, dark) {
    const { response } = await this.send({ cmd: "render", ...rect, dark });
    return response.result;
  }
}
