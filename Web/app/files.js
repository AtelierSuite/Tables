// Opening and saving files on the user's device. Where the browser has the File
// System Access API, documents save back in place; elsewhere they open through
// a file picker and save as downloads.

const OPEN_TYPES = [
  {
    description: "Spreadsheets",
    accept: {
      "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet": [".xlsx"],
      "application/vnd.ms-excel.sheet.macroEnabled.12": [".xlsm"],
      "application/vnd.apple.numbers": [".numbers"],
      "text/csv": [".csv"],
      "text/tab-separated-values": [".tsv", ".tab"],
      "text/plain": [".txt"],
    },
  },
];

export const SAVE_TYPES = {
  xlsx: { description: "Excel Workbook", mime: "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet", extension: ".xlsx" },
  xlsm: { description: "Excel Macro-Enabled Workbook", mime: "application/vnd.ms-excel.sheet.macroEnabled.12", extension: ".xlsm" },
  numbers: { description: "Numbers Document", mime: "application/vnd.apple.numbers", extension: ".numbers" },
  csv: { description: "Comma-Separated Values", mime: "text/csv", extension: ".csv" },
  tsv: { description: "Tab-Separated Values", mime: "text/tab-separated-values", extension: ".tsv" },
};

export const canSaveInPlace = typeof window.showSaveFilePicker === "function";

/**
 * Asks the user for a file to open.
 * @returns {Promise<{ name: string, bytes: Uint8Array, handle?: FileSystemFileHandle } | null>}
 */
export async function pickFile() {
  if (typeof window.showOpenFilePicker === "function") {
    try {
      const [handle] = await window.showOpenFilePicker({ types: OPEN_TYPES, excludeAcceptAllOption: false, multiple: false });
      return readHandle(handle);
    } catch (error) {
      if (error?.name === "AbortError") return null;
      throw error;
    }
  }
  return new Promise((resolve) => {
    const input = document.createElement("input");
    input.type = "file";
    input.accept = Object.values(OPEN_TYPES[0].accept).flat().join(",");
    input.addEventListener("change", async () => {
      const file = input.files?.[0];
      resolve(file ? { name: file.name, bytes: new Uint8Array(await file.arrayBuffer()) } : null);
    });
    input.addEventListener("cancel", () => resolve(null));
    input.click();
  });
}

/** Reads a file the user picked earlier, asking again for permission when the browser wants that. */
export async function readHandle(handle) {
  if (handle.queryPermission && (await handle.queryPermission({ mode: "read" })) !== "granted") {
    if ((await handle.requestPermission({ mode: "read" })) !== "granted") return null;
  }
  const file = await handle.getFile();
  return { name: file.name, bytes: new Uint8Array(await file.arrayBuffer()), handle };
}

/** Writes bytes into a file the user picked, asking for permission to write when needed. */
export async function writeHandle(handle, bytes) {
  if (handle.queryPermission && (await handle.queryPermission({ mode: "readwrite" })) !== "granted") {
    if ((await handle.requestPermission({ mode: "readwrite" })) !== "granted") return false;
  }
  const writable = await handle.createWritable();
  await writable.write(bytes);
  await writable.close();
  return true;
}

/**
 * Asks where to save, and saves there; downloads instead where the browser can't ask.
 * @returns {Promise<{ name: string, handle?: FileSystemFileHandle } | null>}
 */
export async function saveFileAs(bytes, suggestedName, format) {
  const type = SAVE_TYPES[format];
  if (canSaveInPlace) {
    try {
      const handle = await window.showSaveFilePicker({
        suggestedName,
        types: [{ description: type.description, accept: { [type.mime]: [type.extension] } }],
      });
      await writeHandle(handle, bytes);
      return { name: handle.name, handle };
    } catch (error) {
      if (error?.name === "AbortError") return null;
      throw error;
    }
  }
  download(bytes, suggestedName, type.mime);
  return { name: suggestedName };
}

export function download(bytes, name, mime) {
  const url = URL.createObjectURL(new Blob([bytes], { type: mime }));
  const link = document.createElement("a");
  link.href = url;
  link.download = name;
  link.hidden = true;
  document.body.append(link);
  link.click();
  link.remove();
  setTimeout(() => URL.revokeObjectURL(url), 10_000);
}

/** Files the operating system asked the installed app to open (manifest file_handlers). */
export function onLaunchFiles(callback) {
  if (!("launchQueue" in window)) return;
  window.launchQueue.setConsumer(async (params) => {
    const handle = params.files?.[0];
    if (handle) callback(await readHandle(handle));
  });
}

/** Files dropped onto the window. */
export function onDroppedFiles(element, callback, onHover) {
  element.addEventListener("dragover", (event) => {
    if (![...(event.dataTransfer?.types ?? [])].includes("Files")) return;
    event.preventDefault();
    onHover?.(true);
  });
  element.addEventListener("dragleave", (event) => {
    if (event.relatedTarget && element.contains(event.relatedTarget)) return;
    onHover?.(false);
  });
  element.addEventListener("drop", async (event) => {
    onHover?.(false);
    const item = [...(event.dataTransfer?.items ?? [])].find((entry) => entry.kind === "file");
    if (!item) return;
    event.preventDefault();
    const handle = await item.getAsFileSystemHandle?.();
    if (handle?.kind === "file") {
      callback(await readHandle(handle));
      return;
    }
    const file = item.getAsFile();
    if (file) callback({ name: file.name, bytes: new Uint8Array(await file.arrayBuffer()) });
  });
}
