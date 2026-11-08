// What Tables keeps on this device: recently opened files (with their file
// handles, where the browser can keep them) and autosaved copies of open
// documents, so nothing is lost if the window closes before a save.
//
// Records live in IndexedDB; draft contents in the origin private file system,
// falling back to IndexedDB where that isn't available.

const DATABASE = "tables";
const VERSION = 1;

function open() {
  return new Promise((resolve, reject) => {
    const request = indexedDB.open(DATABASE, VERSION);
    request.onupgradeneeded = () => {
      const db = request.result;
      if (!db.objectStoreNames.contains("documents")) db.createObjectStore("documents", { keyPath: "id" });
      if (!db.objectStoreNames.contains("blobs")) db.createObjectStore("blobs");
    };
    request.onsuccess = () => resolve(request.result);
    request.onerror = () => reject(request.error);
  });
}

let database = null;
async function db() {
  database ??= await open();
  return database;
}

function transaction(store, mode, body) {
  return db().then((connection) => new Promise((resolve, reject) => {
    const tx = connection.transaction(store, mode);
    const result = body(tx.objectStore(store));
    tx.oncomplete = () => resolve(result?.result ?? result);
    tx.onerror = () => reject(tx.error);
    tx.onabort = () => reject(tx.error);
  }));
}

/**
 * @typedef {object} DocumentRecord
 * @property {string} id
 * @property {string} name        the file name shown
 * @property {number} openedAt
 * @property {number} [draftAt]   when an autosaved copy was last written
 * @property {string} [draftName] the file name of the autosaved copy
 * @property {FileSystemFileHandle} [handle]
 */

/** @returns {Promise<DocumentRecord[]>} newest first */
export async function recentDocuments() {
  try {
    const records = await transaction("documents", "readonly", (store) => store.getAll());
    return records.sort((a, b) => Math.max(b.openedAt, b.draftAt ?? 0) - Math.max(a.openedAt, a.draftAt ?? 0));
  } catch {
    return [];
  }
}

export async function saveRecord(record) {
  try {
    await transaction("documents", "readwrite", (store) => store.put(record));
  } catch {
    // Storage may be unavailable (private browsing); recents are a convenience.
  }
}

export async function removeRecord(id) {
  try {
    await transaction("documents", "readwrite", (store) => store.delete(id));
    await removeDraft(id);
  } catch {
    // Nothing to remove.
  }
}

export async function clearRecents() {
  for (const record of await recentDocuments()) {
    if (!record.draftAt) await removeRecord(record.id);
  }
}

async function draftsFolder() {
  const root = await navigator.storage?.getDirectory?.();
  return root ? root.getDirectoryHandle("drafts", { create: true }) : null;
}

/** Writes an autosaved copy of a document. */
export async function writeDraft(id, bytes) {
  try {
    const folder = await draftsFolder();
    if (folder) {
      const file = await folder.getFileHandle(id, { create: true });
      const writable = await file.createWritable();
      await writable.write(bytes);
      await writable.close();
      return true;
    }
  } catch {
    // Fall through to IndexedDB (Safari's private file system has no createWritable before 17.4 in windows).
  }
  try {
    await transaction("blobs", "readwrite", (store) => store.put(new Blob([bytes]), id));
    return true;
  } catch {
    return false;
  }
}

/** @returns {Promise<Uint8Array | null>} */
export async function readDraft(id) {
  try {
    const folder = await draftsFolder();
    if (folder) {
      const file = await (await folder.getFileHandle(id)).getFile();
      return new Uint8Array(await file.arrayBuffer());
    }
  } catch {
    // Try IndexedDB.
  }
  try {
    const blob = await transaction("blobs", "readonly", (store) => store.get(id));
    return blob ? new Uint8Array(await blob.arrayBuffer()) : null;
  } catch {
    return null;
  }
}

export async function removeDraft(id) {
  try {
    const folder = await draftsFolder();
    await folder?.removeEntry(id);
  } catch {
    // Already gone.
  }
  try {
    await transaction("blobs", "readwrite", (store) => store.delete(id));
  } catch {
    // Already gone.
  }
}

/** Asks the browser not to evict what Tables keeps, once there is something worth keeping. */
export async function persist() {
  try {
    if (navigator.storage?.persisted && !(await navigator.storage.persisted())) await navigator.storage.persist();
  } catch {
    // Best effort.
  }
}
